#!/usr/bin/env bash
# dotclaude pooler-readonly-guard — PreToolUse hook (matcher: Bash, and through
# mcp-tool-adapter.sh, Serena's execute_shell_command). Refuses a command that
# sets a SESSION-level read-only Postgres setting on a connection it cannot
# prove is a direct (session-mode, :5432) one.
#
# Supabase fronts Postgres with Supavisor in TRANSACTION pooling mode on :6543:
# a backend is handed out per transaction, not per client, so a client that
# sets read-only at SESSION level on that connection leaves the backend
# read-only for whichever client the pooler hands it to next, the app's own
# writes included. They then fail with Postgres `25006` ("cannot execute
# INSERT/UPDATE in a read-only transaction") in bursts that clear only when the
# poisoned backend recycles (MuscleBuddy#8460: an audit probe ran
# `PGOPTIONS='-c default_transaction_read_only=on' psql "$MB_PROD_DATABASE_URL"`).
#
# The safe form scopes read-only to the TRANSACTION, on the direct connection:
#
#   psql "$DIRECT_URL" -c "BEGIN READ ONLY; ... ; ROLLBACK;"
#
# Refused: a SESSION-level read-only setting (`default_transaction_read_only`,
# `SESSION CHARACTERISTICS ... READ ONLY`, a bare `SET transaction_read_only`,
# `set_config(..., false)`, any of them riding in PGOPTIONS or a URL's
# `options=`) unless the command names only a direct connection: a variable
# whose name ends in DIRECT_URL (`DIRECT_URL`, `MB_PROD_DIRECT_URL`, …) or a
# literal `:5432`, and nothing pooled or opaque. The hook reads only the command
# string, so it cannot see what `$URL`, `$(…)` or a sourced file holds; every
# such indirection is refused, which is the safe direction for an incident that
# broke production writes.
#
# Always allowed: `BEGIN READ ONLY` and `SET LOCAL` / `set_config(..., true)`
# (transaction-scoped), reads (`SHOW`, `current_setting`), and an explicit
# false value. A heredoc body is prose unless its opener feeds a SQL client.
#
# Fail-open on anything unexpected: a guard that bricks every Bash call is
# worse than one that occasionally misses.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "⚠️  dotclaude pooler-readonly-guard: DISABLED — python3 is not installed, so nothing was checked (bin/doctor.sh lists the prerequisites)." >&2; exit 0; }

input="$(cat)"
command_str="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    sys.stdout.write(json.load(sys.stdin).get("tool_input", {}).get("command", "") or "")
except Exception:
    pass
' 2>/dev/null)" || exit 0
[ -n "$command_str" ] || exit 0

# Cheap exit for the overwhelming majority of commands.
printf '%s' "$command_str" | grep -qiE 'read[_ -]only|read%5fonly' || exit 0

# A heredoc body is blanked unless its opener names a SQL client, which runs
# it. If the scrub itself fails, judge the whole command.
scrubbed="$(printf '%s' "$command_str" \
  | perl -0777 -pe "s/^([^\n]*?)<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2([^\n]*)\n(.*?)^\3\$/do { my (\$o, \$h, \$r, \$b) = (\$1, \$3, \$4, \$5); (\"\$o<<\$h\$r\" =~ m{psql|pgcli|pgsql|db\s+execute|sqlcmd}i) ? \"\$o<<\$h\$r\n\$b\" : \"\$o\$r \" }/gmse" 2>/dev/null)" \
  || scrubbed="$command_str"
[ -n "$scrubbed" ] || scrubbed="$command_str"

lc="$(printf '%s' "$scrubbed" | tr '[:upper:]' '[:lower:]')"

# Judged on a normalised copy: libpq URL escapes decoded (`%3d`, `%20`, `%5f`)
# and a dashed name (`--default-transaction-read-only=on`) read as the GUC it
# names. Postgres takes a boolean as any unambiguous prefix of on/true/yes or
# 1/t/y, `TO` as well as `=`, in either quote style, so a setter is refused for
# any value but an explicit false.
norm="$(printf '%s' "$lc" | sed -E 's/%3d/=/g; s/%5f/_/g; s/%20|\+/ /g')"

is_false() {
  case "$1" in
    0 | f | fa | fal | fals | false | n | no | of | off) return 0 ;;
    *) return 1 ;;
  esac
}

sets_session_readonly=0
# `<name> {=|to} <value>` after something that makes it a setter (SET [SESSION],
# -c, --, options=…-c), so `SHOW transaction_read_only` stays a read and
# `SET LOCAL` (not `set ` + name) stays transaction-scoped.
setter_value_re='(^|[^a-z_])(set[[:space:]]+(session[[:space:]]+)?|-c[[:space:]]*|--|options[[:space:]]*=[^[:space:]]*-c[[:space:]]*)["]?(default[_-])?transaction[_-]read[_-]only["]?[[:space:]]*(=|to)[[:space:]]*[\\'\''"]*[a-z0-9]+'
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  value="$(printf '%s' "$hit" | sed -E 's/.*(=|to)[[:space:]]*[\\'\''"]*//')"
  is_false "$value" || sets_session_readonly=1
done < <(printf '%s\n' "$norm" | grep -oE "$setter_value_re")

# set_config('<name>', '<value>', <is_local>): session scope unless is_local is true.
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  third="$(printf '%s' "$hit" | sed -E "s/.*,[[:space:]]*[\\\\'\"]*([a-z0-9]+)[\\\\'\"]*[[:space:]]*\)?\$/\\1/")"
  case "$third" in true | t | tr | tru | y | yes | 1 | on) ;; *) sets_session_readonly=1 ;; esac
done < <(printf '%s\n' "$norm" | grep -oE "set_config[[:space:]]*\([[:space:]]*[\\'\''\"]*(default[_-])?transaction[_-]read[_-]only[\\'\''\"]*[[:space:]]*,[^,]*,[[:space:]]*[\\'\''\"]*[a-z0-9]+[\\'\''\"]*[[:space:]]*\)?")

# ALTER ROLE/USER/DATABASE … SET … read_only persists into every new session,
# pooled ones included, so no connection makes it safe.
persistent=0
if printf '%s' "$norm" | grep -qE 'alter[[:space:]]+(role|user|database)[^;]*[[:space:]]set[[:space:]]+["]?(default[_-])?transaction[_-]read[_-]only["]?[[:space:]]*(=|to)[[:space:]]*[\\'\''"]*(on|t|tr|tru|true|y|ye|yes|1)\b'; then
  persistent=1
  sets_session_readonly=1
fi

if printf '%s' "$norm" | grep -qE 'session[[:space:]]+characteristics[[:space:]]+as[[:space:]]+transaction[^;'\''"]*read[[:space:]]+only'; then
  sets_session_readonly=1
fi

((sets_session_readonly)) || exit 0

names_direct=0
printf '%s' "$lc" | grep -qE '\$\{?[a-z0-9_]*direct_url\b|:5432([^0-9]|$)' && names_direct=1

names_pooler=0
printf '%s' "$lc" | grep -qE ':6543|pgbouncer|pooler|port%3d6543' && names_pooler=1

# Every `$NAME` that is not a direct URL, every command substitution, and every
# sourced file is a target this hook cannot see into.
names_opaque=0
if printf '%s' "$lc" | grep -oE '\$\{?[a-z_][a-z0-9_]*' | tr -d '${' \
     | grep -qvE '^([a-z0-9_]*direct_url|[0-9]|pgoptions)$'; then
  names_opaque=1
fi
printf '%s' "$lc" | grep -qE '\$\(|`|(^|[;&|[:space:]])(source|\.)[[:space:]]' && names_opaque=1

if ((names_direct)) && ! ((names_pooler)) && ! ((names_opaque)) && ! ((persistent)); then
  exit 0
fi

cat >&2 <<'EOF'
⛔ dotclaude pooler-readonly-guard blocked this command.

It sets a SESSION-level Postgres read-only setting on a connection this hook
cannot prove is a direct (:5432, session-mode) one: it names the :6543
transaction pooler, or reaches its target through a variable, a command
substitution or a sourced file. (An ALTER ROLE/DATABASE ... SET of it is
refused on any connection: it persists into every future session.)

Supavisor hands out a backend PER TRANSACTION on :6543. A session-level
read-only setting there (default_transaction_read_only, SESSION
CHARACTERISTICS ... READ ONLY, a bare SET transaction_read_only, PGOPTIONS -c)
leaves the backend read-only for whichever client gets it next, the app's own
writes included: production then fails with Postgres 25006 until the backend
recycles (MuscleBuddy#8460).

Scope read-only to the TRANSACTION, on the direct connection:

  psql "$DIRECT_URL" -X -A -F '|' -c "BEGIN READ ONLY; <query>; ROLLBACK;"

(In MuscleBuddy that is $MB_PROD_DIRECT_URL. Never write a connection string
into a file.)
EOF
exit 2
