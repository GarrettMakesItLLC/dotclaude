#!/usr/bin/env bash
# dotclaude git-guard — PreToolUse hook for the Bash tool.
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
if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi
cmd="$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    sys.stdout.write(json.load(sys.stdin).get("tool_input", {}).get("command", "") or "")
except Exception:
    pass' 2>/dev/null)"

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
  | sed -E "s/'[^']*'/ /g; s/\"[^\"]*\"/ /g")"

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

# Only inspect git invocations beyond this point.
printf '%s' "$scrubbed" | grep -Eq '(^|[^[:alnum:]_./-])git([[:space:]]|$)' || exit 0

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
if [ -n "${GIT_GUARD_HOOK_PROVEN_KILLED:-}" ]; then
  if printf '%s' "$scrubbed" | grep -Eq -- '--no-verify'; then
    echo "⚠️  dotclaude git-guard: allowing git --no-verify — GIT_GUARD_HOOK_PROVEN_KILLED is set." >&2
    echo "   This bypasses commit hooks. Only legitimate when the hook was proven OOM-killed" >&2
    echo "   (exit 137 / dmesg 'Killed process'), not when it found a real problem." >&2
  fi
elif printf '%s' "$scrubbed" | grep -Eq -- '--no-verify'; then
  block "git --no-verify is forbidden. Fix the failing hook (gitleaks/lint/typecheck) and commit normally — then make a NEW commit. If the hook was OOM-killed by unrelated swarm contention (exit 137, or 'dmesg | grep -i \"killed process\"' names it) rather than finding a real problem, set GIT_GUARD_HOOK_PROVEN_KILLED=1 for this one command."
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
  if [ -n "${GIT_GUARD_HOOK_PROVEN_KILLED:-}" ]; then
    echo "⚠️  dotclaude git-guard: allowing git commit -n — GIT_GUARD_HOOK_PROVEN_KILLED is set." >&2
    echo "   This bypasses commit hooks. Only legitimate when the hook was proven OOM-killed" >&2
    echo "   (exit 137 / dmesg 'Killed process'), not when it found a real problem." >&2
  else
    block "git commit -n bypasses hooks (short for --no-verify). Forbidden — fix the hook and retry. If the hook was OOM-killed by unrelated swarm contention (exit 137, or 'dmesg | grep -i \"killed process\"' names it) rather than finding a real problem, set GIT_GUARD_HOOK_PROVEN_KILLED=1 for this one command."
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

# 5) A path-scoped discard (`git checkout -- <path>`, `git checkout HEAD --
# <path>`, `git restore <path>`) silently overwrites the WORKING TREE from the
# index/HEAD, taking any uncommitted change to that path with it — no warning,
# no diff. The standing instruction to verify a guard by deliberately breaking
# something routes agents straight at this: "undo the break" reads as
# `git checkout -- <file>`, which reverts to the last commit and can erase
# UNRELATED uncommitted work in the same file along with the deliberate one.
#
# `git checkout <ref-other-than-HEAD> -- <path>` (obtaining a REAL historical
# defect, e.g. `git checkout origin/main -- <path>`) is the recommended form
# and stays unimpeded, as do `--staged`, `--source=<ref>`, branch switches, and
# a path with no uncommitted changes. Extracted from `$nq` (quotes stripped,
# content kept), not `$scrubbed` — a quoted path is a real argument here, not
# message prose to blank out.
#
# NARROW ESCAPE: GIT_GUARD_ALLOW_DISCARD=1 lifts ONLY this block, for the
# deliberate case — always logged loudly, same shape as #185's escape above.
#
# KNOWN GAP: paths are matched on whitespace, so a path containing a space
# isn't handled — same class of trade-off as the other rules in this file.
checkout_args="$(printf '%s' "$nq" \
  | perl -0777 -ne 'while (/git\s+checkout((?:(?!\s*(?:;|&&|\|\||\||\n)).)*)/gs) { print "$1\n" }')"
restore_args="$(printf '%s' "$nq" \
  | perl -0777 -ne 'while (/git\s+restore((?:(?!\s*(?:;|&&|\|\||\||\n)).)*)/gs) { print "$1\n" }')"

discard_paths=""

if [ -n "$checkout_args" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rest=""
    if printf '%s' "$line" | grep -Eq '^[[:space:]]*--[[:space:]]+'; then
      rest="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*--[[:space:]]+//')"
    elif printf '%s' "$line" | grep -Eq '^[[:space:]]*(HEAD|@)(~0|\^0)?[[:space:]]+--[[:space:]]+'; then
      # Every spelling that RESOLVES to HEAD, not just the word: `@` is its
      # documented synonym and `HEAD~0`/`HEAD^0`/`@~0`/`@^0` are the same
      # commit. The discriminator is what the ref resolves to, and a textual
      # match on `HEAD` alone let three spellings of it through while blocking
      # the fourth — `git checkout HEAD~0 -- <path>` discards exactly as much
      # as `git checkout HEAD -- <path>` (#383).
      rest="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*(HEAD|@)(~0|\^0)?[[:space:]]+--[[:space:]]+//')"
    fi
    [ -n "$rest" ] && discard_paths="$discard_paths $rest"
  done <<EOF
$checkout_args
EOF
fi

if [ -n "$restore_args" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s' "$line" | grep -Eq -- '--staged|--source' && continue
    rest="$(printf '%s' "$line" | sed -E 's/(^|[[:space:]])--[a-zA-Z-]+(=[^[:space:]]*)?//g')"
    [ -n "$(printf '%s' "$rest" | tr -d '[:space:]')" ] && discard_paths="$discard_paths $rest"
  done <<EOF
$restore_args
EOF
fi

discard_paths_trimmed="$(printf '%s' "$discard_paths" | tr -d '[:space:]')"
if [ -n "$discard_paths_trimmed" ]; then
  if [ -n "${GIT_GUARD_ALLOW_DISCARD:-}" ]; then
    echo "⚠️  dotclaude git-guard: allowing a path-scoped discard — GIT_GUARD_ALLOW_DISCARD is set." >&2
    echo "   This can silently drop uncommitted work in the named path(s). Only legitimate for a" >&2
    echo "   deliberate discard you have already reviewed." >&2
  else
    for p in $discard_paths; do
      if [ -n "$(git status --porcelain -- "$p" 2>/dev/null)" ]; then
        block "git checkout/restore would discard UNCOMMITTED changes in '$p' — silently, with no warning or diff. Commit first (git reset --soft HEAD~1 undoes it), or restore a REAL historical defect with a ref-scoped form instead: git checkout <sha-or-origin/trunk> -- $p (a ref that is NOT HEAD — HEAD, @ and HEAD~0 all resolve to the commit you are already on, so they discard your uncommitted work rather than fetching an older version of it). Genuinely deliberate? cp $p $p.bak && mv it back afterward, or set GIT_GUARD_ALLOW_DISCARD=1 for this one command."
      fi
    done
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

INV = re.compile(
    r"(?:^|[;&|]\s*)git\s+(?:-C\s+(\S+)\s+)?"
    r"(checkout|switch|branch|update-ref)\s+"
    r"((?:(?!\s*(?:;|&&|\|\||\||\n)).)*)",
    re.S,
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
    if [ -n "${GIT_GUARD_ALLOW_WORKTREE_STEAL:-}" ]; then
      echo "⚠️  dotclaude git-guard: allowing a worktree-branch collision — GIT_GUARD_ALLOW_WORKTREE_STEAL is set." >&2
      echo "   This can silently rewrite another worktree's HEAD out from under whatever is running there." >&2
    else
      hit_branch="$(printf '%s' "$wt_hit" | sed -n 1p)"
      hit_path="$(printf '%s' "$wt_hit" | sed -n 2p)"
      block "branch '$hit_branch' is checked out in another worktree ($hit_path) — forcing or renaming it here would silently rewrite that worktree's HEAD out from under whatever is running there (#411). Operate on that worktree directly, or if this is genuinely deliberate, set GIT_GUARD_ALLOW_WORKTREE_STEAL=1 for this one command."
    fi
  fi
fi

exit 0
