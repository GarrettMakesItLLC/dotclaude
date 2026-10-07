#!/usr/bin/env bash
# dotclaude heredoc-guard — PreToolUse hook (matcher: Bash). Refuses a heredoc
# whose delimiter is UNQUOTED (`<<EOF`, `<<-EOF`) when its body contains a
# backtick span or `$(`.
#
# An unquoted delimiter makes bash expand the body before the reader sees it:
# every `cmd` and $(cmd) in it RUNS, in the shell's cwd and environment. A
# script or doc fed through `python3 - <<EOF` (unquoted, to interpolate one
# variable) runs each markdown code span it contains — `npx prisma migrate
# deploy` included, against whatever database the worktree's env points at.
# A quoted delimiter (`<<'EOF'`, `<<"EOF"`, `<<\EOF`) passes the body through
# untouched; values go in through env or argv instead.
#
# Escaped forms (\` and \$() are literal in an unquoted body and are allowed.
# Deliberate expansion: lead the command with `HEREDOC_EXPAND_OK=1`.
#
# Pattern-based, not a shell parse: a `<<` inside a quoted string on its own
# line is skipped, and anything this cannot read fails open.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "⚠️  dotclaude heredoc-guard: DISABLED — python3 is not installed, so nothing was checked (bin/doctor.sh lists the prerequisites)." >&2; exit 0; }
input="$(cat)"

INPUT_JSON="$input" python3 - <<'PYEOF'
import json, os, re, sys

try:
    obj = json.loads(os.environ["INPUT_JSON"])
except Exception:
    sys.exit(0)
if obj.get("tool_name") != "Bash":
    sys.exit(0)
cmd = (obj.get("tool_input") or {}).get("command") or ""
if "<<" not in cmd or re.search(r"(^|[\s;&|(])HEREDOC_EXPAND_OK=1\b", cmd):
    sys.exit(0)

OP = re.compile(r"<<(-?)[ \t]*(\\?)(['\"]?)([A-Za-z_][A-Za-z0-9_.-]*)\3")


def operators(line):
    """Heredoc operators on one command line, skipping quoted text and `<<<`."""
    found, quote, i = [], None, 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c == "\\":
            i += 2
            continue
        elif c in "'\"":
            quote = c
        elif c == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        elif line.startswith("<<<", i):
            i += 3
            continue
        elif line.startswith("<<", i):
            m = OP.match(line, i)
            if m:
                quoted = bool(m.group(2) or m.group(3))
                found.append((m.group(4), m.group(1) == "-", quoted))
                i = m.end()
                continue
        i += 1
    return found


EXPANDS = re.compile(r"`[^`]*`|\$\(")
lines = cmd.split("\n")
hits, pending, i = [], [], 0
while i < len(lines):
    if pending:
        delim, dash, quoted = pending.pop(0)
        body = []
        while i < len(lines):
            line = lines[i]
            i += 1
            if (line.lstrip("\t") if dash else line) == delim:
                break
            body.append(line)
        if not quoted:
            text = re.sub(r"\\.", "", "\n".join(body))
            m = EXPANDS.search(text)
            if m:
                hits.append((delim, m.group(0)[:60]))
        continue
    pending.extend(operators(lines[i]))
    i += 1

if not hits:
    sys.exit(0)
delim, sample = hits[0]
print(
    f"⛔ dotclaude heredoc-guard: the heredoc ending at `{delim}` has an UNQUOTED delimiter and its\n"
    f"body contains {sample!r}. Bash expands an unquoted heredoc before the reader sees it, so\n"
    "every backtick span and $(…) in the body RUNS — in this shell, with this env (a markdown\n"
    "code span like `npx prisma migrate deploy` included).\n"
    f"Fix: quote the delimiter — <<'{delim}' — and pass values in through env or argv\n"
    "  (VAR=value python3 - <<'EOF' … os.environ['VAR'] …).\n"
    "Deliberate expansion: lead the command with HEREDOC_EXPAND_OK=1.",
    file=sys.stderr,
)
sys.exit(2)
PYEOF
