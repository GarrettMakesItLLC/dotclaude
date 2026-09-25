#!/usr/bin/env bash
# Self-test for fleet-mode.sh.
#
# The point of the script is a VERDICT, so the test asserts verdicts against
# fixtures rather than asserting that it ran. Every branch of the matrix is
# covered — including the two that make the design defensible: a single flaky
# fast workflow must NOT read as a refusal, and a stale `degraded` declaration
# on a repo whose CI came back must be reported as stale rather than believed.
#
# No network: FLEET_MODE_RUNS_JSON substitutes a fixture for the one `gh api`
# call.  Run:  bash bin/fleet-mode.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/fleet-mode.sh"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export FLEET_MODE_CACHE_DIR="$TMP/cache"
export FLEET_MODE_NO_REFRESH=1

# A throwaway repo with a GitHub origin, standing in for the session's project.
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" remote add origin git@github.com:GarrettMakesItLLC/fixture.git

# --- fixtures ---------------------------------------------------------------
# Timestamps are generated relative to now so the fixtures never age out.
mkfixture() {
  FIX_KIND="$1" python3 -c '
import json, os, sys, time
from datetime import datetime, timezone

kind = os.environ["FIX_KIND"]

def iso(offset):
    return datetime.fromtimestamp(time.time() + offset, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def run(name, conclusion, dur, age, status="completed", event="push"):
    return {"name": name, "status": status, "conclusion": conclusion, "event": event,
            "run_started_at": iso(-age), "created_at": iso(-age),
            "updated_at": iso(-age + dur)}

runs = []
if kind == "refused":
    # 18 instant failures across many workflows, newest first by age.
    for i in range(18):
        runs.append(run("workflow-%d" % (i % 9), "failure", 2, 60 + i * 60))
    runs.append(run("workflow-0", "success", 90, 86400 * 3))
    runs.append(run("workflow-1", "success", 120, 86400 * 4))
elif kind == "healthy":
    runs.append(run("validate", "success", 70, 300))
    runs.append(run("validate", "failure", 65, 900))
    runs.append(run("commitlint", "success", 80, 1800))
elif kind == "one-flaky":
    # Same instant-failure shape, but ONE workflow. A repo with a single job
    # that fails in two seconds is a repo with a bug, not a refused runner.
    for i in range(8):
        runs.append(run("smoke", "failure", 2, 60 + i * 60))
    runs.append(run("validate", "success", 95, 400))
elif kind == "stale-history":
    # Refusals in the past, newest run executed: CI came back.
    runs.append(run("validate", "success", 88, 120))
    for i in range(6):
        runs.append(run("workflow-%d" % i, "failure", 2, 3600 + i * 60))
elif kind == "buried-refusal":
    # #381: a repo that deploys often. 25 `deployment_status` runs conclude
    # `skipped` and fill any count-based window, pushing every run that
    # actually gates a merge past it. The refusal is in the data and the probe
    # could not see it.
    for i in range(25):
        runs.append(run("Deployment status", "skipped", 1, 60 + i * 30, event="deployment_status"))
    for i in range(6):
        runs.append(run("workflow-%d" % (i % 3), "failure", 2, 3600 + i * 60))
elif kind == "slow-newest-refusal":
    # #398: 19 instant refusals across 19 workflows, and the single newest run
    # is a refused many-job workflow whose record took 42s to close. That one
    # duration must not veto the other nineteen.
    runs.append(run("Scheduled lane staleness", "failure", 42, 30))
    for i in range(19):
        runs.append(run("workflow-%d" % i, "failure", 3, 60 + i * 60))
elif kind == "single-gating-refusal":
    # #414: RedThreadEvents has exactly ONE workflow on a gating event (CI),
    # so `gating` corroboration alone can never reach >= 2 distinct names —
    # the OTHER refused workflows (OG image monitor, SEO monitor, Supabase
    # auth posture, Deploy verification) run on `schedule`, a non-gating
    # event, and sit only in the unfiltered feed.
    for i in range(4):
        runs.append(run("CI", "failure", 2, 30 + i * 60, event="push"))
    for i, wf in enumerate(["OG image monitor", "SEO monitor", "Supabase auth posture",
                            "Deploy verification"]):
        runs.append(run(wf, "failure", 3, 40 + i * 10, event="schedule"))
elif kind == "schedule-only":
    # The fallback case: a repo whose CI genuinely only runs on a schedule.
    # Filtering to zero gating runs must not make it permanently UNKNOWN.
    for i in range(4):
        runs.append(run("nightly", "success", 120, 3600 + i * 3600, event="schedule"))
elif kind == "empty":
    pass
elif kind == "garbage":
    sys.stdout.write("<html>not json</html>")
    sys.exit(0)
else:
    raise SystemExit("unknown fixture: " + kind)

print(json.dumps({"total_count": len(runs), "workflow_runs": runs}))
'
}

for k in refused healthy one-flaky stale-history buried-refusal slow-newest-refusal single-gating-refusal schedule-only empty garbage; do
  mkfixture "$k" > "$TMP/$k.json"
done

marker() {  # marker <mode|->
  mkdir -p "$REPO/.claude"
  if [ "$1" = "-" ]; then rm -f "$REPO/.claude/fleet-mode.json"
  else printf '{"mode":"%s","issue":"GarrettMakesItLLC/fixture#1"}\n' "$1" > "$REPO/.claude/fleet-mode.json"; fi
}

run_probe() { FLEET_MODE_RUNS_JSON="$TMP/$1.json" "$CLI" probe --dir "$REPO" "${@:2}"; }
run_report() { FLEET_MODE_RUNS_JSON="$TMP/$1.json" "$CLI" report --dir "$REPO" "${@:2}"; }
fresh() { rm -rf "$FLEET_MODE_CACHE_DIR"; }

want() {  # want <label> <expected-substring> <actual>
  case "$3" in
    *"$2"*) : ;;
    *) echo "FAIL ($1): expected to find '$2' in:"; echo "$3" | sed 's/^/    /'; fail=1 ;;
  esac
}
wantnot() {
  case "$3" in
    *"$2"*) echo "FAIL ($1): did NOT expect '$2' in:"; echo "$3" | sed 's/^/    /'; fail=1 ;;
    *) : ;;
  esac
}

# --- 1. CI refusing jobs, degraded mode not declared -------------------------
fresh; marker -
out="$(run_probe refused)"
want "refused/undeclared" "CI IS REFUSING JOBS" "$out"
want "refused/undeclared" "degraded mode NOT declared" "$out"
want "refused/undeclared" "UNMEASURED" "$out"
want "refused/undeclared" "skills/operating-a-fleet" "$out"

# --- 1b. A refusal buried under deploy runs is still found (#381) -----------
# The feed's newest 25 runs are `deployment_status`, which conclude `skipped`
# and fill any count-based window. Before windowing by EVENT the probe reported
# UNKNOWN here — about a question the data answers.
fresh; marker -
out="$(run_probe buried-refusal)"
want "buried-refusal" "CI IS REFUSING JOBS" "$out"
wantnot "buried-refusal" "UNKNOWN" "$out"

out="$(run_probe slow-newest-refusal)"
want "slow-newest-refusal" "CI IS REFUSING JOBS" "$out"
wantnot "slow-newest-refusal" "UNKNOWN" "$out"

# --- 1d. A single gating workflow still corroborates from the wider feed (#414)
fresh; marker -
out="$(run_probe single-gating-refusal)"
want "single-gating-refusal" "CI IS REFUSING JOBS" "$out"
wantnot "single-gating-refusal" "UNKNOWN" "$out"

# --- 1c. A repo whose CI genuinely only runs on a schedule still gets an
# answer. Filtering to zero gating runs falls back to the whole feed rather
# than answering UNKNOWN forever.
fresh; marker -
out="$(run_probe schedule-only)"
wantnot "schedule-only" "UNKNOWN" "$out"

# --- 2. CI refusing AND degraded declared: the mode is on, say what to do ----
fresh; marker degraded
out="$(run_probe refused)"
want "refused/declared" "FLEET MODE: DEGRADED" "$out"
want "refused/declared" "fleet-lease.sh take integrator" "$out"
want "refused/declared" "ci-replica.sh" "$out"
want "refused/declared" "ALL GREEN @ <sha>" "$out"
want "refused/declared" "fleet-reconcile.sh" "$out"
wantnot "refused/declared" "NOT declared" "$out"

# --- 3. Healthy CI, nothing declared: SILENT. -------------------------------
fresh; marker -
out="$(run_report healthy)"
[ -z "$out" ] || { echo "FAIL (healthy/undeclared): expected silence, got:"; echo "$out"; fail=1; }
rc=0; run_report healthy >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || { echo "FAIL (healthy/undeclared): exit $rc"; fail=1; }

# --- 4. The stale-marker case a marker-only design cannot see ---------------
fresh; marker degraded
out="$(run_probe stale-history)"
want "stale marker" "STALE DECLARATION" "$out"
want "stale marker" "Actions is running jobs again" "$out"

# --- 4b. Verdicts owed for the blind window (MuscleBuddy#8389) --------------
owed_marker() {  # owed_marker <mode> <ledger-json>
  mkdir -p "$REPO/.claude"
  printf '%s\n' "$2" > "$REPO/.claude/owed.json"
  printf '{"mode":"%s","issue":"GarrettMakesItLLC/fixture#1","owedVerdicts":".claude/owed.json"}\n' "$1" \
    > "$REPO/.claude/fleet-mode.json"
}
LEDGER='{"items":[{"id":"ios-compile","paid":null},{"id":"nightly","paid":{"at":"x"}}]}'
fresh; owed_marker degraded "$LEDGER"
out="$(run_probe stale-history)"
want "owed/stale" "STALE DECLARATION" "$out"
want "owed/stale" "1 verdict(s) owed" "$out"
want "owed/stale" "ios-compile" "$out"
wantnot "owed/stale" "nightly" "$out"
want "owed/stale" "BEFORE declaring normal" "$out"

fresh; owed_marker degraded "$LEDGER"
out="$(run_probe refused)"
want "owed/degraded" "FLEET MODE: DEGRADED" "$out"
want "owed/degraded" "ios-compile" "$out"

# Normal again with a debt outstanding is NOT the silent case.
fresh; owed_marker normal "$LEDGER"
out="$(run_report healthy)"
want "owed/normal" "VERDICTS OWED" "$out"
want "owed/normal" "ios-compile" "$out"

# Everything paid: silent again.
fresh; owed_marker normal '{"items":[{"id":"ios-compile","paid":{"at":"x"}}]}'
out="$(run_report healthy)"
[ -z "$out" ] || { echo "FAIL (owed/paid): expected silence, got:"; echo "$out"; fail=1; }

# A named ledger that cannot be read says so, never "nothing owed".
fresh; owed_marker normal '{{{ not json'
out="$(run_report healthy)"
want "owed/unreadable" "unreadable" "$out"
rm -f "$REPO/.claude/owed.json"

# --- 5. One workflow failing fast is a bug, not a refusal -------------------
fresh; marker -
out="$(run_report one-flaky)"
[ -z "$out" ] || { echo "FAIL (one-flaky): must not read as a refusal, got:"; echo "$out"; fail=1; }

# --- 6. No CI at all -> say so, do not guess a mode -------------------------
fresh; marker -
out="$(run_probe empty)"
want "no ci" "FLEET MODE: NO CI" "$out"

# --- 7. Workflows declared but no runs -> unknown, not healthy --------------
fresh
mkdir -p "$REPO/.github/workflows"; echo "name: x" > "$REPO/.github/workflows/x.yml"
out="$(run_probe empty)"
want "workflows but no runs" "FLEET MODE: UNKNOWN" "$out"
rm -rf "$REPO/.github"

# --- 8. An unreadable API response is unknown, never a guess ----------------
fresh
out="$(run_probe garbage)"
want "garbage" "FLEET MODE: UNKNOWN" "$out"
want "garbage" "Treat the gate as unverified" "$out"

# --- 8b. UNKNOWN with degraded already declared says so, not just "unverified"
# (#414): a session must not read "gate unverified" and miss that degraded
# mode is already authorized for this repo.
fresh; marker degraded
out="$(run_probe garbage)"
want "unknown/degraded" "FLEET MODE: UNKNOWN" "$out"
want "unknown/degraded" "already declares degraded mode" "$out"
want "unknown/degraded" "GarrettMakesItLLC/fixture#1" "$out"
marker -

# --- 9. The hook envelope is valid JSON and carries the banner --------------
fresh; marker -
out="$(run_report refused --hook-json)"
echo "$out" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
h = doc["hookSpecificOutput"]
assert h["hookEventName"] == "SessionStart", doc
assert "REFUSING JOBS" in h["additionalContext"], h
' || { echo "FAIL (hook-json): envelope did not carry the banner"; fail=1; }

# --- 10. The cache is what makes it fast: a warm report must not re-probe ---
fresh; marker -
run_report refused >/dev/null
out="$(FLEET_MODE_RUNS_JSON="$TMP/does-not-exist.json" "$CLI" report --dir "$REPO")"
want "warm cache" "CI IS REFUSING JOBS" "$out"

# --- 11. A corrupt cache must not crash or lie ------------------------------
printf 'not json' > "$FLEET_MODE_CACHE_DIR/GarrettMakesItLLC_fixture.json"
rc=0; out="$(FLEET_MODE_RUNS_JSON="$TMP/healthy.json" "$CLI" report --dir "$REPO" 2>/dev/null)" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL (corrupt cache): exit $rc"; fail=1; }
wantnot "corrupt cache" "REFUSING" "$out"

# --- 12. A corrupt declaration is ignored, not obeyed -----------------------
fresh
mkdir -p "$REPO/.claude"; printf '{{{ not json' > "$REPO/.claude/fleet-mode.json"
rc=0; out="$(run_report healthy 2>/dev/null)" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL (corrupt marker): exit $rc"; fail=1; }
[ -z "$out" ] || { echo "FAIL (corrupt marker): expected silence, got: $out"; fail=1; }
marker -

# --- 13. No GitHub origin -> nothing to say, and no error -------------------
BARE="$TMP/bare"; mkdir -p "$BARE"; git -C "$BARE" init -q
rc=0; out="$("$CLI" report --dir "$BARE" 2>/dev/null)" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL (no origin): exit $rc"; fail=1; }
[ -z "$out" ] || { echo "FAIL (no origin): expected silence, got: $out"; fail=1; }

# --- 14. A worktree answers for ITS repo, not for the checkout it was cut from
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPO" worktree add -q "$TMP/wt" -b wt-branch 2>/dev/null
fresh; marker -
out="$(FLEET_MODE_RUNS_JSON="$TMP/refused.json" "$CLI" probe --dir "$TMP/wt")"
want "worktree" "GarrettMakesItLLC/fixture" "$out"

if [ "$fail" = 0 ]; then
  echo "fleet-mode: all cases passed"
fi
exit "$fail"
