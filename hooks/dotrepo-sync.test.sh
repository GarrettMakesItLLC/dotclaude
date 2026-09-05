#!/usr/bin/env bash
# Self-test for dotrepo-sync.sh. Builds throwaway bare + clone repo pairs so
# real dotclaude/dotfiles are never touched, and asserts every staleness case
# is handled without ever forcing a change onto a dirty or diverged tree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/dotrepo-sync.sh"
fail=0

# A bare "remote" plus a clone of it, both throwaway, with git identity set
# so commits work in CI with no global config.
make_pair() {
  local base origin clone
  base="$(mktemp -d)"
  origin="$base/origin.git"
  clone="$base/clone"
  git init --quiet --bare "$origin"
  git clone --quiet "$origin" "$clone"
  git -C "$clone" config user.email test@example.com
  git -C "$clone" config user.name test
  echo one > "$clone/file"
  git -C "$clone" add file
  git -C "$clone" commit --quiet -m one
  git -C "$clone" push --quiet origin "$(git -C "$clone" rev-parse --abbrev-ref HEAD)"
  printf '%s' "$clone"
}

# Push one more commit to the shared remote from a second clone, simulating
# "someone else pushed" without touching the first clone's working tree.
advance_remote() {
  local clone="$1" second
  second="$(mktemp -d)/second"
  git clone --quiet "$(git -C "$clone" remote get-url origin)" "$second"
  git -C "$second" config user.email test@example.com
  git -C "$second" config user.name test
  echo two >> "$second/file"
  git -C "$second" commit --quiet -am two
  git -C "$second" push --quiet origin "HEAD:$(git -C "$clone" rev-parse --abbrev-ref HEAD)"
  rm -rf "$(dirname "$second")"
}

run() { DOTCLAUDE_DIR="$1" DOTFILES_DIR="$2" "$HOOK" 2>/dev/null; }

# --- up to date: silent, exit 0 ---
c1="$(make_pair)"; c2="$(make_pair)"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 up to date, got $code"; fail=1; }
[ -z "$out" ] || { echo "FAIL: must stay silent up to date, got: $out"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- clean fast-forward: pulls, reports count ---
c1="$(make_pair)"; c2="$(make_pair)"
advance_remote "$c1"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 on clean pull, got $code"; fail=1; }
printf '%s' "$out" | grep -q 'pulled 1 new commit' \
  || { echo "FAIL: should report pulling 1 commit, got: $out"; fail=1; }
[ "$(git -C "$c1" rev-parse HEAD)" = "$(git -C "$c1" rev-parse '@{u}')" ] \
  || { echo "FAIL: c1 should now be at upstream HEAD"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- behind + dirty tree: reports, does not pull ---
c1="$(make_pair)"; c2="$(make_pair)"
advance_remote "$c1"
echo local-edit >> "$c1/file"
before="$(git -C "$c1" rev-parse HEAD)"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 when dirty, got $code"; fail=1; }
printf '%s' "$out" | grep -q 'uncommitted' \
  || { echo "FAIL: should report uncommitted local changes, got: $out"; fail=1; }
[ "$(git -C "$c1" rev-parse HEAD)" = "$before" ] \
  || { echo "FAIL: dirty repo must not be pulled"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- behind + only a LIVE path dirty: still pulls (#325) ---
# `settings.json` is the running app's own settings file, so /model and
# /output-style rewrite it in place. Counting that as "dirty" froze dotclaude
# at one commit for a week while nine piled up behind it — including fixes
# that were still being hit live because they had never deployed.
c1="$(make_pair)"; c2="$(make_pair)"
# Track settings.json on the remote first, so the clone is clean, not ahead.
echo '{"model":"sonnet"}' > "$c1/settings.json"
git -C "$c1" add settings.json
git -C "$c1" commit --quiet -m settings
git -C "$c1" push --quiet origin "$(git -C "$c1" rev-parse --abbrev-ref HEAD)"
advance_remote "$c1"
echo '{"model":"opus[1m]"}' > "$c1/settings.json"   # the app rewrites it live
before="$(git -C "$c1" rev-parse HEAD)"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL(live-path): must exit 0, got $code"; fail=1; }
[ "$(git -C "$c1" rev-parse HEAD)" != "$before" ] \
  || { echo "FAIL(live-path): a dirty settings.json must not block the pull, got: $out"; fail=1; }
grep -q 'opus' "$c1/settings.json" \
  || { echo "FAIL(live-path): the local settings.json must be left untouched"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- a live path dirty AND changed upstream: refuses, names the file (#325) ---
# git declines rather than clobbering, and the note says which file and what
# clears it, instead of the generic "resolve by hand".
c1="$(make_pair)"; c2="$(make_pair)"
echo '{"model":"sonnet"}' > "$c1/settings.json"
git -C "$c1" add settings.json
git -C "$c1" commit --quiet -m settings
git -C "$c1" push --quiet origin "$(git -C "$c1" rev-parse --abbrev-ref HEAD)"
second="$(mktemp -d)/s"
git clone --quiet "$(git -C "$c1" remote get-url origin)" "$second"
git -C "$second" config user.email test@example.com
git -C "$second" config user.name test
echo '{"model":"haiku"}' > "$second/settings.json"
git -C "$second" commit --quiet -am upstream-settings
git -C "$second" push --quiet origin "HEAD:$(git -C "$c1" rev-parse --abbrev-ref HEAD)"
rm -rf "$(dirname "$second")"
echo '{"model":"opus[1m]"}' > "$c1/settings.json"
before="$(git -C "$c1" rev-parse HEAD)"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL(live-clash): must exit 0, got $code"; fail=1; }
[ "$(git -C "$c1" rev-parse HEAD)" = "$before" ] \
  || { echo "FAIL(live-clash): must not pull over a locally-edited live file"; fail=1; }
grep -q 'opus' "$c1/settings.json" \
  || { echo "FAIL(live-clash): local settings.json was clobbered"; fail=1; }
printf '%s' "$out" | grep -q 'settings.json' \
  || { echo "FAIL(live-clash): the note should name the file, got: $out"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- diverged (ahead and behind): reports, does not pull ---
c1="$(make_pair)"; c2="$(make_pair)"
advance_remote "$c1"
git -C "$c1" config user.email test@example.com
git -C "$c1" config user.name test
echo local-commit >> "$c1/file"
git -C "$c1" commit --quiet -am local-commit
before="$(git -C "$c1" rev-parse HEAD)"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 when diverged, got $code"; fail=1; }
printf '%s' "$out" | grep -q 'diverged' \
  || { echo "FAIL: should report diverged history, got: $out"; fail=1; }
[ "$(git -C "$c1" rev-parse HEAD)" = "$before" ] \
  || { echo "FAIL: diverged repo must not be pulled"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- pulled sources for a compiled artifact: rebuilds it (#325) ---
# The github MCP runs from a gitignored `dist/`, so a pull deploys its sources
# and not the thing executed. Asserted with a stub `npm` on PATH, because what
# matters is that the build is INVOKED for the right change and skipped for the
# wrong one — not that a real esbuild ran.
mcp_pair() {
  local clone="$1" second
  second="$(mktemp -d)/second"
  git clone --quiet "$(git -C "$clone" remote get-url origin)" "$second"
  git -C "$second" config user.email test@example.com
  git -C "$second" config user.name test
  mkdir -p "$second/mcp/github/src"
  echo '{"name":"m"}' > "$second/mcp/github/package.json"
  echo 'export const x = 1;' > "$second/mcp/github/src/index.ts"
  git -C "$second" add mcp
  git -C "$second" commit --quiet -m mcp
  git -C "$second" push --quiet origin "HEAD:$(git -C "$clone" rev-parse --abbrev-ref HEAD)"
  rm -rf "$(dirname "$second")"
}

# A stub npm that records its invocation. `mode` picks pass or fail.
stub_npm() {
  local bin="$1" mode="$2"
  mkdir -p "$bin"
  cat > "$bin/npm" <<STUB
#!/usr/bin/env bash
echo "npm \$*" >> "$bin/calls"
[ "$mode" = ok ] && exit 0
exit 1
STUB
  chmod +x "$bin/npm"
}

c1="$(make_pair)"; c2="$(make_pair)"
mcp_pair "$c1"
mkdir -p "$c1/mcp/github/node_modules"
bin="$(mktemp -d)"; stub_npm "$bin" ok
out="$(PATH="$bin:$PATH" run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL(rebuild): must exit 0, got $code"; fail=1; }
grep -q 'run --silent build' "$bin/calls" 2>/dev/null \
  || { echo "FAIL(rebuild): should have run the MCP build, calls: $(cat "$bin/calls" 2>/dev/null)"; fail=1; }
printf '%s' "$out" | grep -q 'rebuilt github MCP' \
  || { echo "FAIL(rebuild): should report the rebuild, got: $out"; fail=1; }
rm -rf "$bin" "$(dirname "$c1")" "$(dirname "$c2")"

# --- a pull that does not touch those sources: no build ---
# Rebuilding on every pull would add seconds to every session start for nothing.
c1="$(make_pair)"; c2="$(make_pair)"
mkdir -p "$c1/mcp/github/node_modules"
echo '{"name":"m"}' > "$c1/mcp/github/package.json"
advance_remote "$c1"
bin="$(mktemp -d)"; stub_npm "$bin" ok
out="$(PATH="$bin:$PATH" run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL(no-rebuild): must exit 0, got $code"; fail=1; }
[ ! -f "$bin/calls" ] \
  || { echo "FAIL(no-rebuild): must not build when sources are untouched, calls: $(cat "$bin/calls")"; fail=1; }
rm -rf "$bin" "$(dirname "$c1")" "$(dirname "$c2")"

# --- no node_modules: skipped, silently ---
# A first-run install is minutes; a session start must never pay for it.
c1="$(make_pair)"; c2="$(make_pair)"
mcp_pair "$c1"
bin="$(mktemp -d)"; stub_npm "$bin" ok
out="$(PATH="$bin:$PATH" run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL(no-install): must exit 0, got $code"; fail=1; }
[ ! -f "$bin/calls" ] \
  || { echo "FAIL(no-install): must not build without an install present"; fail=1; }
rm -rf "$bin" "$(dirname "$c1")" "$(dirname "$c2")"

# --- the build fails: still exit 0, but say the code is STALE ---
# Silence here reproduces the original bug: a stale build is a working build.
c1="$(make_pair)"; c2="$(make_pair)"
mcp_pair "$c1"
mkdir -p "$c1/mcp/github/node_modules"
bin="$(mktemp -d)"; stub_npm "$bin" fail
out="$(PATH="$bin:$PATH" run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL(build-fail): must exit 0, got $code"; fail=1; }
printf '%s' "$out" | grep -q 'STALE' \
  || { echo "FAIL(build-fail): a failed build must say the MCP is stale, got: $out"; fail=1; }
rm -rf "$bin" "$(dirname "$c1")" "$(dirname "$c2")"

# --- missing directory: silent, exit 0 ---
out="$(run "/nonexistent-dotclaude-$$" "/nonexistent-dotfiles-$$")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 with missing repos, got $code"; fail=1; }
[ -z "$out" ] || { echo "FAIL: must stay silent with missing repos, got: $out"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "dotrepo-sync: all cases passed"
fi
exit "$fail"
