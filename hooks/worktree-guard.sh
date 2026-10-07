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
#   - Any edit when WORKTREE_GUARD_OFF is set to a non-empty value in the
#     SESSION's environment — the owner's escape hatch for a deliberate
#     main-tree edit or a solo main session, exported before Claude Code starts.
#     It is a blanket opt-out, so it is read only from the hook's own
#     environment, never from an inline `WORKTREE_GUARD_OFF=1 cmd` prefix an
#     agent could type, and every call it lets through says so on stderr: a
#     leaked export in a shell profile must not be silent.
#
# Fail-open by design: unparseable input, no python3, no git, or any ambiguity
# exits 0 and lets the edit through. A guard that bricks every edit is far worse
# than one that occasionally misses — it is a backstop, not the only boundary.
#
# NOT ABOUT THE MAIN TREE (#273): one Bash rule fires wherever it is run —
# creating `node_modules` as a symlink or hardlink tree. Its damage lands in
# the directory it points AT, so the main-tree question does not apply.
#
# BASH COVERAGE (#92): a `Bash` command is scanned for write patterns —
# redirection (`>`, `>>`), `sed -i`/`--in-place`, `cp`/`mv`/`install`/`tee`
# destinations, and a Python `open(path, "w"/"a"/...)` call inside a heredoc
# whose OWN command word is `python`/`python3` (the heredoc-to-python3
# workaround that motivated this). Every candidate path found is checked
# against the same main-tree/worktree logic as Edit/Write. This is
# deliberately best-effort, NOT exhaustive — a write buried in a script it
# invokes, or spelled in a way the regexes below don't recognize, still gets
# through. It closes the common escape hatch (an agent reaching for `python3 -
# <<EOF ... open(path, "w") ... EOF` when Edit/Write was blocked), not every
# possible one.
#
# The `open()` scan is scoped to a python-headed heredoc, not the whole
# command text (#7995): a command that merely QUOTES the pattern —
# `echo 'open("docs/x.py", "w")'`, a printf assembling a script string — never
# invokes python and writes nothing, so scanning the whole command reported a
# false positive on prose. A relative target is resolved against the `cd`
# base tracked for the segment that owns the heredoc, not the hook's own cwd
# or the repo root.
#
# Quoting is read by one lexical pass that understands nested command
# substitution and only treats an UNQUOTED `<<` as a heredoc (#429), and a
# `cd` inside `( … )`/`$( … )` is scoped to that subshell.
#
# KNOWN GAPS (by design — backstop, not a sandbox):
#   - Cannot distinguish a subagent from the main session (no such flag in hook
#     input). Both are guarded; the escape hatch + config-repo exemption cover
#     the legitimate main-session cases.
#   - Bash coverage is pattern-based, not a real shell parse — see above.
#   - A write-target whose LEADING path segment is a shell expansion (`$D/x`,
#     `` `pwd`/x ``) is allowed through unjudged: nothing here knows where it
#     points, and guessing resolves it into whatever tree the session runs in.
#
# UNTRUSTED CWD (#166): a RELATIVE write-target with no tracked `cd` base lands
# wherever the tool's cwd happens to be, and in an agent thread that cwd is not
# the agent's to trust — it resets between Bash calls and has been observed
# pointing into a SIBLING worktree the agent never entered, so the write lands
# silently in another agent's tree. Resolving such a target against the hook's
# own cwd then CLEARS it (a linked worktree is exactly what this guard wants to
# see), which is how the drift bypasses the guard entirely. So when the hook's
# cwd is a linked worktree of a convention repo, a relative target is blocked
# rather than resolved: the agent must spell an absolute path or lead with
# `cd <absolute-path> &&`, which is verifiable. A cwd in a MAIN tree still
# resolves normally — that path blocks anyway, and the message is more useful.
# Claude Code deletes a leading `cd <dir> &&` before any hook runs (and before
# it reaches the transcript) when <dir> is already the session's cwd, so from
# inside the tree a `cd` into that same tree arrives as no `cd` at all and is
# indistinguishable from a drift. The block message therefore steers to an
# absolute write-target, the one spelling that survives (#466, #468).
#
# NOT THE CAUSE OF NetWorthy#223: a Bash command merely referencing a
# credential-shaped env var name (`export DATABASE_URL=$NW_DATABASE_URL`) was
# reported blocked with a "worktree-isolated agent's git operations must
# target its own worktree" message inside a worktree-isolated agent. This
# script has no env-var-name deny-list — it only scans for write-target
# PATTERNS (redirects, sed -i, cp/mv/tee, open(...,"w")), none of which those
# commands contain, and it was confirmed to exit 0 (allow) on all of them
# (see worktree-guard.test.sh). That error string does not appear anywhere in
# this repo; it is compiled into the Claude Code CLI binary itself — a
# separate, built-in worktree-isolation Bash-safety check for agents
# dispatched with `isolation: "worktree"`, outside this repo's source. Tracked
# as a vendor gap, not fixed here.

set -uo pipefail

# Drain stdin first so the producing side never sees a broken pipe, then apply
# the escape hatch: opt out entirely.
input="$(cat)"
if [ -n "${WORKTREE_GUARD_OFF:-}" ]; then
  echo "⚠️  dotclaude worktree-guard: OFF — WORKTREE_GUARD_OFF is exported in this session; nothing was checked." >&2
  exit 0
fi

# Need python3 to parse the tool_input JSON. No parser -> fail open.
command -v python3 >/dev/null 2>&1 || exit 0

# A linked `node_modules` — checked before anything else, because it is the one
# write here whose damage lands somewhere the command never names.
#
# Pointing a throwaway worktree's `node_modules` at a sibling's, to skip a
# multi-minute install, does not share the install: something in the npm/npx
# path resolves through the link, materialises a real directory on the new
# side, and leaves the ORIGINAL holding one entry. The sibling belongs to
# another agent in a swarm, and it is now broken.
#
# What makes it worth a guard rather than a lesson is that the failure is
# misattributed by construction. A missing install surfaces through the bundler
# as source-level errors naming real files and real symbols — six "No matching
# export in packages/engine/src/index.ts" from esbuild, for exports that are
# all present — minutes after tsc, eslint and vitest all passed. It reads as a
# regression from the last edit, so the debugging goes into code that is fine
# (#273).
#
# Scoped to the destination being `node_modules` itself. Linking a single
# package into one, or anything else anywhere, is untouched.
# Its own stderr is kept and its exit status checked, for the same reason the
# main extractor's are: a crashed check that returns nothing is indistinguishable
# from one that found nothing, and the whole rule goes quiet (#319).
link_err="$(mktemp 2>/dev/null || echo /tmp/worktree-guard-link-err.$$)"
link_verdict="$(INPUT_JSON="$input" python3 - <<'PYEOF' 2>"$link_err"
import json, os, re, shlex, sys

try:
    obj = json.loads(os.environ.get("INPUT_JSON", ""))
except Exception:
    sys.exit(0)
if obj.get("tool_name", "") != "Bash":
    sys.exit(0)
cmd = obj.get("tool_input", {}).get("command") or ""

# `ln -s` makes the symlink; `cp -s`/`cp -al` make a tree of them. Each takes
# its destination last, and `ln -s SRC` with no destination lands the link in
# the cwd under the source's basename — which is `node_modules` exactly when
# the source is one.
LINKERS = {"ln", "cp"}

def is_node_modules(tok):
    return tok.strip("\"'").rstrip("/").split("/")[-1] == "node_modules"

for seg in re.split(r"&&|\|\||\||;|\n", cmd):
    try:
        toks = shlex.split(seg)
    except ValueError:
        toks = seg.split()
    if not toks:
        continue
    cmd_tok = toks[0].split("/")[-1]
    if cmd_tok not in LINKERS:
        continue
    flags = [t for t in toks[1:] if t.startswith("-")]
    letters = "".join(f.lstrip("-") for f in flags if not f.startswith("--"))
    symbolic = "s" in letters or "--symbolic" in flags or "--symbolic-link" in flags
    hardlinked = cmd_tok == "cp" and ("l" in letters or "--link" in flags)
    if not (symbolic or hardlinked):
        continue
    operands = [t for t in toks[1:] if not t.startswith("-")]
    if not operands:
        continue
    # The destination, or — for a one-operand `ln -s SRC` — the implied one.
    target = operands[-1] if len(operands) > 1 else operands[0]
    if is_node_modules(target):
        print(seg.strip())
        break
PYEOF
)"
link_status=$?
if [ "$link_status" -ne 0 ]; then
  echo "⛔ dotclaude worktree-guard could not inspect this command, so it is refusing it." >&2
  echo "Reason: the node_modules-link check exited $link_status. That is a bug in the guard," >&2
  echo "  not a verdict on your command (#319)." >&2
  [ -s "$link_err" ] && { echo "Check error:" >&2; sed 's/^/    /' "$link_err" >&2; }
  echo "Fix: repair hooks/worktree-guard.sh. Meanwhile the owner can export WORKTREE_GUARD_OFF=1" >&2
  echo "  before starting the session (an inline prefix is not read)." >&2
  rm -f "$link_err"
  exit 2
fi
rm -f "$link_err"
if [ -n "$link_verdict" ]; then
  echo "⛔ dotclaude worktree-guard blocked this command." >&2
  echo "Reason: it creates \`node_modules\` as a link:" >&2
  echo "    $link_verdict" >&2
  echo "  This does not share one install between two worktrees. npm resolves through" >&2
  echo "  the link, materialises a real directory on THIS side, and empties the one you" >&2
  echo "  pointed at — which in a swarm belongs to another agent. The breakage then" >&2
  echo "  surfaces as bundler errors naming real files and real exports, so the next" >&2
  echo "  hour goes into debugging source that is fine (#273)." >&2
  echo "Instead, either:" >&2
  echo "  - give the throwaway worktree its own real install — slow, but the only" >&2
  echo "    correct option the moment the two trees' lockfiles differ at all; or" >&2
  echo "  - skip the second worktree: commit your work in progress on the branch you" >&2
  echo "    are on (\`git commit\`, undone with \`git reset --soft HEAD~1\`), check out" >&2
  echo "    the baseline in place, and reuse the install that is already correct for" >&2
  echo "    this tree. Not \`git stash\` — \`refs/stash\` is shared across every" >&2
  echo "    worktree of the repo, which is its own version of this bug." >&2
  exit 2
fi
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
# The extractor's stderr is kept, not discarded. An error in it used to be
# indistinguishable from "this command writes nothing": empty output, exit 0,
# every write allowed. A misplaced `import` while fixing #295 silently switched
# the whole guard off and flipped every BLOCK case in the self-test to
# pass-as-allowed — nothing in a real session would have shown it (#319).
guard_err="$(mktemp 2>/dev/null || echo /tmp/worktree-guard-err.$$)"
candidates="$(INPUT_JSON="$input" python3 - <<'PYEOF' 2>"$guard_err"
import json, os, re, shlex, sys

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

    # One lexical pass over the command decides what is DATA and what is shell:
    # quoted runs, heredoc bodies and `# …` comments. Every write-pattern scan
    # below consults it, so they all agree on where a quote begins and ends.
    #
    # It has to understand command substitution. `"$(python3 -c '…{"k":1}…')"`
    # is ONE double-quoted word, but a scanner that pairs each `"` with the next
    # `"` closes it at the `"` inside the JSON and inverts every quote after
    # that — the quoted text of a later argument then reads as bare shell, and
    # its `&&`, `sed`, `|`, `cd` are reported as write-targets (#429). A heredoc
    # start is also only a heredoc when it is itself unquoted: `c="cat <<'EOF'
    # …"` is a string, and its "body" is part of that string.
    #
    # Returns (spans, bodies, heredocs, comments):
    #   spans     (start, end) of each quoted run; `end` is the closing quote.
    #             Nested substitutions record their own inner spans too, which
    #             is harmless for every "is this offset quoted?" test.
    #   bodies    (start, end) of each heredoc body, delimiter line excluded.
    #   heredocs  (op_offset, body_start, body_end) per unquoted `<<DELIM`.
    #   comments  (start, end) of each unquoted `# …` tail.
    # An unterminated quote ends the analysis where it opens rather than
    # swallowing the rest of the text, so a stray apostrophe cannot blind the
    # scan to a real redirect after it.
    HEREDOC_OP = re.compile(
        r"<<(-?)[ \t]*(?:'([^'\n]*)'|\"([^\"\n]*)\"|\\?([A-Za-z0-9_.-]+))"
    )

    class _Unterminated(Exception):
        pass

    def analyse(text):
        n = len(text)
        spans, bodies, heredocs, comments, pending = [], [], [], [], []

        def consume_bodies(i):
            for op_at, delim, dash in pending:
                start = i
                while i < n:
                    e = text.find("\n", i)
                    e = n if e == -1 else e
                    line = text[i:e]
                    if (line.lstrip("\t") if dash else line).strip() == delim:
                        bodies.append((start, i))
                        heredocs.append((op_at, start, i))
                        i = e + 1
                        break
                    i = e + 1
                else:
                    bodies.append((start, n))
                    heredocs.append((op_at, start, n))
            del pending[:]
            return i

        def scan_dq(i):
            """Index of the `"` closing a double-quoted run opened before i."""
            while i < n:
                c = text[i]
                if c == "\\":
                    i += 2
                    continue
                if c == '"':
                    return i
                if c == "$" and text[i + 1 : i + 2] == "(":
                    i = scan(i + 2, ")", arith=text[i + 2 : i + 3] == "(")
                    continue
                if c == "`":
                    i = scan(i + 1, "`")
                    continue
                i += 1
            raise _Unterminated()

        def scan(i, closer=None, arith=False):
            depth = 0
            while i < n:
                c = text[i]
                if c == "\\":
                    i += 2
                    continue
                if closer == "`" and c == "`":
                    return i + 1
                if closer == ")" and c == "(":
                    depth += 1
                elif closer == ")" and c == ")":
                    if depth == 0:
                        return i + 1
                    depth -= 1
                if c == "'":
                    ansi = i > 0 and text[i - 1] == "$"
                    j = i + 1
                    while j < n and text[j] != "'":
                        j += 2 if (ansi and text[j] == "\\") else 1
                    if j >= n:
                        raise _Unterminated()
                    spans.append((i, j))
                    i = j + 1
                    continue
                if c == '"':
                    j = scan_dq(i + 1)
                    spans.append((i, j))
                    i = j + 1
                    continue
                if c == "$" and text[i + 1 : i + 2] == "(":
                    i = scan(i + 2, ")", arith=text[i + 2 : i + 3] == "(")
                    continue
                if c == "`":
                    i = scan(i + 1, "`")
                    continue
                # `#` opens a comment only at the start of a token — start of
                # line or after whitespace. That keeps `s#a#b#` (a sed script),
                # a URL fragment and `${#var}` intact (#289).
                if c == "#" and (i == 0 or text[i - 1] in " \t\n"):
                    e = text.find("\n", i)
                    e = n if e == -1 else e
                    comments.append((i, e))
                    i = e
                    continue
                if c == "<" and not arith and text.startswith("<<", i) and not text.startswith("<<<", i):
                    m = HEREDOC_OP.match(text, i)
                    if m:
                        delim = m.group(2) if m.group(2) is not None else (
                            m.group(3) if m.group(3) is not None else m.group(4)
                        )
                        pending.append((i, delim, m.group(1) == "-"))
                        i = m.end()
                        continue
                if c == "\n":
                    i += 1
                    if pending:
                        i = consume_bodies(i)
                    continue
                i += 1
            return n

        try:
            scan(0)
        except _Unterminated:
            pass
        return spans, bodies, heredocs, comments

    def quoted_spans(text):
        return analyse(text)[0]

    def blank(text, ranges):
        """Blank each range, preserving length and newlines, so every offset
        computed on the original still lines up."""
        chars = list(text)
        for lo, hi in ranges:
            for k in range(lo, hi):
                if chars[k] != "\n":
                    chars[k] = " "
        return "".join(chars)

    # Heredoc bodies are data (#140): a `>` opening a markdown blockquote line
    # is not a redirect. A comment is prose, and prose contains arrows: `# curl
    # -> stdin` yielded `stdin` as a write target (#289). Both are blanked for
    # every pattern EXCEPT the open()-in-heredoc scan below, which deliberately
    # reads python heredoc bodies — the escape hatch #92 was filed for.
    _spans, _bodies, heredocs, _comments = analyse(cmd)
    blanked = blank(cmd, _bodies + _comments)

    # Track a leading `cd <dir>` chain (`cd a && cd b && write relfile`) so a
    # RELATIVE write-target is resolved against the directory the shell would
    # actually be in at that point, not the hook process's own cwd (#143) —
    # e.g. `cd /repo/.worktrees/foo && cat >> notes.md` must resolve notes.md
    # inside the worktree, not wherever this hook happens to run from.
    # Segmenting on &&/||/|/;/newline (order preserved) lets us walk the
    # command left-to-right and update the effective directory as we go.
    # have_base flips false (stop tracking, judge nothing relative from here
    # on — refuse to guess rather than guess wrong) the moment a `cd` target
    # isn't statically resolvable (`cd -`, `cd` with no args, a `$VAR`).
    effective = ""
    have_base = False

    def join(base, target):
        if target.startswith("/"):
            return target
        if not have_base:
            return None
        return base.rstrip("/") + "/" + target if base else "/" + target

    # Split on shell separators, but only where they are NOT inside quotes. A
    # `|`, `;` or `&&` inside a quoted argument is data — a jq filter
    # (`.[]|select(...)`), an awk program, a sed script — and cutting there
    # split a quoted run in half, which broke the quote pairing the redirect
    # scan below depends on and turned a quoted `>` into a phantom redirect.
    # Each part keeps its offset into `text`, so a heredoc operator found by
    # `analyse` can be matched to the segment that owns it.
    def split_unquoted(text):
        spans = quoted_spans(text)
        inside = lambda k: any(lo <= k <= hi for lo, hi in spans)
        parts, buf, start, i, n = [], [], 0, 0, len(text)
        while i < n:
            if not inside(i):
                two = text[i : i + 2]
                if two in ("&&", "||"):
                    parts.append((start, "".join(buf)))
                    buf, i = [], i + 2
                    start = i
                    continue
                if text[i] in ("|", ";", "\n"):
                    parts.append((start, "".join(buf)))
                    buf, i = [], i + 1
                    start = i
                    continue
            buf.append(text[i])
            i += 1
        parts.append((start, "".join(buf)))
        return [(o, p) for o, p in parts if p.strip()]

    # Literal assignments made earlier in the same command (`W=/abs/wt`, then
    # `cd "$W"` on a later line) are as static as a literal `cd /abs/wt`, and
    # a script that names its worktree once and `cd`s into it is the shape the
    # block message itself recommends (#401). Only a value with no expansion
    # in it is recorded; anything else forgets the name, so a `W=$(pwd)`
    # reassignment can never leave a stale literal behind.
    assigned = {}
    assign_re = re.compile(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(\S*)$")

    def note_assignment(seg):
        m = assign_re.match(seg.strip())
        if not m:
            return False
        name, val = m.group(1), m.group(2).strip(QUOTES)
        if val and not any(c in val for c in "$`"):
            assigned[name] = val
        else:
            assigned.pop(name, None)
        return True

    def cd_target(raw):
        """The directory a `cd <raw>` enters, or None when it is not static."""
        t = raw.strip(QUOTES)
        m = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(/.*)?", t)
        if m and m.group(1) in assigned:
            t = assigned[m.group(1)] + (m.group(2) or "")
        if not t or t == "-" or any(c in t for c in "$`"):
            return None
        return t

    def paren_moves(seg):
        """Unquoted `(` and `)` in seg, in order — `$(` counts as a `(`."""
        spans = quoted_spans(seg)
        return [
            (k, ch)
            for k, ch in enumerate(seg)
            if ch in "()" and not any(lo <= k <= hi for lo, hi in spans)
        ]

    # A `cd` inside `( … )` or `$( … )` changes directory for that subshell
    # only. Each unquoted `(` saves the tracked directory and its `)` restores
    # it, so `(cd /wt && make) ; echo x > rel` still judges `rel` against the
    # directory the parent shell is actually in — not the subshell's.
    saved = []
    segs_ordered = split_unquoted(blanked)
    per_seg = []  # (offset, base_or_None, segment_text)
    for off, seg in segs_ordered:
        body = seg.lstrip()
        lead = len(seg) - len(body)
        # Leading group openers: `(` opens a subshell, `{` a group in THIS shell.
        while body[:1] in ("(", "{"):
            if body[0] == "(":
                saved.append((effective, have_base))
            body = body[1:].lstrip()
        consumed = len(seg) - len(body)
        seg_base = effective if have_base else None
        if note_assignment(body):
            pass
        else:
            toks = body.split()
            if toks and toks[0] == "cd":
                # A trailing `)`/`}` closing a group belongs to the group, not
                # to cd's operand: `(cd /wt)` enters /wt.
                args = [t for t in (tok.rstrip(")}") for tok in toks[1:]) if t]
                target = cd_target(args[0]) if len(args) == 1 else None
                resolved = join(effective, target) if target is not None else None
                if resolved is not None:
                    effective, have_base = resolved, True
                else:
                    have_base = False
                    # Not a bare `cd DIR` — it may still carry a write
                    # (`cd /x > /abs/log`), so it is scanned, unjudged-relative.
                    if len(toks) > 2:
                        per_seg.append((off + consumed, None, body))
            else:
                per_seg.append((off + consumed, seg_base, body))
        # Groups opened and closed within the rest of this segment.
        for _, ch in paren_moves(body):
            if ch == "(":
                saved.append((effective, have_base))
            elif saved:
                effective, have_base = saved.pop()

    for _off, base, seg in per_seg:
        # Redirection: `> path` / `>> path`, not `2>&1`, `&>`, `>=`, or a
        # `[ a > b ]` test operator (single `>` inside `[ ... ]` is a string
        # comparison, not a redirect — excluded by requiring the target look
        # like a path, not `]`).
        quoted = quoted_spans(seg)
        # `->`, `=>` and `<>` are arrows and an operator, not redirections.
        # A `-` or `=` before the `>` never begins one, and `<>` is SQL's
        # not-equals (#271, #289, #258). Excluded here as well as by the
        # quoted-span test, because an arrow also turns up unquoted — in a
        # comment, or in `env -u X railway … --stdin`-style prose.
        for m in re.finditer(r"(?<![&\d=\-<])>>?\s*([^\s|&;><)]+)", seg):
            # A `>` INSIDE a quoted argument is data, not an operator: a jq
            # filter (`select(.date > "2026-01-01")`), an awk program, a commit
            # message. The operator itself is never quoted — only its target
            # may be — so testing the `>` position leaves `> "file"` detected.
            if any(lo <= m.start() < hi for lo, hi in quoted):
                continue
            tgt = m.group(1).strip(QUOTES)
            if tgt and tgt not in ("/dev/null", "&1", "&2") and not tgt.startswith("&"):
                out.append(f"{base}\t{tgt}" if base else tgt)

        # sed -i / --in-place: the FILES it edits, which means skipping the
        # script.
        #
        # This used to take every non-flag token on the segment, so `sed -i
        # 's/a/b/' file` reported the script as a write target — and the
        # suggested fix, prefixing it with an absolute directory, was nonsense
        # because the flagged token is a program (#295, #313).
        #
        # It also used to find `sed` with `\bsed\b` anywhere in the segment.
        # A hyphen is a word boundary, so the branch name
        # `issue-295-worktree-guard-blocks-sed-i-by-reading-t` matched, and
        # `git worktree add <dir> <that-branch>` was parsed as a sed
        # invocation whose "files" were `git`, `worktree` and `add`. The guard
        # blocked its own prescribed remedy. `sed` is now looked for as an
        # actual command token.
        # Shell-aware, because a sed script routinely contains spaces:
        # `sed -i "s/module: 'a',/module: 'b',/" file` splits into four
        # whitespace tokens and three of them look like paths (#313). Falls
        # back to a plain split if the segment will not tokenise — a partial
        # read is better than dropping the check entirely.
        try:
            toks_seg = shlex.split(seg)
        except ValueError:
            toks_seg = seg.split()
        sed_at = next(
            (
                i
                for i, t in enumerate(toks_seg)
                if t.strip(QUOTES) == "sed" or t.strip(QUOTES).endswith("/sed")
            ),
            None,
        )
        if sed_at is not None and any(
            t == "-i" or t.startswith("-i") or t == "--in-place" or t.startswith("--in-place=")
            for t in toks_seg[sed_at + 1 :]
        ):
            # Positional parse, the way sed reads its own argv: `-e`/`-f` take
            # the next token, `--expression=`/`--file=` carry theirs, and the
            # first bare token is the script UNLESS a flag already supplied
            # one. Everything after that is a file.
            script_from_flag = False
            expect_flag_arg = False
            script_seen = False
            for tok in toks_seg[sed_at + 1 :]:
                if expect_flag_arg:
                    expect_flag_arg = False
                    continue
                if tok in ("-e", "-f", "--expression", "--file"):
                    script_from_flag = True
                    expect_flag_arg = True
                    continue
                if tok.startswith("--expression=") or tok.startswith("--file="):
                    script_from_flag = True
                    continue
                if tok.startswith("-"):
                    continue
                if not script_seen and not script_from_flag:
                    script_seen = True
                    continue
                tgt = tok.strip(QUOTES)
                out.append(f"{base}\t{tgt}" if base else tgt)

        # cp/mv/install/tee: last non-flag token is the destination. `tee
        # FILE`'s one argument is both its first and last non-flag token, so
        # this covers the common single-destination form; `tee a b` (writes
        # both) only catches the last, which costs nothing beyond a miss.
        # Shell-aware, like the sed parse above: a quoted destination with
        # spaces is one argument, and a whitespace split would read its last
        # word as a relative write target (#510).
        toks = toks_seg
        if toks:
            head = toks[0].rsplit("/", 1)[-1]
            if head in ("cp", "mv", "install", "tee"):
                nonflags = [t for t in toks[1:] if not t.startswith("-")]
                if nonflags:
                    tgt = nonflags[-1].strip(QUOTES)
                    out.append(f"{base}\t{tgt}" if base else tgt)

    # Python `open(path, "w"...)`/`"a"...` embedded in a heredoc — the pattern
    # this rule exists for (#92). Scoped to a heredoc whose OWN command word is
    # `python`/`python3` (#7995): the whole-command scan this replaced matched
    # `open(...)` text anywhere, including inside a quoted `echo`/`printf`
    # argument that writes nothing. Only heredocs `analyse` found UNQUOTED
    # count — `c="python3 - <<'EOF' …"` is a string, not a heredoc (#429).
    # Deliberately reads the ORIGINAL (unblanked) heredoc body — that is the
    # one span this extractor is meant to see inside. A relative target
    # resolves against the directory tracked for the segment that owns the
    # heredoc operator, the same base every other pattern above uses.
    py_cmd_re = re.compile(r"^python3?(\.\d+)?$")

    for op_at, body_start, body_end in heredocs:
        owner = None
        for off, base, seg in per_seg:
            if off <= op_at < off + len(seg):
                owner = (off, base, seg)
        if owner is None:
            continue
        off, base, seg = owner
        head_toks = seg[: op_at - off].split()
        cmd_word = ""
        for t in reversed(head_toks):
            cand = t.rsplit("/", 1)[-1].strip(QUOTES)
            # `python3 - <<EOF` (stdin) and any other bare flag are not the
            # command word — skip past them to the actual program name.
            if cand and cand != "-" and not cand.startswith("-"):
                cmd_word = cand
                break
        if not py_cmd_re.match(cmd_word):
            continue
        body = cmd[body_start:body_end]
        for m in re.finditer(r"open\(\s*[\"']([^\"']+)[\"']\s*,\s*[\"'][wax]", body):
            tgt = m.group(1)
            out.append(f"{base}\t{tgt}" if base else tgt)
else:
    p = ti.get("file_path") or ti.get("notebook_path") or ""
    if p:
        out.append(p)

sys.stdout.write("\n".join(o for o in out if "\n" not in o))
PYEOF
)"
extract_status=$?

# "No interpreter" and "the extractor crashed" are different states, and the
# difference is what makes failing closed safe here.
#
# No python3 at all: the guard cannot run, and blocking every Bash write on the
# machine would be worse than the drift it prevents. Stay open, as before.
#
# python3 present and the script failed: that is a bug in this guard, not a
# clean bill of health for the command. Block, and print what broke — a guard
# that quietly stops guarding is worse than no guard, because the protection is
# assumed.
if [ "$extract_status" -ne 0 ] && command -v python3 >/dev/null 2>&1; then
  echo "⛔ dotclaude worktree-guard could not inspect this command, so it is refusing it." >&2
  echo "Reason: the write-target extractor exited $extract_status. That is a bug in the" >&2
  echo "  guard, not a verdict on your command — but it cannot tell a safe write from an" >&2
  echo "  unsafe one while it is broken, so it fails closed rather than waving everything" >&2
  echo "  through (#319)." >&2
  if [ -s "$guard_err" ]; then
    echo "Extractor error:" >&2
    sed 's/^/    /' "$guard_err" >&2
  fi
  echo "Fix: repair hooks/worktree-guard.sh. Meanwhile the owner can export" >&2
  echo "  WORKTREE_GUARD_OFF=1 before starting the session (an inline prefix is not" >&2
  echo "  read) — and please file the error above, because every session on this" >&2
  echo "  machine is hitting it." >&2
  rm -f "$guard_err"
  exit 2
fi
rm -f "$guard_err"

[ -z "$candidates" ] && exit 0

# Need git to reason about worktrees at all.
command -v git >/dev/null 2>&1 || exit 0

# Resolve this script's own repo root ONCE (used by the config-repo exemption
# below, checked per-candidate).
self="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
selfroot=""
[ -n "$self" ] && selfroot="$(git -C "$self" rev-parse --show-toplevel 2>/dev/null)"

# Is the hook's own cwd a linked worktree of a repo using the convention? If so
# it is an untrustworthy base for a relative write-target (see UNTRUSTED CWD in
# the header). Computed once; consulted per-candidate.
cwd_untrusted=0
if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
  cwd_gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)"
  cwd_common_rel="$(git rev-parse --git-common-dir 2>/dev/null)"
  cwd_common=""
  case "${cwd_common_rel:-}" in
    "") ;;
    /*) cwd_common="$cwd_common_rel" ;;
    *)  cwd_common="$(cd "$cwd_common_rel" 2>/dev/null && pwd)" ;;
  esac
  if [ -n "$cwd_gitdir" ] && [ -n "$cwd_common" ] && [ "$cwd_gitdir" != "$cwd_common" ]; then
    # The main working tree owning this linked worktree — the config-repo
    # exemption is about the repo, not about which of its trees you stand in.
    cwd_mainroot="$(dirname "$cwd_common")"
    if [ "$cwd_mainroot" != "$selfroot" ] && git check-ignore -q ".worktrees/.probe" 2>/dev/null; then
      cwd_untrusted=1
    fi
  fi
fi

# Check one candidate path; echoes a block reason and returns 2 on a hit, 0
# otherwise. Isolated in a function so Bash's multiple candidates can each be
# checked without repeating the Edit/Write single-path logic.
check_one() {
  file_path="$1"

  # A candidate the shell would expand before writing — `$VAR/x`, `` `cmd`/x ``
  # — is unresolvable here, and only its LEADING segment decides which tree it
  # lands in. Climbing a relative path like `$D/railway.json` bottoms out at the
  # hook's own cwd, which silently reinterprets a target anywhere on disk as a
  # main-tree write (MuscleBuddy#3962: writes to a /tmp scratchpad blocked).
  # Refuse to guess, exactly as the `cd` tracker above does. A `$` further along
  # an otherwise-resolvable path still climbs to a real ancestor, so it stays.
  case "$file_path" in
    /*) ;;
    "~"/*) file_path="$HOME/${file_path#"~"/}" ;;
    *)
      case "${file_path%%/*}" in
        *'$'* | *'`'*) return 0 ;;
      esac
      if [ "$cwd_untrusted" = 1 ]; then
        echo "⛔ dotclaude worktree-guard blocked this write." >&2
        # A `cd` the guard could not resolve — `cd $VAR`, `cd -`, `cd` bare —
        # is a different situation from no `cd` at all, and the generic advice
        # is unfollowable there: "use an absolute path" cannot be done when the
        # directory legitimately comes from a variable, so the operator is told
        # to do something impossible and reads the guard as broken (#320).
        #
        # It still BLOCKS. The destination is unknowable, and unknowable is the
        # risk — `$VAR` can expand into a sibling agent's worktree. What changes
        # is that the message says which of the two it is and what would
        # actually clear it.
        # Matched against the raw payload, so the anchor allows any non-word
        # character before `cd` — the command sits inside JSON, where it is
        # preceded by a quote rather than by start-of-line.
        if printf '%s' "$input" | grep -qE '(^|[^a-zA-Z0-9_/.-])cd +((\\?")?\$|`|-([ "\\]|$))'; then
          echo "Reason: '$file_path' is relative, and the \`cd\` before it is one this guard" >&2
          echo "  cannot resolve — a variable, \`cd -\`, or a bare \`cd\`. So the directory" >&2
          echo "  this write lands in is not knowable from the command text, and unknowable" >&2
          echo "  is the risk: a variable can expand into a SIBLING agent's worktree." >&2
          echo "Fix: expand it yourself, so the tree is named in the command:" >&2
          echo "    cd \"\$THE_VAR\" && …    ->    cd /abs/path/to/your/worktree && …" >&2
          echo "  or give the write an absolute target and drop the cd entirely." >&2
        else
          echo "Reason: '$file_path' is relative, so it lands in whatever directory this" >&2
          echo "  tool call happens to be in — and that cwd is a linked worktree this" >&2
          echo "  command never entered. An agent's Bash cwd resets between calls and can" >&2
          echo "  point into a SIBLING agent's worktree, so a relative write is not" >&2
          echo "  attributable to any tree (see #166)." >&2
          echo "Fix: give the write an absolute target:" >&2
          echo "    echo x > $(pwd -P)/$file_path" >&2
          echo "  If you DID lead with \`cd $(pwd -P) &&\`, Claude Code deleted it before" >&2
          echo "  this hook ran, because it names the cwd the session is already in —" >&2
          echo "  so the \`cd\` form cannot work from inside the tree. Use the absolute" >&2
          echo "  target (or the Edit/Write tool with an absolute path)." >&2
        fi
        echo "Policy: ~/dotclaude/CLAUDE.md (Worktree-first). Deliberate?" >&2
        echo "  Ask the user to run it via the ! prefix. (WORKTREE_GUARD_OFF=1 is a session-wide" >&2
        echo "  opt-out the owner exports before starting Claude Code; an inline prefix is not read.)" >&2
        return 2
      fi
      ;;
  esac

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
  echo "  Ask the user to run it via the ! prefix. (WORKTREE_GUARD_OFF=1 is a session-wide" >&2
  echo "  opt-out the owner exports before starting Claude Code; an inline prefix is not read.)" >&2
  return 2
}

blocked=0
while IFS=$'\t' read -r a b; do
  [ -z "$a" ] && continue
  # A tracked cd-base arrives as "base<TAB>relative-path"; no base is just
  # "path" (b empty) — read splits on the FIRST tab only via IFS, so a path
  # containing no tab lands entirely in $a.
  #
  # An ABSOLUTE target ignores the base. `cd /repo && cat > /tmp/x` writes to
  # /tmp, and joining produced `/repo//tmp/x`, which climbed to /repo and
  # blocked a legitimate scratchpad write from a main-tree cwd (#267).
  if [ -n "$b" ]; then
    case "$b" in
      /*) path="$b" ;;
      *)  path="$a/$b" ;;
    esac
  else
    path="$a"
  fi
  if ! check_one "$path"; then
    blocked=1
  fi
done <<<"$candidates"

exit $((blocked ? 2 : 0))
