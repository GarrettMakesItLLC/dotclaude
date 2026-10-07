#!/usr/bin/env bash
# dotclaude db-push-guard — PreToolUse hook (matcher: Bash). Refuses
# `prisma db push` against any database that is not local.
#
# `db push` writes schema changes straight to the database and records no
# migration, so against a shared database (staging, production, a Supabase
# project) it silently drifts the deployed schema away from
# `prisma/migrations/` — and the next `migrate deploy` then fails on objects
# that already exist. Schema reaches a shared database only through a
# timestamped migration and `prisma migrate deploy` (rules/prisma.md).
#
# The database it would hit is whichever URL variable Prisma reads: `DATABASE_URL`,
# `DIRECT_URL` (a `directUrl`, or a `prisma.config.ts` datasource pointing at it,
# is what the CLI connects through), and any other name the directory's
# `schema.prisma` / `prisma.config.ts` reads with `env("X")` or `process.env.X`.
# Each is resolved from an inline `X=` on the command, else the ambient
# environment, else the `.env` in the directory the command runs in (after a
# leading `cd`), which is where Prisma itself looks. Every one that resolves must
# be local — judging only `DATABASE_URL` let a prod `DIRECT_URL` through beside a
# local `DATABASE_URL`. Local means localhost, 127.0.0.1, [::1] or
# host.docker.internal. When none resolves the push is blocked: nothing proves
# it safe.
#
# Fail-open on input it cannot parse.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "⚠️  dotclaude db-push-guard: DISABLED — python3 is not installed, so nothing was checked (bin/doctor.sh lists the prerequisites)." >&2; exit 0; }
input="$(cat)"

parsed="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", "") or "")
    print(d.get("cwd", "") or "")
except Exception:
    pass
' 2>/dev/null)" || exit 0
command_str="$(printf '%s' "$parsed" | sed -n 1p)"
hook_cwd="$(printf '%s' "$parsed" | sed -n 2p)"
normalized="$(printf '%s' "$command_str" | tr '\n' ' ' | tr -s ' ' | tr -d "\"'")"

# `prisma` at a command position (after env assignments and a runner), so prose
# that merely names the command is not judged.
printf '%s' "$normalized" | grep -Eq '(^|[;&|(]|&&)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((npx|bunx|pnpm|pnpm[[:space:]]+exec|yarn|npm[[:space:]]+exec([[:space:]]+--)?)[[:space:]]+)?([^[:space:]]*/)?prisma[[:space:]]+db[[:space:]]+push([[:space:]]|$)' || exit 0

dir="${hook_cwd:-$PWD}"
cd_target="$(printf '%s' "$normalized" | grep -oE '(^|[;&|(]|&&)[[:space:]]*cd[[:space:]]+[^[:space:];&|]+' | head -1 | sed -E 's/.*cd[[:space:]]+//')"
if [ -n "$cd_target" ]; then
  case "$cd_target" in
    /*) dir="$cd_target" ;;
    \~/*) dir="$HOME/${cd_target#\~/}" ;;
    *) dir="$dir/$cd_target" ;;
  esac
fi

# The variable names to judge: the two Prisma conventions, plus any the
# directory's own Prisma config reads.
names="DATABASE_URL DIRECT_URL"
for f in "$dir/prisma.config.ts" "$dir/prisma.config.js" "$dir/prisma.config.mjs" "$dir/schema.prisma" "$dir/prisma/schema.prisma"; do
  [ -f "$f" ] || continue
  names="$names $(grep -oE "env\(['\"][A-Za-z_][A-Za-z0-9_]*['\"]\)|process\.env(\.[A-Za-z_][A-Za-z0-9_]*|\[['\"][A-Za-z_][A-Za-z0-9_]*['\"]\])" "$f" \
    | grep -oE "[A-Za-z_][A-Za-z0-9_]*['\"]?\]?\)?$" | tr -d "'\")]" | tr '\n' ' ')"
done
names="$(printf '%s' "$names" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"

# resolve <NAME> -> prints "<url>\t<where>" or nothing. Inline matches the exact
# name at a word start, so `MB_PROD_DATABASE_URL=` is not read as `DATABASE_URL=`.
resolve() {
  local n="$1" v
  v="$(printf ' %s' "$normalized" | sed -n "s/.*[[:space:];&|(]$n=\([^[:space:];&|]*\).*/\1/p" | head -1)"
  [ -n "$v" ] && { printf '%s\tthe inline %s\n' "$v" "$n"; return; }
  v="${!n:-}"
  [ -n "$v" ] && { printf '%s\tthe exported %s\n' "$v" "$n"; return; }
  if [ -f "$dir/.env" ]; then
    v="$(sed -n "s/^\(export \)\{0,1\}$n=//p" "$dir/.env" | tail -1 | tr -d "\"'")"
    [ -n "$v" ] && printf '%s\t%s in %s/.env\n' "$v" "$n" "$dir"
  fi
}

resolved=0
for n in $names; do
  line="$(resolve "$n")"
  [ -n "$line" ] || continue
  resolved=1
  url="${line%%	*}"; source_desc="${line#*	}"
  case "$url" in
    *@localhost[:/]* | *@127.0.0.1[:/]* | *"@[::1]"* | *@host.docker.internal[:/]* | file:*) continue ;;
  esac
  echo "⛔ dotclaude db-push-guard: 'prisma db push' against a non-local database ($source_desc). It records no migration, so the deployed schema drifts from prisma/migrations/ and the next \`migrate deploy\` fails on objects that already exist. Write a timestamped migration and apply it with \`prisma migrate deploy\` (rules/prisma.md)." >&2
  exit 2
done

if [ "$resolved" = 0 ]; then
  echo "⛔ dotclaude db-push-guard: 'prisma db push' with no resolvable database URL (checked: $names), so nothing proves it is local. Change schema through a timestamped migration (\`prisma migrate dev --create-only\`, or a hand-written prisma/migrations/<ts>_<name>/migration.sql) and apply it with \`prisma migrate deploy\`." >&2
  exit 2
fi
exit 0
