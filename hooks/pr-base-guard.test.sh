#!/usr/bin/env bash
# Self-test for pr-base-guard.sh against a two-tier and a single-tier fixture
# repo: a non-dev head into main is blocked (gh CLI and the github-rest MCP),
# dev -> main, feature -> dev, another repo, and a single-tier repo pass.
#   bash hooks/pr-base-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/pr-base-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mk() { # dir, with-dev
  git init -q -b main "$1"
  git -C "$1" commit -q --allow-empty -m init
  git -C "$1" remote add origin git@github.com:Org/Two.git
  git -C "$1" update-ref refs/remotes/origin/main HEAD
  [ "$2" = yes ] && git -C "$1" update-ref refs/remotes/origin/dev HEAD
  git -C "$1" checkout -q -b feat/x
}
mk "$TMP/two" yes
mk "$TMP/one" no

bash_payload() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }
mcp_payload() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"mcp__github-rest__pr_create","tool_input":json.loads(sys.argv[1])}))' "$1"; }
check() {
  local want="$1" dir="$2" payload="$3" got
  printf '%s' "$payload" | (cd "$dir" && "$GUARD") >/dev/null 2>&1
  got=$?
  [ "$got" = "$want" ] || { echo "FAIL: want $want got $got in $(basename "$dir"): $payload"; fail=1; }
}

check 2 "$TMP/two" "$(bash_payload 'gh pr create --base main --title x --body y')"
check 2 "$TMP/two" "$(bash_payload 'gh pr create -B main -H feat/x -t x')"
check 2 "$TMP/two" "$(bash_payload 'gh pr create --base=main --fill')"
check 2 "$TMP/two" "$(mcp_payload '{"title":"x","head":"feat/x","base":"main"}')"
check 2 "$TMP/two" "$(mcp_payload '{"title":"x","head":"feat/x","base":"main","repo":"Org/Two"}')"
check 0 "$TMP/two" "$(bash_payload 'gh pr create --base main --head dev --title promote')"
check 0 "$TMP/two" "$(mcp_payload '{"title":"x","head":"dev","base":"main"}')"
check 0 "$TMP/two" "$(bash_payload 'gh pr create --base dev --title x')"
check 0 "$TMP/two" "$(mcp_payload '{"title":"x","head":"feat/x","base":"main","repo":"Org/Other"}')"
check 0 "$TMP/two" "$(bash_payload 'gh pr list --base main')"
check 0 "$TMP/one" "$(bash_payload 'gh pr create --base main --title x')"
check 0 "$TMP/one" "$(mcp_payload '{"title":"x","head":"feat/x","base":"main"}')"
printf 'not json' | "$GUARD" >/dev/null 2>&1 || { echo "FAIL: garbage input did not fail open"; fail=1; }

[ "$fail" = 0 ] && echo "pr-base-guard: all cases passed"
exit "$fail"
