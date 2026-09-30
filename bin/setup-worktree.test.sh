#!/usr/bin/env bash
# Self-test for setup-worktree.sh on fixture repos with stub install commands
# (no npm, no network): the install strategy (hook shims, env files, install
# under the lock, retry, scope verification, prisma/post steps, the sweep lock,
# --check) and the mirror strategy (nested copies, .bin links, workspace links,
# drift detection and refresh, a stale main tree refused, .bin links re-pointed
# once the worktree has its own package, packages a branch moved left out of the
# nest, lock timeouts, the envPrefix-named stamp and the state postSteps see).
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

# --------------------------------------------------------------------------
# A fresh mirror fixture: main tree with one nested dep (apps/web: foo@1), a root
# tool with a .bin link, the install stamp, and one worktree. $1 = dir, $2 = the
# manifest JSON.
mk_mirror() {
  local m="$1"
  git init -q -b main "$m"
  mkdir -p "$m/.claude" "$m/apps/web"
  printf '%s\n' "$2" >"$m/.claude/repo.json"
  echo '{ "name": "@demo/web", "version": "0.0.0" }' >"$m/apps/web/package.json"
  echo '{ "lockfileVersion": 3, "packages": { "apps/web/node_modules/foo": { "version": "1.0.0" }, "apps/web/node_modules/bar": { "version": "1.0.0" } } }' >"$m/package-lock.json"
  git -C "$m" add . && git -C "$m" commit -q -m init
  mkdir -p "$m/apps/web/node_modules/foo" "$m/apps/web/node_modules/bar/bin" "$m/apps/web/node_modules/.bin" "$m/node_modules/tool/bin" "$m/node_modules/.bin"
  echo '{ "name": "foo", "version": "1.0.0" }' >"$m/apps/web/node_modules/foo/package.json"
  echo '{ "name": "bar", "version": "1.0.0" }' >"$m/apps/web/node_modules/bar/package.json"
  echo '#!/bin/sh' >"$m/apps/web/node_modules/bar/bin/bar.js"
  ln -s ../bar/bin/bar.js "$m/apps/web/node_modules/.bin/bar"
  echo '#!/bin/sh' >"$m/node_modules/tool/bin/t.js"
  ln -s ../tool/bin/t.js "$m/node_modules/.bin/tool"
  touch -d '2000-01-01' "$m/package-lock.json"
  echo '{}' >"$m/node_modules/.package-lock.json"
  git -C "$m" worktree add -q "$m/.worktrees/w" -b w
}

echo "setup-worktree: mirror — a worktree with packages of its own"
P="$TMP/own"
mk_mirror "$P" '{ "envPrefix": "DEMO", "worktree": { "strategy": "mirror", "linkRootBin": true,
  "postSteps": ["env | grep ^SETUP_WORKTREE_ | sort >>\"$WORKTREE/.step-env\"; echo --- >>\"$WORKTREE/.step-env\""] } }'
X="$P/.worktrees/w"
run "$X"
[ "$RC" = 0 ] && ok "exits 0" || bad "rc=$RC $OUT"
[ -f "$(git -C "$X" rev-parse --path-format=absolute --git-dir)/demo-nested-deps-stamp" ] && ok "the copy stamp is named from envPrefix" || bad "no demo-nested-deps-stamp"
grep -q '^SETUP_WORKTREE_STALE=1$' "$X/.step-env" && grep -q '^SETUP_WORKTREE_COPIED_STAMP=$' "$X/.step-env" \
  && grep -q "^SETUP_WORKTREE_LOCK=.*with-check-lock.sh$" "$X/.step-env" \
  && ok "postSteps see the state from before the copy (stale, nothing copied yet)" || bad "step env: $(cat "$X/.step-env")"
: >"$X/.step-env"
run "$X"
grep -q '^SETUP_WORKTREE_STALE=0$' "$X/.step-env" && grep -q '^SETUP_WORKTREE_COPIED_STAMP=[0-9]' "$X/.step-env" \
  && ok "a re-run tells postSteps the copy is current and stamped" || bad "step env: $(cat "$X/.step-env")"

# The worktree gains its own copy of the root tool (an install run here). The
# .bin link still runs the MAIN tree's copy against this tree's packages.
mkdir -p "$X/node_modules/tool/bin" && echo '#!/bin/sh' >"$X/node_modules/tool/bin/t.js"
run --check "$X"
[ "$RC" = 1 ] && grep -q "main tree's copy of a package this worktree has itself: tool" <<<"$OUT" \
  && ok "--check names a .bin link that splits one tool across two trees" || bad "split --check: rc=$RC $OUT"
[ "$(readlink "$X/node_modules/.bin/tool")" = "$P/node_modules/tool/bin/t.js" ] && ok "--check changed nothing" || bad "--check wrote"
run "$X"
[ "$RC" = 0 ] && [ "$(readlink "$X/node_modules/.bin/tool")" = "../tool/bin/t.js" ] && grep -q 're-pointed 1 root bin' <<<"$OUT" \
  && ok "a run re-points it at the worktree's own package, relative" || bad "re-point: rc=$RC $(readlink "$X/node_modules/.bin/tool") $OUT"
run --check "$X"
[ "$RC" = 0 ] && ok "--check passes once re-pointed" || bad "--check after re-point: rc=$RC $OUT"

echo "setup-worktree: mirror — a branch that hoisted a nested package"
H="$TMP/hoist"
mk_mirror "$H" '{ "worktree": { "strategy": "mirror",
  "postSteps": ["printf %s \"$SETUP_WORKTREE_EXEMPT\" >\"$WORKTREE/.exempt\""] } }'
Y="$H/.worktrees/w"
# The branch moved bar out of apps/web to its own root at 2.0.0 and installed it.
echo '{ "lockfileVersion": 3, "packages": { "apps/web/node_modules/foo": { "version": "1.0.0" }, "node_modules/bar": { "version": "2.0.0" } } }' >"$Y/package-lock.json"
mkdir -p "$Y/node_modules/bar" && echo '{ "name": "bar", "version": "2.0.0" }' >"$Y/node_modules/bar/package.json"
run "$Y"
[ "$RC" = 0 ] && ok "exits 0" || bad "rc=$RC $OUT"
[ -f "$Y/apps/web/node_modules/foo/package.json" ] && ok "a package the branch did not move is still copied" || bad "foo not copied"
[ ! -e "$Y/apps/web/node_modules/bar" ] && ok "the moved package is not copied back into the nest to shadow the branch's own" || bad "bar was copied: $(ls "$Y/apps/web/node_modules")"
[ ! -e "$Y/apps/web/node_modules/.bin" ] && ok "its now-dangling .bin link is removed" || bad ".bin left: $(ls -la "$Y/apps/web/node_modules/.bin" 2>&1)"
grep -qx 'bar' "$Y/.exempt" && ok "postSteps are told which packages the branch moved" || bad "exempt: $(cat "$Y/.exempt" 2>&1)"

echo "setup-worktree: mirror — a check-lock timeout is named, not blamed on the source"
L="$TMP/lock"
mk_mirror "$L" '{ "worktree": { "strategy": "mirror" } }'
Z="$L/.worktrees/w"
printf '#!/bin/sh\nexit 75\n' >"$TMP/lock75" && chmod +x "$TMP/lock75"
OUT="$(SETUP_WORKTREE_LOCK="$TMP/lock75" "$SW" "$Z" 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'timed out before copying: apps/web' <<<"$OUT" && ! grep -q INCOMPLETE <<<"$OUT" \
  && ok "a freshly written source is not copied past the lock, and says why" || bad "rc=$RC $OUT"
OUT="$(SETUP_WORKTREE_LOCK="$TMP/lock75" SETUP_WORKTREE_STABLE_SECS=0 "$SW" "$Z" 2>&1)"; RC=$?
[ "$RC" = 0 ] && grep -q 'retried unlocked' <<<"$OUT" && [ -f "$Z/apps/web/node_modules/foo/package.json" ] \
  && ok "a quiet source is copied unlocked after a timeout" || bad "rc=$RC $OUT"
rm -rf "$Z/apps/web/node_modules/foo"
run --check "$Z"
[ "$RC" = 1 ] && [ "$(grep -o 'apps/web/foo' <<<"$OUT" | wc -l)" = 1 ] && ok "a missing package is named once" || bad "dup: $OUT"

echo "setup-worktree: credential nudges"
N="$TMP/nudge"
mk_mirror "$N" '{ "stateDir": "~/.nudge", "ops": { "channel": true }, "worktree": { "strategy": "mirror" } }'
mv "$HOME/.config/secrets/gmi.env" "$TMP/gmi.env.away"
run "$N/.worktrees/w"
grep -q 'ops secrets not found' <<<"$OUT" && grep -q 'agent shell creds not found' <<<"$OUT" \
  && grep -q 'no GitHub Packages token' <<<"$OUT" && ok "a fresh machine is told what to build" || bad "nudges: $OUT"
mv "$TMP/gmi.env.away" "$HOME/.config/secrets/gmi.env"
run "$N/.worktrees/w"
! grep -q 'no GitHub Packages token' <<<"$OUT" && ok "gmi.env holding the PAT silences the token nudge" || bad "token nudge: $OUT"

echo "setup-worktree: a repo with no manifest is refused"
git init -q "$TMP/none"
run "$TMP/none"
[ "$RC" = 1 ] && grep -q 'has not opted in' <<<"$OUT" && ok "refused" || bad "rc=$RC $OUT"

exit "$fail"
