#!/usr/bin/env bash
# Self-test for setup-worktree.sh on fixture repos with stub install commands
# (no npm, no network): the install strategy (hook shims, env files, install
# under the lock, retry, scope verification, prisma/post steps, the sweep lock,
# --check) and the mirror strategy (nested copies, .bin links, workspace links,
# drift detection and refresh, a stale main tree refused).
#   bash bin/setup-worktree.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW="$HERE/setup-worktree.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

command -v node >/dev/null 2>&1 || { echo "  skip: node is required for the mirror strategy"; exit 0; }
unset BASH_ENV REPO_MANIFEST NODE_AUTH_TOKEN
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export CHECK_LOCK_DIR="$TMP/locks" CHECK_MAX_LOAD=999999 CHECK_MIN_AVAIL_MB=0 CHECK_TIMEOUT=60
mkdir -p "$HOME/.config/secrets" "$CHECK_LOCK_DIR"
echo 'export NODE_AUTH_TOKEN=ghp_frompat' >"$HOME/.config/secrets/gmi.env"

run() { OUT="$("$SW" "$@" 2>&1)"; RC=$?; }

# --------------------------------------------------------------------------
echo "setup-worktree: install strategy"
R="$TMP/inst"
git init -q -b main "$R"
mkdir -p "$R/.claude" "$R/apps/web"
cat >"$R/.claude/repo.json" <<'J'
{ "stateDir": "~/.inst",
  "worktree": { "strategy": "install",
    "envFiles": ["apps/web/.env"],
    "install": "sh \"$MAIN_TREE/install-stub.sh\"",
    "requireScopes": ["@gmi"],
    "prismaGenerate": "touch prisma.generated",
    "postSteps": ["touch post.ran"],
    "lockWorktree": "agent worktree — test" } }
J
git -C "$R" add . && git -C "$R" commit -q -m init
mkdir -p "$R/.husky/_" && echo shim >"$R/.husky/_/h"
echo 'VITE=1' >"$R/apps/web/.env"
echo 'DATABASE_URL=live' >"$R/.env"
# The stub fails on its first call when FAIL_ONCE exists, records whether it ran
# under the writer lock and which token it saw, and installs the scope only when
# NO_SCOPE is absent.
cat >"$R/install-stub.sh" <<'S'
if [ -f "$MAIN_TREE/FAIL_ONCE" ]; then rm -f "$MAIN_TREE/FAIL_ONCE"; exit 1; fi
echo "held=${CHECK_LOCK_HELD:-} token=${NODE_AUTH_TOKEN:-}" >>"$MAIN_TREE/install.log"
mkdir -p node_modules/lodash
[ -f "$MAIN_TREE/NO_SCOPE" ] || mkdir -p node_modules/@gmi/x
S
git -C "$R" worktree add -q "$R/.worktrees/a" -b a
W="$R/.worktrees/a"
run "$W"
[ "$RC" = 0 ] && ok "exits 0" || bad "rc=$RC $OUT"
[ -f "$W/.husky/_/h" ] && ok "husky shims copied" || bad "no shims"
[ -f "$W/apps/web/.env" ] && [ ! -f "$W/.env" ] && ok "listed env files copied, root .env withheld" || bad "env copy wrong"
grep -q 'held=1 token=ghp_frompat' "$R/install.log" && ok "install ran under the writer lock with the PAT from gmi.env" || bad "install.log: $(cat "$R/install.log" 2>&1)"
[ -f "$W/prisma.generated" ] && [ -f "$W/post.ran" ] && ok "prisma and post steps ran in the worktree" || bad "steps did not run"
git -C "$R" worktree list --porcelain | grep -A3 "worktree $W" | grep -q '^locked' && ok "worktree locked against sweeps" || bad "not locked"
run --check "$W"
[ "$RC" = 0 ] && ok "--check passes on a bootstrapped tree" || bad "--check rc=$RC $OUT"
rm -rf "$W/node_modules/@gmi"
run --check "$W"
[ "$RC" = 1 ] && grep -q '@gmi' <<<"$OUT" && ok "--check names a missing scope" || bad "--check rc=$RC $OUT"

touch "$R/FAIL_ONCE"; : >"$R/install.log"
run "$W"
[ "$RC" = 0 ] && [ "$(wc -l <"$R/install.log")" = 1 ] && ok "a failed install is retried once from an empty tree" || bad "retry: rc=$RC $OUT"
touch "$R/NO_SCOPE"; rm -rf "$W/node_modules"
run "$W"
[ "$RC" = 1 ] && grep -q 'missing @gmi after install' <<<"$OUT" && ok "an install that silently omitted a scope fails" || bad "scope: rc=$RC $OUT"
rm -f "$R/NO_SCOPE"
run "$R"
[ "$RC" = 0 ] && grep -q 'main checkout, nothing to bootstrap' <<<"$OUT" && ok "the main checkout is left alone" || bad "main: $OUT"

# --------------------------------------------------------------------------
echo "setup-worktree: mirror strategy"
M="$TMP/mir"
git init -q -b main "$M"
mkdir -p "$M/.claude" "$M/apps/web" "$M/packages/core"
cat >"$M/.claude/repo.json" <<'J'
{ "worktree": { "strategy": "mirror", "linkRootBin": true, "workspaceScope": "@demo",
                "checkSteps": ["test -f apps/web/package.json"] } }
J
echo '{ "name": "@demo/web", "version": "0.0.0" }' >"$M/apps/web/package.json"
echo '{ "name": "@demo/core", "version": "0.0.0" }' >"$M/packages/core/package.json"
echo '{ "lockfileVersion": 3, "packages": { "apps/web/node_modules/foo": { "version": "1.0.0" } } }' >"$M/package-lock.json"
git -C "$M" add . && git -C "$M" commit -q -m init
# The main tree's install: a nested dep, a root bin, npm's install stamp.
mkdir -p "$M/apps/web/node_modules/foo" "$M/node_modules/tool/bin" "$M/node_modules/.bin"
echo '{ "name": "foo", "version": "1.0.0" }' >"$M/apps/web/node_modules/foo/package.json"
echo 'module.exports = 1' >"$M/apps/web/node_modules/foo/index.js"
echo '#!/bin/sh' >"$M/node_modules/tool/bin/t.js"
ln -s ../tool/bin/t.js "$M/node_modules/.bin/tool"
sleep 1; echo '{}' >"$M/node_modules/.package-lock.json"
git -C "$M" worktree add -q "$M/.worktrees/b" -b b
V="$M/.worktrees/b"
run "$V"
[ "$RC" = 0 ] && ok "exits 0" || bad "rc=$RC $OUT"
[ -f "$V/apps/web/node_modules/foo/index.js" ] && [ ! -L "$V/apps/web/node_modules" ] && ok "nested deps copied as real files" || bad "no nested copy"
[ -L "$V/node_modules/.bin/tool" ] && [ "$(readlink "$V/node_modules/.bin/tool")" = "$M/node_modules/tool/bin/t.js" ] && ok ".bin links point at the resolved main-tree binary" || bad ".bin: $(ls -la "$V/node_modules/.bin" 2>&1)"
[ "$(readlink "$V/node_modules/@demo/core")" = "../../packages/core" ] && ok "workspace scope linked to this worktree's own package" || bad "scope link: $(ls -la "$V/node_modules/@demo" 2>&1)"
run --check "$V"
[ "$RC" = 0 ] && ok "--check passes, checkSteps ran" || bad "--check rc=$RC $OUT"

echo '{ "name": "foo", "version": "2.0.0" }' >"$M/apps/web/node_modules/foo/package.json"
echo 'x' >"$M/apps/web/node_modules/foo/new.js"
run --check "$V"
[ "$RC" = 1 ] && grep -q 'held at a version.*apps/web/foo' <<<"$OUT" && ok "--check reports a copy the main tree moved off" || bad "drift: rc=$RC $OUT"
run "$V"
[ "$RC" = 0 ] && grep -q '"2.0.0"' "$V/apps/web/node_modules/foo/package.json" && [ -f "$V/apps/web/node_modules/foo/new.js" ] && ok "a re-run refreshes the drifted package" || bad "refresh: rc=$RC $OUT"
rm "$V/apps/web/node_modules/foo/index.js"
run --check "$V"
[ "$RC" = 1 ] && grep -q 'missing or incomplete: apps/web/foo' <<<"$OUT" && ok "a same-version copy missing files is caught" || bad "incomplete: rc=$RC $OUT"

sleep 1; touch "$M/package-lock.json"
run "$V"
[ "$RC" = 1 ] && grep -q 'predate its own package-lock.json' <<<"$OUT" && ok "a main tree older than its lockfile is refused as a source" || bad "stale main: rc=$RC $OUT"

echo "setup-worktree: a repo with no manifest is refused"
git init -q "$TMP/none"
run "$TMP/none"
[ "$RC" = 1 ] && grep -q 'has not opted in' <<<"$OUT" && ok "refused" || bad "rc=$RC $OUT"

exit "$fail"
