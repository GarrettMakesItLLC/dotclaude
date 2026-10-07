#!/usr/bin/env bash
# dotclaude mcp-tool-adapter — PreToolUse hook wrapper: `mcp-tool-adapter.sh <guard>`.
#
# Every guard here reads Claude Code's native payload shapes: Bash's `command`,
# Read/Edit/Write's absolute `file_path`. Tools that do the same things under
# other names walked past all of them: Serena's `execute_shell_command` runs a
# shell, its file tools read and write by `relative_path`, and the Grep tool
# reads file contents by `path`. Rather than teach each guard every vendor's
# field names, this restates such a call in the native shape the guard already
# judges, and runs the guard on it with its exit status and stderr unchanged:
#
#   mcp__[plugin_serena_]serena__execute_shell_command  -> Bash  {command}
#   …__read_file                                        -> Read  {file_path}
#   …__search_for_pattern                               -> Grep  {path, glob}
#   Grep                                                -> Grep  (passed through)
#   …__create_text_file                                 -> Write {file_path, content}
#   …__replace_content / replace_in_files / delete_lines / replace_lines /
#      insert_at_line / replace_symbol_body / insert_after_symbol /
#      insert_before_symbol / rename_symbol / safe_delete_symbol
#                                                       -> Edit  {file_path}
#
# Serena resolves `relative_path` against its active project, which the hook
# cannot see; the session's `cwd` is where the plugin is started, so paths
# resolve against it. An empty `relative_path` (replace_in_files,
# search_for_pattern over the whole project) is the project root itself, and a
# shell `cwd` argument moves the payload's `cwd` the same way.
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
m = re.fullmatch(r"mcp__(?:plugin_serena_)?serena__([a-z_]+)", tool)
op = m.group(1) if m else None

def at(p):
    p = os.path.expanduser(p or "")
    return os.path.normpath(os.path.join(cwd, p)) if p else cwd

EDITS = {"replace_content", "replace_in_files", "delete_lines", "replace_lines", "insert_at_line",
         "replace_symbol_body", "insert_after_symbol", "insert_before_symbol", "rename_symbol",
         "safe_delete_symbol"}
out = None
if op == "execute_shell_command":
    out = {"tool_name": "Bash", "tool_input": {"command": ti.get("command") or ""},
           "cwd": at(ti.get("cwd")) if ti.get("cwd") else cwd}
elif op == "read_file":
    out = {"tool_name": "Read", "tool_input": {"file_path": at(ti.get("relative_path"))}}
elif op == "search_for_pattern":
    out = {"tool_name": "Grep", "tool_input": {"path": at(ti.get("relative_path")),
                                               "glob": ti.get("paths_include_glob") or ""}}
elif op == "create_text_file":
    out = {"tool_name": "Write", "tool_input": {"file_path": at(ti.get("relative_path")),
                                                "content": ti.get("content") or ""}}
elif op in EDITS:
    out = {"tool_name": "Edit", "tool_input": {"file_path": at(ti.get("relative_path"))}}
elif tool == "Grep":
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
