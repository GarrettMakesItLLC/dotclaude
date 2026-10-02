#!/usr/bin/env bash
# Self-test for agent-env-build.sh on a fixture repo, stub `gh`/`railway` CLIs
# and a throwaway HOME: source priority, bare vs aliased vs namespaced exports,
# the machine-wide fallback and its limits, the Railway fallback and when it is
# NOT consulted, cloud.env as the last source, and a run from a worktree.
#   bash bin/agent-env-build.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEB="$HERE/agent-env-build.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

unset BASH_ENV
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset RAILWAY_TOKEN REPO_MANIFEST GITHUB_TOKEN
mkdir -p "$HOME" "$TMP/bin"
cat >"$TMP/bin/gh" <<'S'
#!/usr/bin/env bash
[ "$1 $2" = "auth token" ] && echo gho_fromgh
S
cat >"$TMP/bin/railway" <<'S'
#!/usr/bin/env bash
echo x >>"$RAILWAY_CALLS"
cat "$RAILWAY_FIXTURE"
S
chmod +x "$TMP/bin/gh" "$TMP/bin/railway"
export PATH="$TMP/bin:$PATH" RAILWAY_CALLS="$TMP/railway.calls" RAILWAY_FIXTURE="$TMP/railway.kv"

REPO="$TMP/repo"
git init -q -b main "$REPO"
mkdir -p "$REPO/.claude" "$REPO/apps/server"
cat >"$REPO/.claude/repo.json" <<'J'
{ "name": "Demo", "envPrefix": "DM", "stateDir": "~/.demo",
  "credentials": {
    "sources": ["apps/server/.env.local", "apps/server/.env", ".env"],
    "direct": ["SUPABASE_URL", "VAPID_PUBLIC_KEY", "ANTHROPIC_API_KEY", "NODE_AUTH_TOKEN", "FROM_CLOUD", "SIBLING_KEY"],
    "aliasDirect": true,
    "namespaced": { "DM_PROD_DATABASE_URL": "DATABASE_URL", "DM_PROD_DIRECT_URL": "DIRECT_URL" },
    "machineWide": ["NODE_AUTH_TOKEN"],
    "githubToken": true,
    "railway": { "service": "server", "environment": "production",
                 "fallback": ["VAPID_PUBLIC_KEY", "DIRECT_URL"] } } }
J
git -C "$REPO" add .claude && git -C "$REPO" commit -q -m init
printf 'SUPABASE_URL=\n' >"$REPO/apps/server/.env.local"
printf 'SUPABASE_URL="https://demo.supabase.co"\n' >"$REPO/apps/server/.env"
printf "DATABASE_URL='postgres://local'\nANTHROPIC_API_KEY=sk-root\n" >"$REPO/.env"
mkdir -p "$HOME/.demo"
printf 'FROM_CLOUD=cloudval\nSUPABASE_URL=https://wrong-cloud\n' >"$HOME/.demo/cloud.env"
printf 'VAPID_PUBLIC_KEY=vapid-rw\nDIRECT_URL=postgres://direct-rw\nDATABASE_URL=postgres://should-not-win\n' >"$RAILWAY_FIXTURE"
printf '[ -f "$HOME/.config/secrets/gmi.env" ] && . "$HOME/.config/secrets/gmi.env"\n' >"$HOME/.bashrc"

get() { ( set +u; unset "$1"; . "$HOME/.demo/agent.env" >/dev/null 2>&1; printf '%s' "${!1:-}" ); }
run() { OUT="$(cd "${RUN_DIR:-$REPO}" && env NODE_AUTH_TOKEN=ghp_ambient SIBLING_KEY=from-sibling "$AEB" 2>&1)"; RC=$?; }

echo "agent-env-build: sources, priority and export shapes"
: >"$RAILWAY_CALLS"
run
F="$HOME/.demo/agent.env"
[ "$RC" = 0 ] && ok "exits 0" || bad "rc=$RC $OUT"
[ "$(get SUPABASE_URL)" = "https://demo.supabase.co" ] && ok "an empty value in an earlier source falls through to the next" || bad "SUPABASE_URL=$(get SUPABASE_URL)"
[ "$(get DM_SUPABASE_URL)" = "https://demo.supabase.co" ] && ok "direct keys also exported under the prefix alias" || bad "alias missing"
[ "$(get DM_PROD_DATABASE_URL)" = "postgres://local" ] && ok "namespaced export, local source wins over Railway" || bad "DM_PROD_DATABASE_URL=$(get DM_PROD_DATABASE_URL)"
! grep -qE '^export (DATABASE_URL|DIRECT_URL)=' "$F" && ok "no bare database URL is ever exported" || bad "bare DB URL exported"
[ "$(get FROM_CLOUD)" = cloudval ] && ok "cloud.env is read" || bad "FROM_CLOUD missing"
[ "$(get NODE_AUTH_TOKEN)" = ghp_ambient ] && ok "machine-wide key falls back to the ambient shell" || bad "NODE_AUTH_TOKEN=$(get NODE_AUTH_TOKEN)"
! grep -q 'SIBLING_KEY=' "$F" && grep -q '^unset DM_SIBLING_KEY$' "$F" && ok "a repo key in the ambient shell is NOT trusted; its alias is unset" || bad "sibling: $(grep SIBLING "$F")"
[ "$(get GITHUB_TOKEN)" = gho_fromgh ] && ! grep -q 'gho_fromgh' <(grep NODE_AUTH_TOKEN "$F") && ok "GITHUB_TOKEN from gh, never as NODE_AUTH_TOKEN" || bad "gh token handling"

! grep -qE '^export ANTHROPIC_(API_KEY|AUTH_TOKEN)=' "$F" && [ "$(get DM_ANTHROPIC_API_KEY)" = sk-root ] && ok "the Anthropic key is exported only under the alias" || bad "anthropic: $(grep ANTHROPIC "$F")"
[ "$( ( set +u; export ANTHROPIC_API_KEY=sk-older-bundle; . "$F" >/dev/null 2>&1; printf '%s' "${ANTHROPIC_API_KEY:-}" ) )" = "" ] && ok "sourcing the bundle unsets a bare Anthropic key from an earlier one" || bad "bare Anthropic key survives sourcing"

echo "agent-env-build: the Railway fallback"
[ "$(get VAPID_PUBLIC_KEY)" = vapid-rw ] && [ "$(get DM_PROD_DIRECT_URL)" = postgres://direct-rw ] && ok "missing fallback keys come from Railway" || bad "railway: $OUT"
[ "$(wc -l <"$RAILWAY_CALLS")" = 1 ] && ok "Railway fetched exactly once" || bad "railway calls: $(wc -l <"$RAILWAY_CALLS")"
grep -q 'read from Railway.*VAPID_PUBLIC_KEY' <<<"$OUT" && ok "Railway provenance is reported" || bad "no provenance: $OUT"
printf 'VAPID_PUBLIC_KEY=v-local\nDIRECT_URL=postgres://d-local\n' >>"$REPO/.env"
: >"$RAILWAY_CALLS"
run
[ ! -s "$RAILWAY_CALLS" ] && ok "a complete local env never calls Railway" || bad "Railway called anyway"

echo "agent-env-build: the file"
[ "$(stat -c %a "$F")" = 600 ] && ok "mode 600" || bad "mode $(stat -c %a "$F")"
src_line="$(grep -n 'demo/agent.env' "$HOME/.bashrc" | cut -d: -f1)"
gmi_line="$(grep -n 'gmi.env' "$HOME/.bashrc" | tail -1 | cut -d: -f1)"
[ -n "$src_line" ] && [ "$src_line" -lt "$gmi_line" ] && ok "sourced from ~/.bashrc above gmi.env" || bad "bashrc: $(cat "$HOME/.bashrc")"

echo "agent-env-build: from a linked worktree it reads the main checkout's env"
git -C "$REPO" worktree add -q "$REPO/.worktrees/wt" -b wt
rm -f "$F"
RUN_DIR="$REPO/.worktrees/wt" run
[ "$RC" = 0 ] && [ "$(get DM_ANTHROPIC_API_KEY)" = sk-root ] && ok "main tree .env used" || bad "rc=$RC $OUT"

echo "agent-env-build: no manifest is refused"
git init -q "$TMP/bare"
OUT="$(cd "$TMP/bare" && "$AEB" 2>&1)"; RC=$?
[ "$RC" != 0 ] && grep -q 'no .claude/repo.json' <<<"$OUT" && ok "refused" || bad "rc=$RC $OUT"

exit "$fail"
