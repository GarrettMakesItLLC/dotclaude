#!/usr/bin/env bash
# Self-test for kb-sync.sh. Builds a throwaway MEMORY_ROOT/WORKSPACE_ROOT/
# DOTCLAUDE_DIR/VAULT_DIR so the real ~/vault and ~/.claude/projects are
# never touched, then asserts the vault it produces, its idempotence, and
# its --dry-run behavior.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/kb-sync.sh"
fail=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MEMORY_ROOT="$WORK/projects"
WORKSPACE_ROOT="$WORK/workspace"
DOTCLAUDE_DIR="$WORK/dotclaude"
VAULT_DIR="$WORK/vault"
TEMPLATE_DIR="$HERE/../templates/obsidian"

# --- fixture: one memory project with a fact file + a non-.md file to
# exclude, one repo with CLAUDE.md + rules, one repo with neither (skipped),
# one worktree-container dir (skipped by name). ---
mkdir -p "$MEMORY_ROOT/-home-garrett-workspace-DemoApp/memory/skill-observations"
cat > "$MEMORY_ROOT/-home-garrett-workspace-DemoApp/memory/fact_one.md" <<'EOF'
---
name: fact_one
---
A fact linking [[fact_two]].
EOF
cat > "$MEMORY_ROOT/-home-garrett-workspace-DemoApp/memory/MEMORY.md" <<'EOF'
# Memory Index
EOF
echo "not markdown" > "$MEMORY_ROOT/-home-garrett-workspace-DemoApp/memory/skill-observations/log.txt"

mkdir -p "$WORKSPACE_ROOT/DemoApp/.claude/rules"
echo "# DemoApp" > "$WORKSPACE_ROOT/DemoApp/CLAUDE.md"
echo "# a rule" > "$WORKSPACE_ROOT/DemoApp/.claude/rules/style.md"

mkdir -p "$WORKSPACE_ROOT/NoDocsHere"
echo "irrelevant" > "$WORKSPACE_ROOT/NoDocsHere/README.md"

mkdir -p "$WORKSPACE_ROOT/DemoApp-worktrees"
echo "# should be skipped" > "$WORKSPACE_ROOT/DemoApp-worktrees/CLAUDE.md"

run() {
  MEMORY_ROOT="$MEMORY_ROOT" WORKSPACE_ROOT="$WORKSPACE_ROOT" \
    DOTCLAUDE_DIR="$DOTCLAUDE_DIR" VAULT_DIR="$VAULT_DIR" TEMPLATE_DIR="$TEMPLATE_DIR" \
    "$SCRIPT"
}

# --- first run: builds the expected tree ---
out="$(run)"; code=$?
[ "$code" = 0 ] || { echo "FAIL: exit $code, output: $out"; fail=1; }

[ -f "$VAULT_DIR/memory/DemoApp/fact_one.md" ] \
  || { echo "FAIL: memory fact not copied"; fail=1; }
[ -f "$VAULT_DIR/memory/DemoApp/_index.md" ] \
  || { echo "FAIL: memory project index missing"; fail=1; }
[ -e "$VAULT_DIR/memory/DemoApp/skill-observations" ] \
  && { echo "FAIL: skill-observations/ should be excluded"; fail=1; }

[ -f "$VAULT_DIR/repos/DemoApp/CLAUDE.md" ] \
  || { echo "FAIL: repo CLAUDE.md not copied"; fail=1; }
[ -f "$VAULT_DIR/repos/DemoApp/rules/style.md" ] \
  || { echo "FAIL: repo rule not copied"; fail=1; }
[ -e "$VAULT_DIR/repos/NoDocsHere" ] \
  && { echo "FAIL: a repo with neither CLAUDE.md nor rules should be skipped"; fail=1; }
[ -e "$VAULT_DIR/repos/DemoApp-worktrees" ] \
  && { echo "FAIL: a *-worktrees dir should be skipped"; fail=1; }

[ -f "$VAULT_DIR/Map of Content.md" ] \
  || { echo "FAIL: top-level map of content missing"; fail=1; }
[ -f "$VAULT_DIR/README.md" ] \
  || { echo "FAIL: vault README missing"; fail=1; }
grep -q 'generated' "$VAULT_DIR/README.md" \
  || { echo "FAIL: README should say the vault is generated"; fail=1; }

[ -f "$VAULT_DIR/.obsidian/app.json" ] \
  || { echo "FAIL: .obsidian template not seeded on first run"; fail=1; }

# --- idempotence: a second run with no source changes reports none, and
# leaves file content identical ---
before_sum="$(find "$VAULT_DIR" -type f -exec cksum {} + | LC_ALL=C sort)"
run >/dev/null; code2=$?
[ "$code2" = 0 ] || { echo "FAIL: second run exit $code2"; fail=1; }
after_sum="$(find "$VAULT_DIR" -type f -exec cksum {} + | LC_ALL=C sort)"
[ "$before_sum" = "$after_sum" ] \
  || { echo "FAIL: idempotent re-run changed file content"; fail=1; }

# --- a later hand-tweak to .obsidian must survive a re-run ---
echo '{"tweaked":true}' > "$VAULT_DIR/.obsidian/app.json"
run >/dev/null
grep -q tweaked "$VAULT_DIR/.obsidian/app.json" \
  || { echo "FAIL: re-run overwrote a hand-tweaked .obsidian file"; fail=1; }

# --- a removed source file disappears from the vault (rsync --delete) ---
rm "$MEMORY_ROOT/-home-garrett-workspace-DemoApp/memory/fact_one.md"
run >/dev/null
[ -f "$VAULT_DIR/memory/DemoApp/fact_one.md" ] \
  && { echo "FAIL: deleted source file should disappear from the vault"; fail=1; }

# --- --dry-run: reports without writing ---
DRY_VAULT="$WORK/dry-vault"
out3="$(MEMORY_ROOT="$MEMORY_ROOT" WORKSPACE_ROOT="$WORKSPACE_ROOT" \
  DOTCLAUDE_DIR="$DOTCLAUDE_DIR" VAULT_DIR="$DRY_VAULT" TEMPLATE_DIR="$TEMPLATE_DIR" \
  "$SCRIPT" --dry-run)"
code3=$?
[ "$code3" = 0 ] || { echo "FAIL: --dry-run exit $code3"; fail=1; }
[ -e "$DRY_VAULT" ] \
  && { echo "FAIL: --dry-run must not create the vault dir"; fail=1; }
grep -qi 'dry run' <<<"$out3" \
  || { echo "FAIL: --dry-run output should say so, got: $out3"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "kb-sync: all cases passed"
fi
exit "$fail"
