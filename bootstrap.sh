#!/usr/bin/env bash
# dotclaude bootstrap — run on a fresh machine to set up Claude Code with my global config.
#
# Usage:
#   git clone git@github.com:<user>/dotclaude.git ~/dotclaude
#   bash ~/dotclaude/bootstrap.sh
#
# Idempotent: safe to re-run. Existing files are backed up to ~/.claude.bak.<timestamp>/.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/.claude.bak.$TIMESTAMP"

echo "→ dotclaude bootstrap"
echo "  repo:    $REPO_DIR"
echo "  target:  $CLAUDE_DIR"
echo

mkdir -p "$CLAUDE_DIR"

# --------------------------------------------------------------------------
# Symlink shared files from the repo into ~/.claude/
# --------------------------------------------------------------------------
SHARED_FILES=(
  "CLAUDE.md"
  "settings.json"
  "keybindings.json"
)

backup_if_real() {
  local target="$1"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    mkdir -p "$BACKUP_DIR"
    echo "  backing up existing $target → $BACKUP_DIR/"
    mv "$target" "$BACKUP_DIR/"
  elif [ -L "$target" ]; then
    rm "$target"
  fi
}

echo "→ Linking files into $CLAUDE_DIR"
for f in "${SHARED_FILES[@]}"; do
  src="$REPO_DIR/$f"
  dst="$CLAUDE_DIR/$f"
  if [ ! -e "$src" ]; then
    echo "  skip: $f (not in repo)"
    continue
  fi
  backup_if_real "$dst"
  ln -s "$src" "$dst"
  echo "  linked: $f"
done

# --------------------------------------------------------------------------
# User-installed skills
# --------------------------------------------------------------------------
# Most domain skills are now bundled in plugins (settings.json declares them).
# The only standalone user skill is `find-skills`, which has no auto-installer.
# If you want it, manually drop the skill folder into ~/.claude/skills/find-skills/.
echo
echo "→ User skills: nothing to install (all domain skills come from plugins)"

# --------------------------------------------------------------------------
# Plugins are declared in settings.json (enabledPlugins + extraKnownMarketplaces).
# Claude Code auto-installs them on first launch from the official marketplace.
# --------------------------------------------------------------------------
echo
echo "→ Plugins declared in settings.json (auto-install on next \`claude\` launch):"
grep -E '@claude-plugins-official' "$REPO_DIR/settings.json" | sed -E 's/[[:space:]]*"([^"]+)".*/    \1/'

echo
echo "✓ Bootstrap complete."
echo
echo "Next steps:"
echo "  1. Launch Claude Code: \`claude\`"
echo "  2. Trust the marketplace when prompted (anthropics/claude-plugins-official)"
echo "  3. Plugins will install automatically; verify with \`/plugin\`"
echo
if [ -d "$BACKUP_DIR" ]; then
  echo "Existing files backed up to: $BACKUP_DIR"
fi
