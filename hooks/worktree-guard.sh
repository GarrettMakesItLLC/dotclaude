#!/usr/bin/env bash
# dotclaude worktree-guard — PreToolUse hook for file-mutating tools
# (Edit | Write | MultiEdit | NotebookEdit | Bash).
#
# Turns the "Worktree-first for code changes" rule in ~/dotclaude/CLAUDE.md from
# prose Claude follows probabilistically into a hard, deterministic block. Wired
# in settings.json under hooks.PreToolUse. On a policy hit it exits 2, which
# blocks the edit and feeds stderr back to Claude.
#
# THE PROBLEM IT SOLVES: multiple agents running in one checkout write to the
# MAIN working tree instead of an isolated worktree, so their uncommitted
# changes bleed into every other agent's view. This blocks main-tree edits in
# repos that use the worktree convention, forcing agents onto `.worktrees/`.
#
# WHAT COUNTS AS "uses the worktree convention": the repo gitignores
# `.worktrees/` (checked via `git check-ignore`, so a global gitignore counts
# too). Repos that don't gitignore it are untouched.
#
# ALWAYS ALLOWED (exit 0):
#   - Edits already inside a linked worktree (detected structurally via
#     git-dir != git-common-dir — NOT by matching ".worktrees" in the path, so
#     a worktree placed anywhere still passes).
#   - The dotclaude config repo itself. Its hooks/skills/settings ARE the live
#     config (via the ~/.claude symlinks); editing them in a throwaway worktree
#     would not take effect. Self-identified by locating this script's own repo.
#   - Any edit when WORKTREE_GUARD_OFF is set to a non-empty value — the escape
#     hatch for a deliberate main-tree edit or a solo main session. Export it in
#     your shell profile to opt a whole session out.
#
# Fail-open by design: unparseable input, no python3, no git, or any ambiguity
# exits 0 and lets the edit through. A guard that bricks every edit is far worse
# than one that occasionally misses — it is a backstop, not the only boundary.
#
# BASH COVERAGE (#92): a `Bash` command is scanned for write patterns —
# redirection (`>`, `>>`), `sed -i`/`--in-place`, `cp`/`mv`/`install`/`tee`
# destinations, and a Python `open(path, "w"/"a"/...)` call anywhere in the
# command (the heredoc-to-python3 workaround that motivated this). Every
# candidate path found is checked against the same main-tree/worktree logic as
# Edit/Write. This is deliberately best-effort, NOT exhaustive — a write
# buried in a script it invokes, or spelled in a way the regexes below don't
# recognize, still gets through. It closes the common escape hatch (an agent
# reaching for `python3 - <<EOF ... open(path, "w") ... EOF` when Edit/Write
# was blocked), not every possible one.
#
# KNOWN GAPS (by design — backstop, not a sandbox):
#   - Cannot distinguish a subagent from the main session (no such flag in hook
#     input). Both are guarded; the escape hatch + config-repo exemption cover
#     the legitimate main-session cases.
#   - Bash coverage is pattern-based, not a real shell parse — see above.

set -uo pipefail

# Drain stdin first so the producing side never sees a broken pipe, then apply
# the escape hatch: opt out entirely.
input="$(cat)"
[ -n "${WORKTREE_GUARD_OFF:-}" ] && exit 0

# Need python3 to parse the tool_input JSON. No parser -> fail open.
command -v python3 >/dev/null 2>&1 || exit 0
# Edit/Write/MultiEdit use file_path; NotebookEdit uses notebook_path; Bash
# uses command, scanned below for write patterns instead of a single path.
# Emits one candidate path per line — bash variables cannot hold an embedded
# NUL byte ($(...) truncates there), and a literal newline in a path is rare
# enough to accept missing (fail-open, per the header).
# A quoted heredoc delimiter ('PYEOF'): bash passes the body through with NO
# expansion or quote-interpretation, unlike `python3 -c '...'` — which breaks
# the moment the Python source itself needs a single quote (regex character
# classes, str.strip(), etc. all do). Input travels via an env var, not stdin —
# the heredoc IS python3's stdin (that's how `python3 -` gets its script), so
# piping JSON in on top of it would just be discarded.
candidates="$(INPUT_JSON="$input" python3 - <<'PYEOF' 2>/dev/null
import json, os, re, sys

try:
    obj = json.loads(os.environ.get("INPUT_JSON", ""))
except Exception:
    sys.exit(0)

tool = obj.get("tool_name", "")
ti = obj.get("tool_input", {})
out = []
QUOTES = "\"'"

if tool == "Bash":
    cmd = ti.get("command") or ""

    # A quoted (or unquoted) heredoc body is data, passed through verbatim with
    # no shell interpretation — a `>` at the start of a markdown blockquote
    # line, or any other shell-metacharacter-looking prose, is not a redirect.
    # Blank out heredoc body lines before scanning for write patterns so prose
    # can't be mistaken for one; `blanked` is used for every pattern EXCEPT the
    # open()-in-heredoc scan below, which deliberately reads heredoc bodies —
    # that's the python3-heredoc escape hatch #92 was filed for.
    def blank_heredoc_bodies(text):
        lines = text.split("\n")
        start_re = re.compile(r"<<-?\s*([\"']?)(\w+)\1")
        i = 0
        while i < len(lines):
            m = start_re.search(lines[i])
            if not m:
                i += 1
                continue
            delim = m.group(2)
            j = i + 1
            while j < len(lines) and lines[j].strip() != delim:
                lines[j] = ""
                j += 1
            i = j + 1
        return "\n".join(lines)

    blanked = blank_heredoc_bodies(cmd)

    # Track a leading `cd <dir>` chain (`cd a && cd b && write relfile`) so a
    # RELATIVE write-target is resolved against the directory the shell would
    # actually be in at that point, not the hook process's own cwd (#143) —
    # e.g. `cd /repo/.worktrees/foo && cat >> notes.md` must resolve notes.md
    # inside the worktree, not wherever this hook happens to run from.
    # Segmenting on &&/||/|/;/newline (order preserved) lets us walk the
    # command left-to-right and update the effective directory as we go.
    # have_base flips false (stop tracking, judge nothing relative from here
    # on — refuse to guess rather than guess wrong) the moment a `cd` target
    # isn't staticaly resolvable (`cd -`, `cd` with no args, a `$VAR`).
    effective = ""
    have_base = False

    def join(base, target):
        if target.startswith("/"):
            return target
        if not have_base:
            return None
        return base.rstrip("/") + "/" + target if base else "/" + target

    segs_ordered = [s for s in re.split(r"(&&|\|\||\||;|\n)", blanked) if s not in ("&&", "||", "|", ";", "\n")]
    per_seg = []  # (base_or_None, segment_text)
    for seg in segs_ordered:
        toks = seg.split()
        if toks and toks[0] == "cd":
            if len(toks) == 2 and not toks[1].startswith("$") and toks[1] != "-":
                resolved = join(effective, toks[1].strip(QUOTES))
                if resolved is not None:
                    effective, have_base = resolved, True
                else:
                    have_base = False
            else:
                have_base = False
            continue
        per_seg.append((effective if have_base else None, seg))

    for base, seg in per_seg:
        # Redirection: `> path` / `>> path`, not `2>&1`, `&>`, `>=`, or a
        # `[ a > b ]` test operator (single `>` inside `[ ... ]` is a string
        # comparison, not a redirect — excluded by requiring the target look
        # like a path, not `]`).
        for m in re.finditer(r"(?<![&\d])>>?\s*([^\s|&;><)]+)", seg):
            tgt = m.group(1).strip(QUOTES)
            if tgt and tgt not in ("/dev/null", "&1", "&2") and not tgt.startswith("&"):
                out.append(f"{base}\t{tgt}" if base else tgt)

        # sed -i / --in-place: grab all non-flag trailing tokens on that
        # pipeline segment as candidate targets (sed accepts multiple files).
        if re.search(r"\bsed\b.*(-i\b|--in-place\b)", seg):
            for tok in seg.split():
                if not tok.startswith("-") and tok != "sed" and "sed" not in tok:
                    tgt = tok.strip(QUOTES)
                    out.append(f"{base}\t{tgt}" if base else tgt)

        # cp/mv/install/tee: last non-flag token is the destination. `tee
        # FILE`'s one argument is both its first and last non-flag token, so
        # this covers the common single-destination form; `tee a b` (writes
        # both) only catches the last, which costs nothing beyond a miss.
        toks = seg.split()
        if toks:
            head = toks[0].rsplit("/", 1)[-1]
            if head in ("cp", "mv", "install", "tee"):
                nonflags = [t for t in toks[1:] if not t.startswith("-")]
                if nonflags:
                    tgt = nonflags[-1].strip(QUOTES)
                    out.append(f"{base}\t{tgt}" if base else tgt)

    # Python `open(path, "w"...)`/`"a"...` embedded in a heredoc — the pattern
    # this rule exists for. Deliberately scans the ORIGINAL (unblanked) command
    # since this is the one pattern meant to be found inside a heredoc body.
    for m in re.finditer(r"open\(\s*[\"']([^\"']+)[\"']\s*,\s*[\"'][wax]", cmd):
        out.append(m.group(1))
else:
    p = ti.get("file_path") or ti.get("notebook_path") or ""
    if p:
        out.append(p)

sys.stdout.write("\n".join(o for o in out if "\n" not in o))
PYEOF
)"

[ -z "$candidates" ] && exit 0

# Need git to reason about worktrees at all.
command -v git >/dev/null 2>&1 || exit 0

# Resolve this script's own repo root ONCE (used by the config-repo exemption
# below, checked per-candidate).
self="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
selfroot=""
[ -n "$self" ] && selfroot="$(git -C "$self" rev-parse --show-toplevel 2>/dev/null)"

# Check one candidate path; echoes a block reason and returns 2 on a hit, 0
# otherwise. Isolated in a function so Bash's multiple candidates can each be
# checked without repeating the Edit/Write single-path logic.
check_one() {
  file_path="$1"

  # Resolve the nearest existing directory at/above the target (the file may
  # not exist yet on a Write). git -C needs a real directory to run in.
  dir="$file_path"
  [ -d "$dir" ] || dir="$(dirname "$dir")"
  while [ ! -d "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
    dir="$(dirname "$dir")"
  done
  [ -d "$dir" ] || return 0

  # Outside any git work tree -> not our concern.
  [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] || return 0

  # Already inside a LINKED worktree? git-dir and git-common-dir diverge there
  # (e.g. .git/worktrees/foo vs .git). Equal => main working tree. Both
  # resolved to absolute paths so the comparison is robust.
  gitdir="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)"
  common_rel="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)"
  case "$common_rel" in
    /*) commondir="$common_rel" ;;
    *)  commondir="$(cd "$dir" 2>/dev/null && cd "$common_rel" 2>/dev/null && pwd)" ;;
  esac
  if [ -n "$gitdir" ] && [ -n "$commondir" ] && [ "$gitdir" != "$commondir" ]; then
    return 0  # in a linked worktree — exactly what we want
  fi

  # Main working tree from here down. Find its root.
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
  [ -z "$root" ] && return 0

  # Exempt the dotclaude config repo itself (see header).
  [ -n "$selfroot" ] && [ "$root" = "$selfroot" ] && return 0

  # Does this repo use the worktree convention (.worktrees/ gitignored)?
  git -C "$root" check-ignore -q ".worktrees/.probe" 2>/dev/null || return 0

  echo "⛔ dotclaude worktree-guard blocked this edit." >&2
  echo "Reason: '$file_path' is in the MAIN working tree of a repo that uses the" >&2
  echo "  .worktrees/ convention. Parallel agents editing the main tree collide —" >&2
  echo "  uncommitted changes leak into every other agent's checkout." >&2
  echo "Fix: work in an isolated worktree, then edit there:" >&2
  echo "    git worktree add .worktrees/<short-name> -b feature/<short-name>" >&2
  echo "    cd .worktrees/<short-name>" >&2
  echo "Policy: ~/dotclaude/CLAUDE.md (Worktree-first). Deliberate main-tree edit?" >&2
  echo "  Re-run with WORKTREE_GUARD_OFF=1 set, or ask the user to run it via ! prefix." >&2
  return 2
}

blocked=0
while IFS=$'\t' read -r a b; do
  [ -z "$a" ] && continue
  # A tracked cd-base arrives as "base<TAB>relative-path"; no base is just
  # "path" (b empty) — read splits on the FIRST tab only via IFS, so a path
  # containing no tab lands entirely in $a.
  if [ -n "$b" ]; then
    path="$a/$b"
  else
    path="$a"
  fi
  if ! check_one "$path"; then
    blocked=1
  fi
done <<<"$candidates"

exit $((blocked ? 2 : 0))
