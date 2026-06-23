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
# Symlink whole directories that the repo fully owns: path-scoped rules and
# the safety hooks referenced by settings.json.
# --------------------------------------------------------------------------
SHARED_DIRS=(
  "rules"
  "hooks"
)

echo
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

# Ensure hook scripts are executable (git preserves the bit, but some
# filesystems/clones drop it). A non-executable hook silently no-ops, so
# warn loudly if we can't fix it.
if [ -d "$REPO_DIR/hooks" ]; then
  chmod +x "$REPO_DIR"/hooks/*.sh 2>/dev/null || true
  for hook in "$REPO_DIR"/hooks/*.sh; do
    [ -e "$hook" ] || continue
    if [ ! -x "$hook" ]; then
      echo "  WARNING: $hook is not executable — the hook will not run" >&2
    fi
  done
fi

# --------------------------------------------------------------------------
# Skills: ~/.claude/skills/ may hold plugin- and user-managed skills, so link
# each of our skills individually instead of clobbering the whole directory.
# --------------------------------------------------------------------------
if [ -d "$REPO_DIR/skills" ]; then
  echo
  echo "→ Linking skills into $CLAUDE_DIR/skills"
  mkdir -p "$CLAUDE_DIR/skills"
  for src in "$REPO_DIR"/skills/*/; do
    [ -d "$src" ] || continue
    name="$(basename "$src")"
    dst="$CLAUDE_DIR/skills/$name"
    backup_if_real "$dst"
    ln -s "${src%/}" "$dst"
    echo "  linked: skills/$name"
  done
fi

# --------------------------------------------------------------------------
# Custom MCP servers vendored in this repo. Unlike marketplace plugins, their
# source lives here, so a fresh machine must install deps, build, and register
# the server with Claude Code. node_modules/ and dist/ are gitignored, so this
# step is what makes the server runnable after a clone or pull.
# --------------------------------------------------------------------------
GITHUB_MCP_DIR="$REPO_DIR/mcp/github"
if [ -f "$GITHUB_MCP_DIR/package.json" ]; then
  echo
  echo "→ Building custom github-rest MCP ($GITHUB_MCP_DIR)"
  if command -v npm >/dev/null 2>&1; then
    if [ -f "$GITHUB_MCP_DIR/package-lock.json" ]; then
      ( cd "$GITHUB_MCP_DIR" && npm ci )
    else
      ( cd "$GITHUB_MCP_DIR" && npm install )
    fi
    ( cd "$GITHUB_MCP_DIR" && npm run build )
    echo "  built: mcp/github/dist"

    if command -v claude >/dev/null 2>&1; then
      if claude mcp get github-rest >/dev/null 2>&1; then
        echo "  already registered: github-rest (run \`claude mcp remove github-rest\` to re-add)"
      else
        claude mcp add --scope user github-rest -- node "$GITHUB_MCP_DIR/dist/index.js"
        echo "  registered: github-rest (user scope)"
      fi
    else
      echo "  NOTE: \`claude\` CLI not found — register manually:"
      echo "        claude mcp add --scope user github-rest -- node $GITHUB_MCP_DIR/dist/index.js"
    fi
  else
    echo "  WARNING: npm not found — install Node.js, then re-run bootstrap to build the github-rest MCP" >&2
  fi
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
echo
if [ -d "$BACKUP_DIR" ]; then
  echo "Existing files backed up to: $BACKUP_DIR"
fi
