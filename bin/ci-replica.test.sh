#!/usr/bin/env bash
# Self-test for ci-replica.sh. Builds throwaway manifests in a temp repo and
# asserts the properties the gate depends on: real exit codes, NOT-RUN never
# reading as PASS, `unset` actually removing a variable from the child, logs
# written per job, and a malformed manifest refused rather than half-run.
#   bash bin/ci-replica.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CIR="$HERE/ci-replica.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

ROOT="$TMP/repo"
mkdir -p "$ROOT/.claude"
git init --quiet "$ROOT"

# manifest-json -> OUT / RC
run() {
  local manifest="$1"; shift
  printf '%s' "$manifest" > "$ROOT/.claude/ci-replica.json"
  OUT="$("$CIR" --repo-root "$ROOT" --log-dir "$TMP/logs" "$@" 2>&1)"; RC=$?
}

echo "ci-replica: exit codes are the command's own"
run '{"version":1,"jobs":[
  {"name":"green","commands":["true","echo hello"]},
  {"name":"red","commands":["exit 7"]}
]}'
[ "$RC" = 1 ] && ok "a failing job makes the run exit 1" || bad "expected rc=1, got $RC: $OUT"
grep -q 'PASS.*green' <<<"$OUT" && ok "the passing job reads PASS" || bad "no PASS row: $OUT"
grep -q 'FAIL.*red' <<<"$OUT"   && ok "the failing job reads FAIL" || bad "no FAIL row: $OUT"
grep -q 'exit 7' <<<"$OUT"      && ok "the real exit code is reported, not a pipe's" || bad "exit code lost: $OUT"

echo "ci-replica: a command that would read clean behind a pipe"
# `false | tail -1` exits 0. Run bare, it must fail.
run '{"version":1,"jobs":[{"name":"oomish","commands":["false"]}]}'
[ "$RC" = 1 ] && ok "a bare failing command is not masked" || bad "masked failure: rc=$RC $OUT"

echo "ci-replica: remaining commands in a job are skipped after a failure"
run '{"version":1,"jobs":[{"name":"chain","commands":["exit 3","touch '"$TMP"'/should-not-exist"]}]}'
[ -e "$TMP/should-not-exist" ] && bad "ran a command after a failure" || ok "stops the job at the first failure"

echo "ci-replica: NOT-RUN is never PASS"
run '{"version":1,"jobs":[
  {"name":"ok","commands":["true"]},
  {"name":"macos","local":false,"localReason":"macOS runner only","commands":[]}
]}'
[ "$RC" = 0 ] && ok "a NOT-RUN job does not fail the run" || bad "rc=$RC: $OUT"
grep -q 'NOT-RUN.*macos' <<<"$OUT" && ok "the unrunnable job reads NOT-RUN" || bad "no NOT-RUN row: $OUT"
grep -q 'macOS runner only' <<<"$OUT" && ok "its reason is printed" || bad "reason not printed: $OUT"
grep -q 'NOT-RUN is not PASS' <<<"$OUT" \
  && ok "the summary says NOT-RUN is not coverage" || bad "silent hole in the gate: $OUT"

echo "ci-replica: data-plane jobs are opt-in"
DP='{"version":1,"jobs":[{"name":"e2e","needsDataPlane":true,"dataPlaneReason":"truncates the shared branch","commands":["touch '"$TMP"'/dp-ran"]}]}'
run "$DP"
[ -e "$TMP/dp-ran" ] && bad "ran a data-plane job without --data-plane" || ok "skipped without --data-plane"
grep -q 'NOT-RUN' <<<"$OUT" && ok "and reports it NOT-RUN" || bad "silently skipped: $OUT"
run "$DP" --data-plane
[ -e "$TMP/dp-ran" ] && ok "--data-plane runs it" || bad "--data-plane did not run it: $OUT"

echo "ci-replica: env and unset reach the child"
export CIR_TEST_LEAK="ambient"
run '{"version":1,"env":{"CIR_TEST_SET":"from-manifest"},"unset":["CIR_TEST_LEAK"],"jobs":[
  {"name":"envcheck","commands":["test \"$CIR_TEST_SET\" = from-manifest","test -z \"${CIR_TEST_LEAK-}\""]}
]}'
[ "$RC" = 0 ] && ok "env is set and unset is removed in the child" || bad "env handling: rc=$RC $OUT"
run '{"version":1,"env":{"A":"global"},"jobs":[
  {"name":"override","env":{"A":"job"},"commands":["test \"$A\" = job"]}
]}'
[ "$RC" = 0 ] && ok "a job-level env value wins over the global one" || bad "override: rc=$RC $OUT"

echo "ci-replica: logs"
run '{"version":1,"jobs":[{"name":"logged","commands":["echo marker-in-log"]}]}'
[ -f "$TMP/logs/logged.log" ] && ok "a per-job log is written" || bad "no log file"
grep -q 'marker-in-log' "$TMP/logs/logged.log" 2>/dev/null && ok "the log holds the command output" || bad "output not captured"
grep -q '### exit: 0' "$TMP/logs/logged.log" 2>/dev/null && ok "the log records the exit code" || bad "exit code not logged"

echo "ci-replica: budget flag"
run '{"version":1,"jobs":[{"name":"slow","budgetSeconds":0,"commands":["true"]},{"name":"tight","budgetSeconds":1,"commands":["sleep 2"]}]}'
grep -q 'over budget' <<<"$OUT" && ok "an over-budget job is flagged" || bad "no budget flag: $OUT"
grep -q 'PASS.*tight' <<<"$OUT" && ok "over budget is still a PASS, not a FAIL" || bad "budget turned into a failure: $OUT"
grep -q 'contention' <<<"$OUT" && bad "the discriminator hint should only print when something failed" \
  || ok "no discriminator hint on an all-green run"
run '{"version":1,"jobs":[{"name":"broken","commands":["exit 4"]}]}'
grep -q 'contention' <<<"$OUT" \
  && ok "on a failure it prints the alone-vs-in-suite discriminator" || bad "no discriminator on failure: $OUT"

echo "ci-replica: selection"
run '{"version":1,"jobs":[{"name":"a","commands":["touch '"$TMP"'/sel-a"]},{"name":"b","commands":["touch '"$TMP"'/sel-b"]}]}' --job b
[ -e "$TMP/sel-b" ] && [ ! -e "$TMP/sel-a" ] && ok "--job runs only the named job" || bad "selection wrong: $OUT"
run '{"version":1,"jobs":[{"name":"a","commands":["true"]}]}' --job typo
[ "$RC" = 2 ] && ok "an unknown --job is refused, not silently an empty green run" || bad "typo accepted: rc=$RC $OUT"

echo "ci-replica: --list"
run '{"version":1,"jobs":[{"name":"a","commands":["false"]},{"name":"m","local":false,"localReason":"macOS","commands":[]}]}' --list
[ "$RC" = 0 ] && ok "--list exits 0" || bad "--list rc=$RC"
grep -q 'RUNS-HERE' <<<"$OUT" && ok "--list prints the runs-here column" || bad "no table: $OUT"

echo "ci-replica: a malformed manifest is refused, not half-run"
for bad_manifest in \
  '{"version":2,"jobs":[{"name":"a","commands":["true"]}]}' \
  '{"version":1}' \
  '{"version":1,"jobs":[]}' \
  '{"version":1,"jobs":[{"name":"a b","commands":["true"]}]}' \
  '{"version":1,"jobs":[{"name":"a","commands":["true"]},{"name":"a","commands":["true"]}]}' \
  '{"version":1,"jobs":[{"name":"a","commands":["echo one\necho two"]}]}' \
  '{"version":1,"jobs":[{"name":"a","local":false,"commands":[]}]}' \
  '{"version":1,"jobs":[{"name":"a","needsDataPlane":true,"commands":["true"]}]}' \
  '{"version":1,"jobs":[{"name":"a","commands":[]}]}' \
  'not json at all'
do
  run "$bad_manifest"
  [ "$RC" = 2 ] || bad "expected rc=2 for manifest: $bad_manifest (got $RC: $OUT)"
done
ok "every malformed manifest exits 2"

run '{"version":1,"jobs":[{"name":"a","commands":["true"]}]}' --manifest "$TMP/nope.json"
[ "$RC" = 2 ] && ok "a missing manifest exits 2 and says where the schema is" || bad "missing manifest: rc=$RC"
grep -q 'ci-replica-manifest' <<<"$OUT" && ok "and points at the schema doc" || bad "no pointer: $OUT"

echo "ci-replica: the shipped example manifest is valid"
EXAMPLE="$(cd "$HERE/.." && pwd)/skills/operating-a-fleet/references/ci-replica.example.json"
if [ -f "$EXAMPLE" ]; then
  OUT="$("$CIR" --repo-root "$ROOT" --manifest "$EXAMPLE" --list 2>&1)"; RC=$?
  [ "$RC" = 0 ] && ok "the documented example loads" || bad "example manifest rejected: $OUT"
  grep -q 'ios-simulator' <<<"$OUT" && ok "and declares its unrunnable jobs" || bad "example missing local:false jobs"
else
  bad "example manifest not found at $EXAMPLE"
fi

[ "$fail" = 0 ] && echo "ci-replica: all cases passed"
exit "$fail"
