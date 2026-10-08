#!/usr/bin/env bash
# Self-test for pooler-readonly-guard.sh: a session-level read-only setting is
# refused on a pooled or unprovable connection and allowed on a direct one;
# transaction-scoped forms, reads and prose pass. The rows are MuscleBuddy's
# prod-readonly-pooler-guard corpus (its own test and hook-bypass-corpus), which
# this global guard replaces, plus the generalised direct-URL names.
#   bash hooks/pooler-readonly-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/pooler-readonly-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# check <want> <command> — `\n` in the command is a newline.
check() {
  local want="$1" cmd got
  cmd="$(printf '%b' "$2")"
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd" \
    | "$GUARD" >/dev/null 2>"$TMP/err"
  got=$?
  [ "$got" = "$want" ] || { echo "FAIL: want $want got $got: $cmd"; fail=1; }
}

while IFS= read -r row; do check 2 "$row"; done <<'ROWS'
U="$MB_PROD_DATABASE_URL"; PGOPTIONS='-c default_transaction_read_only=on' timeout 90 psql "$U" -X -A -F '|' -c "$1"
PGOPTIONS='-c default_transaction_read_only=on' psql "postgresql://x:y@host:6543/postgres?pgbouncer=true" -c "select 1"
psql "$MB_PROD_DATABASE_URL" -c "SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY; select 1;"
psql "$MB_PROD_DATABASE_URL" -c "SET transaction_read_only = on; select 1;"
PGOPTIONS='-c default_transaction_read_only=on' psql "postgresql://x:y@host/postgres?pgbouncer=true" -c "select 1"
URL=$(railway variables get DATABASE_URL --service musclebuddyserver); PGOPTIONS="-c default_transaction_read_only=on" psql "$URL" -c "select 1;"
PGOPTIONS="-c default_transaction_read_only=on" psql "postgresql://u:p@aws-0-us-east-1.pooler.supabase.com/postgres?options=--port%3D6543" -c "select 1;"
source /tmp/opaque_creds.env; PGOPTIONS="-c default_transaction_read_only=on" psql "$PROD_POOLED_URL" -c "select 1;"
PGOPTIONS="-c default_transaction_read_only=on" psql "$MB_PROD_DIRECT_URL" -c "select 1" && psql "$OTHER_URL" -c "select 2"
psql "$MB_PROD_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'\nSET default_transaction_read_only = on;\nselect 1;\nSQL
psql "$MB_PROD_DATABASE_URL" <<SQL\nSET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY;\nSQL
cat <<'SQL' | psql "$MB_PROD_DATABASE_URL"\nSET default_transaction_read_only = on;\nSQL
psql "$MB_PROD_DATABASE_URL" -c 'SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL READ COMMITTED, READ ONLY'
psql "$MB_PROD_DATABASE_URL" -c 'SET SESSION CHARACTERISTICS AS TRANSACTION DEFERRABLE READ ONLY'
psql "$MB_PROD_DATABASE_URL" -c 'SET SESSION CHARACTERISTICS AS TRANSACTION NOT DEFERRABLE, READ ONLY'
psql "$MB_PROD_DATABASE_URL" -c 'SET "default_transaction_read_only" = on; select 1'
psql "$MB_PROD_DATABASE_URL" -c 'SET SESSION "transaction_read_only" TO on'
PGOPTIONS="-c default_transaction_read_only=1" psql "$MB_PROD_DATABASE_URL" -c "select 1"
PGOPTIONS="-c default_transaction_read_only=yes" psql "$MB_PROD_DATABASE_URL" -c "select 1"
PGOPTIONS="-c default_transaction_read_only=t" psql "$MB_PROD_DATABASE_URL" -c "select 1"
PGOPTIONS="--default-transaction-read-only=on" psql "$MB_PROD_DATABASE_URL" -c "select 1"
psql "$MB_PROD_DATABASE_URL" -c "SET default_transaction_read_only TO on; select 1"
psql "$MB_PROD_DATABASE_URL" -c "select set_config('default_transaction_read_only','on',false)"
psql "$MB_PROD_DATABASE_URL" -c "SET default_transaction_read_only = \"on\""
psql "$MB_PROD_DATABASE_URL?options=-c%20default_transaction_read_only%3Don" -c "select 1"
PGOPTIONS="-c default_transaction_read_only=y" psql "$MB_PROD_DATABASE_URL" -c "select 1"
PGOPTIONS="-c default_transaction_read_only=tru" psql "$MB_PROD_DATABASE_URL" -c "select 1"
PGOPTIONS="-c transaction_read_only=yes" psql "$MB_PROD_DATABASE_URL" -c "select 1"
psql "$MB_PROD_DATABASE_URL" -c "SET SESSION default_transaction_read_only = 'true'"
psql "$MB_PROD_DATABASE_URL" -c "ALTER ROLE app SET default_transaction_read_only TO on"
psql "$MB_PROD_DATABASE_URL" -c "select set_config('transaction_read_only', 'on', 'f')"
# probe\npsql "$MB_PROD_DATABASE_URL" -c "SET default_transaction_read_only TO 1"
PGOPTIONS='-c default_transaction_read_only=on' psql "$DATABASE_URL" -c "select 1"
PGOPTIONS='-c default_transaction_read_only=on' psql "postgresql://u:p@aws-0-us-east-1.pooler.supabase.com:6543/postgres" -c "select 1"
psql "$DIRECT_URL" -c "ALTER DATABASE postgres SET default_transaction_read_only = on"
psql "$DATABASE_URL?options=-c%20default%5Ftransaction%5Fread%5Fonly%3Don" -c "select 1"
ROWS

while IFS= read -r row; do check 0 "$row"; done <<'ROWS'
psql "$MB_PROD_DATABASE_URL" -c "BEGIN READ ONLY; select 1; ROLLBACK;"
psql "$MB_PROD_DATABASE_URL" -c "BEGIN; SET LOCAL default_transaction_read_only = on; select 1; COMMIT;"
psql "$MB_PROD_DATABASE_URL" -c "select set_config('default_transaction_read_only','on',true)"
psql "$MB_PROD_DATABASE_URL" -c "show default_transaction_read_only"
psql "$MB_PROD_DATABASE_URL" -c "select current_setting('transaction_read_only')"
psql "$MB_PROD_DATABASE_URL" -c "SET default_transaction_read_only = off"
PGOPTIONS="-c default_transaction_read_only=on" psql "$MB_PROD_DIRECT_URL" -c "select 1"
psql "$MB_PROD_DATABASE_URL" <<'SQL'\nBEGIN READ ONLY;\nselect 1;\nROLLBACK;\nSQL
psql "$MB_PROD_DATABASE_URL" -c 'SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE' -c 'BEGIN READ ONLY; select 1; ROLLBACK;'
psql "$MB_PROD_DIRECT_URL" -c "BEGIN READ ONLY; select 1; ROLLBACK;"
psql "$MB_PROD_DATABASE_URL" -c "BEGIN; SET LOCAL transaction_read_only = on; select 1; COMMIT;"
echo hello world
npm run typecheck
cat > runbook.md <<'EOF'\nNever run PGOPTIONS='-c default_transaction_read_only=on' against MB_PROD_DATABASE_URL.\nEOF
PGOPTIONS='-c default_transaction_read_only=on' psql "$DIRECT_URL" -c "select 1"
PGOPTIONS='-c default_transaction_read_only=on' psql "${RT_DIRECT_URL}" -c "select 1"
PGOPTIONS='-c default_transaction_read_only=on' psql "postgresql://u:p@db.abcdefgh.supabase.co:5432/postgres" -c "select 1"
psql "$DATABASE_URL" -c "ALTER ROLE app SET default_transaction_read_only = off"
git commit -m "docs: never set default_transaction_read_only on the pooler"
ROWS

# The refusal names the incident and the safe form.
check 2 'PGOPTIONS="-c default_transaction_read_only=on" psql "$MB_PROD_DATABASE_URL" -c "select 1"'
for want in 'BEGIN READ ONLY' 'MB_PROD_DIRECT_URL' '#8460' '25006'; do
  grep -qF -- "$want" "$TMP/err" || { echo "FAIL: the refusal does not say '$want'"; fail=1; }
done

# Fail open on garbage.
printf 'not json' | "$GUARD" >/dev/null 2>&1 || { echo "FAIL: garbage input did not fail open"; fail=1; }

[ "$fail" = 0 ] && echo "pooler-readonly-guard: all cases passed"
exit "$fail"
