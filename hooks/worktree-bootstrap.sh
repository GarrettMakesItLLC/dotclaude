#!/usr/bin/env bash
# dotclaude worktree-bootstrap — PostToolUse hook (matcher: Bash).
#
# The COMPLEMENT to worktree-guard.sh: the guard FORCES agents into an isolated
# `.worktrees/` checkout, but a fresh worktree has no `.env.local`, no generated
# Prisma client, etc. — so the agent's very first typecheck/lint/test fails on a
# missing environment instead of on real code. This hook primes it.
#
# Fires after every Bash call, cheaply no-ops unless the command was a
# `git worktree add`, and on a match primes the new worktree DETACHED (#408) —
# this is a PostToolUse hook with its own time budget, and priming can queue for
# minutes behind a check lock on a busy box, so it never runs inline.
#
# Which script primes it:
#   - a repo with a `.claude/repo.json` manifest (docs/repo-manifest.md) ->
#     dotclaude's shared `bin/setup-worktree.sh`, driven by that manifest;
#   - otherwise the repo's own `bin/setup-worktree.sh`, if it has one;
#   - neither -> no-op, so this hook is inert in a repo that hasn't opted in.
#
# The hook's message reaches the agent as `additionalContext` JSON on stdout: a
# PostToolUse hook's stderr is not surfaced on exit 0.
#
# Fail-open by design: no python3, unparseable input, no match, or any error
# exits 0 and stays silent. A bootstrap hook that blocks a shell is far worse
# than one that occasionally misses — `bin/setup-worktree.sh` is always runnable
# by hand as the fallback.
set -uo pipefail

input="$(cat)"

# Need python3 to parse the payload; without it, fail open.
command -v python3 >/dev/null 2>&1 || exit 0

# Pull the command string and the shell's cwd out of the PostToolUse payload.
command_str="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
except Exception:
    print("")
' 2>/dev/null)" || exit 0
payload_cwd="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("cwd", "") or "")
except Exception:
    print("")
' 2>/dev/null)" || payload_cwd=""

# Only care about `git worktree add`. Anything else: silent no-op.
#
# Matched on the two words in sequence rather than the literal string
# "git worktree add", because a global flag sits between them in the form that
# creates a worktree in ANOTHER repo — `git -C <dir> worktree add …` — which is
# exactly the case #312 is about, and which the substring test never fired on.
case "$command_str" in
  *worktree*add*) ;;
  *) exit 0 ;;
esac

# Extract the target path: the first non-flag token after `add`. Handles both
# `git worktree add <path> -b <branch>` and `git worktree add -b <branch> <path>`.
target="$(printf '%s' "$command_str" | python3 -c '
import shlex, sys
try:
    toks = shlex.split(sys.stdin.read())
except Exception:
    sys.exit(0)
# `worktree` immediately followed by `add`, so the loose shell prefilter above
# cannot be satisfied by the two words appearing anywhere in a command — a
# commit message, or `git worktree list && mkdir add`.
pair = next(
    (i for i in range(len(toks) - 1) if toks[i] == "worktree" and toks[i + 1] == "add"),
    None,
)
if pair is None:
    sys.exit(0)
rest = toks[pair + 2:]
skip_next = False
flags_with_arg = {"-b", "-B", "--reason", "--lock"}
for t in rest:
    if skip_next:
        skip_next = False
        continue
    if t in flags_with_arg:
        skip_next = True
        continue
    if t.startswith("-"):
        continue
    print(t)
    break
' 2>/dev/null)" || exit 0

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
# The SHELL's cwd from the payload, not the project dir: an agent inside
# `.worktrees/a` that creates `.worktrees/b` would otherwise resolve to
# `.worktrees/a/.worktrees/b`, find nothing, and give up.
base_cwd="${payload_cwd:-$project_dir}"

messages=""

# Prime ONE worktree: choose the script that belongs to the repo that owns it,
# launch it DETACHED, and append a note to $messages. Returns 1, silently, when
# the tree cannot be primed, 2 when the repo is not opted in (no script).
prime_one() {
  local target="$1" owner_repo self_dir shared_script script wt_git_dir log rc_file
  [ -d "$target" ] || return 1

  # The script belongs to the repo the WORKTREE was created in, which is not
  # necessarily the session's project (#312): ask git which repo owns it.
  # `--git-common-dir` resolves to the MAIN checkout's `.git`, whose parent is
  # the repo whose `bin/` holds the script. Falls back to the project dir when
  # git cannot answer.
  owner_repo="$(git -C "$target" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$owner_repo" ]; then
    owner_repo="$(dirname "$owner_repo")"
  else
    owner_repo="$project_dir"
  fi
  [ -d "$owner_repo" ] || return 1

  # A manifest opts the repo into dotclaude's shared script. The worktree's own
  # copy is read first — it is tracked, so it is the branch's — then the main
  # checkout's.
  self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  shared_script="$self_dir/../bin/setup-worktree.sh"
  if { [ -f "$target/.claude/repo.json" ] || [ -f "$owner_repo/.claude/repo.json" ]; } && [ -x "$shared_script" ]; then
    script="$(cd "$(dirname "$shared_script")" && pwd)/setup-worktree.sh"
  else
    script="$owner_repo/bin/setup-worktree.sh"
  fi
  [ -x "$script" ] || return 2   # not opted in: inert, not a failure

  # Run it DETACHED (#408): priming can queue for minutes behind
  # `bin/with-check-lock.sh`, longer than this hook's own time budget, and a
  # kill partway leaves a half-primed tree. The log and rc marker live in the
  # WORKTREE's own git-dir (`--git-dir`, the per-worktree admin dir) so
  # concurrent primings never collide. The repo's pre-push
  # `setup-worktree --check` catches an incomplete result.
  wt_git_dir="$(git -C "$target" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  [ -n "$wt_git_dir" ] || wt_git_dir="$target"
  log="$wt_git_dir/worktree-bootstrap.log"
  rc_file="$wt_git_dir/worktree-bootstrap.rc"
  rm -f "$rc_file" 2>/dev/null || true

  # Every path is its own argv entry, so a space or quote can't break the
  # redirection.
  (
    nohup sh -c '"$1" "$2" > "$3" 2>&1; echo $? > "$4"' _ \
      "$script" "$target" "$log" "$rc_file" >/dev/null 2>&1 &
  )

  messages="${messages}dotclaude worktree-bootstrap: priming $target in the background with $script.
Log: $log
Done when: $rc_file exists and reads 0. Until then, do not trust a typecheck, lint or test result from that worktree.
"
  return 0
}

resolved=""
if [ -n "$target" ]; then
  case "$target" in
    /*) resolved="$target" ;;
    *) resolved="$base_cwd/$target" ;;
  esac
fi

# The target is parsed from the LITERAL command string, so a shell variable
# (`for d in …; do git worktree add .worktrees/$d …; done`) never resolves and
# the tree it created would go unprimed with no message (#497). When the
# target is empty, contains `$`/a backtick, or names no directory, sweep the
# repo's linked worktrees instead: prime every one with neither a rc marker nor
# `node_modules`, and name any that cannot be primed.
if [ -n "$resolved" ] && [ -d "$resolved" ] && case "$target" in *'$'*|*'`'*) false ;; *) true ;; esac; then
  prime_one "$resolved" || true
else
  case "$command_str" in
    *'$'*|*'`'*) ;;
    *) exit 0 ;;   # a plain add whose target simply is not there: nothing to do
  esac
  unprimed=""
  wt_path=""
  first=1
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt_path="${line#worktree }" ;;
      "")
        if [ -n "$wt_path" ]; then
          if [ "$first" = 1 ]; then
            first=0   # the main checkout is not a linked worktree
          else
            wt_gd="$(git -C "$wt_path" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
            if [ -d "$wt_path" ] && [ -n "$wt_gd" ] \
               && [ ! -e "$wt_gd/worktree-bootstrap.rc" ] && [ ! -d "$wt_path/node_modules" ]; then
              prime_one "$wt_path"
              [ $? = 1 ] && unprimed="${unprimed}  $wt_path
"
            fi
          fi
        fi
        wt_path=""
        ;;
    esac
  done < <(git -C "$base_cwd" worktree list --porcelain 2>/dev/null; echo)
  if [ -n "$unprimed" ]; then
    messages="${messages}dotclaude worktree-bootstrap: the worktree target in this command could not be resolved (shell variable?) and these linked worktrees have no bootstrap marker and no node_modules, and could not be primed. Run setup-worktree.sh by hand:
${unprimed}"
  fi
fi

[ -n "$messages" ] || exit 0

python3 -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": sys.argv[1]}}))
' "$messages" 2>/dev/null || true
exit 0
