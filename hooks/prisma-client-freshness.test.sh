#!/usr/bin/env bash
# Self-test for prisma-client-freshness.sh: silent without Prisma or with a
# current client; reports a missing client and one older than the schema, for
# the default node_modules location, a generator `output`, a multi-file schema
# folder, and a worktree resolving to the main checkout's client.
#   bash hooks/prisma-client-freshness.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/prisma-client-freshness.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

run() { CLAUDE_PROJECT_DIR="$1" "$HOOK" 2>/dev/null; }
expect() { # want(quiet|missing|stale) dir label
  local out; out="$(run "$2")"
  case "$1" in
    quiet) [ -z "$out" ] || { echo "FAIL($3): expected silence, got $out"; fail=1; } ;;
    missing) grep -q 'not generated' <<<"$out" || { echo "FAIL($3): expected 'not generated', got '$out'"; fail=1; } ;;
    stale) grep -q 'older than' <<<"$out" || { echo "FAIL($3): expected 'older than', got '$out'"; fail=1; } ;;
  esac
  if [ -n "$out" ] && ! python3 -c 'import json,sys; json.loads(sys.argv[1])["hookSpecificOutput"]["additionalContext"]' "$out" 2>/dev/null; then
    echo "FAIL($3): output is not hook JSON: $out"; fail=1
  fi
}

R="$TMP/r"; mkdir -p "$R"; git init -q "$R"
expect quiet "$R" "no prisma"

mkdir -p "$R/prisma"
echo 'generator client { provider = "prisma-client-js" }' >"$R/prisma/schema.prisma"
expect missing "$R" "default location, none"
mkdir -p "$R/node_modules/.prisma/client"; sleep 1; touch "$R/node_modules/.prisma/client/index.d.ts"
expect quiet "$R" "default location, current"
sleep 1; touch "$R/prisma/schema.prisma"
expect stale "$R" "default location, stale"

O="$TMP/o"; mkdir -p "$O/prisma"; git init -q "$O"
printf 'generator client {\n  provider = "prisma-client"\n  output   = "./generated/client"\n}\n' >"$O/prisma/schema.prisma"
expect missing "$O" "generator output, none"
mkdir -p "$O/prisma/generated/client"; sleep 1; touch "$O/prisma/generated/client/client.ts"
expect quiet "$O" "generator output, current"

F="$TMP/f"; mkdir -p "$F/prisma/schema"; git init -q "$F"
echo 'model A { id Int @id }' >"$F/prisma/schema/a.prisma"
expect missing "$F" "schema folder, none"

M="$TMP/m"; git init -q -b main "$M"; mkdir -p "$M/prisma"
echo 'generator client { provider = "prisma-client-js" }' >"$M/prisma/schema.prisma"
git -C "$M" add . && git -C "$M" commit -q -m init
mkdir -p "$M/node_modules/.prisma/client"; sleep 1; touch "$M/node_modules/.prisma/client/index.d.ts"
git -C "$M" worktree add -q "$M/.worktrees/w" -b w
touch -d '1 hour ago' "$M/.worktrees/w/prisma/schema.prisma"
expect quiet "$M/.worktrees/w" "worktree resolves to the main client"

[ "$fail" = 0 ] && echo "prisma-client-freshness: all cases passed"
exit "$fail"
