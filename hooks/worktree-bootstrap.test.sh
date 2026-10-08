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
log_path="$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    ctx = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
except Exception:
    sys.exit(0)
for line in ctx.splitlines():
    if line.startswith("Log: "):
        print(line[5:])
')"
[ -n "$log_path" ] || { echo "FAIL (slow script): hook did not name a log path: $out"; fail=1; }
rc_path="$(printf '%s' "$log_path" | sed 's/worktree-bootstrap\.log$/worktree-bootstrap.rc/')"
if [ -n "$log_path" ]; then
  wait_for "$rc_path" || { echo "FAIL (slow script): rc marker never appeared at $rc_path"; fail=1; }
  [ "$(cat "$rc_path" 2>/dev/null)" = 0 ] \
    || { echo "FAIL (slow script): rc marker did not read 0: $(cat "$rc_path" 2>/dev/null)"; fail=1; }
  grep -q 'done' "$log_path" 2>/dev/null \
    || { echo "FAIL (slow script): the script's own output was not captured in the log"; fail=1; }
fi

# --- a relative target resolves against the SHELL's cwd from the payload, not
# the project dir: an agent inside one worktree creating a sibling.
rm -f "$RECORD"
mkdir -p "$PROJ/.worktrees/sib"
CLAUDE_PROJECT_DIR="$PROJ" python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))
' "git worktree add ../sib -b feat/sib" "$PROJ/.worktrees/wt" | CLAUDE_PROJECT_DIR="$PROJ" "$HOOK" >/dev/null 2>&1
wait_for "$RECORD" && [ "$(cat "$RECORD")" = "$PROJ/.worktrees/wt/../sib" ] \
  || { echo "FAIL (payload cwd): setup ran with '$(cat "$RECORD" 2>/dev/null)', wanted the sibling"; fail=1; }

# --- a repo with .claude/repo.json is primed by dotclaude's SHARED script,
# even when it also carries its own bin/setup-worktree.sh.
MAN="$TMP/manifest-repo"
mk_repo "$MAN" LOCAL
mkdir -p "$MAN/.claude"
echo '{ "worktree": { "strategy": "install", "install": "true" } }' >"$MAN/.claude/repo.json"
git -C "$MAN" add -A && git -C "$MAN" commit --quiet -m manifest
git -C "$MAN" worktree add --quiet "$MAN/.worktrees/wt" -b feat/m
rm -f "$XREPO_RECORD"
out="$(CHECK_LOCK_DIR="$TMP/locks" CLAUDE_PROJECT_DIR="$MAN" python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))
' "git -C $MAN worktree add $MAN/.worktrees/wt -b feat/m" \
  | CHECK_LOCK_DIR="$TMP/locks" CLAUDE_PROJECT_DIR="$MAN" "$HOOK" 2>/dev/null)"
mrc="$(git -C "$MAN/.worktrees/wt" rev-parse --path-format=absolute --git-dir)/worktree-bootstrap.rc"
wait_for "$mrc" || sleep 3
[ -f "$XREPO_RECORD" ] && { echo "FAIL (manifest): the repo-local script ran: $(cat "$XREPO_RECORD")"; fail=1; }
grep -q 'bin/setup-worktree.sh' <<<"$out" && ! grep -q "$MAN/bin" <<<"$out" \
  || { echo "FAIL (manifest): hook did not name the shared script: $out"; fail=1; }
[ "$(cat "$mrc" 2>/dev/null)" = 0 ] || { echo "FAIL (manifest): shared script rc=$(cat "$mrc" 2>/dev/null) log=$(cat "${mrc%.rc}.log" 2>/dev/null)"; fail=1; }


# --- #497: a target that is a shell variable (a for-loop) never resolves from
# the literal command string. The hook must sweep the repo's linked worktrees
# and prime every one lacking a rc marker and node_modules, leave primed ones
# alone, and stay inert for a repo with no setup script.
LOOP="$TMP/loop-repo"
mk_repo "$LOOP" LOOP
for d in w1 w2 w3; do git -C "$LOOP" worktree add --quiet "$LOOP/.worktrees/$d" -b "feat/$d"; done
mkdir -p "$LOOP/.worktrees/w2/node_modules"          # already installed
git -C "$LOOP/.worktrees/w3" rev-parse --path-format=absolute --git-dir \
  | { read -r gd; echo 0 > "$gd/worktree-bootstrap.rc"; }   # already bootstrapped
: > "$TMP/loop-calls"
cat > "$LOOP/bin/setup-worktree.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$TMP/loop-calls"
EOF
loop_out="$(CLAUDE_PROJECT_DIR="$LOOP" python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))
' 'for d in w1 w2 w3; do git worktree add -q .worktrees/$d -b feat/$d; done' "$LOOP" \
  | CLAUDE_PROJECT_DIR="$LOOP" "$HOOK" 2>/dev/null)"
[ $? = 0 ] || { echo "FAIL (loop): hook exited non-zero"; fail=1; }
tries=100; while [ ! -s "$TMP/loop-calls" ] && [ $tries -gt 0 ]; do sleep 0.05; tries=$((tries-1)); done
sleep 0.3
[ "$(cat "$TMP/loop-calls")" = "$LOOP/.worktrees/w1" ] \
  || { echo "FAIL (loop): wanted only w1 primed, got: $(cat "$TMP/loop-calls")"; fail=1; }
grep -q "$LOOP/.worktrees/w1" <<<"$loop_out" \
  || { echo "FAIL (loop): no priming message naming w1: $loop_out"; fail=1; }

# A loop in a repo with no setup script stays silent (inert, not opted in).
# stays silent.
NOS="$TMP/loop-noscript"
mkdir -p "$NOS"; git init --quiet "$NOS"
git -C "$NOS" config user.email t@t; git -C "$NOS" config user.name t
echo x > "$NOS/f"; git -C "$NOS" add -A; git -C "$NOS" commit --quiet -m init
git -C "$NOS" worktree add --quiet "$NOS/.worktrees/w1" -b feat/w1
nos_out="$(CLAUDE_PROJECT_DIR="$NOS" python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))
' 'for d in w1; do git worktree add -q .worktrees/$d; done' "$NOS" \
  | CLAUDE_PROJECT_DIR="$NOS" "$HOOK" 2>/dev/null)"
[ -z "$nos_out" ] || { echo "FAIL (loop, no script): wanted silence, got: $nos_out"; fail=1; }

# --- #530: only a real `git … worktree add` primes or sweeps. A `git add` run
# inside a `.worktrees/` path, or the words in an argument, must neither prime
# nor sweep the repo's other (unprimed) worktrees.
git -C "$LOOP" worktree add --quiet "$LOOP/.worktrees/w4" -b feat/w4   # unprimed
: > "$TMP/loop-calls"
for c in \
  "cd $LOOP/.worktrees/w4 && git add README.md && git rebase --continue" \
  'B=$PWD; git -C "$B" add f && git commit -m "worktree add docs"' \
  'echo "git worktree add" > $TMP/note && git add .worktrees/x' \
  'grep -rn "worktree add" $HOME/notes'; do
  sweep_out="$(CLAUDE_PROJECT_DIR="$LOOP" python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))
' "$c" "$LOOP" | CLAUDE_PROJECT_DIR="$LOOP" "$HOOK" 2>/dev/null)"
  sleep 0.3
  [ -s "$TMP/loop-calls" ] && { echo "FAIL (#530): '$c' primed: $(cat "$TMP/loop-calls")"; fail=1; : > "$TMP/loop-calls"; }
  [ -z "$sweep_out" ] || { echo "FAIL (#530): '$c' printed: $sweep_out"; fail=1; }
done
# A global option between git and worktree is still an invocation.
: > "$TMP/loop-calls"
CLAUDE_PROJECT_DIR="$LOOP" python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))
' "git -C $LOOP worktree add -q $LOOP/.worktrees/w5 -b feat/w5" "$LOOP" >/dev/null
git -C "$LOOP" worktree add --quiet "$LOOP/.worktrees/w5" -b feat/w5
CLAUDE_PROJECT_DIR="$LOOP" python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))
' "git -C $LOOP -c core.x=1 worktree add -q $LOOP/.worktrees/w5 -b feat/w5" "$LOOP" \
  | CLAUDE_PROJECT_DIR="$LOOP" "$HOOK" >/dev/null 2>&1
tries=100; while [ ! -s "$TMP/loop-calls" ] && [ $tries -gt 0 ]; do sleep 0.05; tries=$((tries-1)); done
[ "$(cat "$TMP/loop-calls")" = "$LOOP/.worktrees/w5" ] \
  || { echo "FAIL (#530): git -C … -c … worktree add did not prime w5: $(cat "$TMP/loop-calls")"; fail=1; }

# --- #533: a repo with no manifest whose own bin/setup-worktree.sh IS
# dotclaude's shared script (dotclaude itself) is not opted in: no priming
# message, so no rc marker the agent is told to wait for.
SELF="$TMP/self-repo"
mkdir -p "$SELF/bin"; git init --quiet "$SELF"
git -C "$SELF" config user.email t@t; git -C "$SELF" config user.name t
ln -s "$(cd "$(dirname "$HOOK")/../bin" && pwd)/setup-worktree.sh" "$SELF/bin/setup-worktree.sh"
echo x > "$SELF/f"; git -C "$SELF" add -A; git -C "$SELF" commit --quiet -m init
git -C "$SELF" worktree add --quiet "$SELF/.worktrees/w1" -b feat/w1
self_out="$(CLAUDE_PROJECT_DIR="$SELF" python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))
' "git worktree add .worktrees/w1 -b feat/w1" "$SELF" | CLAUDE_PROJECT_DIR="$SELF" "$HOOK" 2>/dev/null)"
[ -z "$self_out" ] || { echo "FAIL (#533): a repo without a manifest was primed: $self_out"; fail=1; }
gd="$(git -C "$SELF/.worktrees/w1" rev-parse --path-format=absolute --git-dir)"
sleep 0.3
[ ! -e "$gd/worktree-bootstrap.rc" ] || { echo "FAIL (#533): rc marker written: $(cat "$gd/worktree-bootstrap.rc")"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "worktree-bootstrap: all cases passed"
fi
exit "$fail"
