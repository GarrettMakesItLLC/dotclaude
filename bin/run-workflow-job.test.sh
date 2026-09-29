#!/usr/bin/env bash
# Self-test for run-workflow-job.py: runs a job's `run:` steps in order, skips
# `uses:` steps, stops at the first failure, refuses what it cannot model.
#   bash bin/run-workflow-job.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RWJ="$HERE/run-workflow-job.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

wf="$TMP/wf.yml"
cat > "$wf" <<'Y'
jobs:
  good:
    steps:
      - uses: actions/checkout@v4
      - name: one
        run: |
          echo first > "$OUT"
          installer-that-does-not-exist --now
      - name: two
        env: { WORD: second }
        run: echo "$WORD" >> "$OUT"
  red:
    steps:
      - run: exit 7
      - run: echo unreachable > "$TMP_MARK"
  conditional:
    steps:
      - if: always()
        run: "true"
  plumbing:
    steps:
      - uses: actions/checkout@v4
Y

export OUT="$TMP/out"
python3 "$RWJ" "$wf" good --drop-line '^\s*installer-that' >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "a passing job exits 0 (uses: skipped, dropped line neutralised)" || bad "good job rc=$rc"
[ "$(cat "$OUT")" = "$(printf 'first\nsecond')" ] && ok "steps run in order with their env" || bad "out was: $(cat "$OUT")"

python3 "$RWJ" "$wf" good >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "without --drop-line the install line runs and fails the job" || bad "unexpected pass"

export TMP_MARK="$TMP/mark"
python3 "$RWJ" "$wf" red >/dev/null 2>&1; rc=$?
[ "$rc" = 7 ] && [ ! -e "$TMP_MARK" ] && ok "the first failing step's exit code is returned and later steps do not run" || bad "red: rc=$rc"

python3 "$RWJ" "$wf" conditional >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "a step with if: is refused, not guessed" || bad "conditional rc=$rc"
python3 "$RWJ" "$wf" plumbing >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "a job with no run: steps is refused rather than passing empty" || bad "plumbing rc=$rc"
python3 "$RWJ" "$wf" nope >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "an unknown job is refused" || bad "nope rc=$rc"

[ "$fail" = 0 ] && echo "run-workflow-job: all cases passed"
exit "$fail"
