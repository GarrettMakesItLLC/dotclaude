#!/usr/bin/env bash
# Self-test for worktree-reap-trigger.sh. The hook is copied next to a stub
# reaper in a fake dotclaude tree, so "how was the reaper invoked" is answered by
# the hook actually invoking it. Run locally or in CI:
#   bash hooks/worktree-reap-trigger.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A fake dotclaude whose reaper records its argv and cwd.
DOT="$TMP/dot"
mkdir -p "$DOT/hooks" "$DOT/bin"
cp "$HERE/worktree-reap-trigger.sh" "$DOT/hooks/"
CALLS="$TMP/calls.log"
cat >"$DOT/bin/worktree-reap.sh" <<STUB
#!/usr/bin/env bash
printf '%s @ %s\n' "\$*" "\$PWD" >> "$CALLS"
STUB
chmod +x "$DOT/bin/worktree-reap.sh" "$DOT/hooks/worktree-reap-trigger.sh"

# new_repo <with-worktrees: 1|0>: sets REPO to a fresh repo.
new_repo() {
  REPO="$(mktemp -d "$TMP/repo.XXXXXX")"
  git init -q "$REPO"
  [ "$1" = 1 ] && mkdir -p "$REPO/.worktrees"
  : >"$CALLS"
}

calls() { grep -c . "$CALLS" 2>/dev/null || true; }

# run_hook <expected-calls> [VAR=val ...]: run the hook, then wait for the
# detached sweep to land. The count is given rather than inferred: waiting for
# the log to merely exist returns at once on every run after the first, which
# turns a throttle regression into a pass.
run_hook() {
  local want="$1" out; shift
  out="$(env CLAUDE_PROJECT_DIR="$REPO" "$@" bash "$DOT/hooks/worktree-reap-trigger.sh" 2>&1)"; HOOK_RC=$?
  HOOK_OUT="$out"
  for _ in $(seq 1 100); do
    [ "$(calls)" -ge "$want" ] && break
    sleep 0.05
  done
  # A "should not sweep" case has nothing to wait for; give the child a moment
  # to prove it wrong.
  [ "$want" = 0 ] && sleep 0.3
  return 0
}

# --- the safe form: --apply, no --force, no path, run from the main tree ---
new_repo 1
run_hook 1
[ "$HOOK_RC" = 0 ] || bad "must exit 0, got $HOOK_RC"
[ "$(cat "$CALLS")" = "--apply @ $REPO" ] \
  && ok "sweeps with --apply, no path, from the main tree" || bad "invocation was: $(cat "$CALLS")"
grep -q "worktree-reap" <<<"$HOOK_OUT" && ok "says it started" || bad "no start line: $HOOK_OUT"

# --- throttled: a second start inside the interval does not sweep ---
run_hook 0
[ "$(calls)" = 1 ] && ok "throttled inside the interval" || bad "second start swept ($(calls) calls)"

# --- the interval elapsing sweeps again ---
run_hook 2 WORKTREE_REAP_INTERVAL_SECS=0
[ "$(calls)" = 2 ] && ok "sweeps again once the interval elapses" || bad "interval 0 gave $(calls) calls"

# --- the log records what the sweep decided ---
log="$REPO/.git/worktree-reap.log"
for _ in $(seq 1 100); do grep -q "exit 0" "$log" 2>/dev/null && break; sleep 0.05; done
grep -q "sweep started by SessionStart hook" "$log" && grep -q "exit 0" "$log" \
  && ok "logs the sweep beside the git dir" || bad "log was: $(cat "$log" 2>/dev/null)"

# --- the off switch leaves no stamp ---
new_repo 1
run_hook 0 WORKTREE_REAP_TRIGGER_OFF=1
[ "$(calls)" = 0 ] && [ ! -e "$REPO/.git/worktree-reap.stamp" ] \
  && ok "WORKTREE_REAP_TRIGGER_OFF disables the sweep" || bad "off switch ignored"

# --- inert in a repo without .worktrees/ ---
new_repo 0
run_hook 0
[ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && [ "$(calls)" = 0 ] && [ ! -e "$REPO/.git/worktree-reap.stamp" ] \
  && ok "inert without .worktrees/" || bad "swept a repo with no .worktrees/: rc=$HOOK_RC out=$HOOK_OUT"

# --- the reaper is dotclaude's, never the repo's own ---
new_repo 1
mkdir -p "$REPO/bin"
printf '#!/usr/bin/env bash\necho repo-copy >> %q\n' "$CALLS" >"$REPO/bin/worktree-reap.sh"
chmod +x "$REPO/bin/worktree-reap.sh"
run_hook 1
grep -q "repo-copy" "$CALLS" && bad "ran the repo's own bin/worktree-reap.sh" || ok "ignores the repo's own bin/worktree-reap.sh"

# --- found through a symlink, as ~/.claude/hooks is installed ---
new_repo 1
mkdir -p "$TMP/home/.claude"
ln -sfn "$DOT/hooks" "$TMP/home/.claude/hooks"
out="$(env CLAUDE_PROJECT_DIR="$REPO" bash "$TMP/home/.claude/hooks/worktree-reap-trigger.sh" 2>&1)"
for _ in $(seq 1 100); do [ "$(calls)" -ge 1 ] && break; sleep 0.05; done
[ "$(calls)" = 1 ] && ok "resolves the reaper through a symlinked hook" || bad "symlinked hook ran $(calls) sweeps"

# --- no reaper beside the hook: silent, exit 0 ---
new_repo 1
mv "$DOT/bin/worktree-reap.sh" "$DOT/bin/worktree-reap.sh.off"
run_hook 0
[ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && ok "silent without a reaper" || bad "no reaper: rc=$HOOK_RC out=$HOOK_OUT"
mv "$DOT/bin/worktree-reap.sh.off" "$DOT/bin/worktree-reap.sh"

# --- outside a git repo: exit 0 ---
REPO="$(mktemp -d "$TMP/nogit.XXXXXX")"
run_hook 0
[ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && ok "exits 0 outside a git repo" || bad "non-repo: rc=$HOOK_RC out=$HOOK_OUT"

# --- registered globally ---
python3 - "$HERE/../settings.json" <<'PY' && ok "registered under SessionStart in settings.json" || bad "not registered under SessionStart"
import json, sys
cfg = json.load(open(sys.argv[1]))
cmds = [h.get("command", "") for g in cfg["hooks"]["SessionStart"] for h in g["hooks"]]
sys.exit(0 if any("hooks/worktree-reap-trigger.sh" in c for c in cmds) else 1)
PY

[ "$fail" = 0 ] && echo "worktree-reap-trigger: all cases passed"
exit "$fail"
