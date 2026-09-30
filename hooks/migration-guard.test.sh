#!/usr/bin/env bash
# Self-test for migration-guard.sh on a fixture migrations directory: the name,
# ordering, collision, round-hour and future-date rules on a NEW migration, the
# checksum lock on EXISTING SQL, and the future-dated-base escape.
#   bash hooks/migration-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/migration-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

M="$TMP/repo/prisma/migrations"
mkdir -p "$M/20260101093722_init"
echo 'CREATE TABLE a();' >"$M/20260101093722_init/migration.sql"
echo 'provider = "postgresql"' >"$M/migration_lock.toml"

check() {
  local want="$1" path="$2" tool="${3:-Write}" got
  python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[2],"tool_input":{"file_path":sys.argv[1],"content":"x"}}))' "$path" "$tool" \
    | "$GUARD" >/dev/null 2>&1
  got=$?
  [ "$got" = "$want" ] || { echo "FAIL: want $want got $got for $tool $path"; fail=1; }
}

past="$(date -u -d '-1 day' +%Y%m%d%H)4411"
check 0 "$M/${past}_add_widget/migration.sql"
check 2 "$M/20251231093722_too_early/migration.sql"
check 2 "$M/20260101093722_collides/migration.sql"
check 2 "$M/$(date -u -d '-1 day' +%Y%m%d%H)0000_round/migration.sql"
check 2 "$M/$(date -u -d '+2 days' +%Y%m%d%H)4411_future/migration.sql"
check 2 "$M/add_widget/migration.sql"
check 2 "$M/20260101093722_init/migration.sql" Edit
check 0 "$M/20260101093722_init/new-notes.sql"
check 0 "$M/migration_lock.toml" Edit
check 0 "$TMP/repo/prisma/schema.prisma" Edit
check 0 "$TMP/repo/src/index.ts"

# The base already holds a future-dated migration: just after it is legal,
# far past it is not.
fut="$(date -u -d '+3 days' +%Y%m%d%H)3722"
mkdir -p "$M/${fut}_ahead"
check 0 "$M/${fut%3722}4411_after_ahead/migration.sql"
check 2 "$M/$(date -u -d '+9 days' +%Y%m%d%H)4411_way_ahead/migration.sql"

printf 'not json' | "$GUARD" >/dev/null 2>&1 || { echo "FAIL: garbage input did not fail open"; fail=1; }
[ "$fail" = 0 ] && echo "migration-guard: all cases passed"
exit "$fail"
