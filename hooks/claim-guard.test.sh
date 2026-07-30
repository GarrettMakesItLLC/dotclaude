#!/usr/bin/env bash
# Self-test for claim-guard.sh. Builds throwaway git repos, serves canned issue
# JSON from a local HTTP server (CLAIM_GUARD_API), feeds a PreToolUse payload
# through the hook, and asserts the exit code (2 = blocked, 0 = allowed).
# No network. Run locally or in CI:
#   bash hooks/claim-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/claim-guard.sh"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# --- stub `gh auth token` so the hook never touches the real CLI
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/bin/sh
[ "$1" = "auth" ] && [ "$2" = "token" ] && { echo faketoken; exit 0; }
exit 1
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# --- canned REST responses, served as static files at /repos/<owner>/<name>/issues/<n>
API_ROOT="$TMP/api/repos/octo/repo/issues"
mkdir -p "$API_ROOT"
cat > "$API_ROOT/5" <<'JSON'
{"number":5,"assignees":[{"login":"GarrettMakesIt"}],"labels":[{"name":"status:in-progress"},{"name":"type:bug"}]}
JSON
cat > "$API_ROOT/6" <<'JSON'
{"number":6,"assignees":[],"labels":[{"name":"status:ready"}]}
JSON
cat > "$API_ROOT/7" <<'JSON'
{"number":7,"assignees":[{"login":"GarrettMakesIt"}],"labels":[{"name":"status:ready"}]}
JSON
cat > "$API_ROOT/8" <<'JSON'
{"number":8,"assignees":[{"login":"GarrettMakesIt"}],"labels":[{"name":"status:in-review"},{"name":"type:feature"}]}
JSON

# -u so the "Serving HTTP on ... port N" banner is flushed into the log we poll.
python3 -u -m http.server 0 --directory "$TMP/api" > "$TMP/srv.log" 2>&1 &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

PORT=""
tries=0
while [ -z "$PORT" ] && [ "$tries" -lt 50 ]; do
  PORT="$(sed -nE 's/.*port ([0-9]+).*/\1/p' "$TMP/srv.log" | head -1)"
  tries=$((tries + 1))
  [ -z "$PORT" ] && sleep 0.1
done
if [ -z "$PORT" ]; then
  echo "FAIL: local API stub did not start"
  exit 1
fi
export CLAIM_GUARD_API="http://127.0.0.1:$PORT"
export CLAIM_GUARD_CACHE_DIR="$TMP/cache"

# want, tool_name, path-key, path, [CLAIM_GUARD_OFF value], [session id]
check() {
  local want="$1" tool="$2" key="$3" path="$4" off="${5:-}" session="${6:-s1}" got
  python3 -c '
import json,sys
print(json.dumps({"session_id":sys.argv[4],"tool_name":sys.argv[1],"tool_input":{sys.argv[2]:sys.argv[3]}}))
' "$tool" "$key" "$path" "$session" | CLAIM_GUARD_OFF="$off" "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: want $want, got $got for $tool $key=$path off='$off'"
    fail=1
  fi
}

# repo() <dir> <branch> <origin-url>
repo() {
  local dir="$1" branch="$2" origin="$3"
  mkdir -p "$dir/src"
  git -C "$dir" init -q
  git -C "$dir" commit -qm init --allow-empty
  git -C "$dir" checkout -q -b "$branch"
  if [ -n "$origin" ]; then
    git -C "$dir" remote add origin "$origin"
  fi
}

# --- claimed issue (assigned + status:in-progress) -> allow
repo "$TMP/claimed" "issue-5-fix-the-thing" "https://github.com/octo/repo.git"
check 0 Edit         file_path     "$TMP/claimed/src/app.ts"
check 0 Write        file_path     "$TMP/claimed/src/brand-new.ts"
check 0 NotebookEdit notebook_path "$TMP/claimed/src/nb.ipynb"
check 0 Edit         file_path     "$TMP/claimed/src/dir with space/x.ts"   # quoting edge case

# --- unclaimed issue (no assignee) -> block
repo "$TMP/unclaimed" "issue-6-do-a-thing" "git@github.com:octo/repo.git"
check 2 Edit         file_path     "$TMP/unclaimed/src/app.ts"
check 2 Write        file_path     "$TMP/unclaimed/a/b/c/deep.ts"           # missing ancestors
check 2 NotebookEdit notebook_path "$TMP/unclaimed/src/nb.ipynb"

# --- status:in-review -> allow: the same claim after its PR opened, so a review
# fixup on the claimed branch is still editable
repo "$TMP/inreview" "issue-8-in-review" "https://github.com/octo/repo.git"
check 0 Edit file_path "$TMP/inreview/src/app.ts"

# --- assigned but NOT status:in-progress -> block (assignee alone is not a claim)
repo "$TMP/halfclaimed" "issue-7-half" "https://github.com/octo/repo.git"
check 2 Edit file_path "$TMP/halfclaimed/src/app.ts"

# --- escape hatch on an otherwise-blocking edit -> allow
check 0 Edit file_path "$TMP/unclaimed/src/app.ts" 1

# --- branches that do not encode an issue -> allow (must never block ordinary work)
repo "$TMP/scratch" "chore/tidy-up" "https://github.com/octo/repo.git"
check 0 Edit file_path "$TMP/scratch/src/app.ts"
repo "$TMP/issueish" "issuefix-6-not-a-claim" "https://github.com/octo/repo.git"
check 0 Edit file_path "$TMP/issueish/src/app.ts"

# --- non-GitHub origin, and no origin at all -> allow
repo "$TMP/gitlab" "issue-6-do-a-thing" "https://gitlab.com/octo/repo.git"
check 0 Edit file_path "$TMP/gitlab/src/app.ts"
repo "$TMP/noremote" "issue-6-do-a-thing" ""
check 0 Edit file_path "$TMP/noremote/src/app.ts"

# --- not a git repo at all -> allow
check 0 Write file_path "$TMP/loose.txt"

# --- detached HEAD on a claim-shaped checkout -> allow (no branch to read)
git -C "$TMP/unclaimed" checkout -q --detach
check 0 Edit file_path "$TMP/unclaimed/src/app.ts"
git -C "$TMP/unclaimed" checkout -q issue-6-do-a-thing

# --- unreachable API -> fail open, never block on a network problem
LIVE_API="$CLAIM_GUARD_API"
export CLAIM_GUARD_API="http://127.0.0.1:1"
check 0 Edit file_path "$TMP/unclaimed/src/app.ts"
export CLAIM_GUARD_API="$LIVE_API"

# --- a positive answer is cached per session+repo+branch: with the API now
# unreachable the claimed repo still passes (cache hit), while a fresh session
# has nothing cached and falls through to fail-open. Both allow; the assertion
# that matters is that a cache file was written for the claimed branch only.
if ! find "$CLAIM_GUARD_CACHE_DIR" -type f -name '*issue-5*' 2>/dev/null | grep -q .; then
  echo "FAIL: no cache entry written for the claimed branch"
  fail=1
fi
if find "$CLAIM_GUARD_CACHE_DIR" -type f -name '*issue-6*' 2>/dev/null | grep -q .; then
  echo "FAIL: a blocked (unclaimed) result was cached — a retry after issue_claim would be stale"
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "claim-guard: all cases passed"
fi
exit "$fail"
