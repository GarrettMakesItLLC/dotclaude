#!/usr/bin/env bash
# dotclaude pr-base-guard — PreToolUse hook (matcher: Bash|mcp__github-rest__pr_create).
#
# In a two-tier repo (one with a `dev` branch on origin), feature work targets
# `dev` and the only PR into `main` is the `dev -> main` promotion. A PR opened
# against `main` from anything else is rejected by the repo's CI base check —
# but only after a full CI run, which is the cost this avoids.
#
# Judged: `gh pr create --base main` (and `-B main`) and the github-rest MCP's
# `pr_create` with `base: "main"`. The head is `--head`/`-H` or the MCP `head`,
# else the current branch. A single-tier repo (no `origin/dev`) is never judged,
# and neither is a PR aimed at a repo other than the one the session is in —
# this hook cannot see that repo's branches.
#
# Fail-open on anything it cannot parse.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || exit 0
input="$(cat)"

verdict="$(printf '%s' "$input" | python3 -c '
import json, re, shlex, subprocess, sys

def git(*a):
    try:
        r = subprocess.run(["git", *a], capture_output=True, text=True, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool = d.get("tool_name", "")
ti = d.get("tool_input", {}) or {}
base = head = repo = None
if tool == "Bash":
    cmd = ti.get("command", "") or ""
    for seg in re.split(r"\s*(?:&&|\|\||;|\||\n)\s*", cmd):
        try:
            t = shlex.split(seg)
        except ValueError:
            continue
        if len(t) >= 3 and t[:3] == ["gh", "pr", "create"]:
            names = {"--base": "base", "-B": "base", "--head": "head", "-H": "head", "--repo": "repo", "-R": "repo"}
            found = {}
            i = 3
            while i < len(t):
                a = t[i]
                if a in names and i + 1 < len(t):
                    found[names[a]] = t[i + 1]
                    i += 2
                    continue
                if "=" in a and a.split("=", 1)[0] in names:
                    found[names[a.split("=", 1)[0]]] = a.split("=", 1)[1]
                i += 1
            base, head, repo = found.get("base"), found.get("head"), found.get("repo")
            break
elif tool.endswith("pr_create"):
    base, head, repo = ti.get("base"), ti.get("head"), ti.get("repo")
else:
    sys.exit(0)

if base != "main":
    sys.exit(0)
if repo:
    url = git("remote", "get-url", "origin")
    slug = re.sub(r"\.git$", "", re.sub(r"^(git@[^:]+:|https?://[^/]+/)", "", url))
    if not slug or slug.lower() != repo.lower():
        sys.exit(0)
if not git("rev-parse", "--verify", "--quiet", "refs/remotes/origin/dev"):
    sys.exit(0)
if not head:
    head = git("rev-parse", "--abbrev-ref", "HEAD")
head = (head or "").split(":")[-1]
if head and head != "dev":
    print(head)
' 2>/dev/null)" || exit 0

[ -n "$verdict" ] || exit 0
echo "⛔ dotclaude pr-base-guard: a PR from '$verdict' into 'main'. In this two-tier repo the only PR into 'main' is 'dev -> main'; feature work targets 'dev' (--base dev). The repo's CI base check rejects any other base, after a full run." >&2
exit 2
