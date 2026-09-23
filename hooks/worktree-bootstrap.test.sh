#!/usr/bin/env bash
# Self-test for worktree-bootstrap.sh. Feeds PostToolUse payloads through the
# hook and asserts it (a) always exits 0 immediately (fail-open, and never
# blocks on the priming script — #408) and (b) runs the repo's
# bin/setup-worktree.sh with the correct target only on a `git worktree add`,
# DETACHED: the hook itself never waits for it, so every assertion about what
# the script did polls for it rather than expecting it done the instant the
# hook returns.
# Run locally or in CI:  bash hooks/worktree-bootstrap.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/worktree-bootstrap.sh"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Poll for a file the detached script is expected to (eventually) write,
# rather than assuming it exists the instant the hook process exits — that is
# the exact synchronous assumption #408 removes.
wait_for() {
  local file="$1" tries=100
  while [ ! -f "$file" ] && [ "$tries" -gt 0 ]; do
    sleep 0.05
    tries=$((tries - 1))
  done
  [ -f "$file" ]
}

# A fake project with an instrumented bin/setup-worktree.sh that records its arg.
PROJ="$TMP/proj"
mkdir -p "$PROJ/bin" "$PROJ/.worktrees/wt"
RECORD="$TMP/record"
cat > "$PROJ/bin/setup-worktree.sh" <<EOF
#!/usr/bin/env bash
printf '%s' "\$1" > "$RECORD"
EOF
chmod +x "$PROJ/bin/setup-worktree.sh"

# Run the hook with a payload built from a command string. Asserts exit 0 and
# (if expect_target non-empty) that setup-worktree.sh recorded that target —
# polling, since the hook returns before the detached script has necessarily
# finished (or even started).
run() {
  local desc="$1" cmd="$2" expect_target="$3" got
  rm -f "$RECORD"
  CLAUDE_PROJECT_DIR="$PROJ" python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))
' "$cmd" | CLAUDE_PROJECT_DIR="$PROJ" "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" != 0 ]; then
    echo "FAIL ($desc): hook exited $got, must always be 0"; fail=1; return
  fi
  if [ -z "$expect_target" ]; then
    # A non-match: give a beat for a wrongly-fired background job to show up,
    # then assert it never did.
    sleep 0.2
    [ -f "$RECORD" ] && { echo "FAIL ($desc): setup ran when it should not have"; fail=1; }
    return
  fi
  wait_for "$RECORD" || { echo "FAIL ($desc): setup never ran (no $RECORD after polling)"; fail=1; return; }
  local recorded; recorded="$(cat "$RECORD")"
  if [ "$recorded" != "$expect_target" ]; then
    echo "FAIL ($desc): setup ran with '$recorded', wanted '$expect_target'"; fail=1
  fi
}

# --- the worktree's OWN repo owns the setup script, not the session's (#312).
# Two real repos, each with an instrumented script. A session whose project is
# A creates a worktree in B; B's script must run, not A's.
mk_repo() {
  local root="$1" tag="$2"
  mkdir -p "$root/bin"
  git init --quiet "$root"
  git -C "$root" config user.email t@t
  git -C "$root" config user.name t
  cat > "$root/bin/setup-worktree.sh" <<EOF
#!/usr/bin/env bash
printf '%s %s' "$tag" "\$1" > "$XREPO_RECORD"
EOF
  chmod +x "$root/bin/setup-worktree.sh"
  echo x > "$root/f"
  git -C "$root" add -A
  git -C "$root" commit --quiet -m init
}

XREPO_RECORD="$TMP/xrecord"
A="$TMP/repo-a"; B="$TMP/repo-b"
mk_repo "$A" A
mk_repo "$B" B
git -C "$B" worktree add --quiet "$B/.worktrees/wt" -b feat/x
rm -f "$XREPO_RECORD"
CLAUDE_PROJECT_DIR="$A" python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))
' "git -C $B worktree add $B/.worktrees/wt -b feat/x" \
  | CLAUDE_PROJECT_DIR="$A" "$HOOK" >/dev/null 2>&1
xgot=$?
[ "$xgot" = 0 ] || { echo "FAIL (cross-repo): hook exited $xgot"; fail=1; }
wait_for "$XREPO_RECORD" || { echo "FAIL (cross-repo): setup never ran"; fail=1; }
xrec=""; [ -f "$XREPO_RECORD" ] && xrec="$(cat "$XREPO_RECORD")"
case "$xrec" in
  "B $B/.worktrees/wt") ;;
  "A "*) echo "FAIL (cross-repo): ran the SESSION repo's script: '$xrec'"; fail=1 ;;
  *) echo "FAIL (cross-repo): wanted B's script, got '$xrec'"; fail=1 ;;
esac

# A repo with no setup script must stay a no-op even when the session's repo
# HAS one — priming a tree that should be left alone is the other half of #312.
C="$TMP/repo-c"
mkdir -p "$C"; git init --quiet "$C"
git -C "$C" config user.email t@t; git -C "$C" config user.name t
echo x > "$C/f"; git -C "$C" add -A; git -C "$C" commit --quiet -m init
git -C "$C" worktree add --quiet "$C/.worktrees/wt" -b feat/y
rm -f "$XREPO_RECORD"
CLAUDE_PROJECT_DIR="$A" python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))
' "git -C $C worktree add $C/.worktrees/wt -b feat/y" \
  | CLAUDE_PROJECT_DIR="$A" "$HOOK" >/dev/null 2>&1
sleep 0.2
[ -f "$XREPO_RECORD" ] \
  && { echo "FAIL (no-script repo): primed with '$(cat "$XREPO_RECORD")'"; fail=1; }

# Matches -> setup runs with absolute target, both flag orderings.
run "path then -b"  "git worktree add .worktrees/wt -b feat/x"  "$PROJ/.worktrees/wt"
run "-b then path"  "git worktree add -b feat/x .worktrees/wt"  "$PROJ/.worktrees/wt"
run "absolute path" "git worktree add $PROJ/.worktrees/wt -b feat/x"  "$PROJ/.worktrees/wt"

# Non-matches -> no-op (setup must NOT run), still exit 0.
run "unrelated cmd" "git status"                         ""
run "worktree list" "git worktree list"                  ""
run "target missing" "git worktree add .worktrees/nope -b feat/y"  ""

# No opt-in script -> no-op even on a real add.
PROJ2="$TMP/proj2"; mkdir -p "$PROJ2/.worktrees/wt"
rm -f "$RECORD"
CLAUDE_PROJECT_DIR="$PROJ2" python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))
' "git worktree add .worktrees/wt -b feat/z" | CLAUDE_PROJECT_DIR="$PROJ2" "$HOOK" >/dev/null 2>&1
[ $? = 0 ] || { echo "FAIL (no script): non-zero exit"; fail=1; }

# Garbage input -> fail open (exit 0).
printf 'not json' | "$HOOK" >/dev/null 2>&1
[ $? = 0 ] || { echo "FAIL (garbage input): non-zero exit"; fail=1; }

# --- #408: the hook returns immediately even when the priming script is SLOW,
# and it names the log/rc-marker location it detached into.
SLOW="$TMP/slow"
mkdir -p "$SLOW/bin" "$SLOW/.worktrees/wt"
cat > "$SLOW/bin/setup-worktree.sh" <<'EOF'
#!/usr/bin/env bash
sleep 5
printf 'done\n'
exit 0
EOF
chmod +x "$SLOW/bin/setup-worktree.sh"

start="$(date +%s)"
out="$(CLAUDE_PROJECT_DIR="$SLOW" python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))
' "git worktree add .worktrees/wt -b feat/slow" \
  | CLAUDE_PROJECT_DIR="$SLOW" "$HOOK" 2>&1)"
slow_got=$?
elapsed=$(( $(date +%s) - start ))
[ "$slow_got" = 0 ] || { echo "FAIL (slow script): hook exited $slow_got"; fail=1; }
[ "$elapsed" -lt 3 ] \
  || { echo "FAIL (slow script): hook took ${elapsed}s to return — it must never wait on the priming script"; fail=1; }
log_path="$(printf '%s' "$out" | sed -n 's/^  Log: //p')"
[ -n "$log_path" ] || { echo "FAIL (slow script): hook did not name a log path: $out"; fail=1; }
rc_path="$(printf '%s' "$log_path" | sed 's/worktree-bootstrap\.log$/worktree-bootstrap.rc/')"
if [ -n "$log_path" ]; then
  wait_for "$rc_path" || { echo "FAIL (slow script): rc marker never appeared at $rc_path"; fail=1; }
  [ "$(cat "$rc_path" 2>/dev/null)" = 0 ] \
    || { echo "FAIL (slow script): rc marker did not read 0: $(cat "$rc_path" 2>/dev/null)"; fail=1; }
  grep -q 'done' "$log_path" 2>/dev/null \
    || { echo "FAIL (slow script): the script's own output was not captured in the log"; fail=1; }
fi

if [ "$fail" = 0 ]; then
  echo "worktree-bootstrap: all cases passed"
fi
exit "$fail"
