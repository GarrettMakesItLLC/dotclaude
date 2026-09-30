#!/usr/bin/env bash
# Install the graphify skill at user scope, from the graphify CLI on this machine.
#
#   ~/.claude/bin/graphify-skill.sh            # install or refresh ~/.claude/skills/graphify
#   ~/.claude/bin/graphify-skill.sh --check    # report only; exit 1 if missing or stale
#
# The skill is third-party (graphifyy on PyPI, Apache-2.0, github.com/Graphify-Labs/graphify)
# and ships INSIDE the CLI package, versioned with it. So it is generated from the
# installed CLI rather than vendored here or into each product repo: a vendored
# copy drifts from the CLI it documents the moment either is upgraded, and five
# copies drift from each other.
#
# `graphify install --platform claude` at user scope would also append to
# ~/.claude/CLAUDE.md, which is dotclaude's own tracked file. So the skill is
# generated in a scratch project (`--project`) and only its skill directory is
# copied to ~/.claude/skills/graphify. The per-repo half — the graphify section
# in a repo's CLAUDE.md and its PreToolUse `graphify hook-guard` hooks — is
# `graphify claude install`, run in the product repo (bootstrapping-a-product-repo).
#
# `.graphify_version` in the skill directory records which CLI wrote it; --check
# compares it with `graphify --version`.
set -euo pipefail

DEST="${GRAPHIFY_SKILL_DEST:-$HOME/.claude/skills/graphify}"

command -v graphify >/dev/null 2>&1 || { echo "graphify-skill: the graphify CLI is not installed (uv tool install graphifyy)" >&2; exit 1; }
cli_version="$(graphify --version 2>/dev/null | awk '{print $NF}' | head -1)"

if [ "${1:-}" = --check ]; then
  have="$(cat "$DEST/.graphify_version" 2>/dev/null || true)"
  if [ ! -f "$DEST/SKILL.md" ]; then
    echo "graphify-skill: $DEST is missing — run ~/.claude/bin/graphify-skill.sh" >&2
    exit 1
  elif [ -n "$cli_version" ] && [ "$have" != "$cli_version" ]; then
    echo "graphify-skill: skill is from graphify ${have:-unknown}, the CLI is $cli_version — run ~/.claude/bin/graphify-skill.sh" >&2
    exit 1
  fi
  echo "graphify-skill: $DEST matches graphify $cli_version"
  exit 0
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
(cd "$scratch" && git init -q . && graphify install --project --platform claude >/dev/null 2>&1) \
  || { echo "graphify-skill: 'graphify install --project' failed" >&2; exit 1; }
src="$scratch/.claude/skills/graphify"
[ -f "$src/SKILL.md" ] || { echo "graphify-skill: the CLI wrote no skill at $src" >&2; exit 1; }

# A symlink or a real directory left by an older install is replaced whole, so a
# reference file the new version dropped does not linger.
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST.new"
cp -r "$src" "$DEST.new"
[ -f "$DEST.new/.graphify_version" ] || printf '%s' "$cli_version" >"$DEST.new/.graphify_version"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"
echo "graphify-skill: installed $DEST (graphify $(cat "$DEST/.graphify_version"))"
