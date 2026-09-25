#!/usr/bin/env bash
# Runs one of GarrettMakesItLLC/ci's composite actions locally, at the exact ref a consumer pins,
# through ci's scripts/run-composite.py — so a consumer's degraded-mode replica
# (.claude/ci-replica.json) can keep a check its workflow delegates to a shared action.
#
#   run-shared-action.sh <action> [--ref <ref>] [run-composite.py args...]
#   run-shared-action.sh check-action-pins --ref v1 --input workflow-dir=.github/workflows
#
# The action runs from ci at <ref> (default v1); the runner comes from ci's main, since it is the
# replica's tool rather than part of the action under test. Both are fetched once per commit into
# ~/.cache/gmi-ci/<sha>. GMI_CI_SOURCE=<dir> uses a local ci tree for both instead (tests, offline).
set -euo pipefail

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage
case "$1" in -h|--help) usage ;; esac
action="$1"; shift
ref="v1"
if [ "${1:-}" = "--ref" ]; then
  [ $# -ge 2 ] || usage
  ref="$2"; shift 2
fi

REPO="GarrettMakesItLLC/ci"
CACHE="${GMI_CI_CACHE:-$HOME/.cache/gmi-ci}"

# ref -> directory holding ci at that commit
tree_at() {
  local r="$1" sha dir tmp
  sha="$(gh api "repos/$REPO/commits/$r" --jq .sha)" || { echo "run-shared-action: cannot resolve $REPO@$r" >&2; return 1; }
  dir="$CACHE/$sha"
  if [ ! -f "$dir/.complete" ]; then
    tmp="$(mktemp -d)"
    gh api "repos/$REPO/tarball/$sha" > "$tmp/ci.tar.gz"
    mkdir -p "$dir"
    tar -xzf "$tmp/ci.tar.gz" -C "$dir" --strip-components=1
    rm -rf "$tmp"
    touch "$dir/.complete"
  fi
  printf '%s\n' "$dir"
}

if [ -n "${GMI_CI_SOURCE:-}" ]; then
  action_tree="$GMI_CI_SOURCE"
  runner_tree="$GMI_CI_SOURCE"
else
  action_tree="$(tree_at "$ref")"
  runner_tree="$(tree_at main)"
fi

if [ ! -f "$action_tree/actions/$action/action.yml" ]; then
  echo "run-shared-action: $REPO@$ref has no actions/$action" >&2
  exit 2
fi
exec python3 "$runner_tree/scripts/run-composite.py" "$action_tree/actions/$action" "$@"
