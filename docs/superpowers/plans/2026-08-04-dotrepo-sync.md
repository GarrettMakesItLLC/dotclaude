# dotrepo-sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a SessionStart hook that fast-forwards `~/dotclaude` and
`~/workspace/dotfiles` when they're cleanly behind their remote, and reports —
never force-touches — when they aren't (dirty tree or diverged history).

**Architecture:** One new bash hook, `hooks/dotrepo-sync.sh`, following the exact
shape of the existing `hooks/link-doctor.sh` (fail-open, silent when healthy,
`additionalContext` JSON payload on drift). Registered in `settings.json`'s
`SessionStart` hook list, ordered before `link-doctor.sh` so a freshly-pulled
`dotclaude` is what the symlink doctor verifies in the same session start.

**Tech Stack:** bash, git, python3 (for JSON payload construction — same as
`link-doctor.sh`).

## Global Constraints

- Fail open on every error path (missing repo dir, no network, no upstream,
  fetch/pull failure) — exit 0, silent. A sync check must never block a session
  start. (spec: Design, step 3)
- Never touch a repo with a dirty working tree or diverged local history — only
  a clean fast-forward is automatic. (spec: Design, step 2)
- Runs unconditionally on every session start, no cwd branching. (spec:
  Non-goals)
- Only `dotclaude` and `dotfiles` are in scope — no other repo fleet members.
  (spec: Non-goals)

---

### Task 1: `dotrepo-sync.sh` hook + test

**Files:**
- Create: `hooks/dotrepo-sync.sh`
- Create: `hooks/dotrepo-sync.test.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: an executable hook at `hooks/dotrepo-sync.sh` that reads
  `DOTCLAUDE_DIR` (default `$HOME/dotclaude`) and `DOTFILES_DIR` (default
  `$HOME/workspace/dotfiles`) env vars, and on stdout emits either nothing, or a
  single JSON object `{"hookSpecificOutput": {"hookEventName": "SessionStart",
  "additionalContext": "<newline-joined notes>"}}`. Always exits 0. Task 2 wires
  this into `settings.json`.

- [ ] **Step 1: Write the test file**

Create `hooks/dotrepo-sync.test.sh`:

```bash
#!/usr/bin/env bash
# Self-test for dotrepo-sync.sh. Builds throwaway bare + clone repo pairs so
# real dotclaude/dotfiles are never touched, and asserts every staleness case
# is handled without ever forcing a change onto a dirty or diverged tree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/dotrepo-sync.sh"
fail=0

# A bare "remote" plus a clone of it, both throwaway, with git identity set
# so commits work in CI with no global config.
make_pair() {
  local base origin clone
  base="$(mktemp -d)"
  origin="$base/origin.git"
  clone="$base/clone"
  git init --quiet --bare "$origin"
  git clone --quiet "$origin" "$clone"
  git -C "$clone" config user.email test@example.com
  git -C "$clone" config user.name test
  echo one > "$clone/file"
  git -C "$clone" add file
  git -C "$clone" commit --quiet -m one
  git -C "$clone" push --quiet origin "$(git -C "$clone" rev-parse --abbrev-ref HEAD)"
  printf '%s' "$clone"
}

# Push one more commit to the shared remote from a second clone, simulating
# "someone else pushed" without touching the first clone's working tree.
advance_remote() {
  local clone="$1" second
  second="$(mktemp -d)/second"
  git clone --quiet "$(git -C "$clone" remote get-url origin)" "$second"
  git -C "$second" config user.email test@example.com
  git -C "$second" config user.name test
  echo two >> "$second/file"
  git -C "$second" commit --quiet -am two
  git -C "$second" push --quiet origin "HEAD:$(git -C "$clone" rev-parse --abbrev-ref HEAD)"
  rm -rf "$(dirname "$second")"
}

run() { DOTCLAUDE_DIR="$1" DOTFILES_DIR="$2" "$HOOK" 2>/dev/null; }

# --- up to date: silent, exit 0 ---
c1="$(make_pair)"; c2="$(make_pair)"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 up to date, got $code"; fail=1; }
[ -z "$out" ] || { echo "FAIL: must stay silent up to date, got: $out"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- clean fast-forward: pulls, reports count ---
c1="$(make_pair)"; c2="$(make_pair)"
advance_remote "$c1"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 on clean pull, got $code"; fail=1; }
printf '%s' "$out" | grep -q 'pulled 1 new commit' \
  || { echo "FAIL: should report pulling 1 commit, got: $out"; fail=1; }
[ "$(git -C "$c1" rev-parse HEAD)" = "$(git -C "$c1" rev-parse '@{u}')" ] \
  || { echo "FAIL: c1 should now be at upstream HEAD"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- behind + dirty tree: reports, does not pull ---
c1="$(make_pair)"; c2="$(make_pair)"
advance_remote "$c1"
echo local-edit >> "$c1/file"
before="$(git -C "$c1" rev-parse HEAD)"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 when dirty, got $code"; fail=1; }
printf '%s' "$out" | grep -q 'uncommitted' \
  || { echo "FAIL: should report uncommitted local changes, got: $out"; fail=1; }
[ "$(git -C "$c1" rev-parse HEAD)" = "$before" ] \
  || { echo "FAIL: dirty repo must not be pulled"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- diverged (ahead and behind): reports, does not pull ---
c1="$(make_pair)"; c2="$(make_pair)"
advance_remote "$c1"
git -C "$c1" config user.email test@example.com
git -C "$c1" config user.name test
echo local-commit >> "$c1/file"
git -C "$c1" commit --quiet -am local-commit
before="$(git -C "$c1" rev-parse HEAD)"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 when diverged, got $code"; fail=1; }
printf '%s' "$out" | grep -q 'diverged' \
  || { echo "FAIL: should report diverged history, got: $out"; fail=1; }
[ "$(git -C "$c1" rev-parse HEAD)" = "$before" ] \
  || { echo "FAIL: diverged repo must not be pulled"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- missing directory: silent, exit 0 ---
out="$(run "/nonexistent-dotclaude-$$" "/nonexistent-dotfiles-$$")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 with missing repos, got $code"; fail=1; }
[ -z "$out" ] || { echo "FAIL: must stay silent with missing repos, got: $out"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "dotrepo-sync: all cases passed"
fi
exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `chmod +x hooks/dotrepo-sync.test.sh && bash hooks/dotrepo-sync.test.sh`
Expected: FAIL immediately — `hooks/dotrepo-sync.sh: No such file or directory` (or
similar), since the hook doesn't exist yet.

- [ ] **Step 3: Write the hook implementation**

Create `hooks/dotrepo-sync.sh`:

```bash
#!/usr/bin/env bash
# dotrepo-sync — SessionStart hook. Fast-forwards dotclaude and dotfiles when
# they are cleanly behind their remote; reports when they can't be (dirty
# working tree, or local history has diverged). Never force-touches either.
#
# Runs before link-doctor.sh in settings.json so a freshly-pulled dotclaude is
# what the symlink check verifies in the same session start.
#
# Fail-open by design: missing repo, no network, no upstream configured ->
# silent, exit 0. A sync check must never be the reason a session can't start.

set -uo pipefail

DOTCLAUDE_DIR="${DOTCLAUDE_DIR:-$HOME/dotclaude}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/workspace/dotfiles}"

notes=()

sync_repo() {
  local dir="$1" label="$2"
  [ -d "$dir/.git" ] || return 0

  git -C "$dir" fetch --quiet 2>/dev/null || return 0

  local upstream
  upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || return 0

  local counts ahead behind
  counts="$(git -C "$dir" rev-list --left-right --count "HEAD...$upstream" 2>/dev/null)" || return 0
  ahead="$(printf '%s' "$counts" | awk '{print $1}')"
  behind="$(printf '%s' "$counts" | awk '{print $2}')"
  [ -n "$ahead" ] && [ -n "$behind" ] || return 0

  [ "$behind" = 0 ] && return 0

  if [ "$ahead" != 0 ]; then
    notes+=("$label: $behind commit(s) behind, $ahead ahead — diverged, resolve by hand")
    return 0
  fi

  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    notes+=("$label: $behind commit(s) behind, local changes uncommitted — resolve by hand")
    return 0
  fi

  if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
    notes+=("$label: pulled $behind new commit(s)")
  else
    notes+=("$label: $behind commit(s) behind, fast-forward failed — resolve by hand")
  fi
}

sync_repo "$DOTCLAUDE_DIR" "dotclaude"
sync_repo "$DOTFILES_DIR" "dotfiles"

[ "${#notes[@]}" -gt 0 ] || exit 0

command -v python3 >/dev/null 2>&1 || exit 0

msg="$(printf '%s\n' "${notes[@]}")"
DOTREPO_SYNC_NOTES="$msg" python3 -c '
import json, os
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": os.environ.get("DOTREPO_SYNC_NOTES", ""),
    }
}))'

exit 0
```

Make it executable: `chmod +x hooks/dotrepo-sync.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash hooks/dotrepo-sync.test.sh`
Expected: `dotrepo-sync: all cases passed`, exit 0. If the "clean fast-forward"
or "diverged" cases fail because of default-branch-name mismatches, check
`git config --global init.defaultBranch` in the test environment — the test
derives the branch name from the clone itself (`rev-parse --abbrev-ref HEAD`)
specifically to avoid hardcoding `main` vs `master`, so a failure here means a
copy-paste error, not an environment mismatch.

- [ ] **Step 5: Commit**

```bash
git add hooks/dotrepo-sync.sh hooks/dotrepo-sync.test.sh
git commit -m "feat(hooks): add dotrepo-sync SessionStart hook

Fast-forwards dotclaude/dotfiles when cleanly behind their remote;
reports instead of touching a dirty or diverged tree.

Closes GarrettMakesItLLC/dotfiles#5"
```

---

### Task 2: Wire into `settings.json`

**Files:**
- Modify: `settings.json` (`SessionStart` hook list)

**Interfaces:**
- Consumes: `hooks/dotrepo-sync.sh` from Task 1 (path only, no function calls —
  hooks are invoked as standalone processes).
- Produces: nothing further downstream.

- [ ] **Step 1: Add the hook entry before `link-doctor.sh`**

In `settings.json`, the `SessionStart` block currently reads:

```json
  "SessionStart": [
    {
      "matcher": "startup|resume",
      "hooks": [
        {
          "type": "command",
          "command": "\"$HOME\"/.claude/hooks/link-doctor.sh"
        },
        {
          "type": "command",
          "command": "\"$HOME\"/.claude/hooks/agent-creds-sync.sh"
        }
      ]
    }
  ],
```

Change the `hooks` array so `dotrepo-sync.sh` runs first:

```json
  "SessionStart": [
    {
      "matcher": "startup|resume",
      "hooks": [
        {
          "type": "command",
          "command": "\"$HOME\"/.claude/hooks/dotrepo-sync.sh"
        },
        {
          "type": "command",
          "command": "\"$HOME\"/.claude/hooks/link-doctor.sh"
        },
        {
          "type": "command",
          "command": "\"$HOME\"/.claude/hooks/agent-creds-sync.sh"
        }
      ]
    }
  ],
```

- [ ] **Step 2: Validate the JSON**

Run: `python3 -c "import json; json.load(open('settings.json'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Manual smoke test against the real repos**

Run: `bash hooks/dotrepo-sync.sh` (no env override — targets the real
`~/dotclaude` and `~/workspace/dotfiles`)
Expected: no output, exit 0, since both are already up to date in this
session. Confirm exit code: `echo $?` → `0`.

- [ ] **Step 4: Commit**

```bash
git add settings.json
git commit -m "feat(hooks): wire dotrepo-sync into SessionStart

Runs before link-doctor.sh so a freshly-pulled dotclaude is what the
symlink check verifies in the same session start."
```

## Self-Review Notes

- Spec coverage: fast-forward pull (Task 1, `sync_repo`), notify-only on
  dirty/diverged (Task 1), fail-open on every error path (Task 1, every early
  `return 0`), no cwd branching (script takes no cwd input at all), ordering
  before `link-doctor.sh` (Task 2) — all covered.
- No placeholders: every step has literal file content or a literal command.
- Types/signatures: `sync_repo(dir, label)` used identically in both call
  sites; `notes` array and its consumption at the bottom are the only shared
  state, both within Task 1's single file.
