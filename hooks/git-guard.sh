#!/usr/bin/env bash
# dotclaude git-guard — PreToolUse hook for the Bash tool (and, through
# mcp-tool-adapter.sh, Serena's execute_shell_command).
#
# Turns the non-negotiable git rules in ~/dotclaude/CLAUDE.md from prose that
# Claude follows probabilistically into hard, deterministic blocks. Wired in
# settings.json under hooks.PreToolUse (matcher "Bash"). On a policy hit it
# exits 2, which blocks the command and feeds stderr back to Claude.
#
# This matters most because settings.json runs defaultMode "bypassPermissions":
# without a hook there is no other gate between Claude and the shell.
#
# Fail-open by design: if the input can't be parsed (no python3, malformed
# JSON), we exit 0 and let the command through. A guard that bricks every Bash
# call is far worse than one that occasionally misses — it is a backstop, not
# the only safety boundary (project-level gitleaks/pre-commit still apply).
#
# KNOWN GAPS (by design — this is a backstop, not a sandbox; don't expand into a
# regex arms race):
#   - Env-var hook bypasses: `HUSKY=0 git commit`, or core.hooksPath set via
#     GIT_CONFIG_* env vars rather than `-c`. Same class as --no-verify.
#   - `git add -A` / `git add .` that sweeps an unmentioned .env — left to
#     project gitleaks/pre-commit.
#   - Other non-git footguns (curl | sh, writes outside the repo) — out of
#     scope; bypassPermissions does not gate those either. (Reckless `rm -rf` of
#     root/home/system/parent paths IS blocked below — the one non-git rule.)
#   - `rm -rf *` / `rm -rf .` whose danger depends on the current directory
#     (e.g. `cd / && rm -rf *`) — we can't know CWD, so a bare glob/dot is not
#     blocked. Only explicit dangerous path arguments are.
#
# NARROW ESCAPE (#185): GIT_GUARD_HOOK_PROVEN_KILLED=1 lifts ONLY the
# --no-verify/-n block (not force-push or .env), for the one case where "fix
# the hook" has no meaning — the hook process was OOM-killed by unrelated
# swarm contention and never evaluated the diff at all. Deliberately a
# different, narrower variable than a blanket --no-verify escape hatch; the
# bypass is always logged loudly to stderr even though the command is
# allowed through, so it's never silent.

set -uo pipefail

input="$(cat)"

# Extract tool_input.command. jq is NOT guaranteed on every machine, so parse
# with python3 (ubiquitous on Linux/macOS). No parser -> fail open.
command -v python3 >/dev/null 2>&1 || { echo "⚠️  dotclaude git-guard: DISABLED — python3 is not installed, so nothing was checked (bin/doctor.sh lists the prerequisites)." >&2; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "⚠️  dotclaude git-guard: DISABLED — perl is not installed, so nothing was checked (bin/doctor.sh lists the prerequisites)." >&2; exit 0; }
cmd="$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    sys.stdout.write(json.load(sys.stdin).get("tool_input", {}).get("command", "") or "")
except Exception:
    pass' 2>/dev/null)"
parse_rc=$?

# A parser that DIED on a real payload is not "no command". python3 is
# OOM-killed or SIGBUSed routinely under swarm memory pressure, and treating
# its empty output as an empty command let every rule below go unchecked, so
# --no-verify, a force-push to main and a .env commit all passed (#524). The
# parser itself swallows malformed JSON and exits 0, so a non-zero exit here
# means the process was killed: fail closed, and the agent retries.
if [ "$parse_rc" -ne 0 ] && [ -n "$input" ]; then
  echo "⛔ dotclaude git-guard could not read this command: its parser exited $parse_rc (killed under memory pressure?), so nothing was checked." >&2
  echo "Retry the same command; it is blocked only because it could not be judged (#524)." >&2
  exit 2
fi

[ -z "$cmd" ] && exit 0

block() {
  echo "⛔ dotclaude git-guard blocked this command." >&2
  echo "Reason: $1" >&2
  echo "Policy: ~/dotclaude/CLAUDE.md. False positive? Run it yourself with the ! prefix, or edit hooks/git-guard.sh." >&2
  exit 2
}

# Strip message bodies before matching so a commit MESSAGE that merely mentions
# --no-verify / .env / main can't trip the guards. Flags and paths that actually
# matter live outside them.
#
# Two carriers, both scrubbed:
#   - quoted spans ('...' and "..."), which carry a `-m` message;
#   - heredoc bodies (`git commit -F - <<'EOF' … EOF`), which carry a long one.
# The heredoc case was missing, so a message that named `.env.production` — the
# very thing rule 3 exists to describe — blocked its own fix. Both are message
# text by construction: nothing that decides what a git command DOES can live
# inside a heredoc body.
#
# A quoted span is scrubbed across newlines: a multi-line `-m` message is one span,
# and a line-oriented scrub left its opening line unmatched, so the `-n` / `--no-verify`
# after the closing quote sat on a line the commit-args scan below never reached (#436).
#
# (Trade-off, unchanged: a deliberately quoted branch name could slip a
# force-push past — acceptable for a backstop, since quoted branch names are
# rare while quoted messages are universal.)
# The terminator line's own \s*\2\s* tolerates leading/trailing whitespace so
# a `<<-'EOF'` heredoc (which strips leading TABS from the body AND allows an
# indented terminator — routine inside a `$(cat <<-'EOF' ... EOF)` nested in a
# `git commit -m "$(...)"`) still gets fully consumed. Without it, an indented
# closing line doesn't match a bare `^\2$`, the heredoc body — including any
# `.env.local` mentioned in prose — survives the scrub, and rule 3 blocks the
# commit on its own message text (#363).
scrubbed="$(printf '%s' "$cmd" | perl -0777 -pe "s/<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1.*?^[ \t]*\2[ \t]*\$/ /gms" \
  | perl -0777 -pe "s/'[^']*'/ /gs; s/\"[^\"]*\"/ /gs")" \
  || scrubbed="$cmd"  # a scrub killed under memory pressure leaves "": judge the raw command, never nothing

# escape <NAME> <segment-regex>: is the narrow escape NAME in force for the
# command segments that need it? Either the session exported it (the hook runs
# in the session's environment), or every segment of $scrubbed matching
# <segment-regex> carries `NAME=1` as an env prefix of its own git invocation
# (`NAME=1 git …`, after any `cd … &&`). The inline form is the one an agent can
# actually set: the hook process never sees a variable the command assigns, so
# advice to "set it for this one command" was unreachable without it (#477,
# #514). Scoped per segment, so the prefix on one git call lifts nothing for
# another, and matched on $scrubbed, so a message or echo naming the variable
# lifts nothing at all.
escape() {
  [ -n "$(printenv "$1" 2>/dev/null)" ] && return 0
  printf '%s' "$scrubbed" | ESC_NAME="$1" ESC_RE="$2" perl -0777 -ne '
    my ($n, $re) = ($ENV{ESC_NAME}, $ENV{ESC_RE});
    my ($need, $have) = (0, 0);
    for my $seg (split /(?:;|&&|\|\||\||\n)/) {
      next unless $seg =~ /$re/;
      $need++;
      $have++ if $seg =~ /^\s*(?:\(\s*)?(?:env\s+)?(?:[A-Za-z_]\w*=\S*\s+)*\Q$n\E=1\s+(?:[A-Za-z_]\w*=\S*\s+)*git\s/;
    }
    exit(($need && $need == $have) ? 0 : 1);'
}

# 0) Reckless recursive delete of a root / home / system / parent path. The one
# non-git rule, so it runs before the git-only gate below. Matched against a
# quote-STRIPPED copy of the raw command (quotes removed, content kept) — not
# the message-scrubbed string — so a quoted argument like `rm -rf "$HOME"` is
# still caught. Requires a recursive flag (-r/-R/-rf/... in any order, or
# --recursive) AND a dangerous path argument. Allowed by design: relative paths
# (node_modules, dist, .worktrees/x), /tmp/..., deeper project paths.
# Trade-off: a commit MESSAGE that literally contains `rm -rf /` could trip this
# (quote chars are stripped, not the whole span) — rare, and recoverable with
# the ! prefix; blocking an accidental home/root wipe is worth that.
nq="$(printf '%s' "$cmd" | tr -d "\"'")"
if printf '%s' "$nq" | grep -Eq '(^|[^[:alnum:]_./-])rm[[:space:]]+((-[a-zA-Z]+|--[a-z-]+|--)[[:space:]]+)*(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)([[:space:]]+(-[a-zA-Z]+|--[a-z-]+|--))*[[:space:]]+(/([[:space:]]|$|\*)|/(home|root|usr|etc|var|bin|sbin|lib|lib64|opt|boot|sys|proc|dev|Users)([[:space:]/]|$)|~([[:space:]/*]|$)|\$\{?HOME\}?([[:space:]/*]|$)|\.\.([[:space:]/]|$))'; then
  block "recursive delete targeting a root / home / system / parent path. Delete specific project subpaths (relative, or under /tmp) explicitly instead."
fi

# Only inspect git invocations beyond this point. Gated on the quote-STRIPPED
# copy, not the message-scrubbed one: `bash -c "git checkout -- f"` and
# `eval "git checkout -- f"` carry the whole invocation inside quotes, and
# rules 1-4 still match only against $scrubbed.
printf '%s' "$nq" | grep -Eq '(^|[^[:alnum:]_./-])git([[:space:]]|$)' || exit 0

# 1) Never bypass git hooks: --no-verify, commit -n, or -c core.hooksPath=...
#
# NARROW ESCAPE (#185): the failing signal can be the hook process getting
# OOM-killed by unrelated swarm contention, not a real problem with the diff —
# "fix the hook" has no meaning when the hook never evaluated the diff at all.
# GIT_GUARD_HOOK_PROVEN_KILLED=1 lifts ONLY this specific block (not the
# force-push or .env rules below), and only after the caller has actually
# confirmed the kill — via the hook's own "Killed" / exit 137 output, or
# `dmesg | grep -i "killed process"` naming the hook's process. It is
# deliberately a different, narrower variable than a blanket --no-verify
# escape hatch, and the bypass is always logged loudly to stderr so it is
# never silent even though the command itself is allowed through.
if printf '%s' "$scrubbed" | grep -Eq -- '--no-verify'; then
  if escape GIT_GUARD_HOOK_PROVEN_KILLED '--no-verify'; then
    echo "⚠️  dotclaude git-guard: allowing git --no-verify — GIT_GUARD_HOOK_PROVEN_KILLED is set." >&2
    echo "   This bypasses commit hooks. Only legitimate when the hook was proven OOM-killed" >&2
    echo "   (exit 137 / dmesg 'Killed process'), not when it found a real problem." >&2
  else
    block "git --no-verify is forbidden. Fix the failing hook (gitleaks/lint/typecheck) and commit normally — then make a NEW commit. If the push's slow pre-push hook is what keeps dropping the connection (exit 141, ref unmoved), use ~/dotclaude/bin/git-push.sh: it runs the hook first, then pushes with the connection open only for the transfer, and verifies the ref landed. If the hook was OOM-killed by unrelated swarm contention (exit 137, or 'dmesg | grep -i \"killed process\"' names it) rather than finding a real problem, prefix that one git command with GIT_GUARD_HOOK_PROVEN_KILLED=1 (\`GIT_GUARD_HOOK_PROVEN_KILLED=1 git …\`, after any \`cd … &&\`)."
  fi
fi
if printf '%s' "$scrubbed" | grep -Eiq -- '-c[[:space:]=]*core\.hookspath'; then
  block "git -c core.hooksPath=... disables hooks (same effect as --no-verify). Forbidden — fix the hook and retry."
fi
# (push -n is --dry-run, harmless — only commit's -n means --no-verify.)
# Scan only `git commit`'s OWN arguments, up to the next command separator: a
# `-n` anywhere else in a compound command (`grep -n … && git commit …`) is not
# this flag, and blocking on it makes the guard something to work around.
commit_args="$(printf '%s' "$scrubbed" \
  | perl -0777 -ne 'while (/git\s+commit((?:(?!\s*(?:;|&&|\|\||\||\n)).)*)/gs) { print "$1\n" }')"
if [ -n "$commit_args" ] \
   && printf '%s' "$commit_args" | grep -Eq '(^|[[:space:]])-[a-zA-Z]*n[a-zA-Z]*([[:space:]]|$)'; then
  if escape GIT_GUARD_HOOK_PROVEN_KILLED 'git\s+commit\b.*\s-[a-zA-Z]*n[a-zA-Z]*(\s|$)'; then
    echo "⚠️  dotclaude git-guard: allowing git commit -n — GIT_GUARD_HOOK_PROVEN_KILLED is set." >&2
    echo "   This bypasses commit hooks. Only legitimate when the hook was proven OOM-killed" >&2
    echo "   (exit 137 / dmesg 'Killed process'), not when it found a real problem." >&2
  else
    block "git commit -n bypasses hooks (short for --no-verify). Forbidden — fix the hook and retry. If the hook was OOM-killed by unrelated swarm contention (exit 137, or 'dmesg | grep -i \"killed process\"' names it) rather than finding a real problem, prefix that one git command with GIT_GUARD_HOOK_PROVEN_KILLED=1 (\`GIT_GUARD_HOOK_PROVEN_KILLED=1 git …\`, after any \`cd … &&\`)."
  fi
fi

# 2) Force-push to main/master is the user's call, never Claude's. Covers
# --force / -f / --force-with-lease AND the leading-'+' refspec force form, and
# matches main/master written bare, as origin main, refs/heads/main, or :main.
#
# Scoped to `git push`'s OWN arguments for the same reason `git commit -n` is:
# `-f` is a force flag only here. `gh api … -f ref=refs/heads/dev` in the same
# compound command passes a FIELD, and blocking on it makes the guard something
# to work around rather than something to satisfy.
push_args="$(printf '%s' "$scrubbed" \
  | perl -0777 -ne 'while (/git\s+(?:-[^\s]+\s+)*push((?:(?!\s*(?:;|&&|\|\||\||\n)).)*)/gs) { print "$1\n" }')"
if [ -n "$push_args" ]; then
  has_force=0
  printf '%s' "$push_args" | grep -Eq -- '(--force([[:space:]=]|$)|--force-with-lease|[[:space:]]-f([[:space:]]|$))' && has_force=1
  printf '%s' "$push_args" | grep -Eq '[[:space:]]\+[^[:space:]]*(main|master)' && has_force=1
  if [ "$has_force" = 1 ] \
     && printf '%s' "$push_args" | grep -Eq '([[:space:]:/+]|origin[[:space:]]+)(main|master)([[:space:]:]|$)'; then
    block "force-pushing to main/master is reserved for the user (CLAUDE.md). Push a feature branch, or ask first."
  fi
fi

# 3) Never stage/commit a real .env file (.env.example is fine). Catches
# explicit .env references; blanket 'git add -A' that sweeps a .env is left to
# project-level gitleaks/pre-commit, which this does not replace.
if printf '%s' "$scrubbed" | grep -Eq 'git[[:space:]]+(add|commit|stage|rm)([[:space:]]|$)'; then
  if printf '%s' "$scrubbed" | grep -Eq '(^|[[:space:]/=])\.env([[:space:]]|$)' \
     || printf '%s' "$scrubbed" | grep -Eq '\.env\.(local|production|prod|development|dev|staging)'; then
    block ".env files must never be committed — only .env.example is tracked (CLAUDE.md). Use 'vercel env pull' for local values."
  fi
fi

# 4) `git stash` in a repo that has sibling worktrees. `refs/stash` lives in the
# common `.git` and is a single repo-wide STACK: a linked worktree isolates the
# working tree and the index, never the ref namespace. So concurrent agents push
# onto and pop from one stack, and `stash@{0}` is whoever pushed last.
#
# Two agents interleaving push/pop is not hypothetical — one popped the other's
# entry, a worktree received a foreign change, and the original fix left
# `refs/stash` for ~248 dangling commits. Neither agent saw an error, because
# nothing about it is an error to git (#297, #275).
#
# Blocked only where the hazard exists: a repo with more than one worktree. A
# solo checkout stashes freely. `list`/`show` are reads and stay allowed.
# Anchored to a COMMAND position — start of the string or just after a
# separator — so `echo git stash is repo-wide >> notes.md` is prose, not an
# invocation. Reading a command out of running text is how a guard becomes
# something to work around.
if printf '%s' "$scrubbed" | grep -Eq '(^|[;&|]|^[[:space:]]*)[[:space:]]*git([[:space:]]+-[^[:space:]]+)*[[:space:]]+stash([[:space:]]|$)'; then
  stash_verb="$(printf '%s' "$scrubbed" \
    | perl -0777 -ne 'if (/git(?:\s+-\S+)*\s+stash\s*([a-z-]*)/) { print $1 }')"
  case "$stash_verb" in
    list | show) ;;
    *)
      if [ "$(git worktree list 2>/dev/null | wc -l)" -gt 1 ]; then
        block "git stash shares one repo-wide \`refs/stash\` with every worktree of this repo, so a concurrent agent can pop your entry (or you theirs) with no error — that has already cost real work. Commit to your branch instead: a WIP commit is per-branch, visible, and \`git reset --soft HEAD~1\` undoes it. If you genuinely need a stash, name it and pop it by message rather than by index: \`git stash push -m ISSUE\` then \`git stash pop stash@{/ISSUE}\`."
      fi
      ;;
  esac
fi

# 5) A path-scoped discard (`git checkout -- <path>`, `git checkout <path>`,
# `git checkout HEAD -- <path>`, `git restore <path>`) silently overwrites the
# WORKING TREE from the index/HEAD, taking any uncommitted change to that path
# with it — no warning, no diff, exit 0. The standing instruction to verify a
# guard by deliberately breaking something routes agents straight at this:
# "undo the break" reads as `git checkout -- <file>`, which can erase UNRELATED
# uncommitted work in the same file along with the deliberate one.
#
# What is judged, and how:
#   - The tree it acts on: `git -C <dir>` wins, then a leading `cd <dir>`, then
#     the session cwd. The status check has to read the tree the discard lands
#     in, or `git -C <other> checkout -- f` is judged against a clean checkout.
#   - The `--`-less forms agents actually type (`git checkout f.txt`,
#     `git checkout .`): git treats the first argument as a path whenever it does
#     not resolve to a commit, so git is ASKED, not pattern-matched.
#   - A leading ref that resolves to the commit already checked out (`HEAD`,
#     `@`, `HEAD~0`) resets index AND worktree, so a staged-only change is at
#     risk too. Any other ref fetches a different version — the sanctioned way
#     to restore a real historical defect — and is never blocked.
#   - A bare checkout / `git restore <path>` restores from the INDEX, so only an
#     unstaged change is at risk; untracked files never are.
#   - A path held in a loop variable (`for f in a b; do git checkout -- $f`) is
#     expanded from the loop's word list; any other expansion is judged as the
#     whole tree, the widest thing it could discard.
#   - A forced switch (`checkout -f`, `switch --force`/`--discard-changes`,
#     `-fb`/`-fc`) discards every tracked change in the tree, index included.
#   - Every line and every command position counts: a `# comment` line, a
#     backslash continuation, a subshell, a `case` arm, and the wrappers that run
#     their argument as a command (`env`, `nohup`, `timeout`, `time`, `!`,
#     `eval`, `command`, `bash -c`, `xargs` — whose paths come from stdin, so the
#     whole tree is judged).
#
# Allowed: a path with nothing at risk, `restore --staged` (unstages only),
# `restore --source=<ref>`, branch switches (git refuses a lossy one itself),
# `-b/-B/--orphan/-p`. NARROW ESCAPE: GIT_GUARD_ALLOW_DISCARD=1, in the
# environment or as a prefix on the command, lifts ONLY this block, loudly.
discard_report="$(GG_CMD="$nq" GG_INPUT="$input" python3 - <<'PY' 2>/dev/null
import json, os, re, shlex, subprocess

cmd = os.environ.get("GG_CMD", "")
try:
    base = json.loads(os.environ.get("GG_INPUT", "{}")).get("cwd") or os.getcwd()
except Exception:
    base = os.getcwd()

def git(d, *args):
    try:
        r = subprocess.run(["git", "-C", d, *args], capture_output=True, text=True, timeout=10)
        return r.returncode, r.stdout
    except Exception:
        return 1, ""

def resolve_dir(cur, d):
    d = os.path.expanduser(d)
    return os.path.normpath(d if os.path.isabs(d) else os.path.join(cur, d))

# Loop word lists, for `$f`-style paths.
loops = {}
for m in re.finditer(r"(?:^|[;&|({\s])for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+([^;&|)]*)", cmd):
    loops.setdefault(m.group(1), m.group(2).split())

# Every line is judged, not the first: a backslash continuation is one line,
# a whole-line `# comment` is nothing, and a newline is the `;` it means to the
# shell. A subshell's `(`/`)` and a `case` arm's closing `)` are command
# boundaries too, so `(git checkout -- f)` and `case x in x) git restore f;;
# esac` put `git` at a command position. `$(` is left alone: its contents are an
# argument of the command around it.
flat = re.sub(r"\\\n", " ", cmd)
flat = re.sub(r"(?m)^[ \t]*#[^\n]*$", "", flat)
segments = re.split(r"\s*(?:&&|\|\||;;|;|\||\n|(?<!\$)\(|\))\s*", flat)

KEYWORDS = ("do", "then", "else", "elif", "if", "while", "until", "(", "{", "!", "eval", "nohup", "exec")

def unwrap(toks):
    """Strip the words that run the next word as a command — keywords,
    assignments, and the wrappers `env`, `time`, `timeout`, `nice`, `command`,
    `builtin`, `xargs`, `sh -c` — so the command they wrap is what gets judged.
    Returns (toks, reads_stdin): an `xargs` wrapper takes its arguments from
    stdin, which names no path this hook can see."""
    reads_stdin = False
    while toks:
        t = toks[0]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t) or t in KEYWORDS:
            toks = toks[1:]; continue
        if t in ("time", "builtin"):
            toks = toks[1:]
            while toks and toks[0] in ("-p", "--"):
                toks = toks[1:]
            continue
        if t == "command":
            if len(toks) > 1 and toks[1] in ("-v", "-V"):
                return [], False  # a lookup, not an invocation
            toks = toks[1:]
            while toks and toks[0] in ("-p", "--"):
                toks = toks[1:]
            continue
        if t == "env":
            toks = toks[1:]
            while toks and (toks[0].startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0])):
                if toks[0] in ("-u", "--unset", "-C", "--chdir", "-S", "--split-string") and len(toks) > 1:
                    toks = toks[2:]
                else:
                    toks = toks[1:]
            continue
        if t in ("nice", "sudo"):
            toks = toks[1:]
            while toks and toks[0].startswith("-"):
                toks = toks[2:] if toks[0] in ("-n", "-u", "-g") and len(toks) > 1 else toks[1:]
            continue
        if t == "timeout":
            toks = toks[1:]
            while toks and toks[0].startswith("-"):
                toks = toks[2:] if toks[0] in ("-s", "-k") and len(toks) > 1 else toks[1:]
            toks = toks[1:]  # the duration
            continue
        if t == "xargs":
            reads_stdin = True
            toks = toks[1:]
            while toks and toks[0].startswith("-"):
                toks = toks[2:] if toks[0] in ("-I", "-n", "-L", "-P", "-d", "-E", "-s", "-a") and len(toks) > 1 else toks[1:]
            continue
        if t.split("/")[-1] in ("bash", "sh", "zsh", "dash", "ksh"):
            rest, found = toks[1:], False
            while rest and rest[0].startswith("-"):
                f = rest.pop(0)
                if not f.startswith("--") and "c" in f[1:]:
                    found = True
                    break
            if not found:
                return toks, reads_stdin  # runs a script: not a command this hook reads
            toks = rest
            continue
        break
    return toks, reads_stdin

cur = base
reports = []
for seg in segments:
    try:
        toks = shlex.split(seg, posix=True)
    except ValueError:
        toks = seg.split()
    toks, reads_stdin = unwrap(toks)
    if not toks:
        continue
    if toks[0] in ("cd", "pushd") and len(toks) > 1 and "$" not in toks[1]:
        cur = resolve_dir(cur, toks[1])
        continue
    if toks[0] != "git":
        continue
    i, tree = 1, cur
    while i < len(toks) and toks[i].startswith("-"):
        if toks[i] == "-C" and i + 1 < len(toks):
            tree = resolve_dir(tree, toks[i + 1]); i += 2; continue
        if toks[i] in ("-c", "--git-dir", "--work-tree", "--namespace") and i + 1 < len(toks):
            i += 2; continue
        i += 1
    if i >= len(toks) or toks[i] not in ("checkout", "restore", "switch"):
        continue
    sub, args = toks[i], toks[i + 1:]
    if not os.path.isdir(tree):
        continue
    flags = [a for a in args if a.startswith("-")]
    # A FORCED switch (`checkout -f`/`--force`, `switch -f`/`--force`/
    # `--discard-changes`, and a short cluster carrying `f` such as `-fb`/`-fc`)
    # throws away every tracked change in the tree — index and worktree — before
    # it moves, which is exactly the refusal git makes for the unforced form.
    forced = False
    if sub in ("checkout", "switch"):
        for a in args:
            if a == "--":
                break
            if a in ("--force", "--discard-changes") or (re.match(r"^-[A-Za-z]+$", a) and "f" in a[1:]):
                forced = True
    resets_index = False
    if forced:
        paths, resets_index = ["."], True
    elif sub == "switch":
        continue  # an unforced switch: git refuses a lossy one itself
    elif sub == "checkout" and any(f in ("-b", "-B", "-t", "--track", "--orphan", "--detach", "-p", "--patch") for f in flags):
        continue
    elif sub == "restore":
        if any(f.startswith("--source") or f == "-s" or f.startswith("-s=") for f in flags):
            continue
        staged = any(f in ("--staged", "-S") for f in flags)
        worktree = any(f in ("--worktree", "-W") for f in flags)
        if staged and not worktree:
            continue
        resets_index = staged and worktree
        paths = [a for a in args if not a.startswith("-")]
    else:
        # With `--`, whatever precedes it is a tree-ish by definition (an
        # unresolvable one makes git error out, discarding nothing). Without
        # it, the first argument is a ref only if git resolves it as one.
        paths, ref = [], None
        has_dd = "--" in args
        seen_dd = False
        for a in args:
            if a == "--":
                seen_dd = True; continue
            if a.startswith("-"):
                continue
            if ref is None and not paths and not seen_dd and (
                has_dd or git(tree, "rev-parse", "--verify", "--quiet", a + "^{commit}")[0] == 0
            ):
                ref = a; continue
            paths.append(a)
        if ref is not None:
            if not paths and not reads_stdin:
                continue  # a branch switch
            rc_ref, ref_sha = git(tree, "rev-parse", "--verify", "--quiet", ref + "^{commit}")
            _, head_sha = git(tree, "rev-parse", "--verify", "--quiet", "HEAD")
            if rc_ref != 0 or not head_sha or ref_sha.strip() != head_sha.strip():
                continue  # a different (or unresolvable) commit: never a discard of this one
            resets_index = True
    # `xargs git checkout --` takes its paths from stdin: judge the whole tree.
    if reads_stdin and not paths:
        paths = ["."]
    if not paths:
        continue
    expanded = []
    for pth in paths:
        if "$" not in pth and "`" not in pth:
            expanded.append(pth); continue
        mv = re.match(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$", pth)
        words = loops.get(mv.group(1)) if mv else None
        if words and not any(c in w for w in words for c in "$`*?["):
            expanded.extend(words)
        else:
            expanded = ["."]; break
    rc, status = git(tree, "status", "--porcelain", "--", *expanded)
    if rc != 0:
        continue
    for line in status.splitlines():
        if len(line) < 4 or line[0] == "?":
            continue
        x, y, rest = line[0], line[1], line[3:]
        if y != " " or resets_index:
            reports.append(f"{tree}\t{rest}")
print("\n".join(dict.fromkeys(reports)))
PY
)" || discard_report=""

if [ -n "$discard_report" ]; then
  if escape GIT_GUARD_ALLOW_DISCARD 'git\s.*\b(checkout|switch|restore)\b'; then
    echo "⚠️  dotclaude git-guard: allowing a path-scoped discard — GIT_GUARD_ALLOW_DISCARD is set." >&2
    echo "   This can silently drop uncommitted work in the named path(s). Only legitimate for a" >&2
    echo "   deliberate discard you have already reviewed." >&2
  else
    at_risk="$(printf '%s\n' "$discard_report" | awk -F'\t' '{print "    " $2 "   (in " $1 ")"}')"
    block "git checkout/switch/restore would silently discard UNCOMMITTED changes — no warning, no diff, exit 0:
$at_risk
This guard cannot tell a deliberate break from real work; you can. Commit first (git reset --soft HEAD~1 undoes it), or restore a REAL historical defect from a known ref instead: git checkout <sha-or-origin/trunk> -- <path> (a ref that is NOT the commit you are on — HEAD, @ and HEAD~0 discard your work rather than fetching an older version). Genuinely deliberate? cp <path> <path>.bak and mv it back afterward, or prefix the command with GIT_GUARD_ALLOW_DISCARD=1."
  fi
fi

# 6) A worktree-stealing branch operation (#411). Plain `git checkout <branch>`
# / `git switch <branch>` already refuse to check out a branch another
# worktree has checked out ("already used by worktree"). The FORCING and
# RENAMING forms accept it anyway, with no warning, and silently rewrite the
# other worktree's HEAD out from under whatever was running there:
#   - `git checkout -B <b> …` / `git switch -C <b> …` reset a branch even when
#     another worktree has it checked out.
#   - `git branch -f <b> …` force-moves it the same way.
#   - `git branch -m|-M <b> <new>` renames it (or, given one argument, renames
#     the CURRENT branch of the tree running the command — a form that steals
#     exactly the same way but names no branch in the command at all).
#   - `git update-ref refs/heads/<b> …` moves the ref directly.
#
# The command's OWN tree is `-C <dir>` when the invocation names one, else the
# cwd this hook runs in — matching what the incident actually looked like:
# `git -C .worktrees/integration-w1 checkout -B integration/2026-09-23-w3
# origin/dev` stole a branch a DIFFERENT worktree (`.worktrees/integration-w3`)
# had checked out, with a full validation run in progress there.
#
# Delegated to python3 (already required above; nothing past this point runs
# without it) rather than more shell — parsing "which worktree, if any, holds
# this exact branch, other than my own" out of `git worktree list --porcelain`
# is a lookup, not a text scrub, and perl/awk/cut is where the earlier draft of
# this rule went to parse itself into a five-way pipeline with a subshell that
# swallowed its own `exit 2`.
#
# KNOWN GAP, same class as the rest of this file: only a single leading `-C
# <dir>` is recognized as the global flag naming the own tree; other global
# flags before or around it, and `branch --force`/`--move` in place of the
# short forms, are not modelled. A miss here is silence, not a false block.
#
# NARROW ESCAPE: GIT_GUARD_ALLOW_WORKTREE_STEAL=1 lifts ONLY this block, for
# the deliberate case — always logged loudly, same shape as the escapes above.
#
# Extracted from $nq (quotes stripped, content kept): branch names and paths
# are real arguments here, not message prose to blank out.
if command -v python3 >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  wt_hit="$(printf '%s' "$nq" | python3 -c '
import os, re, subprocess, sys

cmd = sys.stdin.read()
cwd = os.getcwd()

# An env-assignment prefix (`FOO=1 git checkout -B …`, `env X=y git …`) is still
# that git invocation: matching only a bare `git` let any prefix walk past.
INV = re.compile(
    r"(?:^|[;&|(]\s*)\s*(?:env\s+)?(?:[A-Za-z_]\w*=\S*\s+)*git\s+(?:-C\s+(\S+)\s+)?"
    r"(checkout|switch|branch|update-ref)\s+"
    r"((?:(?!\s*(?:;|&&|\|\||\||\n)).)*)",
    re.S | re.M,
)

def targets(sub, rest, current_branch):
    if sub == "checkout":
        m = re.search(r"(?:^|\s)-B\s+(\S+)", rest)
        return [m.group(1)] if m else []
    if sub == "switch":
        m = re.search(r"(?:^|\s)-C\s+(\S+)", rest)
        return [m.group(1)] if m else []
    if sub == "branch":
        out = []
        m = re.search(r"(?:^|\s)-f\s+(\S+)", rest)
        if m:
            out.append(m.group(1))
        if re.search(r"(?:^|\s)-[mM]\b", rest):
            toks = [t for t in rest.split() if not t.startswith("-")]
            if len(toks) >= 2:
                out.append(toks[0])
            elif len(toks) == 1 and current_branch:
                out.append(current_branch)
        return out
    if sub == "update-ref":
        m = re.search(r"refs/heads/(\S+)", rest)
        return [m.group(1)] if m else []
    return []

try:
    porcelain = subprocess.run(
        ["git", "worktree", "list", "--porcelain"],
        cwd=cwd, capture_output=True, text=True, timeout=5,
    ).stdout
except Exception:
    porcelain = ""

wt = []
for line in porcelain.splitlines():
    if line.startswith("worktree "):
        wt.append([os.path.realpath(line[len("worktree "):]), None])
    elif line.startswith("branch ") and wt:
        b = line[len("branch "):]
        if b.startswith("refs/heads/"):
            b = b[len("refs/heads/"):]
        wt[-1][1] = b

def branch_of(p):
    for wp, wb in wt:
        if wp == p:
            return wb
    return None

hit = None
for m in INV.finditer(cmd):
    cdir, sub, rest = m.group(1), m.group(2), m.group(3)
    own = os.path.realpath(cdir) if cdir else os.path.realpath(cwd)
    current_branch = branch_of(own)
    for t in targets(sub, rest, current_branch):
        for wp, wb in wt:
            if wb == t and wp != own:
                hit = (t, wp)
                break
        if hit:
            break
    if hit:
        break

if hit:
    print(hit[0])
    print(hit[1])
'
  )"
  if [ -n "$wt_hit" ]; then
    if escape GIT_GUARD_ALLOW_WORKTREE_STEAL 'git\s.*\b(checkout|switch|branch|update-ref)\b'; then
      echo "⚠️  dotclaude git-guard: allowing a worktree-branch collision — GIT_GUARD_ALLOW_WORKTREE_STEAL is set." >&2
      echo "   This can silently rewrite another worktree's HEAD out from under whatever is running there." >&2
    else
      hit_branch="$(printf '%s' "$wt_hit" | sed -n 1p)"
      hit_path="$(printf '%s' "$wt_hit" | sed -n 2p)"
      block "branch '$hit_branch' is checked out in another worktree ($hit_path) — forcing or renaming it here would silently rewrite that worktree's HEAD out from under whatever is running there (#411). Operate on that worktree directly, or if this is genuinely deliberate, prefix that one git command with GIT_GUARD_ALLOW_WORKTREE_STEAL=1 (\`GIT_GUARD_ALLOW_WORKTREE_STEAL=1 git …\`)."
    fi
  fi
fi

exit 0
