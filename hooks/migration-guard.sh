#!/usr/bin/env bash
# dotclaude migration-guard — PreToolUse hook (matcher: Edit|Write|MultiEdit).
# Guards Prisma migration directory names and applied migration SQL at the
# moment they are written.
#
# Prisma applies migration directories in LEXICOGRAPHIC order, not authoring
# order. Hand-written directories from concurrent agents reach for the same
# round hour, and a migration that sorts before an already-applied one, or
# collides with it, applies in an order nobody intended. This blocks the write
# instead of leaving it to a deploy to discover.
#
# Rules on a NEW `prisma/migrations/<timestamp>_<name>/` path:
#   1. the name is `<14-digit UTC timestamp>_<name>`;
#   2. the timestamp sorts strictly after every existing migration;
#   3. it is not on a round hour (…0000), the collision magnet;
#   4. it is not dated further ahead than rule 2 requires (one hour of clock
#      slack): a future-dated one merges unopposed and then blocks every
#      migration authored before its nominal time. Where the newest existing
#      migration is ALREADY future-dated, the ceiling moves to just past it, so
#      rules 2 and 4 stay jointly satisfiable.
#
# Editing SQL inside an EXISTING migration directory is blocked: every database
# that applied it holds a sha256 of its bytes in `_prisma_migrations`, and an
# edit (a comment included) puts the chain out of step with every ledger.
# `migrate deploy` does not notice; a ledger comparison or a replay does,
# permanently. Write a new migration forward instead.
#
# Authoring time only: this cannot see a migration that lands on the base
# branch while this one sits in review, and a directory made with `mkdir` never
# passes through Write/Edit. A repo re-checks ordering against its base in CI
# (rules/prisma.md). The repo is the one the FILE is in, not the session's.
#
# Fail-open on anything unexpected: a hook that wedges every Write is worse than
# one that misses a case.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || exit 0
input="$(cat)"

file_path="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("file_path", ""))
except Exception:
    print("")
' 2>/dev/null)" || exit 0

[ -n "$file_path" ] || exit 0

# Only care about paths under prisma/migrations/.
case "$file_path" in
  */prisma/migrations/*) ;;
  *) exit 0 ;;
esac

migrations_dir="${file_path%%/prisma/migrations/*}/prisma/migrations"
[ -d "$migrations_dir" ] || exit 0

# The migration directory this path lives in, e.g. 20260710163722_add_widget.
rel="${file_path##*/prisma/migrations/}"
dir_name="${rel%%/*}"
[ -n "$dir_name" ] && [ "$dir_name" != "$rel" ] || exit 0

# An existing directory means we're editing already-authored SQL.
if [ -d "$migrations_dir/$dir_name" ]; then
  # migration_lock.toml and friends aren't migrations; only guard the SQL.
  case "$file_path" in
    *.sql) ;;
    *) exit 0 ;;
  esac
  # A brand-new .sql inside a dir created moments ago is fine; a modification
  # to one that already exists on disk is the ledger-drift risk.
  [ -f "$file_path" ] || exit 0
  cat >&2 <<EOF
⛔ dotclaude migration-guard: $dir_name/ already exists and its SQL is checksum-locked.

Every database that applied this migration records a sha256 of its exact bytes
in _prisma_migrations, and any ledger comparison or replay raises on a change —
a comment included — permanently. Write a NEW migration that alters the schema
forward instead; a pointer or a comment that is wrong here stays wrong.
EOF
  exit 2
fi

timestamp="${dir_name%%_*}"

# Must look like a 14-digit Prisma timestamp.
case "$timestamp" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *)
    cat >&2 <<EOF
⛔ dotclaude migration-guard: "$dir_name" is not a valid migration directory name.

Expected <14-digit-timestamp>_<snake_case_name>, e.g. 20260710163722_add_widget.
EOF
    exit 2
    ;;
esac

# The newest existing migration, by the same lexicographic order Prisma uses.
latest=''
for cand in "$migrations_dir"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_*; do
  [ -e "$cand" ] || continue
  cand="$(basename "$cand")"
  [ -z "$latest" ] || [ "$cand" \> "$latest" ] && latest="$cand"
done
latest_ts="${latest%%_*}"

# The ceiling for rule 4: an hour past whichever is later, the clock or the
# newest existing migration. It is not simply "now" because the two rules have
# to stay jointly satisfiable — once a future-dated directory is on the branch,
# sorting after it means being future-dated too, and an applied migration cannot
# be renamed away. Fail open if this `date` cannot do the arithmetic.
cutoff="$(date -u -d '+1 hour' +%Y%m%d%H%M%S 2>/dev/null || true)"
latest_cutoff=''
if [ -n "$latest_ts" ]; then
  latest_cutoff="$(date -u -d "${latest_ts:0:4}-${latest_ts:4:2}-${latest_ts:6:2}T${latest_ts:8:2}:${latest_ts:10:2}:${latest_ts:12:2}Z +1 hour" +%Y%m%d%H%M%S 2>/dev/null || true)"
fi

# Is the branch already in the unsatisfiable state — newest existing migration
# itself in the future? Then a future timestamp just after it is the legal move.
stuck=''
if [ -n "$cutoff" ] && [ -n "$latest_ts" ] && [ "$latest_ts" \> "$cutoff" ]; then
  stuck=1
fi

ceiling="$cutoff"
if [ -n "$stuck" ] && [ -n "$latest_cutoff" ]; then
  ceiling="$latest_cutoff"
fi

if [ -n "$ceiling" ] && [ "$timestamp" \> "$ceiling" ]; then
  cat >&2 <<EOF
⛔ dotclaude migration-guard: migration timestamp $timestamp is in the FUTURE (now: $(date -u +%Y%m%d%H%M%S) UTC).

Migration timestamps are UTC. A future-dated one sorts after everything, so it
merges unopposed and then blocks every migration authored before its own nominal
time — each of those authors then has to pick a timestamp that is itself in the
future. Use a past UTC timestamp, later than the newest existing migration and
not on a round hour, then retry.
EOF
  if [ -n "$stuck" ]; then
    cat >&2 <<EOF

The latest existing migration ($latest_ts) is itself dated in the future, so a
future timestamp IS allowed here — but only just after it, not this far ahead.
Use something up to $ceiling.
EOF
  fi
  exit 2
fi

if [ -n "$latest_ts" ] && [ "$timestamp" \< "$latest_ts" ]; then
  cat >&2 <<EOF
⛔ dotclaude migration-guard: migration timestamp $timestamp sorts BEFORE the latest existing
migration ($latest).

Prisma applies migrations in lexicographic directory order, so this one would
run before migrations authored earlier. Pick a timestamp later than $latest_ts
and not on a round hour, then retry.
EOF
  if [ -n "$stuck" ]; then
    cat >&2 <<EOF

Note: the latest existing migration is itself dated in the FUTURE, so no past
timestamp satisfies this. Sit just after it — a future timestamp is allowed
here, and only here, for exactly that reason.
EOF
  fi
  exit 2
fi

if [ -n "$latest_ts" ] && [ "$timestamp" = "$latest_ts" ]; then
  cat >&2 <<EOF
⛔ dotclaude migration-guard: migration timestamp $timestamp collides with $latest.

Pick a later, non-round timestamp and retry.
EOF
  exit 2
fi

case "$timestamp" in
  *0000)
    cat >&2 <<EOF
⛔ dotclaude migration-guard: migration timestamp $timestamp is on a round hour.

Concurrent agents all reach for the round hour, which is how collisions happen.
Use a real off-hour timestamp (e.g. ${timestamp%0000}3722) later than $latest_ts.
EOF
    exit 2
    ;;
esac

exit 0
