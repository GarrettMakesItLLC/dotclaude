#!/usr/bin/env bash
# dotclaude prisma-client-freshness — SessionStart hook.
#
# A stale generated Prisma client makes typecheck, lint and tests fail with
# errors that read as code bugs — a missing model property, a wrong field type,
# a bogus `no-unnecessary-condition` — which is the single most expensive false
# lead in a Prisma repo. Checking at session start replaces a per-turn
# instruction with a deterministic one.
#
# The schema is `prisma/schema.prisma` or the `prisma/schema/` folder. The
# client is wherever the generator puts it: the `output` of the first
# `generator` block, resolved against the schema's directory, else
# `node_modules/.prisma/client` — in this tree or, for a worktree that resolves
# upward, the main checkout's. Reports "not generated" or "older than the
# schema"; says nothing when the client is current or the repo has no Prisma.
#
# Reports through additionalContext; never blocks. Fail-open on everything.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || exit 0
dir="${CLAUDE_PROJECT_DIR:-$PWD}"
root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$dir")"
common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
main_tree="${common:+$(dirname "$common")}"

msg="$(ROOT="$root" MAIN="${main_tree:-$root}" python3 - <<'PY' 2>/dev/null
import glob, os, re

root, main = os.environ["ROOT"], os.environ["MAIN"]
schemas = []
if os.path.isfile(os.path.join(root, "prisma", "schema.prisma")):
    schemas = [os.path.join(root, "prisma", "schema.prisma")]
elif os.path.isdir(os.path.join(root, "prisma", "schema")):
    schemas = sorted(glob.glob(os.path.join(root, "prisma", "schema", "**", "*.prisma"), recursive=True))
if not schemas:
    raise SystemExit(0)

candidates = []
for s in schemas:
    text = open(s, encoding="utf-8", errors="replace").read()
    m = re.search(r'generator\s+\w+\s*\{[^}]*?\boutput\s*=\s*"([^"]+)"', text, re.S)
    if m:
        candidates.append(os.path.normpath(os.path.join(os.path.dirname(s), m.group(1))))
        break
candidates += [os.path.join(t, "node_modules", ".prisma", "client") for t in dict.fromkeys([root, main])]

def newest(path):
    best = 0.0
    for dirpath, _, files in os.walk(path):
        for f in files:
            try:
                best = max(best, os.path.getmtime(os.path.join(dirpath, f)))
            except OSError:
                pass
    return best

client = next((c for c in candidates if os.path.isdir(c) and newest(c) > 0), None)
rel = os.path.relpath(schemas[0], root) if len(schemas) == 1 else "prisma/schema/"
if client is None:
    print(f"Prisma client not generated in {root}. Typecheck, lint and test failures here are environment, not code, until it is: npx prisma generate")
elif max(os.path.getmtime(s) for s in schemas) > newest(client):
    print(f"The generated Prisma client ({os.path.relpath(client, root)}) is older than {rel}. Typecheck/lint/test failures that name model fields may be stale-client artifacts, not code bugs. Run: npx prisma generate")
PY
)" || exit 0

[ -n "$msg" ] || exit 0
MSG="$msg" python3 -c '
import json, os
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": os.environ["MSG"]}}))'
exit 0
