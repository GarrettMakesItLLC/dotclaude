#!/usr/bin/env bash
# Self-test: a PreToolUse guard whose interpreter is missing stands down — a
# guard must never brick every tool call — but it says so on stderr. A silent
# fail-open made a machine without perl look exactly like a guarded one
# (`git commit -n` went through with rc=0 and no word).
#   bash hooks/guard-prereqs.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# path_without <tool>: a PATH directory holding the ordinary tools a guard uses,
# minus <tool>, so `command -v <tool>` fails and nothing else changes. Built from
# a fixed list rather than the whole PATH, which on WSL spans thousands of files.
path_without() {
  local d="$TMP/no-$1" t src
  [ -d "$d" ] && { echo "$d"; return; }
  mkdir -p "$d"
  for t in bash sh env cat grep sed tr awk head tail cut wc sort uniq dirname basename \
           mktemp rm mkdir ls pwd readlink realpath printf date id stat timeout \
           python3 perl git gh jq; do
    [ "$t" = "$1" ] && continue
    src="$(command -v "$t" 2>/dev/null)" && [ -x "$src" ] && ln -s "$src" "$d/$t"
  done
  echo "$d"
}

# guard, tool, tool_name, input key, input value
while IFS='|' read -r guard tool tname key val; do
  [ -n "$guard" ] || continue
  p="$(path_without "$tool")"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"cwd":"/tmp","tool_input":{sys.argv[2]:sys.argv[3]}}))' "$tname" "$key" "$val")"
  printf '%s' "$payload" > "$TMP/payload.json"
  err="$(PATH="$p" BASH_ENV='' "$p/bash" "$HERE/$guard.sh" < "$TMP/payload.json" 2>"$TMP/err" >/dev/null; echo "rc=$?"; cat "$TMP/err")"
  rc="$(sed -n '1s/^rc=//p' <<<"$err")"; err="$(sed 1d <<<"$err")"
  if [ "$rc" != 0 ]; then
    echo "FAIL: $guard without $tool exited $rc, not 0 (a guard must not brick the tool): $err"; fail=1
  elif ! grep -q "dotclaude $guard: DISABLED — $tool is not installed" <<<"$err"; then
    echo "FAIL: $guard without $tool stood down silently (stderr: ${err:-<empty>})"; fail=1
  fi
done <<'CASES'
git-guard|python3|Bash|command|git commit -n -m x
git-guard|perl|Bash|command|git commit -n -m x
npm-install-guard|python3|Bash|command|npm ci
npm-install-guard|perl|Bash|command|npm ci
worktree-cd-guard|python3|Bash|command|cd /tmp && echo x > f
worktree-cd-guard|perl|Bash|command|cd /tmp && echo x > f
heredoc-guard|python3|Bash|command|cat <<EOF
db-push-guard|python3|Bash|command|npx prisma db push
pooler-readonly-guard|python3|Bash|command|psql -c "SET default_transaction_read_only = on"
pr-base-guard|python3|Bash|command|gh pr create --base main
secret-read-guard|python3|Read|file_path|/home/x/.config/secrets/a.env
worktree-guard|python3|Edit|file_path|/tmp/x.ts
claim-guard|python3|Edit|file_path|/tmp/x.ts
migration-guard|python3|Edit|file_path|/tmp/prisma/migrations/1_x/migration.sql
credential-output-guard|python3|Bash|command|echo hi
CASES

[ "$fail" = 0 ] && echo "guard-prereqs: all cases passed"
exit "$fail"
