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
  "rules"      # path-scoped stack conventions, loaded only when matching files open
  "hooks"      # PreToolUse git-guard etc. — enforce CLAUDE.md rules deterministically
  "commands"   # personal slash commands (e.g. /dotclaude-sync)
)
# Skills are linked individually into ~/.claude/skills/<name> (NOT a whole-dir
# link) so they coexist with skills sourced elsewhere (e.g. ~/.agents).
SHARED_SKILLS=(
  "finishing-work"              # my personal finish-line procedure (definition of done, PR body, cleanup)
  "managing-work-with-issues"   # cross-machine claim protocol, label taxonomy, issue lifecycle
  "extending-the-github-mcp"    # self-healing: unblock, file, and grow the github-rest MCP on capability gaps
  "operating-production"        # incident/rollback posture, health checks, alerting for deployed services
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
  # A skill dropped from SHARED_SKILLS leaves a dangling link behind, which
  # Claude Code surfaces as a broken skill rather than as an absent one.
  for dst in "$CLAUDE_DIR"/skills/*; do
    [ -L "$dst" ] || continue
    tgt="$(readlink "$dst")"
    case "$tgt" in
      "$REPO_DIR"/skills/*) [ -e "$tgt" ] || {
        echo "  ✗ skills/$(basename "$dst") — dangling link to a removed skill. Run bootstrap to prune."
        problems=$((problems + 1))
      } ;;
    esac
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

# Hook scripts must be executable (git preserves the bit, but some clones drop
# it). A non-executable hook silently no-ops, so warn loudly if we can't fix it.
if [ -d "$REPO_DIR/hooks" ]; then
  chmod +x "$REPO_DIR"/hooks/*.sh 2>/dev/null || true
  for hook in "$REPO_DIR"/hooks/*.sh; do
    [ -e "$hook" ] || continue
    [ -x "$hook" ] || echo "  WARNING: $hook is not executable — the hook will not run" >&2
  done
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
  for dst in "$CLAUDE_DIR"/skills/*; do
    [ -L "$dst" ] || continue
    tgt="$(readlink "$dst")"
    case "$tgt" in
      "$REPO_DIR"/skills/*) [ -e "$tgt" ] || { rm "$dst"; echo "  pruned: skills/$(basename "$dst") (removed from repo)"; } ;;
    esac
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
# Remote HTTP MCP servers that authenticate with a static API key (not OAuth,
# not a marketplace plugin). The server URL is reproducible and lives here, but
# the key is a per-machine secret kept out of this repo and supplied via
# $UPLOAD_POST_API_KEY (set in ~/.claude/settings.local.json `env`; see
# integrations.md). We register the header with the literal
# ${UPLOAD_POST_API_KEY} placeholder, which Claude Code expands from the session
# env at runtime — so no key is ever written to a version-controlled file.
# --------------------------------------------------------------------------
if command -v claude >/dev/null 2>&1; then
  echo
  echo "→ Registering upload-post MCP (Upload-Post social publishing, user scope)"
  if claude mcp get upload-post >/dev/null 2>&1; then
    echo "  already registered: upload-post (run \`claude mcp remove upload-post\` to re-add)"
  else
    claude mcp add --scope user --transport http upload-post \
      https://mcp.upload-post.com/mcp \
      --header 'Authorization: ApiKey ${UPLOAD_POST_API_KEY}'
    echo "  registered: upload-post (user scope)"
  fi
  if [ -z "${UPLOAD_POST_API_KEY:-}" ]; then
    echo "  NOTE: set UPLOAD_POST_API_KEY in ~/.claude/settings.local.json \`env\` — see integrations.md" >&2
  fi
fi

# --------------------------------------------------------------------------
# Plugins are declared in settings.json (enabledPlugins + extraKnownMarketplaces).
# Claude Code auto-installs them on first launch from the official marketplace.
# --------------------------------------------------------------------------
echo
echo "→ Plugins declared in settings.json (auto-install on next \`claude\` launch):"
grep -E '@claude-plugins-official' "$REPO_DIR/settings.json" | sed -E 's/[[:space:]]*"([^"]+)".*/    \1/'

# --------------------------------------------------------------------------
# GitHub issue label taxonomy (status:*/type:*/source:*, see
# skills/managing-work-with-issues). This is per-repo, not per-machine — it
# needs a repo checkout and network access, so it doesn't belong in this
# script's symlink/build work. Provision it once per project repo instead,
# via the github-rest MCP's `labels_ensure` tool (idempotent, safe to re-run).
# --------------------------------------------------------------------------
echo
echo "→ Issue label taxonomy: run the 'labels_ensure' MCP tool (github-rest) once in each project repo to provision status:/type:/source: labels."

echo
echo "✓ Bootstrap complete."
echo
echo "Next steps:"
echo "  1. Launch Claude Code: \`claude\`"
echo "  2. Trust the marketplace when prompted (anthropics/claude-plugins-official)"
echo "  3. Plugins will install automatically; verify with \`/plugin\`"
echo "  4. Sanity-check anytime with: bash $REPO_DIR/bootstrap.sh --check"
echo "  5. In each project repo, run the 'labels_ensure' MCP tool once to provision issue labels"
echo
if [ -d "$BACKUP_DIR" ]; then
  echo "Existing files backed up to: $BACKUP_DIR"
fi
