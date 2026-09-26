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

echo "ci-replica: a --job run names every job it left out"
run '{"version":1,"jobs":[{"name":"a","commands":["true"]},{"name":"b","commands":["true"]},{"name":"c","commands":["true"]}]}' --job b
grep -q 'NOT-RUN.*a .*not selected' <<<"$OUT" && grep -q 'NOT-RUN.*c .*not selected' <<<"$OUT" \
  && ok "deselected jobs read NOT-RUN (not selected)" || bad "deselected jobs silent: $OUT"
grep -q '1 passed, 0 failed, 2 not run' <<<"$OUT" \
  && ok "and are counted, so the summary cannot read as a whole run" || bad "summary miscounts: $OUT"
grep -q 'NOT-RUN is not PASS' <<<"$OUT" && ok "the NOT-RUN banner fires for a partial run" || bad "no banner: $OUT"

echo "ci-replica: every run writes verdict.json"
V="$TMP/logs/verdict.json"
[ -f "$V" ] && ok "verdict.json is written" || bad "no verdict at $V: $OUT"
[ "$(jq -r .full "$V")" = false ] && ok "a --job run is recorded as full=false" || bad "partial run marked full: $(cat "$V")"
run '{"version":1,"jobs":[{"name":"a","commands":["true"]},{"name":"r","commands":["exit 4"]},{"name":"m","local":false,"localReason":"mac","commands":[]}]}'
[ "$(jq -r .full "$V")" = true ] && ok "a run with no --job is full=true" || bad "full run not marked: $(cat "$V")"
[ "$(jq -r .exit "$V")" = 1 ] && ok "a failing run records exit 1" || bad "exit not recorded: $(cat "$V")"
[ "$(jq -r '[.jobs[]|.name+":"+.result]|join(",")' "$V")" = "a:PASS,r:FAIL,m:NOT-RUN" ] \
  && ok "each job's result is recorded in manifest order" || bad "jobs wrong: $(cat "$V")"
[ "$(jq -r '.jobs[2].local' "$V")" = false ] && ok "a job's local flag rides along" || bad "local flag missing"
[ "$(jq -r .manifestSha256 "$V")" = "$(sha256sum "$ROOT/.claude/ci-replica.json" | cut -d' ' -f1)" ] \
  && ok "the manifest's sha256 is recorded" || bad "manifest hash wrong"
grep -q "verdict: $V  sha256=" <<<"$OUT" && ok "the run prints the verdict path and its hash" || bad "verdict not announced: $OUT"

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

echo "ci-replica: a job that changes the tree the next job measures"
# Every job runs against ONE working tree in sequence, so an undeclared write
# silently changes what every later job reads. CI cannot see this class at all:
# it gives each job its own checkout.
( cd "$ROOT" && echo base > tracked.txt && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm fixture )

run '{"version":1,"jobs":[
  {"name":"clean","commands":["true"]},
  {"name":"dirties","commands":["echo changed > tracked.txt"]}
]}'
[ "$RC" = 1 ] && ok "an undeclared write fails the run" || bad "expected rc=1, got $RC: $OUT"
grep -q 'tree-guard' <<<"$OUT"  && ok "and says tree-guard" || bad "no tree-guard row: $OUT"
grep -q 'tracked.txt' <<<"$OUT" && ok "and names the file it changed" || bad "file not named: $OUT"
grep -q 'PASS.*clean' <<<"$OUT" && ok "the job before it still reads PASS" || bad "clean job lost: $OUT"
( cd "$ROOT" && git checkout -q -- tracked.txt )

run '{"version":1,"jobs":[
  {"name":"declared","commands":["echo changed > tracked.txt"],"mutatesTree":["tracked.txt"]}
]}'
[ "$RC" = 0 ] && ok "a DECLARED write passes" || bad "declared write rejected: $OUT"
( cd "$ROOT" && git checkout -q -- tracked.txt )

# A new directory: `git status --porcelain` collapses it to `gen/` unless
# -uall is passed, and then no file-level pattern can ever match it.
run '{"version":1,"jobs":[
  {"name":"newdir","commands":["mkdir -p gen && echo x > gen/a.generated.ts"],"mutatesTree":["gen/*.generated.ts"]}
]}'
[ "$RC" = 0 ] && ok "a declared file inside a NEW directory passes" || bad "new-dir glob not matched: $OUT"
( cd "$ROOT" && rm -rf gen )

run '{"version":1,"jobs":[
  {"name":"red-and-dirty","commands":["echo changed > tracked.txt; exit 3"]}
]}'
grep -q 'tree-guard' <<<"$OUT" && ok "a FAILING job is still checked for dirt" || bad "guard skipped on failure: $OUT"
( cd "$ROOT" && git checkout -q -- tracked.txt )

run '{"version":1,"jobs":[
  {"name":"dirties","commands":["echo changed > tracked.txt"]}
]}' --no-tree-guard
[ "$RC" = 0 ] && ok "--no-tree-guard turns it off" || bad "opt-out ignored: $OUT"
( cd "$ROOT" && git checkout -q -- tracked.txt )

run '{"version":1,"jobs":[{"name":"bad","commands":["true"],"mutatesTree":"tracked.txt"}]}'
[ "$RC" = 2 ] && ok "a non-array mutatesTree is refused" || bad "expected rc=2, got $RC: $OUT"

echo "ci-replica: a tree dirty enough to overflow an env var still fails (#415)"
# #415: the guard used to hand both snapshots to python through the
# environment. A single env value over MAX_ARG_STRLEN (128 KiB) makes that
# `exec` fail with 126, and the old code read the empty capture as "no
# undeclared files" — a fail-open. 8000 untracked files comfortably clears
# 128 KiB of `git status --porcelain -uall` output (WSL's @lhci/cli left
# ~6,500 lines behind in the real repro).
run '{"version":1,"jobs":[
  {"name":"leaves-a-mess","commands":["mkdir -p bigdirt && seq 1 8000 | xargs -I{} touch bigdirt/f{}"]}
]}'
[ "$RC" = 1 ] && ok "an oversized dirty tree still fails the run, not silently PASS" \
  || bad "fail-open on an oversized status: rc=$RC $OUT"
grep -q 'tree-guard' <<<"$OUT" && ok "and it's reported as a tree-guard failure" \
  || bad "no tree-guard mention: $OUT"
grep -qE 'PASS +leaves-a-mess' <<<"$OUT" && bad "the dirty job must not read PASS" || ok "not reported PASS"
( cd "$ROOT" && rm -rf bigdirt )

echo "ci-replica: --base reaches every job as CI_REPLICA_BASE"
# The repo needs a commit for --base to resolve against.
git -C "$ROOT" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m base >/dev/null 2>&1
BASEJOB='{"version":1,"jobs":[{"name":"base","commands":["test \"${CI_REPLICA_BASE-unset}\" = \"$EXPECT_BASE\""]}]}'
EXPECT_BASE="unset" run "$BASEJOB"
[ "$RC" = 0 ] && ok "without --base, CI_REPLICA_BASE is not set" || bad "leaked a base: rc=$RC $OUT"
EXPECT_BASE=HEAD run "$BASEJOB" --base HEAD
[ "$RC" = 0 ] && ok "--base HEAD exports CI_REPLICA_BASE=HEAD" || bad "base not exported: rc=$RC $OUT"
grep -q 'base=HEAD' <<<"$OUT" && ok "and the header names it" || bad "header silent about base: $OUT"
run "$BASEJOB" --base no-such-ref
[ "$RC" = 2 ] && ok "an unresolvable --base is refused before any job runs" || bad "expected rc=2, got $RC: $OUT"
# The empty-range refusal a manifest pairs with it: HEAD..HEAD scans nothing.
run '{"version":1,"jobs":[{"name":"scan","commands":["n=$(git rev-list --count \"$(git merge-base \"${CI_REPLICA_BASE:-HEAD~0}\" HEAD)..HEAD\"); [ \"$n\" -gt 0 ]"]}]}' --base HEAD
[ "$RC" = 1 ] && ok "a manifest's empty-range refusal fails the job on a base equal to HEAD" || bad "empty range passed: rc=$RC $OUT"

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
