#!/usr/bin/env bash
# Self-test for git-guard.sh. Feeds commands through the hook and asserts the
# exit code (2 = blocked, 0 = allowed). Run locally or in CI:
#   bash hooks/git-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/git-guard.sh"
fail=0

# wrap a raw command string as the PreToolUse stdin JSON, run the guard.
check() {
  local want="$1" cmd="$2"
  local got
  printf '%s' "$cmd" \
    | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))' \
    | "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: want exit $want, got $got for: $cmd"
    fail=1
  fi
}

# Should BLOCK (exit 2)
check 2 'git commit --no-verify -m "x"'
check 2 'git commit -nm "x"'
check 2 'git commit -n -m "x"'
check 2 'git push --no-verify'
check 2 'git push --force origin main'
check 2 'git push -f origin main'
check 2 'git push --force-with-lease origin master'
check 2 'git add .env'
check 2 'git add config/.env.production'
check 2 'git commit .env -m "x"'

# Should ALLOW (exit 0)
check 0 'git commit -m "feat: normal commit about main flow"'
check 0 'git commit --amend -m "x"'
check 0 'git commit --no-edit'
check 0 'git commit -am "fix main"'
check 0 'git push origin feature/foo'
check 0 'git push --force origin feature/foo'
check 0 'git push -n origin main'
check 0 'git add .env.example'
check 0 'git add src/app.ts'
check 0 'git log -n 5'
check 0 'git clean -n'
check 0 'git status'
check 0 'npm run main'
check 0 'ls -la && echo done'

if [ "$fail" = 0 ]; then
  echo "git-guard: all cases passed"
fi
exit "$fail"
