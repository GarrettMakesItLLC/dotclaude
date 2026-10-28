#!/usr/bin/env bash
# dotclaude mcp-tool-adapter — PreToolUse hook wrapper: `mcp-tool-adapter.sh <guard>`.
#
# Every guard here reads Claude Code's native payload shapes: Bash's `command`,
# Read/Edit/Write's absolute `file_path`. The Grep tool reads file contents by
# `path`, which the guards did not understand. Rather than teach each guard
# that field name, this restates the call in the shape the guard already
# judges, and runs the guard on it with its exit status and stderr unchanged:
#
#   Grep -> Grep {path, glob}   (`path` resolved against the session's `cwd`)
#
# A payload this does not recognise reaches the guard unchanged, so a native
# tool registered on the same matcher is judged exactly as before.
#
# Fail-open like the guards it wraps: no python3 is announced and lets the call
# through; an unparseable payload is passed through for the guard to judge.
set -uo pipefail

guard="${1:-}"
hooks_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
case "$guard" in
  ''|*/*|*..*) echo "⛔ dotclaude mcp-tool-adapter: usage: mcp-tool-adapter.sh <guard-name>" >&2; exit 2 ;;
esac
[ -x "$hooks_dir/$guard.sh" ] || { echo "⛔ dotclaude mcp-tool-adapter: no guard named '$guard' in $hooks_dir" >&2; exit 2; }

input="$(cat)"
command -v python3 >/dev/null 2>&1 || { echo "⚠️  dotclaude mcp-tool-adapter: DISABLED — python3 is not installed, so $guard checked nothing (bin/doctor.sh lists the prerequisites)." >&2; exit 0; }

native="$(printf '%s' "$input" | python3 -c '
import json, os, re, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    sys.stdout.write(raw); sys.exit(0)
tool = d.get("tool_name") or ""
ti = d.get("tool_input") or {}
cwd = d.get("cwd") or os.getcwd()
def at(p):
    p = os.path.expanduser(p or "")
    return os.path.normpath(os.path.join(cwd, p)) if p else cwd

out = None
if tool == "Grep":
    out = {"tool_name": "Grep", "tool_input": {"path": at(ti.get("path")), "glob": ti.get("glob") or ""}}
if out is None:
    sys.stdout.write(raw); sys.exit(0)
for k, v in d.items():
    if k not in ("tool_name", "tool_input"):
        out.setdefault(k, v)
out.setdefault("cwd", cwd)
out["original_tool_name"] = tool
sys.stdout.write(json.dumps(out))
' 2>/dev/null)" || native="$input"

"$hooks_dir/$guard.sh" <<<"$native"
