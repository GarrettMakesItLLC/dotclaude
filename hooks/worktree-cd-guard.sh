#!/usr/bin/env bash
# dotclaude worktree-cd-guard — PreToolUse hook (matcher: Bash). Refuses a
# command that `cd`s into a worktree that is not there.
#
# Every Bash write is supposed to lead with `cd <absolute-path> &&`. When that
# path has gone — a sweep reclaimed it, another session removed it, a name was
# mistyped — the failure is not that the command errors. It is that the command
# KEEPS GOING, in whatever directory the shell is in, usually the main checkout
# on the trunk:
#
#   - `cd <gone>; <cmd>` runs `<cmd>` in the main checkout outright;
#   - `cd <gone> && <cmd>` stops for that one line, and the NEXT line starts
#     fresh in the main checkout with nothing to say it moved.
#
# The cost is not lost data. It is a test reproduction that runs on the trunk,
# passes because the defect lives on the branch, and reads as "cannot
# reproduce" — an operation that changes what a later result MEANS without
# changing how it looks.
#
# Scope is deliberately narrow: only a `cd`/`pushd` to an absolute (or `~/`)
# path that names a worktree (a `.worktrees/` or `.claude/worktrees/` path). A
# missing relative path or a path elsewhere on the box is somebody else's
# business, and a guard that argues about those gets turned off.
#
# Fail-open on anything unexpected.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "⚠️  dotclaude worktree-cd-guard: DISABLED — python3 is not installed, so nothing was checked (bin/doctor.sh lists the prerequisites)." >&2; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "⚠️  dotclaude worktree-cd-guard: DISABLED — perl is not installed, so nothing was checked (bin/doctor.sh lists the prerequisites)." >&2; exit 0; }

input="$(cat)"
command_str="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    sys.stdout.write(json.load(sys.stdin).get("tool_input", {}).get("command", "") or "")
except Exception:
    pass
' 2>/dev/null)" || exit 0
[ -n "$command_str" ] || exit 0

# Heredoc bodies are prose — a command that WRITES a runbook naming a worktree
# path must not be judged on it.
#
# Quotes are STRIPPED rather than blanked, unlike the other guards here. Blanking
# `"$WORKTREE"/.worktrees/thing` leaves `/.worktrees/thing`, an absolute path
# that does not exist and never did — the scrub manufactures the exact shape
# this hook refuses. Keeping the content leaves `$WORKTREE`, which the
# unevaluated-expansion test below skips. What blanking bought instead is
# recovered by requiring `cd` at a COMMAND position: `echo 'cd /gone'` has a
# word before it and is not a cd.
scrubbed="$(printf '%s' "$command_str" \
  | perl -0777 -pe "s/<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1.*?^\2\$/ /gms" 2>/dev/null \
  | tr -d "\"'")" || exit 0
[ -n "$scrubbed" ] || exit 0

# A tree the same command creates first (`git worktree add <p> && cd <p>`,
# `mkdir -p <p> && cd <p>`) does not exist yet when this runs, and is not gone.
# The created path is resolved the way the shell will resolve it: against a
# `git -C <dir>`, else the directory the last `cd` in the command moved to, else
# the session cwd — so `cd <repo> && git worktree add .worktrees/x && cd
# <repo>/.worktrees/x` is recognised, and so is a later `sh -c "cd …"` (#457).
hook_cwd="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    sys.stdout.write(json.load(sys.stdin).get("cwd", "") or "")
except Exception:
    pass
' 2>/dev/null)" || hook_cwd=""
created="$(printf '%s' "$scrubbed" | HOOK_CWD="${hook_cwd:-$PWD}" python3 -c '
import os, re, shlex, sys

def resolve(cur, d):
    d = os.path.expanduser(d)
    return os.path.normpath(d if os.path.isabs(d) else os.path.join(cur, d))

cur = os.environ.get("HOOK_CWD") or os.getcwd()
WRAP = {"env", "nohup", "time", "command", "builtin", "exec", "do", "then", "else", "!"}
for seg in re.split(r"\s*(?:&&|\|\||;;|;|\||&|\n|(?<!\$)\(|\))\s*", sys.stdin.read()):
    try:
        t = shlex.split(seg)
    except ValueError:
        t = seg.split()
    while t and (t[0] in WRAP or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t[0])):
        t = t[1:]
    # `sh -c <cmd>` (quotes already stripped): judge the command it runs.
    if t and t[0].split("/")[-1] in ("sh", "bash", "zsh", "dash") and len(t) > 2 and t[1].startswith("-") and "c" in t[1]:
        t = t[2:]
    if not t:
        continue
    if t[0] in ("cd", "pushd"):
        args = [a for a in t[1:] if not re.match(r"^-[LPe@]*$", a) and a != "--"]
        if args and "$" not in args[0] and args[0] != "-":
            cur = resolve(cur, args[0])
        continue
    if t[0] == "git":
        base, i = cur, 1
        while i < len(t) and t[i].startswith("-"):
            if t[i] == "-C" and i + 1 < len(t):
                base = resolve(base, t[i + 1]); i += 2; continue
            if t[i] in ("-c", "--git-dir", "--work-tree") and i + 1 < len(t):
                i += 2; continue
            i += 1
        if t[i:i + 2] != ["worktree", "add"]:
            continue
        skip = False
        for a in t[i + 2:]:
            if skip:
                skip = False; continue
            if a in ("-b", "-B", "--reason"):
                skip = True; continue
            if a.startswith("-"):
                continue
            print(resolve(base, a)); break
    elif t[0] == "mkdir":
        for a in t[1:]:
            if not a.startswith("-"):
                print(resolve(cur, a))
' 2>/dev/null)" || created=""

missing=()
while IFS= read -r target; do
  [ -n "$target" ] || continue
  # `~` is the form agents actually type for a path under $HOME, and every
  # worktree on this box is under $HOME — so the guard that only understood a
  # literal leading `/` was silent on most of the commands it exists for
  #.
  case "$target" in
    '~'/*) target="${HOME}${target#\~}" ;;
    '~') continue ;;
  esac
  case "$target" in
    /*) ;;
    *) continue ;;
  esac
  # Only paths that name a checkout — a worktree, or a repo root holding one.
  case "$target" in
    */.worktrees/* | */.claude/worktrees/*) ;;
    *) continue ;;
  esac
  # An expansion this hook cannot evaluate is not a missing directory.
  case "$target" in
    *'$'* | *'`'* | *'*'* | *'?'*) continue ;;
  esac
  [ -d "$target" ] && continue
  made=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "$target" in "$c" | "$c"/*) made=1 ;; esac
  done <<<"$created"
  [ "$made" = 1 ] && continue
  missing+=("$target")
  # `pushd` changes the directory exactly as `cd` does, and fails as quietly.
  # `builtin`/`command`/`time` before it, and its `-L`/`-P`/`-e`/`-@`/`--`
  # options before the path, change nothing about where it lands.
done < <(printf '%s' "$scrubbed" \
  | grep -oE '(^|[;&|(){]|&&|\|\||[[:space:]](do|then|else|-c)[[:space:]])[[:space:]]*((builtin|command|time)[[:space:]]+)*(cd|pushd)[[:space:]]+((-[LPe@]+|--)[[:space:]]+)*[^[:space:];&|)]+' \
  | sed -E 's/.*(cd|pushd)[[:space:]]+((-[LPe@]+|--)[[:space:]]+)*//')

((${#missing[@]})) || exit 0

{
  echo "⛔ dotclaude worktree-cd-guard: this command cds into a worktree that is not there."
  for m in "${missing[@]}"; do echo "  $m"; done
  echo
  echo "The command would not stop there. With \`;\` the rest runs in whatever directory the"
  echo "shell is in (usually the main checkout); with \`&&\` only this line stops, and the NEXT"
  echo "command starts in the main checkout with nothing to say it moved. A reproduction run"
  echo "that way passes — the defect is on the branch — and reads as \"cannot reproduce\"."
  echo
  echo "  git worktree list        what the repo actually has right now"
  echo
  echo "If the tree was removed, check its branch out into a new worktree rather than running"
  echo "anything in the main checkout."
} >&2
exit 2
