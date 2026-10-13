#!/usr/bin/env bash
# Self-test for prod-db-url.sh against a stub `railway` CLI: --writer is
# required, the URL comes from the manifest's Railway service with the pgbouncer
# query stripped, writerKey overrides the key, and a missing manifest, service
# or value fails by name without printing anything on stdout.
#   bash bin/prod-db-url.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDU="$HERE/prod-db-url.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

unset BASH_ENV REPO_MANIFEST RAILWAY_TOKEN RAILWAY_API_TOKEN
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME" "$TMP/bin"
cat >"$TMP/bin/railway" <<'S'
#!/usr/bin/env bash
cat "$RAILWAY_FIXTURE"
S
chmod +x "$TMP/bin/railway"
export PATH="$TMP/bin:$PATH" RAILWAY_FIXTURE="$TMP/railway.kv"
printf 'DIRECT_URL=postgresql://owner:pw@db.example.test:5432/postgres?pgbouncer=true\nOWNER_URL="postgresql://own2:pw2@db.example.test:5432/postgres"\n' >"$RAILWAY_FIXTURE"

REPO="$TMP/repo"
git init -q -b main "$REPO"
mkdir -p "$REPO/.claude"
manifest() { printf '%s\n' "$1" >"$REPO/.claude/repo.json"; }
run() { OUT="$(cd "$REPO" && "$PDU" "$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"; }

manifest '{ "credentials": { "railway": { "service": "server", "environment": "production" } } }'

echo "prod-db-url: --writer prints the owner URL, pgbouncer query stripped"
run --writer
[ "$RC" = 0 ] && [ "$OUT" = "postgresql://owner:pw@db.example.test:5432/postgres" ] && ok "DIRECT_URL, query stripped" || bad "rc=$RC out=$OUT err=$ERR"

echo "prod-db-url: the call site must say --writer"
run
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q -- '--writer' <<<"$ERR" && ok "bare call refused" || bad "rc=$RC out=$OUT err=$ERR"
run --reader
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok "any other flag refused" || bad "rc=$RC out=$OUT"

echo "prod-db-url: credentials.writerKey overrides the key"
manifest '{ "credentials": { "writerKey": "OWNER_URL", "railway": { "service": "server" } } }'
run --writer
[ "$RC" = 0 ] && [ "$OUT" = "postgresql://own2:pw2@db.example.test:5432/postgres" ] && ok "writerKey honoured, quotes stripped" || bad "rc=$RC out=$OUT err=$ERR"

echo "prod-db-url: failures are named and print nothing on stdout"
manifest '{ "credentials": { "writerKey": "ABSENT", "railway": { "service": "server" } } }'
run --writer
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q 'ABSENT' <<<"$ERR" && ok "missing key named" || bad "rc=$RC out=$OUT err=$ERR"
manifest '{ "credentials": {} }'
run --writer
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q 'railway.service' <<<"$ERR" && ok "missing service named" || bad "rc=$RC out=$OUT err=$ERR"
rm -f "$REPO/.claude/repo.json"
run --writer
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q 'repo.json' <<<"$ERR" && ok "missing manifest named" || bad "rc=$RC out=$OUT err=$ERR"

exit "$fail"
