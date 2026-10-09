#!/usr/bin/env bash
# Self-test for ops-pull.sh against stub `vercel` and `railway` CLIs and a
# throwaway HOME: the OPS_ channel lands exported with the prefix stripped,
# unreadable and shadowing vars are refused, file secrets are materialised and
# never exported, and cloud values land unsourced with their mapped names.
#   bash bin/ops-pull.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OP="$HERE/ops-pull.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

unset BASH_ENV
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset RAILWAY_TOKEN REPO_MANIFEST
mkdir -p "$HOME" "$TMP/bin"

# Stub CLIs. `vercel env pull <out> --environment=<env>` copies the fixture for
# that environment; `railway variables ... --kv` prints a fixture.
cat >"$TMP/bin/vercel" <<'S'
#!/usr/bin/env bash
[ "$1" = env ] && [ "$2" = pull ] || exit 2
env_name="${4#--environment=}"
cp "$VERCEL_FIXTURE_DIR/${VERCEL_PROJECT_ID:+$VERCEL_PROJECT_ID/}$env_name.env" "$3"
S
cat >"$TMP/bin/railway" <<'S'
#!/usr/bin/env bash
[ -n "${RAILWAY_TOKEN:-}" ] && { echo "token leaked into the CLI" >&2; exit 9; }
cat "$RAILWAY_FIXTURE"
S
chmod +x "$TMP/bin/vercel" "$TMP/bin/railway"
export PATH="$TMP/bin:$PATH" VERCEL_FIXTURE_DIR="$TMP/vf" RAILWAY_FIXTURE="$TMP/railway.kv"
mkdir -p "$VERCEL_FIXTURE_DIR"

REPO="$TMP/repo"
git init -q -b main "$REPO"
mkdir -p "$REPO/.vercel" "$REPO/.claude"
echo '{}' >"$REPO/.vercel/project.json"
git -C "$REPO" commit -q --allow-empty -m init

manifest() { cat >"$REPO/.claude/repo.json"; }
run() { OUT="$(cd "${RUN_DIR:-$REPO}" && "$OP" 2>&1)"; RC=$?; }

echo "ops-pull: no manifest is refused by name"
run
[ "$RC" != 0 ] && grep -q "no .claude/repo.json" <<<"$OUT" && ok "refused" || bad "rc=$RC $OUT"

echo "ops-pull: the OPS_ channel"
manifest <<'J'
{ "name": "Demo", "envPrefix": "DM", "stateDir": "~/.demo",
  "ops": { "channel": true, "unsetAlways": ["DM_RAILWAY_TOKEN"],
           "fileSecrets": ["BUNDLE_B64",
             { "name": "KEY_P8_B64", "path": "signing/AuthKey_{KEY_ID}.p8", "mustContain": "BEGIN PRIVATE KEY" }] } }
J
pem="$(printf -- '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n' | base64 -w0)"
cat >"$VERCEL_FIXTURE_DIR/development.env" <<E
OPS_MONITOR_KEY="m-123"
OPS_UPLOAD_POST_API_KEY="u-456"
OPS_STALE="[SENSITIVE]"
OPS_BUNDLE_B64="Zm9vCg=="
OPS_KEY_P8_B64="$pem"
OPS_KEY_ID="ABC123"
VITE_NOT_OPS="x"
E
printf '# pre\n[ -f "$HOME/.config/secrets/gmi.env" ] && . "$HOME/.config/secrets/gmi.env"\n' >"$HOME/.bashrc"
run
OPS="$HOME/.demo/ops.env"
[ "$RC" = 1 ] && ok "exits 1 because a var is unreadable" || bad "rc=$RC $OUT"
grep -q '^export MONITOR_KEY="m-123"$' "$OPS" && ok "OPS_ prefix stripped, exported" || bad "ops.env: $(cat "$OPS")"
! grep -q 'NOT_OPS' "$OPS" && ok "non-OPS vars are not carried" || bad "non-OPS leaked"
! grep -q 'STALE' "$OPS" && grep -q 'OPS_STALE' <<<"$OUT" && ok "[SENSITIVE] dropped and named" || bad "sensitive: $OUT"
! grep -q '^export BUNDLE_B64\|^export KEY_P8_B64' "$OPS" && grep -q '^unset BUNDLE_B64 KEY_P8_B64$' "$OPS" && ok "file secrets never exported, and unset" || bad "file secrets: $(cat "$OPS")"
grep -q '^unset DM_RAILWAY_TOKEN$' "$OPS" && ok "unsetAlways emitted" || bad "unsetAlways missing"
# Sourcing applies lines in order, so an export below an unset re-sets what it cleared.
last_export="$(grep -n '^export ' "$OPS" | tail -1 | cut -d: -f1)"
first_unset="$(grep -n '^unset ' "$OPS" | head -1 | cut -d: -f1)"
[ -n "$last_export" ] && [ -n "$first_unset" ] && [ "$first_unset" -gt "$last_export" ] \
  && ok "every unset comes after the last export" || bad "unset at line ${first_unset:-none}, last export at ${last_export:-none}"
KEYF="$HOME/.demo/signing/AuthKey_ABC123.p8"
[ -f "$KEYF" ] && grep -q 'BEGIN PRIVATE KEY' "$KEYF" && [ "$(stat -c %a "$KEYF")" = 600 ] && ok "file secret decoded to its {VAR} path, mode 600" || bad "key file: $(ls -la "$HOME/.demo/signing" 2>&1)"
[ "$(stat -c %a "$OPS")" = 600 ] && ok "ops.env is mode 600" || bad "mode $(stat -c %a "$OPS")"
src_line="$(grep -n 'demo/ops.env' "$HOME/.bashrc" | cut -d: -f1)"
gmi_line="$(grep -n 'gmi.env' "$HOME/.bashrc" | tail -1 | cut -d: -f1)"
[ -n "$src_line" ] && [ "$src_line" -lt "$gmi_line" ] && ok "sourced from ~/.bashrc, above gmi.env" || bad "bashrc: $(cat "$HOME/.bashrc")"
run
[ "$(grep -c 'demo/ops.env' "$HOME/.bashrc")" = 1 ] && ok "the source line is added once" || bad "duplicated source line"
cp "$HOME/.bashrc" "$TMP/bashrc.keep"
# shellcheck disable=SC2016 # the literal line a repo's own older script wrote
printf '[ -f "$HOME/.demo/ops.env" ] && . "$HOME/.demo/ops.env"\n[ -f "$HOME/.config/secrets/gmi.env" ] && . "$HOME/.config/secrets/gmi.env"\n' >"$HOME/.bashrc"
run
[ "$(grep -c 'demo/ops.env' "$HOME/.bashrc")" = 1 ] && ok "a \$HOME-spelled source line counts as present" || bad "duplicated: $(cat "$HOME/.bashrc")"
cp "$TMP/bashrc.keep" "$HOME/.bashrc"

echo "ops-pull: a file secret that does not decode to what it must contain is deleted"
bad_pem="$(printf 'not a key' | base64 -w0)"
sed -i "s|^OPS_KEY_P8_B64=.*|OPS_KEY_P8_B64=\"$bad_pem\"|; /OPS_STALE/d" "$VERCEL_FIXTURE_DIR/development.env"
run
[ "$RC" = 1 ] && [ ! -f "$KEYF" ] && grep -q 'did not decode' <<<"$OUT" && ok "removed and reported" || bad "rc=$RC $OUT"

echo "ops-pull: a var that would shadow a CLI login is refused, and nothing is written"
rm -f "$OPS"
echo 'OPS_RAILWAY_TOKEN="abc"' >>"$VERCEL_FIXTURE_DIR/development.env"
run
[ "$RC" = 1 ] && [ ! -f "$OPS" ] && grep -q 'OPS_RAILWAY_TOKEN would export a bare' <<<"$OUT" && ok "refused" || bad "rc=$RC $OUT"
sed -i '/OPS_RAILWAY_TOKEN/d' "$VERCEL_FIXTURE_DIR/development.env"
echo 'OPS_DM_RAILWAY_TOKEN="abc"' >>"$VERCEL_FIXTURE_DIR/development.env"
run
[ "$RC" = 1 ] && grep -q 'ops.unsetAlways' <<<"$OUT" && ok "an unsetAlways name on the channel is refused" || bad "rc=$RC $OUT"

echo "ops-pull: the channel refuses a deploy target, and leaves ops.env alone"
manifest <<'J'
{ "name": "Demo", "envPrefix": "DM", "stateDir": "~/.demo", "ops": { "channel": true, "vercelEnvironment": "production" } }
J
echo '# kept' >"$OPS"
printf 'OPS_MONITOR_KEY="m-123"\n' >"$VERCEL_FIXTURE_DIR/production.env"
run
[ "$RC" = 1 ] && grep -q 'will not read Vercel \[production\]' <<<"$OUT" && [ "$(cat "$OPS")" = '# kept' ] && ok "production refused" || bad "rc=$RC $OUT"
OUT="$(cd "$REPO" && "$OP" preview 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'will not read Vercel \[preview\]' <<<"$OUT" && ok "preview refused, also as an argument" || bad "rc=$RC $OUT"

echo "ops-pull: an empty channel is a mis-pointed one, and ops.env is kept"
manifest <<'J'
{ "name": "Demo", "envPrefix": "DM", "stateDir": "~/.demo", "ops": { "channel": true } }
J
printf 'VITE_NOT_OPS="x"\n' >"$VERCEL_FIXTURE_DIR/development.env"
run
[ "$RC" = 1 ] && grep -q 'returned no OPS_ variables' <<<"$OUT" && [ "$(cat "$OPS")" = '# kept' ] && ok "refused, ops.env untouched" || bad "rc=$RC $OUT"

echo "ops-pull: ops.vercelProject pulls the channel from its own project, without the checkout's link"
manifest <<'J'
{ "name": "Demo", "envPrefix": "DM", "stateDir": "~/.demo",
  "ops": { "channel": true, "vercelProject": { "projectId": "prj_ops", "orgId": "team_x" } } }
J
mkdir -p "$VERCEL_FIXTURE_DIR/prj_ops"
printf 'OPS_MONITOR_KEY="from-ops-project"\n' >"$VERCEL_FIXTURE_DIR/prj_ops/development.env"
mv "$REPO/.vercel/project.json" "$TMP/project.json.keep"
run
mv "$TMP/project.json.keep" "$REPO/.vercel/project.json"
[ "$RC" = 0 ] && grep -q '^export MONITOR_KEY="from-ops-project"$' "$OPS" && ok "read from the named project" || bad "rc=$RC $OUT"
manifest <<'J'
{ "name": "Demo", "stateDir": "~/.demo", "ops": { "channel": true, "vercelProject": { "projectId": "prj_ops" } } }
J
run
[ "$RC" = 1 ] && grep -q 'needs both projectId and orgId' <<<"$OUT" && ok "a half-named project is refused" || bad "rc=$RC $OUT"

echo "ops-pull: cloud values land in cloud.env, unsourced, under mapped names"
manifest <<'J'
{ "name": "Demo", "envPrefix": "DM", "stateDir": "~/.demo",
  "credentials": { "railway": { "service": "server", "environment": "production" } },
  "ops": { "vercelEnvironment": "development",
           "vercelKeys": ["VITE_SUPABASE_URL", "VITE_MISSING"],
           "railwayKeys": { "DATABASE_URL": "DATABASE_URL", "NODE_AUTH_TOKEN": "GMI_PACKAGES_TOKEN" } } }
J
printf 'VITE_SUPABASE_URL="https://x.supabase.co"\n' >"$VERCEL_FIXTURE_DIR/development.env"
printf 'DATABASE_URL=postgres://prod\nNODE_AUTH_TOKEN=ghp_x\nOTHER=1\n' >"$RAILWAY_FIXTURE"
RAILWAY_TOKEN=stale run
CLOUD="$HOME/.demo/cloud.env"
[ "$RC" = 0 ] && ok "exits 0" || bad "rc=$RC $OUT"
grep -q '^VITE_SUPABASE_URL=https://x.supabase.co$' "$CLOUD" && grep -q '^DATABASE_URL=postgres://prod$' "$CLOUD" && grep -q '^GMI_PACKAGES_TOKEN=ghp_x$' "$CLOUD" && ok "values written with mapped names" || bad "cloud.env: $(sed 's/=.*/=…/' "$CLOUD")"
! grep -q '^export\|^OTHER=\|^NODE_AUTH_TOKEN=' "$CLOUD" && ok "no exports, no unmapped keys" || bad "cloud.env carries extras"
! grep -q 'cloud.env' "$HOME/.bashrc" && ok "cloud.env is never sourced" || bad "cloud.env added to bashrc"
grep -q 'token leaked' <<<"$OUT" && bad "RAILWAY_TOKEN reached the CLI" || ok "the CLI route runs with the token stripped"

echo "ops-pull: runs from a linked worktree against the main tree's .vercel link"
git -C "$REPO" worktree add -q "$REPO/.worktrees/wt" -b wt 2>/dev/null
cp "$REPO/.claude/repo.json" "$REPO/.worktrees/wt/.claude/repo.json" 2>/dev/null || { mkdir -p "$REPO/.worktrees/wt/.claude"; cp "$REPO/.claude/repo.json" "$REPO/.worktrees/wt/.claude/"; }
rm -f "$CLOUD"
RUN_DIR="$REPO/.worktrees/wt" run
[ "$RC" = 0 ] && [ -f "$CLOUD" ] && ok "pulled from the worktree" || bad "rc=$RC $OUT"

exit "$fail"
