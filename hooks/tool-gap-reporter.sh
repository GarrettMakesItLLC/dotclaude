#!/usr/bin/env bash
# dotclaude tool-gap-reporter — PostToolUse hook for MCP tools. When the same
# MCP tool fails twice in one session, says so and names where to file it.
#
# Why this exists: CLAUDE.md (Work tracking) says a tool that fails repeatedly or
# can't do what is needed is a defect in the ecosystem, and gets an issue. That
# is prose, and prose loses to momentum — the agent is mid-task, the workaround
# is right there, and the gap goes unrecorded. This hook is the reminder that
# does not depend on remembering.
#
# Why the SECOND failure and not the first: one error is usually the caller's —
# a bad argument, a 404 on something that genuinely isn't there, an expired
# token. The same tool failing twice is a pattern, and a pattern is worth a line
# of context. Nudging on every error would train the agent to ignore the nudge.
#
# Why once per tool per session: the point is one issue per gap, not a reminder
# per call. After it fires for a tool it stays quiet for that tool.
#
# Never blocks. PostToolUse cannot undo the call that already happened, and a
# capability gap is not a policy violation — it is information. Exit is always 0.
#
# Fail-open by design: no python3, malformed JSON, a different event, an
# unreadable state dir -> exit 0 and say nothing.

set -uo pipefail

input="$(cat)"

command -v python3 >/dev/null 2>&1 || exit 0

export TOOL_GAP_STATE_DIR="${TOOL_GAP_STATE_DIR:-${TMPDIR:-/tmp}/claude-tool-gaps-$(id -u)}"

# The python body is single-quoted shell: no apostrophes inside it, or the quote
# closes early and python sees a truncated program.
printf '%s' "$input" | python3 -c '
import json, os, re, sys

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if d.get("hook_event_name") != "PostToolUse":
    sys.exit(0)

tool = d.get("tool_name") or ""
# MCP tools only. A failing Bash command or a rejected Edit is ordinary work
# going wrong, not a missing capability, and it is already visible to the agent.
if not tool.startswith("mcp__"):
    sys.exit(0)

response = d.get("tool_response")


def looks_failed(payload) -> bool:
    """True only on an actual tool error, not on a result that mentions one."""
    if isinstance(payload, dict):
        if payload.get("isError") is True or payload.get("is_error") is True:
            return True
        if isinstance(payload.get("error"), (str, dict)) and payload.get("error"):
            return True
        content = payload.get("content")
        if isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and looks_failed(part):
                    return True
        return False
    if isinstance(payload, str):
        # The shapes an MCP failure actually arrives in.
        return bool(
            re.match(r"\s*(MCP error|InputValidationError|Input validation error)", payload)
            or re.match(r"\s*Error: ", payload)
        )
    return False


if not looks_failed(response):
    sys.exit(0)

session = re.sub(r"[^A-Za-z0-9._-]", "_", str(d.get("session_id") or "nosession"))
state_dir = os.environ.get("TOOL_GAP_STATE_DIR") or ""
if not state_dir:
    sys.exit(0)

key = re.sub(r"[^A-Za-z0-9._-]", "_", f"{session}-{tool}")
count_path = os.path.join(state_dir, key)
notified_path = count_path + ".notified"

try:
    os.makedirs(state_dir, exist_ok=True)
    if os.path.exists(notified_path):
        sys.exit(0)
    count = 0
    if os.path.exists(count_path):
        with open(count_path) as fh:
            count = int((fh.read() or "0").strip() or 0)
    count += 1
    with open(count_path, "w") as fh:
        fh.write(str(count))
    if count < 2:
        sys.exit(0)
    with open(notified_path, "w") as fh:
        fh.write("1")
except Exception:
    sys.exit(0)

# The MCP server behind the tool, for the issue title.
server = tool.split("__")[1] if "__" in tool else tool
msg = (
    f"`{tool}` has now failed {count} times this session. Per CLAUDE.md (Work tracking) that is a "
    "tool gap, not a fact of life: it gets an issue so the next session does not rediscover it.\n"
    f"- Vendored in dotclaude (github-rest) => file in GarrettMakesItLLC/dotclaude and, if it is one "
    "more thin REST wrapper, build it now (skill: closing-tool-gaps).\n"
    f"- A plugin or connector MCP ({server}) => its source is not ours to patch, so file a tracking "
    "issue in GarrettMakesItLLC/dotclaude recording the failing call, the error, and the workaround "
    "you used.\n"
    "- Tooling owned by one app => file in that repo.\n"
    "Include the exact arguments and the error text. If the call was simply wrong, say so and move "
    "on — a wrong call is not a gap, and filing noise is worse than filing nothing."
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": msg,
    }
}))
'

exit 0
