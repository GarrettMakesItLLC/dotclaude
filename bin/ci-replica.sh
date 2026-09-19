#!/usr/bin/env bash
# ci-replica.sh — run a repo's CI locally from a declarative manifest.
#
# Why declarative: an agent reading ci.yml and improvising the equivalent is not
# a gate. Two validators did that on one tree and disagreed about what counted —
# both reported green, each having skipped a different job. A gate two people
# read differently measures nothing. So the jobs live in a committed file,
# `.claude/ci-replica.json`, and this script is the only interpreter.
#
# Guarantees this script makes, each of which has been a real failure somewhere:
#   - exit codes are the command's own; nothing is ever piped into anything
#   - a job that CANNOT run here (macOS, CodeQL) reports NOT-RUN, never PASS
#   - NOT-RUN is called out in the summary, so a green-looking table cannot be
#     mistaken for coverage it does not have
#   - variables named in `unset` are removed from the child environment, because
#     a bash layer re-sourcing a profile is how a run gets pointed at the wrong
#     database and passes about the wrong thing
#
#   ci-replica.sh [--manifest PATH] [--job NAME]... [--data-plane] [--list]
#                 [--log-dir DIR] [--repo-root DIR]
#
# Exit 0 when no job FAILed, 1 when any did, 2 on a bad manifest or usage.
set -uo pipefail

PROG="$(basename "$0")"
MANIFEST=""
LOG_DIR=""
ROOT=""
DATA_PLANE=0
LIST_ONLY=0
SELECTED=()

die() { echo "$PROG: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)  MANIFEST="${2:-}"; shift 2 || die "--manifest needs a path" ;;
    --job)       SELECTED+=("${2:-}"); shift 2 || die "--job needs a name" ;;
    --log-dir)   LOG_DIR="${2:-}"; shift 2 || die "--log-dir needs a path" ;;
    --repo-root) ROOT="${2:-}"; shift 2 || die "--repo-root needs a path" ;;
    --data-plane) DATA_PLANE=1; shift ;;
    --list)      LIST_ONLY=1; shift ;;
    -h|--help)   sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "not in a git repository; pass --repo-root"
fi
[ -d "$ROOT" ] || die "repo root '$ROOT' is not a directory"
[ -n "$MANIFEST" ] || MANIFEST="$ROOT/.claude/ci-replica.json"
[ -f "$MANIFEST" ] || die "no manifest at $MANIFEST (see skills/operating-a-fleet/references/ci-replica-manifest.md)"
command -v python3 >/dev/null 2>&1 || die "python3 is required to read the manifest"

PLAN="$(mktemp -d)"
trap 'rm -rf "$PLAN"' EXIT

# Expand the manifest into one directory per job: .meta (key=value), .cmds (one
# command per line), .env (KEY=VALUE), .unset (one name per line). Passing the
# plan through files instead of shell variables keeps quoting out of the picture
# entirely — a command with quotes, $ or & in it survives byte-for-byte.
MANIFEST="$MANIFEST" PLAN="$PLAN" python3 <<'PY'
import json, os, re, sys

manifest_path = os.environ["MANIFEST"]
plan = os.environ["PLAN"]

def bail(msg):
    print(f"ci-replica: {manifest_path}: {msg}", file=sys.stderr)
    sys.exit(2)

try:
    with open(manifest_path) as fh:
        m = json.load(fh)
except Exception as exc:
    bail(f"is not readable JSON: {exc}")

if not isinstance(m, dict):
    bail("top level must be an object")
if m.get("version") != 1:
    bail(f"unsupported version {m.get('version')!r}; this script speaks version 1")

jobs = m.get("jobs")
if not isinstance(jobs, list) or not jobs:
    bail("`jobs` must be a non-empty array")

global_env = m.get("env") or {}
global_unset = m.get("unset") or []
if not isinstance(global_env, dict):
    bail("top-level `env` must be an object")
if not isinstance(global_unset, list):
    bail("top-level `unset` must be an array")

with open(os.path.join(plan, "log-dir"), "w") as fh:
    fh.write(str(m.get("logDir") or ".ci-replica"))

names = []
order = []
for i, job in enumerate(jobs):
    if not isinstance(job, dict):
        bail(f"jobs[{i}] must be an object")
    name = job.get("name")
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", name or ""):
        bail(f"jobs[{i}].name must be a [A-Za-z0-9._-] string, got {name!r}")
    if name in names:
        bail(f"duplicate job name {name!r}")
    names.append(name)

    cmds = job.get("commands")
    if not isinstance(cmds, list):
        bail(f"job {name}: `commands` must be an array")
    runnable = job.get("local", True) is not False
    if runnable and not cmds:
        bail(f"job {name}: has no commands; mark it \"local\": false if it cannot run here")
    for c in cmds:
        if not isinstance(c, str) or not c.strip():
            bail(f"job {name}: every command must be a non-empty string")
        if "\n" in c:
            bail(f"job {name}: a command may not contain a newline — put the sequence in a repo script")

    local_reason = job.get("localReason") or ""
    if not runnable and not local_reason:
        bail(f"job {name}: \"local\": false requires `localReason` saying why and where it IS verified")
    needs_dp = bool(job.get("needsDataPlane"))
    dp_reason = job.get("dataPlaneReason") or ""
    if needs_dp and not dp_reason:
        bail(f"job {name}: `needsDataPlane` requires `dataPlaneReason`")

    budget = job.get("budgetSeconds", 0)
    if not isinstance(budget, int) or isinstance(budget, bool) or budget < 0:
        bail(f"job {name}: `budgetSeconds` must be a non-negative integer")

    job_env = job.get("env") or {}
    job_unset = job.get("unset") or []
    if not isinstance(job_env, dict):
        bail(f"job {name}: `env` must be an object")
    if not isinstance(job_unset, list):
        bail(f"job {name}: `unset` must be an array")

    d = os.path.join(plan, "jobs", f"{i:03d}")
    os.makedirs(d)
    order.append(f"{i:03d}\t{name}")
    with open(os.path.join(d, "meta"), "w") as fh:
        fh.write(f"name={name}\n")
        fh.write(f"local={'1' if runnable else '0'}\n")
        fh.write(f"local_reason={local_reason}\n")
        fh.write(f"needs_data_plane={'1' if needs_dp else '0'}\n")
        fh.write(f"data_plane_reason={dp_reason}\n")
        fh.write(f"budget={budget}\n")
    with open(os.path.join(d, "cmds"), "w") as fh:
        fh.write("".join(c + "\n" for c in cmds))
    merged = dict(global_env)
    merged.update(job_env)
    with open(os.path.join(d, "env"), "w") as fh:
        for k, v in merged.items():
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", str(k)):
                bail(f"job {name}: {k!r} is not a valid environment variable name")
            if "\n" in str(v):
                bail(f"job {name}: env {k} value may not contain a newline")
            fh.write(f"{k}={v}\n")
    with open(os.path.join(d, "unset"), "w") as fh:
        for k in list(global_unset) + list(job_unset):
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", str(k)):
                bail(f"job {name}: cannot unset {k!r} — not a valid variable name")
            fh.write(f"{k}\n")

with open(os.path.join(plan, "order"), "w") as fh:
    fh.write("\n".join(order) + "\n")
PY
[ $? -eq 0 ] || exit 2

[ -n "$LOG_DIR" ] || LOG_DIR="$ROOT/$(cat "$PLAN/log-dir")"
mkdir -p "$LOG_DIR" || die "cannot create log dir $LOG_DIR"

meta_get() { sed -n "s/^$2=//p" "$1/meta" | head -1; }

selected_wanted() {
  [ ${#SELECTED[@]} -eq 0 ] && return 0
  local want
  for want in "${SELECTED[@]}"; do [ "$want" = "$1" ] && return 0; done
  return 1
}

# Validate --job names against the manifest up front: a typo would otherwise run
# nothing and report an all-green empty table.
if [ ${#SELECTED[@]} -gt 0 ]; then
  for want in "${SELECTED[@]}"; do
    grep -q "	$want\$" "$PLAN/order" || die "no job named '$want' in $MANIFEST"
  done
fi

if [ "$LIST_ONLY" = 1 ]; then
  printf '%-24s %-9s %s\n' JOB RUNS-HERE NOTE
  while IFS="	" read -r idx name; do
    d="$PLAN/jobs/$idx"
    if [ "$(meta_get "$d" local)" = 0 ]; then
      printf '%-24s %-9s %s\n' "$name" "no" "$(meta_get "$d" local_reason)"
    elif [ "$(meta_get "$d" needs_data_plane)" = 1 ]; then
      printf '%-24s %-9s %s\n' "$name" "--data-plane" "$(meta_get "$d" data_plane_reason)"
    else
      printf '%-24s %-9s %s\n' "$name" "yes" "$(wc -l < "$d/cmds" | tr -d ' ') command(s)"
    fi
  done < "$PLAN/order"
  exit 0
fi

echo "ci-replica: $MANIFEST"
echo "            root=$ROOT logs=$LOG_DIR"
echo ""

RESULTS="$PLAN/results"
: > "$RESULTS"
any_fail=0

while IFS="	" read -r idx name; do
  selected_wanted "$name" || continue
  d="$PLAN/jobs/$idx"
  log="$LOG_DIR/$name.log"
  budget="$(meta_get "$d" budget)"

  if [ "$(meta_get "$d" local)" = 0 ]; then
    printf 'NOT-RUN  %-22s %s\n' "$name" "$(meta_get "$d" local_reason)"
    printf 'NOT-RUN\t%s\t0\t%s\n' "$name" "$(meta_get "$d" local_reason)" >> "$RESULTS"
    continue
  fi
  if [ "$(meta_get "$d" needs_data_plane)" = 1 ] && [ "$DATA_PLANE" != 1 ]; then
    printf 'NOT-RUN  %-22s needs a data plane; re-run with --data-plane (%s)\n' \
      "$name" "$(meta_get "$d" data_plane_reason)"
    printf 'NOT-RUN\t%s\t0\tneeds --data-plane: %s\n' "$name" "$(meta_get "$d" data_plane_reason)" >> "$RESULTS"
    continue
  fi

  # env -u for each unset, then KEY=VALUE for each set. `env` is what actually
  # removes a variable from the child: exporting an empty string is a different
  # thing and several checks cannot tell the difference.
  envargs=()
  while IFS= read -r k; do [ -n "$k" ] && envargs+=("-u" "$k"); done < "$d/unset"
  while IFS= read -r kv; do [ -n "$kv" ] && envargs+=("$kv"); done < "$d/env"

  echo "==> $name"
  {
    echo "### ci-replica job: $name"
    echo "### root: $ROOT"
    echo "### started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$log"

  started=$(date +%s)
  rc=0
  failed_cmd=""
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    echo "    \$ $cmd"
    {
      echo ""
      echo "### \$ $cmd"
    } >> "$log"
    # Bare invocation with a redirect, never a pipe: a pipe would report the
    # LAST stage's status and an OOM-killed command reads as a pass.
    ( cd "$ROOT" && env "${envargs[@]}" bash -c "$cmd" ) >> "$log" 2>&1
    rc=$?
    echo "### exit: $rc" >> "$log"
    if [ "$rc" -ne 0 ]; then failed_cmd="$cmd"; break; fi
  done < "$d/cmds"
  elapsed=$(( $(date +%s) - started ))

  if [ "$rc" -eq 0 ]; then
    flag=""
    if [ "$budget" -gt 0 ] && [ "$elapsed" -gt "$budget" ]; then
      flag=" [over budget: ${elapsed}s > ${budget}s]"
    fi
    printf 'PASS     %-22s %ss%s\n' "$name" "$elapsed" "$flag"
    printf 'PASS\t%s\t%s\t%s\n' "$name" "$elapsed" "${flag# }" >> "$RESULTS"
  else
    any_fail=1
    printf 'FAIL     %-22s %ss  exit %s  %s\n' "$name" "$elapsed" "$rc" "$failed_cmd"
    printf 'FAIL\t%s\t%s\texit %s on: %s (log: %s)\n' "$name" "$elapsed" "$rc" "$failed_cmd" "$log" >> "$RESULTS"
  fi
done < "$PLAN/order"

echo ""
echo "──────────────────────────────────────────────────────────────"
printf '%-9s %-24s %-8s %s\n' RESULT JOB SECONDS DETAIL
while IFS="	" read -r status name secs detail; do
  printf '%-9s %-24s %-8s %s\n' "$status" "$name" "$secs" "$detail"
done < "$RESULTS"
echo "──────────────────────────────────────────────────────────────"

pass=$(grep -c '^PASS'    "$RESULTS" || true)
failn=$(grep -c '^FAIL'   "$RESULTS" || true)
notrun=$(grep -c '^NOT-RUN' "$RESULTS" || true)
echo "$pass passed, $failn failed, $notrun not run.  Logs: $LOG_DIR"
if [ "$notrun" -gt 0 ]; then
  echo ""
  echo "NOT-RUN is not PASS. $notrun job(s) above were not measured here — carry them"
  echo "into the run report on the coordination issue rather than implying coverage."
fi
if [ "$failn" -gt 0 ]; then
  echo ""
  echo "Re-run one job alone with --job <name>. A job over budget only in-suite is"
  echo "contention from sibling agents; over budget when run alone is structural."
fi
exit "$any_fail"
