#!/usr/bin/env bash
# dotclaude verify-reminder — PreToolUse hook for the Bash tool and the
# github-rest MCP. Fires ONLY when an agent is about to open a pull request
# (`gh pr create`, or the `pr_create` MCP tool). On a match it injects a
# non-blocking reminder covering the three things a PR hands off on: that the
# change-scoped checks were run, that an issue is linked, and that no finding was
# left dangling. It also names the deferred-work markers the branch actually adds
# (`TODO`/`FIXME`, skipped or focused tests) so "I'll get it next PR" has to be a
# decision rather than an oversight.
#
# Why this exists: "Verify before claiming done" and "Finish what you find" live
# in CLAUDE.md as prose, so subagents follow them only probabilistically. This
# turns them into a deterministic nudge at the one handoff that matters — opening
# the PR — and the marker scan is the part prose cannot do: it reads the diff.
#
# Why PR-create and NOT every push: pushes are constant (many parallel worktree
# agents commit/push all day); nudging each one is alarm fatigue and undoes the
# "fast hooks" standard. The PR is the infrequent, meaningful handoff. See
# GarrettMakesItLLC/dotclaude#7.
#
# Why non-blocking (additionalContext, exit 0) and NOT a block (exit 2): a
# stateless exit-2 would block the agent's verified retry identically and
# deadlock PR creation. This nudge runs NOTHING slow — it never invokes
# typecheck/test/build — so it fully respects the fast-hooks decision: the agent
# does the change-scoped check itself, the hook only reminds.
#
# Fail-open by design: no python3, or malformed JSON, or a tool we don't care
# about -> exit 0 silently and let the call through. This is a nudge, never a gate.

set -uo pipefail

input="$(cat)"

# No JSON parser -> fail open. python3 is ubiquitous on Linux/macOS.
if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

# Pull tool_name and (for Bash) the command in one parse.
read -r tool_name cmd_present < <(printf '%s' "$input" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
name = d.get("tool_name", "") or ""
print(name, 1 if d.get("tool_input", {}).get("command") else 0)' 2>/dev/null)

[ -z "${tool_name:-}" ] && exit 0

# Added lines on this branch that defer work: TODO-class comments, and tests
# skipped or narrowed to `.only`. Reported, never blocked — some are legitimate,
# and prose that merely names a marker matches too. Over-reporting is the right
# side to err on: a false hit costs one line of "intentional, because …" in the
# PR body, a missed one costs a dropped fix.
#
# Diffed against the merge-base with the integration branch so only THIS
# branch's additions count, not markers the codebase already carried. Every
# failure path is silent: no repo, no upstream, detached, slow — the scan is
# dropped and the rest of the nudge still fires.
loose_ends() {
  local base ref out
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  # Take the LATEST merge-base across the candidate integration branches, not the
  # first that resolves: a feature branch cut from `dev` shares an older ancestor
  # with `main`, and using that one would re-report every marker `dev` already
  # carried.
  local mb ts best_ts=0
  for ref in origin/HEAD origin/main origin/dev main dev; do
    git rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || continue
    mb="$(git merge-base "$ref" HEAD 2>/dev/null)" || continue
    [ -n "$mb" ] || continue
    ts="$(git show -s --format=%ct "$mb" 2>/dev/null)" || continue
    case "$ts" in ''|*[!0-9]*) continue ;; esac
    if [ "$ts" -gt "$best_ts" ]; then best_ts="$ts"; base="$mb"; fi
  done
  [ -n "${base:-}" ] || return 0
  # A merge-base equal to HEAD means HEAD is already contained in the base ref —
  # nothing of this branch's own to scan.
  [ "$base" = "$(git rev-parse HEAD 2>/dev/null)" ] && return 0

  # --unified=0 keeps context lines out, so only genuinely added lines match. awk
  # tracks the `+++ b/<path>` header and each hunk's new-side start line so every
  # hit is reported as `file:line` — a bare diff line is not actionable.
  out="$(git diff --unified=0 --no-color "$base"..HEAD 2>/dev/null | awk '
    /^\+\+\+ / { f = substr($0, 7); next }
    /^@@/      { match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
    /^\+/      { line = substr($0, 2)
                 if (line ~ /(TODO|FIXME|XXX|HACK)|\.(skip|only)\(|(^|[^A-Za-z0-9_])(xit|xdescribe|fit|fdescribe)\(|@pytest\.mark\.skip/)
                   printf "  %s:%d: %s\n", f, n, substr(line, 1, 110)
                 n++ }
  ' | head -15)"
  [ -n "$out" ] && printf '%s' "$out"
}

nudge() {
  # Emit a non-blocking PreToolUse reminder. permissionDecision "allow" is
  # required by the schema; additionalContext is shown to the agent beside the
  # tool result. python3 builds the JSON so the message can't break quoting, and
  # the marker list travels via the environment so diff text can't either.
  DOTCLAUDE_LOOSE_ENDS="$(loose_ends)" python3 -c '
import json, os
msg = (
    "Verification check before this PR hands off (CLAUDE.md: \"Verify before you push or open a PR\"). "
    "Confirm you have run the checks relevant to your change on THIS branch'\''s current state and they pass:\n"
    "  - Always: typecheck + the tests affected by your change.\n"
    "  - Only if you touched build-affecting code (config, deps, codegen, bundler/routes): the build.\n"
    "If you have not run them yet, run them now and report the command output. "
    "If anything fails, fix it (or open the PR as a draft) before calling this done. "
    "Scope to your diff — this is a fast local check, not the full suite.\n"
    "Before this PR hands off, also confirm issue linkage: the PR body references the issue it resolves (\"Closes #N\"), and that issue is set to status:in-review. "
    "If no issue tracks this work, create one (see the managing-work-with-issues skill) and link it.\n"
    "Finally, account for every finding (CLAUDE.md: \"Finish what you find\"). "
    "Each bug, stale doc, or rough edge you hit this session is either fixed in this diff or has an issue number — there is no third bucket. "
    "State the count in the PR body: N found, M fixed here, K filed. Anything you could fix now, fix now instead of filing it."
)
# Strip newlines only — a bare .strip() would eat the first entry'\''s indent and
# break its alignment with the rest of the list.
loose = os.environ.get("DOTCLAUDE_LOOSE_ENDS", "").strip("\n")
if loose:
    msg += (
        "\nThis branch ADDS the following deferred-work markers. For each one: fix it in this diff, "
        "or say in the PR body why it stays (and file the issue it points at). Do not let it through unremarked.\n"
        + loose
    )
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "additionalContext": msg,
    }
}))'
  exit 0
}

case "$tool_name" in
  mcp__github-rest__pr_create)
    nudge
    ;;
  Bash)
    # Only the Bash tool carries a command; narrow to actual PR creation so we
    # don't fire on `gh pr view` / `gh pr list` / unrelated commands.
    [ "${cmd_present:-0}" = "1" ] || exit 0
    cmd="$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    sys.stdout.write(json.load(sys.stdin).get("tool_input", {}).get("command", "") or "")
except Exception:
    pass' 2>/dev/null)"
    # Strip quoted spans first (like git-guard) so a `gh pr create` that only
    # appears inside a commit message / echo string can't trip a false nudge.
    cmd="$(printf '%s' "$cmd" | sed -E "s/'[^']*'/ /g; s/\"[^\"]*\"/ /g")"
    # Match `gh pr create` as its own command segment (start of string, or after
    # a separator / whitespace) so a substring like `foogh pr create` can't match.
    if printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:](])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
      nudge
    fi
    ;;
esac

exit 0
