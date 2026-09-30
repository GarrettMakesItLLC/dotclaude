# shellcheck shell=bash
# Read a product repo's `.claude/repo.json`. Sourced, never run.
#
# The manifest carries the per-repo VALUES (env prefix, state dir, env files,
# install command, Railway service, ...) that the shared scripts in this bin/
# directory read, so one copy of the behaviour serves every product repo.
# Schema and field meanings: docs/repo-manifest.md.
#
#   manifest_find [<dir>]        path of the manifest governing <dir>, rc 1 if none
#   manifest_get <dotted.key>    the value: a string/number/bool on one line, a list
#                                one item per line, an object as `key<TAB>value`
#                                lines; rc 1 when absent or null
#   manifest_has <dotted.key>    rc 0 when present and not null
#   manifest_path_expand <p>     `~/x` -> $HOME/x, anything else unchanged
#
# MANIFEST must be set (manifest_find does it) before manifest_get/manifest_has.
# REPO_MANIFEST in the environment overrides discovery, which is how the
# self-tests point a script at a fixture.

# The manifest lives in the checkout, not the main tree only: it is tracked, so
# every worktree has the copy for its own branch — which is the one that should
# decide how that branch is bootstrapped.
manifest_find() {
  local dir="${1:-$PWD}" top
  if [ -n "${REPO_MANIFEST:-}" ]; then
    [ -f "$REPO_MANIFEST" ] || return 1
    MANIFEST="$REPO_MANIFEST"
    printf '%s\n' "$MANIFEST"
    return 0
  fi
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -f "$top/.claude/repo.json" ] || return 1
  MANIFEST="$top/.claude/repo.json"
  printf '%s\n' "$MANIFEST"
}

manifest_get() {
  [ -n "${MANIFEST:-}" ] && [ -f "$MANIFEST" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$MANIFEST" "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        node = json.load(fh)
except Exception:
    sys.exit(1)
for part in sys.argv[2].split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        sys.exit(1)
if node is None:
    sys.exit(1)

def scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (dict, list)):
        return json.dumps(v, separators=(",", ":"))
    return str(v)

if isinstance(node, list):
    for item in node:
        print(scalar(item))
elif isinstance(node, dict):
    for k, v in node.items():
        print(f"{k}\t{scalar(v)}")
else:
    print(scalar(node))
PY
}

manifest_has() {
  manifest_get "$1" >/dev/null 2>&1
}

manifest_path_expand() {
  case "$1" in
    \~) printf '%s\n' "$HOME" ;;
    \~/*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# The main working tree of the repo containing <dir>: the parent of the shared
# git common dir, which every linked worktree resolves to identically. Empty and
# rc 1 outside a repo.
main_tree_of() {
  local common
  common="$(git -C "${1:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  (cd "$(dirname "$common")" && pwd)
}

# Make ~/.bashrc source <file>, once — a line already sourcing it under its
# `$HOME/...` spelling counts, which is how a repo's own older scripts wrote
# it. Inserted ABOVE the
# ~/.config/secrets/gmi.env line when there is one, so gmi.env keeps winning on
# NODE_AUTH_TOKEN: it holds the PAT with `read:packages`, and a bundle sourced
# after it that exported a `gh` OAuth token would silently downgrade npm auth.
# Rewritten through `cat`, not `mv`, so ~/.bashrc keeps its inode and mode.
bashrc_ensure_sourced() {
  local file="$1" label="$2" bashrc="$HOME/.bashrc" line gmi tmp
  line="[ -f \"$file\" ] && . \"$file\""
  grep -qF "$line" "$bashrc" 2>/dev/null && return 0
  case "$file" in
    "$HOME"/*)
      # shellcheck disable=SC2016 # the literal `$HOME` spelling in ~/.bashrc
      grep -qF ". \"\$HOME/${file#"$HOME"/}\"" "$bashrc" 2>/dev/null && return 0
      ;;
  esac
  # shellcheck disable=SC2016 # the literal line as it appears in ~/.bashrc
  gmi='[ -f "$HOME/.config/secrets/gmi.env" ] && . "$HOME/.config/secrets/gmi.env"'
  if grep -qF "$gmi" "$bashrc" 2>/dev/null; then
    tmp="$(mktemp)"
    awk -v src="$line" -v gmi="$gmi" -v label="# $label" '
      !done && $0 == gmi { print label; print src; print ""; done = 1 }
      { print }
    ' "$bashrc" >"$tmp" && cat "$tmp" >"$bashrc"
    rm -f "$tmp"
  else
    printf '\n# %s\n%s\n' "$label" "$line" >>"$bashrc"
  fi
  echo "added the source line for $file to ~/.bashrc — open a new shell to load it."
}
