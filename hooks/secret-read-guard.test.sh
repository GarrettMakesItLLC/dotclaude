#!/usr/bin/env bash
# Self-test for secret-read-guard.sh. Feeds Read/Bash tool calls through the
# hook and asserts the exit code (2 = blocked, 0 = allowed). Run locally or
# in CI:
#   bash hooks/secret-read-guard.test.sh
#
# NEVER read, cat, or print any REAL secrets file in this test — every path
# below is synthetic (it need not even exist on disk; the guard matches on
# the path string, not file contents).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/secret-read-guard.sh"

# Failures are recorded in a FILE, not a variable — git-guard.test.sh (#383)
# and worktree-guard.test.sh both document why: a failing case inside a
# subshell can be silently swallowed and the suite still exits 0.
FAIL_MARKER="$(mktemp)"
trap 'rm -f "$FAIL_MARKER"' EXIT

# want, tool_name, key, value
check() {
  local want="$1" tool="$2" key="$3" val="$4" got
  python3 -c '
import json, sys
print(json.dumps({"tool_name": sys.argv[1], "tool_input": {sys.argv[2]: sys.argv[3]}}))
' "$tool" "$key" "$val" | "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: want exit $want, got $got for $tool $key='$val'"
    echo x >> "$FAIL_MARKER"
  fi
}

# --- Read tool: secrets paths must be blocked. ---
check 2 Read file_path "/home/agent/.config/secrets/gmi.env"
check 2 Read file_path "/home/agent/.redthread/agent.env"
check 2 Read file_path "/home/agent/.musclebuddy/prod.env"
check 2 Read file_path "/some/dir/agent.env"
check 2 Read file_path "/repo/.env"
check 2 Read file_path "/repo/.env.local"
check 2 Read file_path "/repo/.env.production"

# --- Read tool: name-only fixtures must pass. ---
check 0 Read file_path "/repo/.env.example"
check 0 Read file_path "/repo/.env.sample"
check 0 Read file_path "/repo/.env.template"
check 0 Read file_path "/repo/src/environment.ts"
check 0 Read file_path "/repo/README.md"

# --- Bash: the exact incident command (RedThreadEvents#2419). ---
check 2 Bash command 'cat ~/.redthread/agent.env'

# --- Bash: every blocked reader form, against each secrets-path flavor. ---
check 2 Bash command 'cat ~/.config/secrets/gmi.env'
check 2 Bash command 'head ~/.redthread/agent.env'
check 2 Bash command 'tail -f ~/.musclebuddy/prod.env'
check 2 Bash command 'less ~/.config/secrets/gmi.env'
check 2 Bash command 'more ~/.redthread/agent.env'
check 2 Bash command 'bat ~/.config/secrets/gmi.env'
check 2 Bash command 'nl ~/.redthread/agent.env'
check 2 Bash command 'xxd ~/.config/secrets/gmi.env'
check 2 Bash command 'od -c ~/.redthread/agent.env'
check 2 Bash command 'strings ~/.config/secrets/gmi.env'
check 2 Bash command 'base64 ~/.redthread/agent.env'
check 2 Bash command 'awk "{print}" ~/.config/secrets/gmi.env'
check 2 Bash command "awk '{print \$0}' ~/.redthread/agent.env"
check 2 Bash command 'sed ~/.config/secrets/gmi.env'
check 2 Bash command "sed -n '1,5p' ~/.redthread/agent.env"
check 2 Bash command "sed 's/foo/bar/' ~/.config/secrets/gmi.env"
check 2 Bash command 'grep TOKEN ~/.redthread/agent.env'
check 2 Bash command 'grep -A2 TOKEN ~/.config/secrets/gmi.env'
check 2 Bash command 'rg TOKEN ~/.redthread/agent.env'

# --- Bash: readers piped or chained still get caught at the source segment. ---
check 2 Bash command 'cat ~/.redthread/agent.env | head -1'
check 2 Bash command 'cd /tmp && cat ~/.config/secrets/gmi.env'
check 2 Bash command 'echo start; cat ~/.redthread/agent.env; echo end'

# --- Bash: generic *.env / .env.* patterns outside the named dirs. ---
check 2 Bash command 'cat /app/.env'
check 2 Bash command 'cat /app/.env.production'
check 2 Bash command 'cat /app/config/database.env'

# --- Bash: sanctioned redacted/name-only forms must pass. ---
check 0 Bash command "sed 's/=.*/=<redacted>/' ~/.config/secrets/gmi.env"
check 0 Bash command "sed 's/=.*/=<redacted>/' ~/.redthread/agent.env"
check 0 Bash command "grep -oE '^(export )?[A-Za-z_][A-Za-z0-9_]*=' ~/.config/secrets/gmi.env"
check 0 Bash command 'grep -l TOKEN ~/.redthread/agent.env'
check 0 Bash command 'grep -c TOKEN ~/.config/secrets/gmi.env'
check 0 Bash command 'grep -q TOKEN ~/.redthread/agent.env'
check 0 Bash command "awk -F= '{print \$1\"=<REDACTED>\"}' ~/.config/secrets/gmi.env"

# --- Bash: source / dot / set -a are the intended way to USE the file. ---
check 0 Bash command 'source ~/.config/secrets/gmi.env'
check 0 Bash command '. ~/.redthread/agent.env'
check 0 Bash command 'set -a; . ~/.config/secrets/gmi.env; set +a'

# --- Bash: metadata-only reads. ---
check 0 Bash command 'test -f ~/.redthread/agent.env'
check 0 Bash command 'ls ~/.config/secrets/'
check 0 Bash command 'stat ~/.redthread/agent.env'

# --- Bash: writing to the file is not a read. ---
check 0 Bash command 'echo "FOO=bar" >> ~/.config/secrets/gmi.env'
check 0 Bash command 'printf "FOO=bar\n" > ~/.redthread/agent.env'
check 0 Bash command 'cp .env.example .env'

# --- Bash: a command merely mentioning .env.example passes. ---
check 0 Bash command 'cat .env.example'
check 0 Bash command 'diff .env.example .env.sample'

# --- Bash: unrelated commands, including ones naming "cat"/"grep" elsewhere. ---
check 0 Bash command 'cat notes.txt'
check 0 Bash command 'grep TODO src/index.ts'
check 0 Bash command 'echo "run cat ~/.redthread/agent.env manually" > notes.txt'
check 0 Bash command 'npm run build'

# --- Bash: commands whose job is to print a credential (#455). ---
check 2 Bash command 'bin/staging-db-url.sh'
# shellcheck disable=SC2088 # the literal command text is the input
check 2 Bash command '~/.claude/bin/staging-db-url.sh'
check 2 Bash command 'cd ~/workspace/MuscleBuddy && bin/staging-db-url.sh'
check 2 Bash command 'railway variables --kv'
check 2 Bash command 'railway variables --service server --json | jq .'
check 2 Bash command 'vercel env pull --yes /dev/stdout'
check 2 Bash command 'printenv'
check 2 Bash command 'env'
check 2 Bash command 'env | sort'
check 2 Bash command 'export -p'
check 2 Bash command 'printenv DATABASE_URL'
check 2 Bash command 'echo $DATABASE_URL'
check 2 Bash command 'echo "$NODE_AUTH_TOKEN"'
check 2 Bash command 'printf "%s\n" "${SUPABASE_SERVICE_ROLE_KEY}"'
check 2 Bash command 'gh auth token'
check 2 Bash command 'gh auth status --show-token'
check 2 Bash command 'echo "$(bin/staging-db-url.sh)"'
check 2 Bash command 'bin/staging-db-url.sh | tee /tmp/url.txt'
check 2 Bash command 'bin/staging-db-url.sh >&2'
check 2 Bash command 'railway variables --kv | grep DATABASE'
check 2 Bash command 'env FOO=1 bin/staging-db-url.sh'
check 2 Bash command "$(printf 'cd /tmp\nprintenv GITHUB_TOKEN')"

# --- Bash: the same commands, captured, redirected or piped into a non-printing sink. ---
check 0 Bash command 'export STAGING_DATABASE_URL="$(~/.claude/bin/staging-db-url.sh)"'
check 0 Bash command 'psql "$(bin/staging-db-url.sh)" -c "select 1"'
check 0 Bash command 'DB=`bin/staging-db-url.sh`'
check 0 Bash command 'bin/staging-db-url.sh > /tmp/url.txt'
check 0 Bash command 'bin/staging-db-url.sh >/dev/null 2>&1 && echo ok'
check 0 Bash command "bin/staging-db-url.sh | sed 's/:[^:@]*@/:<redacted>@/'"
check 0 Bash command 'railway variables --kv > /tmp/vars.env'
check 0 Bash command 'railway variables --set FOO=bar'
check 0 Bash command 'vercel env pull .env.local --yes'
check 0 Bash command 'printenv NODE_AUTH_TOKEN | head -c 4'
check 0 Bash command 'printenv DATABASE_URL | wc -c'
check 0 Bash command 'printenv HOME'
check 0 Bash command 'echo ${#NODE_AUTH_TOKEN}'
check 0 Bash command 'echo ${NODE_AUTH_TOKEN:0:4}'
check 0 Bash command 'echo "${GITHUB_TOKEN:+set}"'
check 0 Bash command 'echo $HOME'
check 0 Bash command 'NODE_AUTH_TOKEN="$(gh auth token)" npm ci'
check 0 Bash command 'gh auth status'
check 0 Bash command 'env | grep -c TOKEN'
check 0 Bash command 'env FOO=1 npm test'
# The Supabase Management API returns the JWT secret and auth secrets (#479).
check 2 Bash command 'curl -s https://api.supabase.com/v1/projects/$ref/postgrest -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" | cut -c1-200'
check 2 Bash command 'curl -s "https://api.supabase.com/v1/projects/abc/config/auth" -H "Authorization: Bearer $T"'
check 2 Bash command 'curl -s https://api.supabase.com/v1/projects/abc/api-keys?reveal=true -H "Authorization: Bearer $T"'
check 0 Bash command 'curl -s https://api.supabase.com/v1/projects/abc/postgrest -H "Authorization: Bearer $T" > /tmp/pg.json'
check 0 Bash command 'curl -s https://api.supabase.com/v1/projects/abc/postgrest -H "Authorization: Bearer $T" | wc -c'
check 0 Bash command 'curl -s https://api.supabase.com/v1/projects/abc/database/query -H "Authorization: Bearer $T"'
check 0 Bash command 'curl -s https://api.supabase.com/v1/projects/abc/config/auth/sso -H "Authorization: Bearer $T"'
# A `|` inside a quoted regex is an alternation, not a pipe (#485).
check 0 Bash command "awk '/^diff --git a\\/(src\\/lib\\/(supabase-keys|env|supabase)\\.ts)/{p=1} p' x.diff | head -400"
check 0 Bash command 'grep -E "token|env|printenv" notes.md'
check 0 Bash command "rg 'a|env' src && echo done"
check 2 Bash command "echo 'a|b' && env"
check 2 Bash command "grep -c 'x|y' f; env | sort"
check 0 Bash command 'set -euo pipefail'
check 0 Bash command 'export FOO=bar'
check 0 Bash command 'bash bin/staging-db-url.test.sh'
check 0 Bash command "$(printf "cat > notes.md <<'EOF'\nrun printenv to see everything\nEOF")"

# --- Bash: a search PATTERN that ends in .env is not a secrets path (#459). ---
check 0 Bash command 'grep -n "process.env" apps/server/src/jobs/trend-sync.test.ts'
check 0 Bash command 'grep process.env src/config.ts'
check 0 Bash command "rg '\\.env' src/"
check 0 Bash command 'rg -n process.env src/'
check 0 Bash command 'grep DATABASE_URL README.md'
check 0 Bash command 'grep -rn --include=*.ts process.env apps/'
# ...but a real secrets target still refuses, whatever the pattern is.
check 2 Bash command 'grep process.env ~/.redthread/agent.env'
check 2 Bash command "rg '\\.env' /repo/.env"
check 2 Bash command 'grep -e process.env .env.local'
check 2 Bash command 'grep TOKEN ~/.config/secrets/gmi.env'
check 2 Bash command 'grep -n process.env src/a.ts .env'

if [ -s "$FAIL_MARKER" ]; then
  echo "FAILED: $(wc -l < "$FAIL_MARKER") case(s)."
  exit 1
fi
echo "All secret-read-guard.test.sh cases passed."
