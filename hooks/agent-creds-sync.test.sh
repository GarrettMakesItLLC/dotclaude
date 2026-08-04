#!/usr/bin/env bash
# Self-test for agent-creds-sync.sh. Feeds SessionStart payloads through the
# hook against a fake repo and asserts: (a) always exits 0 (fail-open), (b)
# bin/agent-env-build.sh runs every time when present, (c) bin/ops-pull.sh runs
# only when the staleness stamp is missing/old, and stamps on success, (d) both
# are no-ops when absent. Run locally or in CI:  bash hooks/agent-creds-sync.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/agent-creds-sync.sh"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

new_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

run_hook() {
  local dir="$1"
  CLAUDE_PROJECT_DIR="$dir" "$HOOK" >/dev/null 2>&1
  echo $?
}

# --- No opt-in scripts at all -> pure no-op, still exits 0. ---
REPO1="$TMP/repo1"; new_repo "$REPO1"
rc="$(run_hook "$REPO1")"
[ "$rc" = 0 ] || { echo "FAIL (no scripts): exit $rc"; fail=1; }

# --- agent-env-build.sh runs every session. ---
REPO2="$TMP/repo2"; new_repo "$REPO2"
mkdir -p "$REPO2/bin"
BUILD_LOG="$TMP/build.log"
cat > "$REPO2/bin/agent-env-build.sh" <<EOF
#!/usr/bin/env bash
echo ran >> "$BUILD_LOG"
EOF
chmod +x "$REPO2/bin/agent-env-build.sh"

rc="$(run_hook "$REPO2")"
[ "$rc" = 0 ] || { echo "FAIL (build script): exit $rc"; fail=1; }
[ "$(wc -l < "$BUILD_LOG" 2>/dev/null || echo 0)" = 1 ] || { echo "FAIL (build script): expected 1 run"; fail=1; }

run_hook "$REPO2" >/dev/null
[ "$(wc -l < "$BUILD_LOG")" = 2 ] || { echo "FAIL (build script): expected a run every session"; fail=1; }

# --- ops-pull.sh runs when never pulled, then is skipped until stale. ---
REPO3="$TMP/repo3"; new_repo "$REPO3"
mkdir -p "$REPO3/bin"
PULL_LOG="$TMP/pull.log"
cat > "$REPO3/bin/ops-pull.sh" <<EOF
#!/usr/bin/env bash
echo ran >> "$PULL_LOG"
EOF
chmod +x "$REPO3/bin/ops-pull.sh"

run_hook "$REPO3" >/dev/null
[ "$(wc -l < "$PULL_LOG" 2>/dev/null || echo 0)" = 1 ] || { echo "FAIL (ops-pull): expected first-run pull"; fail=1; }

git_dir="$(git -C "$REPO3" rev-parse --path-format=absolute --git-common-dir)"
[ -f "$git_dir/ops-pull-stamp" ] || { echo "FAIL (ops-pull): stamp not written"; fail=1; }

run_hook "$REPO3" >/dev/null
[ "$(wc -l < "$PULL_LOG")" = 1 ] || { echo "FAIL (ops-pull): expected fresh stamp to skip re-pull"; fail=1; }

# Backdate the stamp past the 12h window -> pulls again.
touch -d '13 hours ago' "$git_dir/ops-pull-stamp" 2>/dev/null || touch -t 202001010000 "$git_dir/ops-pull-stamp"
run_hook "$REPO3" >/dev/null
[ "$(wc -l < "$PULL_LOG")" = 2 ] || { echo "FAIL (ops-pull): expected stale stamp to re-pull"; fail=1; }

# --- A failing ops-pull.sh must not stamp (retried next session). ---
REPO4="$TMP/repo4"; new_repo "$REPO4"
mkdir -p "$REPO4/bin"
cat > "$REPO4/bin/ops-pull.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$REPO4/bin/ops-pull.sh"
rc="$(run_hook "$REPO4")"
[ "$rc" = 0 ] || { echo "FAIL (failing ops-pull): exit $rc, must fail open"; fail=1; }
git_dir4="$(git -C "$REPO4" rev-parse --path-format=absolute --git-common-dir)"
[ -f "$git_dir4/ops-pull-stamp" ] && { echo "FAIL (failing ops-pull): stamp written despite failure"; fail=1; }

# --- Not a git repo -> no-op, exits 0. ---
NONGIT="$TMP/nongit"; mkdir -p "$NONGIT"
rc="$(run_hook "$NONGIT")"
[ "$rc" = 0 ] || { echo "FAIL (non-git dir): exit $rc"; fail=1; }

# --- Worktree-safe: hook run from a linked worktree finds the main tree's scripts. ---
REPO5="$TMP/repo5"; new_repo "$REPO5"
mkdir -p "$REPO5/bin"
WT_BUILD_LOG="$TMP/wt-build.log"
cat > "$REPO5/bin/agent-env-build.sh" <<EOF
#!/usr/bin/env bash
echo ran >> "$WT_BUILD_LOG"
EOF
chmod +x "$REPO5/bin/agent-env-build.sh"
git -C "$REPO5" branch wt-branch -q
git -C "$REPO5" worktree add -q "$TMP/repo5-wt" wt-branch
rc="$(run_hook "$TMP/repo5-wt")"
[ "$rc" = 0 ] || { echo "FAIL (worktree): exit $rc"; fail=1; }
[ "$(wc -l < "$WT_BUILD_LOG" 2>/dev/null || echo 0)" = 1 ] || { echo "FAIL (worktree): main tree's build script did not run"; fail=1; }

# --- Garbage / missing CLAUDE_PROJECT_DIR -> fail open. ---
rc=0; "$HOOK" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || { echo "FAIL (no project dir): exit $rc"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "agent-creds-sync: all cases passed"
fi
exit "$fail"
