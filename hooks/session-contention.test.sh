#!/usr/bin/env bash
# Self-test for session-contention.sh: it must exit 0 and report one line in a
# git repo, stay silent outside one, and flag a busy box. Run locally or in CI:
#   bash hooks/session-contention.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/session-contention.sh"
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

run() { CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>&1; }

git init -q "$TMP/repo"
git -C "$TMP/repo" commit -q --allow-empty -m init
out="$(run "$TMP/repo")"; rc=$?
[ "$rc" = 0 ] && grep -q "0 linked worktrees" <<<"$out" \
  && ok "reports a quiet box with no linked worktrees" || bad "quiet case: rc=$rc out=$out"

for n in 1 2 3 4 5 6; do git -C "$TMP/repo" worktree add -q "$TMP/wt$n" -b "b$n" 2>/dev/null; done
out="$(run "$TMP/repo")"; rc=$?
[ "$rc" = 0 ] && grep -q "already busy: 6 linked worktrees" <<<"$out" \
  && ok "flags six linked worktrees as busy" || bad "busy case: rc=$rc out=$out"

mkdir "$TMP/nogit"
out="$(run "$TMP/nogit")"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "silent outside a git repo" || bad "non-repo: rc=$rc out=$out"

python3 - "$HERE/../settings.json" <<'PY' && ok "registered under SessionStart in settings.json" || bad "not registered under SessionStart"
import json, sys
cfg = json.load(open(sys.argv[1]))
cmds = [h.get("command", "") for g in cfg["hooks"]["SessionStart"] for h in g["hooks"]]
sys.exit(0 if any("hooks/session-contention.sh" in c for c in cmds) else 1)
PY

[ "$fail" = 0 ] && echo "session-contention: all cases passed"
exit "$fail"
