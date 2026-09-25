#!/usr/bin/env bash
# Self-test for run-shared-action.sh against a local ci tree (GMI_CI_SOURCE), no network:
# an action's exit status and outputs pass through, and a missing action is refused.
#   bash bin/run-shared-action.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/run-shared-action.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

# A minimal runner standing in for ci's scripts/run-composite.py: runs the action's one script.
mkdir -p "$TMP/ci/scripts" "$TMP/ci/actions/greet"
cat > "$TMP/ci/scripts/run-composite.py" <<'PY'
import subprocess, sys
action, args = sys.argv[1], sys.argv[2:]
sys.exit(subprocess.call(["bash", f"{action}/run.sh", *args]))
PY
printf 'name: greet\n' > "$TMP/ci/actions/greet/action.yml"
cat > "$TMP/ci/actions/greet/run.sh" <<'SH'
[ "$1" = "--input" ] && [ "$2" = "who=fail" ] && exit 7
echo "hello $2"
SH

out="$(GMI_CI_SOURCE="$TMP/ci" bash "$RUN" greet --ref v1 --input who=world 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "hello who=world" ] && ok "runs the action and passes its args" || bad "pass-through: rc=$rc out=$out"

GMI_CI_SOURCE="$TMP/ci" bash "$RUN" greet --input who=fail >/dev/null 2>&1; rc=$?
[ "$rc" -eq 7 ] && ok "the action's exit status is the script's" || bad "exit status: expected 7, got $rc"

out="$(GMI_CI_SOURCE="$TMP/ci" bash "$RUN" nope 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && [[ "$out" == *"no actions/nope"* ]] && ok "refuses an action the ref does not have" || bad "missing action: rc=$rc out=$out"

bash "$RUN" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "no arguments is a usage error" || bad "usage: rc=$rc"

[ "$fail" -eq 0 ] && echo "run-shared-action: all cases passed"
exit "$fail"
