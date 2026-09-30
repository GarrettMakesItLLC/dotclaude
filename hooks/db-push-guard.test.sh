#!/usr/bin/env bash
# Self-test for db-push-guard.sh: `prisma db push` is blocked against a remote
# or unresolvable database (inline, exported, or from the .env Prisma reads)
# and allowed against a local one; unrelated prisma commands pass.
#   bash hooks/db-push-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/db-push-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
unset DATABASE_URL BASH_ENV
mkdir -p "$TMP/remote" "$TMP/local" "$TMP/none"
echo 'DATABASE_URL="postgresql://u:p@aws-0.pooler.supabase.com:5432/postgres"' >"$TMP/remote/.env"
echo 'DATABASE_URL=postgresql://u:p@localhost:5432/dev' >"$TMP/local/.env"

check() {
  local want="$1" dir="$2" cmd="$3" got
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))' "$cmd" "$dir" \
    | "$GUARD" >/dev/null 2>&1
  got=$?
  [ "$got" = "$want" ] || { echo "FAIL: want $want got $got in $(basename "$dir") (DATABASE_URL=${DATABASE_URL:-}): $cmd"; fail=1; }
}

check 2 "$TMP/remote" "npx prisma db push"
check 2 "$TMP/none" "npx prisma db push"
check 2 "$TMP/local" "DATABASE_URL=postgresql://u:p@db.x.supabase.co:5432/postgres npx prisma db push"
check 2 "$TMP/none" "cd $TMP/remote && npx prisma db push --accept-data-loss"
check 0 "$TMP/local" "npx prisma db push"
check 0 "$TMP/remote" "DATABASE_URL=postgresql://u:p@127.0.0.1:5432/x npx prisma db push"
check 0 "$TMP/none" "cd $TMP/local && prisma db push"
check 0 "$TMP/remote" "npx prisma migrate deploy"
check 0 "$TMP/remote" "npx prisma generate"
check 2 "$TMP/remote" "echo start; node_modules/.bin/prisma db push"
check 0 "$TMP/remote" "echo 'never run prisma db push against prod' >> notes.md"
export DATABASE_URL=postgresql://u:p@prod.example.com:5432/app
check 2 "$TMP/none" "npx prisma db push"
unset DATABASE_URL
printf 'not json' | "$GUARD" >/dev/null 2>&1 || { echo "FAIL: garbage input did not fail open"; fail=1; }

[ "$fail" = 0 ] && echo "db-push-guard: all cases passed"
exit "$fail"
