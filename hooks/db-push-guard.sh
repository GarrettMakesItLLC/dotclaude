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
# The database it would hit: an inline `DATABASE_URL=` on the command, else the
# ambient environment, else the `.env` in the directory the command runs in
# (after a leading `cd`), which is where Prisma itself looks. Local means
# localhost, 127.0.0.1, [::1] or host.docker.internal. A URL that cannot be
# resolved at all is blocked: nothing proves it safe.
#
# Fail-open on input it cannot parse.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || exit 0
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

url="$(printf '%s' "$normalized" | sed -n 's/.*DATABASE_URL=\([^ ]*\).*/\1/p' | head -1)"
source_desc="the inline DATABASE_URL"
if [ -z "$url" ] && [ -n "${DATABASE_URL:-}" ]; then
  url="$DATABASE_URL"; source_desc="the exported DATABASE_URL"
fi
if [ -z "$url" ] && [ -f "$dir/.env" ]; then
  url="$(sed -n 's/^\(export \)\{0,1\}DATABASE_URL=//p' "$dir/.env" | tail -1 | tr -d "\"'")"
  source_desc="DATABASE_URL in $dir/.env"
fi

if [ -z "$url" ]; then
  echo "⛔ dotclaude db-push-guard: 'prisma db push' with no resolvable DATABASE_URL, so nothing proves it is local. Change schema through a timestamped migration (\`prisma migrate dev --create-only\`, or a hand-written prisma/migrations/<ts>_<name>/migration.sql) and apply it with \`prisma migrate deploy\`." >&2
  exit 2
fi

case "$url" in
  *@localhost[:/]* | *@127.0.0.1[:/]* | *"@[::1]"* | *@host.docker.internal[:/]* | file:*) exit 0 ;;
esac

echo "⛔ dotclaude db-push-guard: 'prisma db push' against a non-local database ($source_desc). It records no migration, so the deployed schema drifts from prisma/migrations/ and the next \`migrate deploy\` fails on objects that already exist. Write a timestamped migration and apply it with \`prisma migrate deploy\` (rules/prisma.md)." >&2
exit 2
