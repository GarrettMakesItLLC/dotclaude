#!/usr/bin/env bash
# dotclaude bootstrap — set up Claude Code with my global config on a machine.
#
# Usage:
#   git clone git@github.com:<user>/dotclaude.git ~/dotclaude
#   bash ~/dotclaude/bootstrap.sh            # install (symlink into ~/.claude/)
#   bash ~/dotclaude/bootstrap.sh --check    # doctor: verify links, change nothing
#
# Idempotent: safe to re-run. Existing real files are backed up to
# ~/.claude.bak.<timestamp>/ before being replaced with symlinks.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

# What gets linked into ~/.claude/. Single source of truth for install + doctor.
SHARED_FILES=(
  "CLAUDE.md"
  "settings.json"
  "keybindings.json"
)
# Whole-dir symlinks: the repo dir BECOMES ~/.claude/<dir>, so nothing
# machine-local can live alongside these. If you ever need a non-repo hook or
# command on one machine, move that entry to a per-name scheme like
# SHARED_SKILLS below.
SHARED_DIRS=(
  "hooks"      # PreToolUse git-guard etc. — enforce CLAUDE.md rules deterministically
  "commands"   # personal slash commands (e.g. /dotclaude-sync)
)
# Skills are linked individually into ~/.claude/skills/<name> (NOT a whole-dir
# link) so they coexist with skills sourced elsewhere (e.g. ~/.agents).
SHARED_SKILLS=(
  "find-skills"   # skill discovery — the one user-level skill not in a plugin
)

MODE="install"
case "${1:-}" in
  --check|-c)  MODE="check" ;;
  --help|-h)   sed -n '2,11p' "$0"; exit 0 ;;
  "")          ;;
  *)           echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
esac

# --------------------------------------------------------------------------
# Doctor: verify every expected symlink exists and points back into the repo.
# Catches the documented footgun where a re-run (or a stray editor) replaced
# ~/.claude/CLAUDE.md with a real file, silently detaching it from the repo.
# Changes nothing; exits non-zero if anything is off.
# --------------------------------------------------------------------------
doctor() {
  echo "→ dotclaude doctor — verifying symlinks in $CLAUDE_DIR"
  echo "  repo: $REPO_DIR"
  local problems=0 name src dst tgt
  for name in "${SHARED_FILES[@]}" "${SHARED_DIRS[@]}"; do
    src="$REPO_DIR/$name"
    dst="$CLAUDE_DIR/$name"
    [ -e "$src" ] || continue
    if [ -L "$dst" ]; then
      tgt="$(readlink "$dst")"
      if [ "$tgt" = "$src" ]; then
        echo "  ✓ $name"
      else
        echo "  ✗ $name — points to '$tgt', expected '$src'"
        problems=$((problems + 1))
      fi
    elif [ -e "$dst" ]; then
      echo "  ✗ $name — real file/dir shadowing the repo (not a symlink). Re-run bootstrap to fix."
      problems=$((problems + 1))
    else
      echo "  ✗ $name — missing. Run bootstrap to link it."
      problems=$((problems + 1))
    fi
  done
  for name in "${SHARED_SKILLS[@]}"; do
    src="$REPO_DIR/skills/$name"
    dst="$CLAUDE_DIR/skills/$name"
    [ -e "$src" ] || continue
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
      echo "  ✓ skills/$name"
    else
      echo "  ✗ skills/$name — not linked to repo. Run bootstrap to fix."
      problems=$((problems + 1))
    fi
  done
  if [ "$problems" -eq 0 ]; then
    echo "✓ All symlinks healthy."
    return 0
  fi
  echo
  echo "✗ $problems issue(s) found. Fix with: bash $REPO_DIR/bootstrap.sh"
  return 1
}

if [ "$MODE" = "check" ]; then
  if doctor; then exit 0; else exit 1; fi
fi

# --------------------------------------------------------------------------
# Install
# --------------------------------------------------------------------------
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/.claude.bak.$TIMESTAMP"

echo "→ dotclaude bootstrap"
echo "  repo:    $REPO_DIR"
echo "  target:  $CLAUDE_DIR"
echo

mkdir -p "$CLAUDE_DIR"

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

# Whole-dir links so anything added to them in the repo syncs automatically.
echo "→ Linking directories into $CLAUDE_DIR"
for d in "${SHARED_DIRS[@]}"; do
  src="$REPO_DIR/$d"
  dst="$CLAUDE_DIR/$d"
  if [ ! -d "$src" ]; then
    echo "  skip: $d/ (not in repo)"
    continue
  fi
  backup_if_real "$dst"
  ln -s "$src" "$dst"
  echo "  linked: $d/"
done

# Hook scripts must be executable.
if [ -d "$REPO_DIR/hooks" ]; then
  chmod +x "$REPO_DIR"/hooks/*.sh 2>/dev/null || true
fi

# Per-skill links into ~/.claude/skills/ (coexist with other skill sources).
if [ "${#SHARED_SKILLS[@]}" -gt 0 ]; then
  echo "→ Linking skills into $CLAUDE_DIR/skills"
  mkdir -p "$CLAUDE_DIR/skills"
  for s in "${SHARED_SKILLS[@]}"; do
    src="$REPO_DIR/skills/$s"
    dst="$CLAUDE_DIR/skills/$s"
    if [ ! -d "$src" ]; then
      echo "  skip: skills/$s (not in repo)"
      continue
    fi
    backup_if_real "$dst"
    ln -s "$src" "$dst"
    echo "  linked: skills/$s"
  done
fi

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
echo "  4. Sanity-check anytime with: bash $REPO_DIR/bootstrap.sh --check"
echo
if [ -d "$BACKUP_DIR" ]; then
  echo "Existing files backed up to: $BACKUP_DIR"
fi
