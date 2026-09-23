#!/usr/bin/env bash
# fleet-mode.sh — say whether this repo's merges are gated by CI or by a local
# CI replica, and what the session should therefore do.
#
# THE PROBLEM THIS SOLVES
#   `skills/operating-a-fleet` has two modes. Which one a repo is in changed the
#   whole procedure — what authorizes a merge, what serializes it, whether work
#   is batched into waves — and the only way a machine learned which mode it was
#   in was a human saying so. A session that starts without that fact opens PRs
#   expecting a gate that will never answer, or waits for a run that was refused
#   before it started.
#
# WHERE MODE LIVES, AND WHY
#   Two facts, two different kinds of source, and conflating them is what makes
#   a marker file go stale exactly when it matters:
#
#   1. IS CI ANSWERING? Observable, and it changes without anyone editing
#      anything. So it is PROBED, never declared. The signature of a billing
#      refusal is specific and cheap to read: a workflow run that concludes
#      `failure` seconds after it started, with jobs that ran zero steps, across
#      more than one workflow. Nothing a repo's own code does looks like that.
#   2. HAS DEGRADED MODE BEEN AUTHORIZED? Not observable at all. Entering
#      degraded mode lifts branch protection, which the skill makes explicitly
#      the owner's call, in writing. So it IS declared: `.claude/fleet-mode.json`
#      in the repo, committed, which makes it remote state the whole fleet reads
#      the same way — consistent with the skill's "coordination lives on the
#      remote", unlike a gitignored dotfile on one box.
#
#   The probe is the authority on (1), so a DECLARATION THAT WENT STALE IS
#   CAUGHT rather than believed: a repo still declaring degraded while CI is
#   answering again is reported as "time to leave degraded mode", which is the
#   exact failure a marker-file-only design cannot see.
#
#   And when the probe cannot tell — no `gh`, no network, no runs to read — it
#   says so. It never guesses a mode, because a wrong confident answer here is
#   worse than no answer: it tells a session to trust a gate that is not running.
#
# COST
#   `report` is cache-first and is what the SessionStart hook calls. A warm
#   cache costs one small file read. A cold cache pays one bounded `gh api` call
#   once per repo per TTL; a soft-stale cache serves the old answer and refreshes
#   detached, so only the first session on a machine ever waits.
#
#   fleet-mode.sh probe  [--dir PATH] [--repo owner/name] [--json]
#   fleet-mode.sh report [--dir PATH] [--hook-json]
#   fleet-mode.sh status [--dir PATH]
#   fleet-mode.sh clear  [--dir PATH]
#
# Exit codes: 0 ok / 1 usage or hard error. Never non-zero for "CI is refused" —
# that is an answer, not a failure.
set -uo pipefail

PROG="$(basename "$0")"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

CACHE_DIR="${FLEET_MODE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/dotclaude/fleet-mode}"
SOFT_TTL="${FLEET_MODE_SOFT_TTL:-1800}"     # serve from cache, refresh in background
HARD_TTL="${FLEET_MODE_HARD_TTL:-14400}"    # too old to serve: re-probe in the foreground
PROBE_TIMEOUT="${FLEET_MODE_PROBE_TIMEOUT:-8}"
# Fetched wide, then windowed by EVENT below. A repo that deploys often fills
# its feed with `deployment_status` and `schedule` runs, which conclude
# `skipped` and say nothing about whether a PR can be gated — on MuscleBuddy
# they pushed every gating run past a 20-run window and the probe answered
# UNKNOWN about a question the data answered (#381).
RUNS_PER_PAGE="${FLEET_MODE_RUNS_PER_PAGE:-100}"
# How many GATING runs to classify once the feed is filtered.
RUNS_WINDOW="${FLEET_MODE_RUNS_WINDOW:-20}"

# A run that concluded `failure` within this many seconds of starting, having
# executed no steps, is not a test failure. It is the runner never being handed
# the job.
INSTANT_SECONDS="${FLEET_MODE_INSTANT_SECONDS:-20}"

die() { echo "$PROG: $*" >&2; exit 1; }
usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

# --- arguments --------------------------------------------------------------
[ $# -ge 1 ] || usage 1
ACTION="$1"; shift
DIR=""
REPO=""
AS_JSON=0
HOOK_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)       DIR="${2:-}"; shift ;;
    --repo)      REPO="${2:-}"; shift ;;
    --json)      AS_JSON=1 ;;
    --hook-json) HOOK_JSON=1 ;;
    -h|--help)   usage 0 ;;
    *)           die "unknown option '$1' (try --help)" ;;
  esac
  shift
done
case "$ACTION" in
  probe|report|status|clear) ;;
  -h|--help) usage 0 ;;
  *) die "unknown action '$ACTION' (try --help)" ;;
esac

# The repo the SESSION is in, not the one this script lives in. CLAUDE_PROJECT_DIR
# is what the harness sets; PWD is the fallback for a plain shell invocation.
[ -n "$DIR" ] || DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -d "$DIR" ] || die "not a directory: $DIR"

command -v python3 >/dev/null 2>&1 || die "python3 is required"

# --- which repo is this? ----------------------------------------------------
# Resolved from the remote, not from the directory name: a worktree, a clone
# under a different name and the main checkout must all answer the same.
resolve_repo() {
  [ -n "$REPO" ] && { printf '%s' "$REPO"; return 0; }
  local url
  url="$(git -C "$DIR" remote get-url origin 2>/dev/null)" || return 1
  [ -n "$url" ] || return 1
  url="${url%.git}"
  case "$url" in
    *github.com[:/]*) printf '%s' "${url#*github.com}" | sed 's|^[:/]||' ;;
    *) return 1 ;;
  esac
}

slug="$(resolve_repo || true)"
if [ -z "$slug" ]; then
  # Not a GitHub repo (or no origin). Nothing to probe and nothing to say — a
  # session in a scratch directory does not need a fleet banner.
  case "$ACTION" in
    status) echo "fleet-mode: $DIR has no GitHub origin — nothing to report." ;;
  esac
  exit 0
fi
cache_file="$CACHE_DIR/$(printf '%s' "$slug" | tr '/' '_').json"

repo_root="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$DIR")"
marker_file="$repo_root/.claude/fleet-mode.json"

if [ "$ACTION" = clear ]; then
  rm -f "$cache_file"
  echo "fleet-mode: cleared cache for $slug"
  exit 0
fi

# --- the probe --------------------------------------------------------------
# One API call. FLEET_MODE_RUNS_JSON substitutes a file for it, which is how the
# self-test exercises every branch without a network.
fetch_runs() {
  if [ -n "${FLEET_MODE_RUNS_JSON:-}" ]; then
    cat "$FLEET_MODE_RUNS_JSON" 2>/dev/null
    return $?
  fi
  command -v gh >/dev/null 2>&1 || return 3
  timeout "$PROBE_TIMEOUT" gh api \
    "repos/$slug/actions/runs?per_page=$RUNS_PER_PAGE" 2>/dev/null
}

# Does this checkout even declare CI? Distinguishes "no runs because there are
# no workflows" from "no runs because something is wrong".
has_workflows() {
  local f
  for f in "$repo_root"/.github/workflows/*.yml "$repo_root"/.github/workflows/*.yaml; do
    [ -e "$f" ] && return 0
  done
  return 1
}

classify() {
  local runs_json="$1" workflows="$2"
  FLEET_SLUG="$slug" FLEET_WORKFLOWS="$workflows" \
  FLEET_INSTANT="$INSTANT_SECONDS" FLEET_WINDOW="$RUNS_WINDOW" python3 -c '
import json, os, sys, time
from datetime import datetime

slug = os.environ["FLEET_SLUG"]
instant = float(os.environ["FLEET_INSTANT"])
window = int(os.environ.get("FLEET_WINDOW") or 20)
has_wf = os.environ["FLEET_WORKFLOWS"] == "1"

def ts(s):
    if not s:
        return None
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").timestamp()
    except ValueError:
        return None

raw = sys.stdin.read()
try:
    runs = (json.loads(raw) or {}).get("workflow_runs") or []
except Exception:
    runs = None

def emit(ci, reason, evidence=""):
    print(json.dumps({
        "repo": slug, "ci": ci, "reason": reason,
        "evidence": evidence, "checked_at": int(time.time()),
    }))
    sys.exit(0)

if runs is None:
    emit("unknown", "the Actions API returned something this could not parse")

if not runs:
    if has_wf:
        emit("unknown", "workflows are declared but no run has ever been recorded")
    emit("absent", "this repo declares no workflows and has no Actions runs")

# Only the events that GATE A MERGE carry information about whether CI can be
# the gate. `deployment_status`, `schedule`, `dynamic` and friends run on their
# own cadence and conclude `skipped` constantly; counting them is how a feed
# full of deploys hides a refusal (#381).
GATING_EVENTS = {"push", "pull_request", "merge_group", "workflow_dispatch"}
gating = [r for r in runs if r.get("event") in GATING_EVENTS]
# Fall back to the whole feed rather than answering "unknown" about a repo
# whose CI genuinely only runs on a schedule — a worse answer than the one the
# unfiltered feed can give.
windowed = (gating or runs)[:window]

parsed = []
for r in windowed:
    start = ts(r.get("run_started_at") or r.get("created_at"))
    end = ts(r.get("updated_at"))
    parsed.append({
        "name": r.get("name") or r.get("workflow_id"),
        "conclusion": r.get("conclusion"),
        "status": r.get("status"),
        "dur": (end - start) if (start is not None and end is not None) else None,
        "start": start or 0,
    })
parsed.sort(key=lambda p: p["start"], reverse=True)

def is_instant_fail(p):
    return p["conclusion"] == "failure" and p["dur"] is not None and p["dur"] <= instant

instant_fails = [p for p in parsed if is_instant_fail(p)]
names = {p["name"] for p in instant_fails}

def is_executing(p):
    return (p["conclusion"] == "success"
            or p["status"] in ("in_progress", "queued")
            or (p["dur"] is not None and p["dur"] > 60))

# A refusal, not a defect. Three signals together, because each alone has an
# innocent explanation: many instant failures (one flaky fast job does not
# repeat), across more than one workflow (a repo does not break every workflow
# at once), and the refusal is CURRENT (otherwise it is history). Current means
# nothing among the last few runs executed and at least one of them was
# refused. It is not "the newest run is instant": a refused many-job workflow
# can take tens of seconds to record its jobs as refused, and that one slow
# record used to veto nineteen corroborating ones (#398).
recent = parsed[:5]
if (len(instant_fails) >= 3 and len(names) >= 2
        and not any(is_executing(p) for p in recent)
        and any(is_instant_fail(p) for p in recent)):
    newest = next(p for p in recent if is_instant_fail(p))
    others = [n for n in sorted(names) if n != newest["name"]][:3]
    emit("refused",
         "Actions is refusing jobs — %d of the last %d runs failed within %ds of starting, "
         "across %d workflows" % (len(instant_fails), len(parsed), int(instant), len(names)),
         "most recent: %s%s" % (newest["name"],
                                "; also " + ", ".join(others) if others else ""))

# Actions is demonstrably executing work if anything succeeded, is still
# running, or ran long enough to have done something.
executing = [p for p in parsed if is_executing(p)]
if executing:
    emit("healthy", "Actions is running jobs normally",
         "%d of the last %d runs executed" % (len(executing), len(parsed)))

emit("unknown",
     "the last %d runs neither succeeded nor match the refusal signature" % len(parsed))
' <<<"$runs_json"
}

probe() {
  local runs rc wf=0
  has_workflows && wf=1
  runs="$(fetch_runs)"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$runs" ]; then
    local why="the Actions API could not be reached"
    [ "$rc" = 3 ] && why="the \`gh\` CLI is not installed, so CI state cannot be read"
    printf '{"repo":"%s","ci":"unknown","reason":"%s","evidence":"","checked_at":%s}\n' \
      "$slug" "$why" "$(date +%s)"
    return 0
  fi
  classify "$runs" "$wf"
}

write_cache() {
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
  # Written via a temp file in the same directory: several agent sessions start
  # at once on this box, and a half-written cache read by a sibling is a lie.
  local tmp
  tmp="$(mktemp "$cache_file.XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$cache_file" || { rm -f "$tmp"; return 1; }
}

cache_age() {
  [ -f "$cache_file" ] || { echo ""; return; }
  local mtime now
  mtime="$(date -r "$cache_file" +%s 2>/dev/null)" || { echo ""; return; }
  now="$(date +%s)"
  echo $(( now - mtime ))
}

# --- the declaration --------------------------------------------------------
read_marker() {
  [ -f "$marker_file" ] || { echo ""; return; }
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
mode = str(d.get("mode", "")).lower()
if mode not in ("normal", "degraded"):
    sys.exit(0)
ref = d.get("issue") or d.get("coordination_issue") or ""
print(json.dumps({"mode": mode, "issue": ref, "since": d.get("since", "")}))
' "$marker_file" 2>/dev/null
}

# --- can this box produce the substitute verdict? ---------------------------
# In degraded mode an `ALL GREEN @ <sha>` line from bin/ci-replica.sh is the
# ONLY artifact authorising a merge. The runner is fleet-wide and lives in
# dotclaude; the manifest is per-repo. Either half can be missing, and the
# symptom is `command not found`, which reads as "this box does not do replica
# runs" rather than "this box cannot authorise a merge right now" (#392).
replica_gate() {
  local runner="" manifest="$repo_root/.claude/ci-replica.json"
  for cand in "$HERE/ci-replica.sh" "$HOME/dotclaude/bin/ci-replica.sh" \
              "$HOME/.claude/bin/ci-replica.sh"; do
    if [ -x "$cand" ]; then runner="$cand"; break; fi
  done
  if [ -z "$runner" ]; then echo "no-runner"; return; fi
  if [ ! -f "$manifest" ]; then echo "no-manifest"; return; fi
  echo "ok"
}

# --- rendering --------------------------------------------------------------
# One place decides what a session is told, so `status`, the hook banner and the
# JSON all agree by construction.
render() {
  local verdict="$1" marker="$2"
  FLEET_VERDICT="$verdict" FLEET_MARKER="$marker" FLEET_REPO="$slug" \
  FLEET_REPLICA="$(replica_gate)" python3 -c '
import json, os

v = json.loads(os.environ["FLEET_VERDICT"])
m = os.environ["FLEET_MARKER"]
m = json.loads(m) if m.strip() else {}
repo = os.environ["FLEET_REPO"]
replica = os.environ.get("FLEET_REPLICA", "")
ci = v.get("ci", "unknown")
declared = m.get("mode", "")
issue = m.get("issue", "")
skill = "skills/operating-a-fleet (SKILL.md, then references/degraded-mode.md)"

DO_DEGRADED = (
    "What that changes, this session:\n"
    "  - Batch 3-8 related issues into ONE PR. A PR is not a unit of work here, a wave is.\n"
    "  - Validate locally: `bin/ci-replica.sh` against this repo, per its `.claude/ci-replica.json`.\n"
    "    NOT-RUN is not PASS.\n"
    "  - Take the integrator lease before building a wave: `bin/fleet-lease.sh take integrator`.\n"
    "  - Never merge without a full local verdict. `ALL GREEN @ <sha>` on the coordination issue\n"
    "    is the authorization, and it authorizes that SHA and no other.\n"
    "  - Run `bin/fleet-reconcile.sh --pr <N> --apply` after every merge.\n"
    "Read " + skill + " before acting on any of it."
)

def replica_warning():
    """Named remedy, not just a complaint — the fix is one command."""
    if replica == "no-runner":
        return (
            "⚠ THIS BOX CANNOT AUTHORISE A MERGE RIGHT NOW.\n"
            "  bin/ci-replica.sh is not on this machine, so the `ALL GREEN @ <sha>` line that\n"
            "  substitutes for CI cannot be produced here. A gate that never ran reads exactly\n"
            "  like a gate that passed — do not merge on the absence of a red check.\n"
            "  Fix: run `dotclaude-sync` on this box."
        )
    if replica == "no-manifest":
        return (
            "⚠ THIS BOX CANNOT AUTHORISE A MERGE FOR THIS REPO.\n"
            "  bin/ci-replica.sh is present, but this repo has no .claude/ci-replica.json for it\n"
            "  to execute, so there is nothing to run and no verdict to quote. A gate that never\n"
            "  ran reads exactly like a gate that passed.\n"
            "  Fix: add the manifest — see references/ci-replica-manifest.md."
        )
    return ""

lines = []
if ci == "refused" and declared == "degraded":
    lines.append("FLEET MODE: DEGRADED — %s" % repo)
    lines.append("CI is refusing jobs and degraded mode is declared for this repo%s."
                 % (" (%s)" % issue if issue else ""))
    lines.append(v.get("reason", ""))
    lines.append("")
    warn = replica_warning()
    if warn:
        lines.append(warn)
        lines.append("")
    lines.append(DO_DEGRADED)
elif ci == "refused":
    lines.append("FLEET MODE: CI IS REFUSING JOBS — %s (degraded mode NOT declared)" % repo)
    lines.append(v.get("reason", ""))
    if v.get("evidence"):
        lines.append(v["evidence"])
    lines.append("")
    lines.append(
        "There is no gate on this repo right now. A PR that shows no failing check is\n"
        "UNMEASURED, not green — do not merge on it.\n"
        "Entering degraded mode lifts branch protection, which is the call of the owner in\n"
        "writing, not something an agent decides: observe it, say so on the coordination issue, and stop.\n"
        "Until then you may still batch and validate locally (`bin/ci-replica.sh`).\n"
        "Read " + skill + "."
    )
    warn = replica_warning()
    if warn:
        lines.append("")
        lines.append(warn)
elif ci == "healthy" and declared == "degraded":
    lines.append("FLEET MODE: STALE DECLARATION — %s" % repo)
    lines.append(".claude/fleet-mode.json declares degraded, but Actions is running jobs again.")
    lines.append(v.get("evidence", ""))
    lines.append("")
    lines.append(
        "Leaving degraded mode is not automatic. Per " + skill + ", the last integrator\n"
        "says so on the coordination issue and restores the branch rules — then this file\n"
        "goes back to normal. Until it does, every session on every machine reads a mode\n"
        "this repo is no longer in."
    )
elif ci == "absent":
    lines.append("FLEET MODE: NO CI — %s" % repo)
    lines.append("This repo declares no workflows and has no Actions runs. Nothing gates a merge\n"
                 "here except what you run locally, so say what you ran in the PR body.")
elif ci == "unknown":
    lines.append("FLEET MODE: UNKNOWN — %s" % repo)
    lines.append(v.get("reason", "could not determine whether CI is answering"))
    lines.append("Treat the gate as unverified rather than assuming either mode: check the PR\n"
                 "checks by hand before merging. Re-check with `bin/fleet-mode.sh probe`.")
else:
    # healthy + normal (or undeclared): the silent case.
    pass

print("\n".join(x for x in lines if x is not None).strip())
'
}

# --- actions ----------------------------------------------------------------
marker="$(read_marker)"

case "$ACTION" in
  probe)
    verdict="$(probe)"
    write_cache "$verdict" || true
    if [ "$AS_JSON" = 1 ]; then
      printf '%s\n' "$verdict"
    else
      body="$(render "$verdict" "$marker")"
      if [ -n "$body" ]; then printf '%s\n' "$body"
      else echo "fleet-mode: $slug — CI is healthy, normal mode. (silent in a session)"; fi
    fi
    ;;

  status)
    verdict=""
    [ -f "$cache_file" ] && verdict="$(cat "$cache_file" 2>/dev/null)"
    [ -n "$verdict" ] || verdict="$(probe)"
    if [ "$AS_JSON" = 1 ]; then
      printf '%s\n' "$verdict"
    else
      body="$(render "$verdict" "$marker")"
      if [ -n "$body" ]; then printf '%s\n' "$body"
      else echo "fleet-mode: $slug — CI is healthy, normal mode. (silent in a session)"; fi
    fi
    ;;

  report)
    age="$(cache_age)"
    verdict=""
    if [ -n "$age" ] && [ "$age" -lt "$HARD_TTL" ]; then
      verdict="$(cat "$cache_file" 2>/dev/null)"
      # Soft-stale: the answer on disk is good enough to act on now, and a
      # detached refresh makes the NEXT session's answer current. Nothing waits.
      if [ -n "$verdict" ] && [ "$age" -ge "$SOFT_TTL" ] && [ -z "${FLEET_MODE_NO_REFRESH:-}" ]; then
        ( setsid "$HERE/$PROG" probe --dir "$DIR" --repo "$slug" --json \
            >/dev/null 2>&1 & ) >/dev/null 2>&1 || true
      fi
    fi
    # Cold, or past the hard TTL: a stale-enough answer is worse than the wait.
    # This is the only path that costs a session anything, and it is once per
    # repo per HARD_TTL.
    if [ -z "$verdict" ]; then
      verdict="$(probe)"
      write_cache "$verdict" || true
    fi

    body="$(render "$verdict" "$marker")"
    [ -n "$body" ] || exit 0   # healthy + normal: say nothing at all
    if [ "$HOOK_JSON" = 1 ]; then
      FLEET_BODY="$body" python3 -c '
import json, os
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": os.environ["FLEET_BODY"],
}}))
'
    else
      printf '%s\n' "$body"
    fi
    ;;
esac

exit 0
