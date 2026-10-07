#!/usr/bin/env bash
# Self-test for fleet-mode-report.sh. Asserts the two things a SessionStart hook
# has to get right — it is SILENT in normal mode, and it ALWAYS exits 0 however
# broken the environment underneath it is — plus that a degraded repo actually
# produces a valid envelope. The verdict logic itself is covered by
# bin/fleet-mode.test.sh; this covers the wiring.
#
# Run:  bash hooks/fleet-mode-report.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/fleet-mode-report.sh"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export FLEET_MODE_CACHE_DIR="$TMP/cache"
export FLEET_MODE_NO_REFRESH=1
# The registry banner reads ~/.npmrc; keep the machine's real switch out of it.
export DEGRADED_REGISTRY_NPMRC="$TMP/npmrc"
export GMI_REGISTRY_STATE="$TMP/registry-state" GMI_REGISTRY_HOME="$TMP/registry-store"

REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" remote add origin git@github.com:GarrettMakesItLLC/fixture.git

fixture() {  # fixture <kind> -> path to a runs JSON
  FIX="$1" python3 -c '
import json, os, time
from datetime import datetime, timezone
def iso(o): return datetime.fromtimestamp(time.time()+o, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def run(n, c, d, a): return {"name": n, "status": "completed", "conclusion": c,
                             "run_started_at": iso(-a), "created_at": iso(-a), "updated_at": iso(-a+d)}
kind = os.environ["FIX"]
runs = ([run("wf-%d" % (i % 7), "failure", 2, 60+i*60) for i in range(15)]
        if kind == "refused" else [run("validate", "success", 75, 120)])
print(json.dumps({"workflow_runs": runs}))
'
}
fixture refused > "$TMP/refused.json"
fixture healthy > "$TMP/healthy.json"

run_hook() { CLAUDE_PROJECT_DIR="$REPO" FLEET_MODE_RUNS_JSON="$1" "$HOOK" 2>/dev/null; }
rc_of() { CLAUDE_PROJECT_DIR="$REPO" FLEET_MODE_RUNS_JSON="$1" "$HOOK" >/dev/null 2>&1; echo $?; }

# --- Normal mode: silent. A banner every session is a banner that gets
#     disabled, so this is the case that matters most. ---
rm -rf "$FLEET_MODE_CACHE_DIR"
out="$(run_hook "$TMP/healthy.json")"
[ -z "$out" ] || { echo "FAIL (healthy): expected silence, got: $out"; fail=1; }
[ "$(rc_of "$TMP/healthy.json")" = 0 ] || { echo "FAIL (healthy): non-zero exit"; fail=1; }

# --- Degraded/refused: a parseable SessionStart envelope that names the repo
#     and points at the skill. ---
rm -rf "$FLEET_MODE_CACHE_DIR"
out="$(run_hook "$TMP/refused.json")"
[ -n "$out" ] || { echo "FAIL (refused): expected output"; fail=1; }
echo "$out" | python3 -c '
import json, sys
h = json.load(sys.stdin)["hookSpecificOutput"]
ctx = h["additionalContext"]
assert h["hookEventName"] == "SessionStart", h
assert "GarrettMakesItLLC/fixture" in ctx, ctx
assert "operating-a-fleet" in ctx, ctx
' || { echo "FAIL (refused): envelope did not carry the banner"; fail=1; }

# --- A warm cache is the steady state, and it must cost no network. Point the
#     fixture at nothing and the hook still answers. ---
out="$(run_hook "$TMP/absent.json")"
case "$out" in *REFUSING*) : ;; *) echo "FAIL (warm cache): lost the cached verdict"; fail=1 ;; esac

# --- The CLI being absent (a partial checkout) must fail open. ---
FAKE="$TMP/fakehooks"; mkdir -p "$FAKE"
cp "$HOOK" "$FAKE/fleet-mode-report.sh"
rc=0; CLAUDE_PROJECT_DIR="$REPO" "$FAKE/fleet-mode-report.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || { echo "FAIL (no CLI alongside): exit $rc"; fail=1; }

# --- A session in a directory that is not a repo at all. ---
rc=0; out="$(CLAUDE_PROJECT_DIR="$TMP" "$HOOK" 2>/dev/null)" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL (non-repo cwd): exit $rc"; fail=1; }
[ -z "$out" ] || { echo "FAIL (non-repo cwd): expected silence, got: $out"; fail=1; }

# --- A killed fleet-merge.sh's orphaned lift is reported, in normal mode too,
#     and a live pid's record is not. ---
STATE="$TMP/merge-state"; mkdir -p "$STATE/o-r"
jq -n '{repo:"o/r",source:"Organization",id:22,pid:999999,pr:7,ts:"2026-09-30T00:00:00Z",before:[]}' > "$STATE/o-r/org-22.json"
rm -rf "$FLEET_MODE_CACHE_DIR"
out="$(FLEET_MERGE_STATE_DIR="$STATE" run_hook "$TMP/healthy.json")"
echo "$out" | python3 -c '
import json, sys
ctx = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
assert "o/r Organization ruleset 22 still LIFTED" in ctx, ctx
assert "--restore-pending" in ctx, ctx
' || { echo "FAIL (pending lift): not reported in normal mode: $out"; fail=1; }
rm -rf "$FLEET_MODE_CACHE_DIR"
out="$(FLEET_MERGE_STATE_DIR="$STATE" run_hook "$TMP/refused.json")"
echo "$out" | python3 -c '
import json, sys
ctx = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
assert "ruleset 22 still LIFTED" in ctx and "operating-a-fleet" in ctx, ctx
' || { echo "FAIL (pending lift + degraded): banners not combined"; fail=1; }
jq -n --argjson pid "$$" '{repo:"o/r",source:"Organization",id:22,pid:$pid,pr:7,ts:"now",before:[]}' > "$STATE/o-r/org-22.json"
rm -rf "$FLEET_MODE_CACHE_DIR"
out="$(FLEET_MERGE_STATE_DIR="$STATE" run_hook "$TMP/healthy.json")"
[ -z "$out" ] || { echo "FAIL (live lift): a merge in flight was reported: $out"; fail=1; }

# --- The degraded npm registry switch is reported in normal mode too, merged
#     with the mode banner when there is one. Port 9 answers nothing, so the
#     banner must say BROKEN rather than claim a mirror is serving. ---
printf '%s\n' '# >>> dotclaude degraded-registry (bin/degraded-registry.sh off removes this) >>>' \
  'registry=http://127.0.0.1:9/' '# <<< dotclaude degraded-registry <<<' > "$DEGRADED_REGISTRY_NPMRC"
rm -rf "$FLEET_MODE_CACHE_DIR"
out="$(GMI_REGISTRY_PORT=9 PATH="/usr/bin:/bin" run_hook "$TMP/healthy.json")"
echo "$out" | python3 -c '
import json, sys
ctx = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
assert "DEGRADED REGISTRY BROKEN" in ctx, ctx
' || { echo "FAIL (registry on): not reported: $out"; fail=1; }
rm -rf "$FLEET_MODE_CACHE_DIR"
out="$(GMI_REGISTRY_PORT=9 PATH="/usr/bin:/bin" run_hook "$TMP/refused.json")"
echo "$out" | python3 -c '
import json, sys
ctx = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
assert "DEGRADED REGISTRY" in ctx and "operating-a-fleet" in ctx, ctx
' || { echo "FAIL (registry on + degraded): banners not combined"; fail=1; }
rm -f "$DEGRADED_REGISTRY_NPMRC"

if [ "$fail" = 0 ]; then
  echo "fleet-mode-report: all cases passed"
fi
exit "$fail"
