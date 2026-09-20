#!/usr/bin/env bash
# Self-test for dot-sync.sh. Never touches the real ~/dotclaude, ~/dotfiles,
# or ~/.claude — every scenario points DOTCLAUDE_DIR/DOTFILES_DIR at
# throwaway fixtures (git repo pairs for the pull engine, stub
# bootstrap.sh/install.sh/npm for the rest).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dot-sync.sh"
fail=0

ok()   { echo "  ok: $1"; }
bad()  { echo "  FAIL: $1"; fail=1; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

# --- a bare "remote" + clone pair, same shape as hooks/dotrepo-sync.test.sh ---
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

# A stub npm that records its invocation to $1/calls. $2 picks pass/fail.
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

# --- --help exits 0 and doesn't touch anything ---
out="$("$SCRIPT" --help 2>&1)"; code=$?
[ "$code" = 0 ] || bad "--help must exit 0, got $code"
grep -q "dot-sync" <<<"$out" || bad "--help should print usage, got: $out"
[ "$code" = 0 ] && grep -q "dot-sync" <<<"$out" && ok "--help"

# --- unknown option exits 2 ---
"$SCRIPT" --nonsense >/dev/null 2>&1; code=$?
[ "$code" = 2 ] && ok "unknown option exits 2" || bad "unknown option should exit 2, got $code"

# --- both repos up to date, --skip-checks: reports, no bootstrap/install run ---
c1="$(make_pair)"; c2="$(make_pair)"
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" --skip-checks 2>&1 | strip)"; code=$?
[ "$code" = 0 ] || bad "up-to-date --skip-checks must exit 0, got $code"
grep -q "dotclaude: up to date" <<<"$out" || bad "should report dotclaude up to date, got: $out"
grep -q "dotfiles: up to date" <<<"$out" || bad "should report dotfiles up to date, got: $out"
grep -q "pull only" <<<"$out" || bad "--skip-checks should say so, got: $out"
[ "$code" = 0 ] && ok "up-to-date --skip-checks is fast and quiet about the rest"
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- dotclaude cleanly behind: pulls and reports the count ---
c1="$(make_pair)"; c2="$(make_pair)"
advance_remote "$c1"
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" --skip-checks 2>&1 | strip)"; code=$?
[ "$code" = 0 ] || bad "clean pull must exit 0, got $code"
grep -q "pulled 1 new commit" <<<"$out" || bad "should report pulling 1 commit, got: $out"
[ "$(git -C "$c1" rev-parse HEAD)" = "$(git -C "$c1" rev-parse '@{u}')" ] || bad "c1 should be at upstream HEAD"
[ "$code" = 0 ] && ok "stale dotclaude: pulls and reports"
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- dirty tree behind: reports, does NOT pull, exit reflects it needs a human ---
c1="$(make_pair)"; c2="$(make_pair)"
advance_remote "$c1"
echo local-edit >> "$c1/file"
before="$(git -C "$c1" rev-parse HEAD)"
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" --skip-checks 2>&1 | strip)"
[ "$(git -C "$c1" rev-parse HEAD)" = "$before" ] || bad "dirty repo must not be pulled"
grep -q "uncommitted" <<<"$out" || bad "should report uncommitted changes, got: $out"
ok "dirty dotclaude: reports, never touches it"
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- missing bootstrap.sh / install.sh: tolerated, not an error ---
c1="$(make_pair)"; c2="$(make_pair)"
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" 2>&1 | strip)"; code=$?
[ "$code" = 0 ] || bad "missing bootstrap.sh/install.sh must still exit 0, got $code"
grep -q "no bootstrap.sh found" <<<"$out" || bad "should say bootstrap.sh is missing, got: $out"
grep -q "no install.sh found" <<<"$out" || bad "should say install.sh is missing, got: $out"
grep -q "not vendored in this checkout" <<<"$out" || bad "should say the MCP isn't vendored here, got: $out"
[ "$code" = 0 ] && ok "no bootstrap.sh/install.sh/mcp: tolerated, not errors"
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- bootstrap.sh --check reports drift; no --fix means it is NEVER applied ---
c1="$(make_pair)"; c2="$(make_pair)"
cat > "$c1/bootstrap.sh" <<'STUB'
#!/usr/bin/env bash
echo "call: $*" >> "$(dirname "$0")/bootstrap-calls"
if [ "${1:-}" = "--check" ]; then
  echo "drifted symlink found"
  exit 1
fi
echo "applied"
exit 0
STUB
chmod +x "$c1/bootstrap.sh"
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" 2>&1 | strip)"; code=$?
[ "$code" = 1 ] || bad "unresolved drift should be a non-zero exit, got $code"
grep -q "found drift" <<<"$out" || bad "should report the drift, got: $out"
grep -q "re-run dot-sync.sh --fix to apply" <<<"$out" || bad "should name the --fix escape hatch, got: $out"
[ "$(cat "$c1/bootstrap-calls" 2>/dev/null)" = "call: --check" ] \
  || bad "without --fix, bootstrap.sh must be invoked ONLY with --check, calls: $(cat "$c1/bootstrap-calls" 2>/dev/null)"
[ "$code" = 1 ] && ok "drift reported, never auto-applied without --fix"
rm -f "$c1/bootstrap-calls"

# --- same drift, WITH --fix: applies it ---
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" --fix 2>&1 | strip)"; code=$?
[ "$code" = 0 ] || bad "--fix applying successfully should exit 0, got $code"
grep -q "bootstrap.sh applied" <<<"$out" || bad "should report it applied, got: $out"
calls="$(cat "$c1/bootstrap-calls" 2>/dev/null)"
grep -q '^call: --check$' <<<"$calls" || bad "--fix should still check first, calls: $calls"
[ "$(printf '%s\n' "$calls" | grep -c '^call:')" -ge 2 ] || bad "--fix should check then apply (2 calls), got: $calls"
[ "$code" = 0 ] && ok "--fix applies the drift it found"
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- stale github MCP dist: reported, not built without --build-mcp ---
c1="$(make_pair)"; c2="$(make_pair)"
mkdir -p "$c1/mcp/github/src"
echo '{"name":"m"}' > "$c1/mcp/github/package.json"
echo 'x' > "$c1/mcp/github/src/index.ts"
bin="$(mktemp -d)"; stub_npm "$bin" ok
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" PATH="$bin:$PATH" "$SCRIPT" 2>&1 | strip)"; code=$?
[ "$code" = 1 ] || bad "unbuilt MCP dist should be a non-zero exit, got $code"
grep -q "dist is missing" <<<"$out" || bad "should report the dist as missing, got: $out"
[ ! -f "$bin/calls" ] || bad "must not build without --build-mcp, calls: $(cat "$bin/calls")"
[ "$code" = 1 ] && ok "stale/missing MCP dist: reported, not built without --build-mcp"

# --- same, WITH --build-mcp: builds it ---
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" PATH="$bin:$PATH" "$SCRIPT" --build-mcp 2>&1 | strip)"; code=$?
[ "$code" = 0 ] || bad "--build-mcp succeeding should exit 0, got $code"
grep -q 'npm ci' "$bin/calls" 2>/dev/null || bad "--build-mcp should run npm ci, calls: $(cat "$bin/calls" 2>/dev/null)"
grep -q 'run build' "$bin/calls" 2>/dev/null || bad "--build-mcp should run npm run build, calls: $(cat "$bin/calls" 2>/dev/null)"
grep -q "rebuilt" <<<"$out" || bad "should report the rebuild, got: $out"
[ "$code" = 0 ] && ok "--build-mcp builds the stale/missing dist"
rm -rf "$bin" "$(dirname "$c1")" "$(dirname "$c2")"

# --- --kb with no kb-sync.sh present: tolerated, not an error (may be mid-merge) ---
c1="$(make_pair)"; c2="$(make_pair)"
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" --kb 2>&1 | strip)"; code=$?
[ "$code" = 0 ] || bad "--kb with no kb-sync.sh must still exit 0, got $code"
grep -q "kb-sync.sh not found" <<<"$out" || bad "should say kb-sync.sh is absent, got: $out"
grep -q "tolerating absence" <<<"$out" || bad "should say it is tolerating the absence, got: $out"
[ "$code" = 0 ] && ok "--kb: missing bin/kb-sync.sh (mid-merge elsewhere) is tolerated"

# --- --kb NOT passed: skipped, and says so ---
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" 2>&1 | strip)"
grep -q "skipped (pass --kb" <<<"$out" || bad "without --kb it should say how to opt in, got: $out"
ok "no --kb: skipped, says how to opt in"
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- gateway/ledger tooling: detected and reported, never created ---
c1="$(make_pair)"; c2="$(make_pair)"
mkdir -p "$c1/bin"
cat > "$c1/bin/gateway-status.sh" <<'STUB'
#!/usr/bin/env bash
echo stub
STUB
chmod +x "$c1/bin/gateway-status.sh"
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" 2>&1 | strip)"
grep -q "gateway-status.sh" <<<"$out" || bad "should report the found gateway tool, got: $out"
[ -f "$c1/bin/gateway-status.sh" ] || bad "must never delete/touch what it only reports on"
ok "gateway tooling: detected, reported, left alone"
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- a sourced library is correctly non-executable: reported as such, and
#     never as a problem. bootstrap.sh's doctor exempts it by the same header
#     marker, so the two must not disagree about the same file. ---
c1="$(make_pair)"; c2="$(make_pair)"
mkdir -p "$c1/bin"
cat > "$c1/bin/gateway-common.sh" <<'STUB'
#!/usr/bin/env bash
# Shared plumbing. Sourced, never run.
STUB
chmod -x "$c1/bin/gateway-common.sh"
cat > "$c1/bin/gateway-broken.sh" <<'STUB'
#!/usr/bin/env bash
echo stub
STUB
chmod -x "$c1/bin/gateway-broken.sh"
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" 2>&1 | strip)"; code=$?
grep -q "gateway-common.sh (sourced library)" <<<"$out" \
  || bad "a sourced library must not read as a defect, got: $out"
grep -q "gateway-broken.sh — NOT executable" <<<"$out" \
  || bad "a real script without the bit must be flagged, got: $out"
[ "$code" = 0 ] && bad "a non-executable real script should make dot-sync exit non-zero"
ok "sourced library exempt; a real script missing the bit is flagged"
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- no gateway/ledger tooling at all: reported as absent, tolerated ---
c1="$(make_pair)"; c2="$(make_pair)"
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" 2>&1 | strip)"; code=$?
[ "$code" = 0 ] || bad "no gateway tooling must still exit 0, got $code"
grep -q "no gateway/ledger tooling" <<<"$out" || bad "should say so, got: $out"
[ "$code" = 0 ] && ok "no gateway/ledger tooling: reported absent, exit 0"
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- the repo-fleet sweep is DELEGATED, not reimplemented here ---
c1="$(make_pair)"; c2="$(make_pair)"
mkdir -p "$c1/bin"
cat > "$c1/bin/repo-sweep.sh" <<STUB
#!/usr/bin/env bash
echo "sweep \$*" >> "$c1/sweep-calls"
echo "  REPO  BRANCH  RESULT"
STUB
chmod +x "$c1/bin/repo-sweep.sh"
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" 2>&1 | strip)"
grep -q "4. Repo fleet" <<<"$out" || bad "the fleet sweep should be its own reported step, got: $out"
[ -f "$c1/sweep-calls" ] || bad "repo-sweep.sh should have been invoked"
grep -q "fleet swept" <<<"$out" || bad "a successful sweep should say so, got: $out"
ok "repo fleet: delegated to bin/repo-sweep.sh"

# --deps is passed through; without it, it must not be.
rm -f "$c1/sweep-calls"
DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" >/dev/null 2>&1
grep -q -- "--deps" "$c1/sweep-calls" && bad "--deps must not be passed unless asked for"
rm -f "$c1/sweep-calls"
DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" --deps >/dev/null 2>&1
grep -q -- "--deps" "$c1/sweep-calls" || bad "--deps should reach repo-sweep.sh"
ok "repo fleet: --deps is opt-in and passed through"

# --no-repos skips it entirely.
rm -f "$c1/sweep-calls"
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" --no-repos 2>&1 | strip)"
[ -f "$c1/sweep-calls" ] && bad "--no-repos must not invoke the sweep"
grep -q "skipped (--no-repos)" <<<"$out" || bad "--no-repos should say so, got: $out"
ok "repo fleet: --no-repos skips it and says so"
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- a checkout with no repo-sweep.sh (mid-merge on another machine) ---
c1="$(make_pair)"; c2="$(make_pair)"
out="$(DOTCLAUDE_DIR="$c1" DOTFILES_DIR="$c2" "$SCRIPT" 2>&1 | strip)"; code=$?
[ "$code" = 0 ] || bad "an absent repo-sweep.sh must not fail the run, got $code"
grep -q "repo-sweep.sh not found" <<<"$out" || bad "should say the sweep is absent, got: $out"
ok "repo fleet: an absent sweep is tolerated, not an error"
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

if [ "$fail" = 0 ]; then
  echo "dot-sync: all cases passed"
fi
exit "$fail"
