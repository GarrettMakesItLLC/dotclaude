#!/usr/bin/env bash
# kb-sync — builds/refreshes an Obsidian vault over the fleet's existing
# Markdown: the per-project memory notes under ~/.claude/projects/*/memory
# and each repo's CLAUDE.md / .claude/rules/*.md (plus MuscleBuddy's docs/,
# which is the one repo with a normative docs/ tree worth vaulting whole).
#
# THE VAULT IS A GENERATED VIEW. The repos and the memory dirs stay the
# source of truth — never hand-edit inside the vault. Re-running this script
# is always safe: every generated subtree is rsync --delete'd from its
# source, so a removed source file disappears from the vault too, and
# nothing outside the generated subtrees + first-run .obsidian is touched.
#
# No symlinks: Windows Obsidian (opened over \\wsl.localhost\...) does not
# reliably follow WSL symlinks, so every source tree is rsync-copied (real
# files) instead of linked.
#
# Env overrides (all optional):
#   VAULT_DIR        default: $HOME/vault
#   MEMORY_ROOT       default: $HOME/.claude/projects        (globs */memory)
#   WORKSPACE_ROOT    default: $HOME/workspace                (globs */)
#   DOTCLAUDE_DIR     default: $HOME/dotclaude
#   TEMPLATE_DIR      default: <this repo>/templates/obsidian
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$HOME/vault}"
MEMORY_ROOT="${MEMORY_ROOT:-$HOME/.claude/projects}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$HOME/workspace}"
DOTCLAUDE_DIR="${DOTCLAUDE_DIR:-$HOME/dotclaude}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="${TEMPLATE_DIR:-$REPO_ROOT/templates/obsidian}"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "usage: $(basename "$0") [--dry-run]"
      echo "  builds/refreshes \$VAULT_DIR (default \$HOME/vault) from"
      echo "  ~/.claude/projects/*/memory and the fleet's repo docs."
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

# Repo directory names under WORKSPACE_ROOT that are never a source repo:
# worktree containers and the scratch dir, which hold no CLAUDE.md/rules of
# their own (their content belongs to the checkout they're a worktree of).
SKIP_REPO_NAMES=(scratchpad)
SKIP_REPO_SUFFIX="-worktrees"

changed=0
notes=()

note_rsync_output() {
  # rsync -i output: one changed/created/deleted line per touched file.
  local out="$1" label="$2"
  [ -z "$out" ] && return 0
  local n
  n="$(printf '%s\n' "$out" | grep -c .)"
  [ "$n" -gt 0 ] || return 0
  changed=$((changed + n))
  notes+=("$label: $n file(s) changed")
}

sync_tree() {
  # sync_tree <src-dir> <dest-dir> <label> [rsync-filter-args...]
  local src="$1" dest="$2" label="$3"
  shift 3
  [ -d "$src" ] || return 0
  local flags=(-a --delete -i --filter='P _index.md')
  [ "$DRY_RUN" = 1 ] && flags+=(--dry-run)
  [ "$DRY_RUN" = 1 ] || mkdir -p "$dest" 2>/dev/null || true
  local out
  out="$(rsync "${flags[@]}" "$@" "$src"/ "$dest"/ 2>/dev/null)"
  note_rsync_output "$out" "$label"
}

copy_file() {
  # copy_file <src-file> <dest-file> <label> — for single files, reports a
  # change only when the content actually differs (rsync -i semantics by hand,
  # since a single-file rsync invocation is overkill).
  local src="$1" dest="$2" label="$3"
  [ -f "$src" ] || return 0
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    notes+=("$label: would update")
    changed=$((changed + 1))
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  notes+=("$label: updated")
  changed=$((changed + 1))
}

[ "$DRY_RUN" = 1 ] || mkdir -p "$VAULT_DIR" 2>/dev/null || true

# --- 1. Memory notes: ~/.claude/projects/<slug>/memory/*.md (flat, top-level
# files only — skill-observations/ is working state for the task-observer
# skill, not a durable fact, and is deliberately excluded). ---
memory_dest_root="$VAULT_DIR/memory"
[ "$DRY_RUN" = 1 ] || mkdir -p "$memory_dest_root" 2>/dev/null || true
declare -a memory_projects=()
if [ -d "$MEMORY_ROOT" ]; then
  for mem_dir in "$MEMORY_ROOT"/*/memory; do
    [ -d "$mem_dir" ] || continue
    slug="$(basename "$(dirname "$mem_dir")")"
    project="${slug#-home-garrett-workspace-}"
    project="${project#-home-garrett-}"
    memory_projects+=("$project")
    sync_tree "$mem_dir" "$memory_dest_root/$project" "memory/$project" \
      --exclude='*/' --include='*.md' --exclude='*'
  done
fi

# --- 2. Repo CLAUDE.md + .claude/rules/*.md, for every repo that has either. ---
repos_dest_root="$VAULT_DIR/repos"
[ "$DRY_RUN" = 1 ] || mkdir -p "$repos_dest_root" 2>/dev/null || true
declare -a repo_dirs=()
[ -d "$DOTCLAUDE_DIR" ] && repo_dirs+=("$DOTCLAUDE_DIR")
if [ -d "$WORKSPACE_ROOT" ]; then
  for d in "$WORKSPACE_ROOT"/*/; do
    [ -d "$d" ] || continue
    repo_dirs+=("${d%/}")
  done
fi

declare -a repo_names=()
for repo in "${repo_dirs[@]}"; do
  name="$(basename "$repo")"
  skip=0
  for s in "${SKIP_REPO_NAMES[@]}"; do [ "$name" = "$s" ] && skip=1; done
  case "$name" in *"$SKIP_REPO_SUFFIX") skip=1 ;; esac
  [ "$skip" = 1 ] && continue
  [ -f "$repo/CLAUDE.md" ] || [ -d "$repo/.claude/rules" ] || continue
  repo_names+=("$name")
  copy_file "$repo/CLAUDE.md" "$repos_dest_root/$name/CLAUDE.md" "repos/$name/CLAUDE.md"
  sync_tree "$repo/.claude/rules" "$repos_dest_root/$name/rules" "repos/$name/rules" \
    --include='*.md' --exclude='*'
done

# --- 3. MuscleBuddy's docs/ tree — the fleet's one repo with a normative
# docs/ worth vaulting whole. Excludes docs/superpowers/ (a 5.5MB dated
# archive of historical design specs and plans, not source of truth) — say
# so here rather than silently dropping it.
mb_docs="$WORKSPACE_ROOT/MuscleBuddy/docs"
if [ -d "$mb_docs" ]; then
  sync_tree "$mb_docs" "$repos_dest_root/MuscleBuddy/docs" "repos/MuscleBuddy/docs" \
    --exclude='/superpowers/' --include='*/' --include='*.md' --exclude='*'
fi

# --- 4. Per-source index notes + top-level map of content. ---
gen_index() {
  local dir="$1" title="$2"
  [ -d "$dir" ] || return 0
  local out="$dir/_index.md"
  [ "$DRY_RUN" = 1 ] && return 0
  {
    echo "# $title"
    echo
    echo "> Generated by \`bin/kb-sync.sh\` — do not edit. See [[README]]."
    echo
    find "$dir" -mindepth 1 -maxdepth 1 -not -name '_index.md' | LC_ALL=C sort | while read -r entry; do
      base="$(basename "$entry")"
      if [ -d "$entry" ]; then
        echo "- [[${base}/_index|$base/]]"
      else
        echo "- [[${base%.md}]]"
      fi
    done
  } > "$out"
}

if [ "$DRY_RUN" != 1 ]; then
  for p in "${memory_projects[@]}"; do
    gen_index "$memory_dest_root/$p" "Memory: $p"
  done
  gen_index "$memory_dest_root" "Memory (all projects)"
  for n in "${repo_names[@]}"; do
    gen_index "$repos_dest_root/$n" "Repo: $n"
    [ -d "$repos_dest_root/$n/rules" ] && gen_index "$repos_dest_root/$n/rules" "$n rules"
    [ -d "$repos_dest_root/$n/docs" ] && gen_index "$repos_dest_root/$n/docs" "$n docs"
  done
  gen_index "$repos_dest_root" "Repos (all)"

  cat > "$VAULT_DIR/Map of Content.md" <<EOF
# Map of Content

> Generated by \`bin/kb-sync.sh\` — do not edit. See [[README]].

## Memory (per project)

$(for p in "${memory_projects[@]}"; do echo "- [[memory/$p/_index|$p]]"; done)

## Repos

$(for n in "${repo_names[@]}"; do echo "- [[repos/$n/_index|$n]]"; done)
EOF

  cat > "$VAULT_DIR/README.md" <<EOF
# This vault is generated — do not edit here

This vault is a **read-only view** built by \`bin/kb-sync.sh\` in
[dotclaude](https://github.com/GarrettMakesItLLC/dotclaude) over Markdown that
already exists elsewhere. Edit the source, then re-run the script — this
vault has no independent existence and a re-run will overwrite anything
typed directly into it.

## Where each tree comes from

- **\`memory/<project>/\`** — \`~/.claude/projects/<project-slug>/memory/*.md\`,
  the per-project auto-memory notes (one fact per file, wiki-linked). Edit
  those files directly, or let a session update them.
- **\`repos/<repo>/CLAUDE.md\`** and **\`repos/<repo>/rules/\`** — that repo's
  \`CLAUDE.md\` and \`.claude/rules/*.md\`. Edit them in the repo.
- **\`repos/MuscleBuddy/docs/\`** — MuscleBuddy's \`docs/\` tree (SPEC,
  ARCHITECTURE, API, RUNBOOK, and the rest), excluding \`docs/superpowers/\`
  (a dated archive of historical design specs/plans — large, not source of
  truth). Edit in the MuscleBuddy repo.

\`_index.md\` files and \`Map of Content.md\` are also generated — one index
per source folder, plus this vault-wide map linking them.

## Refreshing

\`\`\`
bin/kb-sync.sh
\`\`\`

See \`docs/knowledge-base.md\` in dotclaude for the full setup (Windows path,
Obsidian install, cron/session-hook options for keeping it fresh).
EOF
fi

# --- 5. Drop in the starter .obsidian config on first run only — never
# overwrite it once it exists, so later tweaks in the app survive a refresh.
if [ -d "$TEMPLATE_DIR" ] && [ ! -d "$VAULT_DIR/.obsidian" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    notes+=(".obsidian: would seed from templates/obsidian")
    changed=$((changed + 1))
  else
    cp -r "$TEMPLATE_DIR" "$VAULT_DIR/.obsidian"
    notes+=(".obsidian: seeded from templates/obsidian (first run)")
    changed=$((changed + 1))
  fi
fi

echo "kb-sync: vault at $VAULT_DIR"
echo "kb-sync: ${#memory_projects[@]} memory project(s), ${#repo_names[@]} repo(s)"
if [ "${#notes[@]}" -gt 0 ]; then
  printf '%s\n' "${notes[@]}"
else
  echo "kb-sync: no changes"
fi
if [ "$DRY_RUN" = 1 ]; then
  echo "kb-sync: dry run — nothing written"
fi

exit 0
