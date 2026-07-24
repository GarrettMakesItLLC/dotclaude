#!/usr/bin/env bash
# dotclaude claim-guard — PreToolUse hook for file-mutating tools
# (Edit | Write | MultiEdit | NotebookEdit).
#
# Turns "claim before you work" from a skill instruction Claude follows
# probabilistically into a hard boundary at the moment work actually starts:
# the first edit. Wired in settings.json under hooks.PreToolUse. On a policy hit
# it exits 2, which blocks the edit and feeds stderr back to Claude.
#
# THE PROBLEM IT SOLVES: two machines drive agents against the same repos. Work
# claimed late — or not at all — gets started twice. The lock itself is the
# remote `issue-<N>-*` branch ref that `issue_claim` creates atomically; this
# hook enforces that an agent editing on such a branch actually went through
# `issue_claim` (issue assigned AND labeled `status:in-progress`) rather than
# creating the branch by hand.
#
# SCOPE: only branches whose name encodes an issue (`issue-<N>-...`). Scratch
# branches, feature branches, detached HEAD, and non-GitHub repos are untouched
# — this must never stand between an agent and ordinary work.
#
# ALWAYS ALLOWED (exit 0):
#   - Any branch that does not match `issue-<N>`.
#   - Any repo whose `origin` is not on github.com, or has no origin.
#   - Any edit when CLAIM_GUARD_OFF is set to a non-empty value.
#   - Anything the API cannot answer within the timeout — see fail-open below.
#
# Fail-open by design: no python3/git/gh, unparseable input, a slow or
# unreachable API, a 404 issue, or any ambiguity exits 0 and lets the edit
# through. A guard that bricks editing whenever GitHub is slow is far worse than
# one that occasionally misses — it is a backstop, not the only boundary.
#
# CACHING: a positive (claimed) answer is cached per session+repo+branch for 10
# minutes under CLAIM_GUARD_CACHE_DIR (default ${TMPDIR:-/tmp}/claude-claim-guard-$UID),
# so a burst of edits costs one API call, not one per keystroke. A negative
# answer is never cached — the agent's next move after a block is to claim, and
# that retry must see the new state immediately.
#
# ENV OVERRIDES: CLAIM_GUARD_OFF (escape hatch), CLAIM_GUARD_CACHE_DIR,
# CLAIM_GUARD_API (REST base URL; exists so the self-test runs offline).

set -uo pipefail

# Drain stdin first so the producing side never sees a broken pipe, then apply
# the escape hatch: opt out entirely.
input="$(cat)"
[ -n "${CLAIM_GUARD_OFF:-}" ] && exit 0

# Need python3 to parse the hook payload and to talk REST. No parser -> fail open.
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0

# Edit/Write/MultiEdit use file_path; NotebookEdit uses notebook_path. One parse
# emits the session id then the path, each on its own line, so a path containing
# spaces survives intact.
parsed="$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input", {}) or {}
print(d.get("session_id") or "nosession")
print(ti.get("file_path") or ti.get("notebook_path") or "")' 2>/dev/null)"

session_id="$(printf '%s' "$parsed" | sed -n 1p)"
file_path="$(printf '%s' "$parsed" | sed -n 2p)"
[ -z "$file_path" ] && exit 0
[ -z "$session_id" ] && session_id="nosession"

# Resolve the nearest existing directory at/above the target (the file may not
# exist yet on a Write). git -C needs a real directory to run in.
dir="$file_path"
[ -d "$dir" ] || dir="$(dirname "$dir")"
while [ ! -d "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
  dir="$(dirname "$dir")"
done
[ -d "$dir" ] || exit 0

# Outside any git work tree -> not our concern.
[ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] || exit 0

# Detached HEAD yields nothing -> nothing to enforce.
branch="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)"
[ -z "$branch" ] && exit 0

# Only branches that encode an issue number are claim-bearing.
issue="$(printf '%s' "$branch" | sed -nE 's/^issue-([0-9]+)(-.*)?$/\1/p')"
[ -z "$issue" ] && exit 0

# Resolve owner/name from origin. No origin, or not GitHub -> out of scope.
url="$(git -C "$dir" remote get-url origin 2>/dev/null)"
[ -z "$url" ] && exit 0
case "$url" in
  *github.com[:/]*) ;;
  *) exit 0 ;;
esac
slug="${url#*github.com}"
slug="${slug#:}"
slug="${slug#/}"
slug="${slug%.git}"
printf '%s' "$slug" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || exit 0

# Cached positive answer within the TTL -> allow without touching the network.
cache_dir="${CLAIM_GUARD_CACHE_DIR:-${TMPDIR:-/tmp}/claude-claim-guard-$(id -u)}"
cache_key="$(printf '%s|%s|%s' "$session_id" "$slug" "$branch" | tr -c '[:alnum:]._-' '_')"
cache_file="$cache_dir/$cache_key"
if [ -f "$cache_file" ] && [ -n "$(find "$cache_file" -mmin -10 2>/dev/null)" ]; then
  exit 0
fi

# Local call, but bound it anyway so a wedged keyring cannot stall every edit.
if command -v timeout >/dev/null 2>&1; then
  token="$(timeout 5 gh auth token 2>/dev/null)"
else
  token="$(gh auth token 2>/dev/null)"
fi
[ -z "$token" ] && exit 0

# REST only (never GraphQL), with a hard 3s timeout. Any failure -> "unknown".
verdict="$(printf '%s' "$token" | python3 -c '
import json, sys, urllib.request

base, slug, number = sys.argv[1], sys.argv[2], sys.argv[3]
token = sys.stdin.read().strip()
req = urllib.request.Request(
    "%s/repos/%s/issues/%s" % (base, slug, number),
    headers={
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "dotclaude-claim-guard",
    },
)
try:
    with urllib.request.urlopen(req, timeout=3) as res:
        data = json.load(res)
except Exception:
    print("unknown")
    sys.exit(0)
if not isinstance(data, dict):
    print("unknown")
    sys.exit(0)
assignees = data.get("assignees") or ([data["assignee"]] if data.get("assignee") else [])
labels = [l.get("name", "") if isinstance(l, dict) else str(l) for l in (data.get("labels") or [])]
print("claimed" if assignees and "status:in-progress" in labels else "unclaimed")
' "${CLAIM_GUARD_API:-https://api.github.com}" "$slug" "$issue" 2>/dev/null)"

if [ "$verdict" = "claimed" ]; then
  mkdir -p "$cache_dir" 2>/dev/null && : > "$cache_file" 2>/dev/null
  exit 0
fi

# Unreachable, slow, 404, malformed -> fail open.
[ "$verdict" = "unclaimed" ] || exit 0

echo "⛔ dotclaude claim-guard blocked this edit." >&2
echo "Reason: you are on branch '$branch', which claims issue #$issue of $slug," >&2
echo "  but that issue is not assigned with status:in-progress — it was never claimed." >&2
echo "  Two machines run agents against this repo; an unclaimed issue is duplicate work" >&2
echo "  waiting to happen. The remote branch ref is the lock, and issue_claim takes it." >&2
echo "Fix: claim it, then work on the branch the claim hands back:" >&2
echo "    issue_claim(repo: \"$slug\", number: $issue)" >&2
echo "  If the claim fails as already-claimed, another machine holds it — pick different work." >&2
echo "  Survey what is already in flight first with work_in_flight." >&2
echo "Policy: ~/dotclaude/CLAUDE.md (Work tracking). Deliberate unclaimed edit?" >&2
echo "  Re-run with CLAIM_GUARD_OFF=1 set, or ask the user to run it via ! prefix." >&2
exit 2
