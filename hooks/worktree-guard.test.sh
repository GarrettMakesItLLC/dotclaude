#!/usr/bin/env bash
# Self-test for worktree-guard.sh. Builds throwaway git repos, feeds a
# PreToolUse payload through the hook, and asserts the exit code
# (2 = blocked, 0 = allowed). Run locally or in CI:
#   bash hooks/worktree-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/worktree-guard.sh"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# want, tool_name, path-key, path, [WORKTREE_GUARD_OFF value]
check() {
  local want="$1" tool="$2" key="$3" path="$4" off="${5:-}" got
  WORKTREE_GUARD_OFF="$off" python3 -c '
import json,sys
print(json.dumps({"tool_name":sys.argv[1],"tool_input":{sys.argv[2]:sys.argv[3]}}))
' "$tool" "$key" "$path" | WORKTREE_GUARD_OFF="$off" "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: want $want, got $got for $tool $key=$path off='$off'"
    fail=1
  fi
}

# --- the guard must fail CLOSED when its own extractor is broken (#319).
# A misplaced import once switched the whole guard off: empty output was
# indistinguishable from "this command writes nothing", so every BLOCK case
# silently passed as allowed. Proven by breaking a copy on purpose.
BROKEN="$TMP/guard-broken.sh"
sed 's/^import json, os, re, shlex, sys$/&\nraise RuntimeError("deliberate breakage")/' \
  "$GUARD" > "$BROKEN"
chmod +x "$BROKEN"
broken_got=$(python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":"echo hello"}}))
' | "$BROKEN" >/dev/null 2>&1; echo $?)
if [ "$broken_got" != "2" ]; then
  echo "FAIL: want 2, got $broken_got for a BROKEN extractor (must fail closed, #319)"
  fail=1
fi
# And the same input through the real guard is allowed, so the case above is
# measuring the breakage rather than the command.
healthy_got=$(python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":"echo hello"}}))
' | "$GUARD" >/dev/null 2>&1; echo $?)
if [ "$healthy_got" != "0" ]; then
  echo "FAIL: want 0, got $healthy_got for 'echo hello' through a healthy guard"
  fail=1
fi

# --- convention repo: .worktrees/ gitignored, one commit, one linked worktree
CONV="$TMP/conv"
mkdir -p "$CONV"
git -C "$CONV" init -q
printf '.worktrees/\n' > "$CONV/.gitignore"
git -C "$CONV" add .gitignore
git -C "$CONV" commit -qm init
git -C "$CONV" worktree add -q "$CONV/.worktrees/wt" -b feat 2>/dev/null
mkdir -p "$CONV/src"

# --- non-convention repo: no .worktrees/ ignore
PLAIN="$TMP/plain"
mkdir -p "$PLAIN/src"
git -C "$PLAIN" init -q
git -C "$PLAIN" commit -qm init --allow-empty

# Should BLOCK (main tree of a convention repo)
check 2 Edit         file_path     "$CONV/src/existing.ts"
check 2 Write        file_path     "$CONV/src/brand-new.ts"      # file need not exist yet
check 2 NotebookEdit notebook_path "$CONV/src/nb.ipynb"

# Should BLOCK — quoting/path-resolution edge cases in the main tree.
mkdir -p "$CONV/dir with space"
check 2 Edit file_path "$CONV/dir with space/x.ts"    # space in path must not break quoting
check 2 Write file_path "$CONV/a/b/c/deep.ts"         # many missing ancestor dirs -> climb to root

# Should BLOCK — convention detected via a GLOBAL gitignore, not the repo's own.
GLOBALIGN="$TMP/globalignore"
printf '.worktrees/\n' > "$GLOBALIGN"
GCONV="$TMP/gconv"
mkdir -p "$GCONV/src"
git -C "$GCONV" init -q
git -C "$GCONV" config core.excludesFile "$GLOBALIGN"   # .worktrees/ ignored globally, not in-repo
git -C "$GCONV" commit -qm init --allow-empty
check 2 Edit file_path "$GCONV/src/app.ts"

# Should ALLOW
check 0 Edit  file_path "$CONV/.worktrees/wt/x.ts"   # inside a linked worktree
check 0 Edit  file_path "$CONV/src/existing.ts" 1     # escape hatch set
check 0 Edit  file_path "$PLAIN/src/app.ts"           # repo doesn't use the convention
check 0 Write file_path "$TMP/loose.txt"              # not in any git repo
check 0 Edit  file_path "$HERE/../CLAUDE.md"          # the dotclaude config repo itself

# Should ALLOW — a linked worktree placed OUTSIDE the repo's .worktrees/ dir.
# The header claims detection is structural (git-dir != git-common-dir), not
# path-name based; this proves it.
git -C "$CONV" worktree add -q "$TMP/external-wt" -b feat-ext 2>/dev/null
check 0 Edit file_path "$TMP/external-wt/x.ts"

# --- Bash coverage (#92): the same guard, driven by scanning `command` for
# write patterns instead of a single file_path.

# Should BLOCK — the exact workaround #92 was filed for: a python3 heredoc
# using open(path, "w") instead of Edit/Write.
check 2 Bash command "python3 - <<'PYEOF'
open('$CONV/src/via-python.ts', 'w').write('x')
PYEOF"

# Should BLOCK — plain shell redirection into the main tree.
check 2 Bash command "echo hi > $CONV/src/redirected.ts"
check 2 Bash command "printf x >> $CONV/src/appended.ts"

# Should BLOCK — sed -i and cp/mv/tee destinations.
check 2 Bash command "sed -i 's/a/b/' $CONV/src/existing.ts"
check 2 Bash command "sed -i -e 's/a/b/' $CONV/src/existing.ts"
check 2 Bash command "sed -i.bak 's/a/b/' $CONV/src/existing.ts"
# Several files after one script: every one of them is a real target.
check 2 Bash command "sed -i 's/a/b/' /tmp/ok.ts $CONV/src/existing.ts"
check 2 Bash command "cp /tmp/whatever.ts $CONV/src/copied.ts"
check 2 Bash command "mv /tmp/whatever.ts $CONV/src/moved.ts"
check 2 Bash command "some-generator | tee $CONV/src/teed.ts"

# Should ALLOW — an arrow is not a redirect, and a `#` comment is prose (#289,
# #271, #258). Each of these blocked on a bare word taken from an arrow's
# right-hand side.
check 0 Bash command "railway variable set X --stdin  # curl -> stdin -> Railway; done"
check 0 Bash command "psql -w -c \"SELECT 1 WHERE c.relname <> 'x';\""
check 0 Bash command "gh api repos/O/R/issues/3 --jq '\"\\(.n) -> \\(.m)\"'"
check 0 Bash command "node -e 'const f=()=>{console.log(1)};f()'"
check 0 Bash command "echo build  # writes dist/out.js -> nowhere real"

# A `#` only opens a comment at the start of a token, so these keep working.
check 2 Bash command "sed -i 's#a#b#' $CONV/src/existing.ts"
check 2 Bash command "curl -s https://x/y#frag > $CONV/src/frag.ts"
# And a real redirect after a comment on an EARLIER line is still a redirect.
check 2 Bash command "# note
echo hi > $CONV/src/afterco.ts"

# Should ALLOW — a read-only Bash command with no write pattern at all.
check 0 Bash command "cat $CONV/src/existing.ts"
check 0 Bash command "git -C $CONV status"

# Should ALLOW — sed's SCRIPT is a program, not a write target (#295, #313).
# The file is absolute and correctly named; only the script looked relative.
check 0 Bash command "sed -i '1s|^node_modules/\$|node_modules|' $CONV/.worktrees/wt/.gitignore"
check 0 Bash command "sed -i \"s/module: 'a',/module: 'b',/\" $CONV/.worktrees/wt/f.ts"
check 0 Bash command "sed -i -e 's/a/b/' -e 's/c/d/' $CONV/.worktrees/wt/f.ts"
check 0 Bash command "sed -i --expression='s/a/b/' $CONV/.worktrees/wt/f.ts"
# A script supplied by -f is a FILE sed reads, not one it writes.
check 0 Bash command "sed -i -f /tmp/script.sed $CONV/.worktrees/wt/f.ts"

# Should ALLOW — `sed` inside another word is not the sed command (#295). A
# hyphen is a word boundary, so a branch name containing `-sed-i-` used to
# make the guard parse `git`, `worktree` and `add` as sed's files — blocking
# its own prescribed remedy.
check 0 Bash command "git -C $CONV worktree add $CONV/.worktrees/w2 issue-295-blocks-sed-i-by-reading"
check 0 Bash command "git -C $CONV log --oneline --grep=sed-i"
check 0 Bash command "grep -r parsed-input $CONV/src"

# Should ALLOW — redirection is present but targets a linked worktree, not the
# main tree; proves Bash candidates go through the same worktree/config-repo
# logic as Edit/Write, not a blanket "any write is bad".
check 0 Bash command "echo hi > $CONV/.worktrees/wt/x.ts"

# Should ALLOW — `2>&1` and `&>` must not be mistaken for a file redirect.
check 0 Bash command "some-command 2>&1"
check 0 Bash command "some-command &> /dev/null"

# Should ALLOW — the escape hatch works for Bash too.
check 0 Bash command "echo hi > $CONV/src/redirected.ts" 1

# --- #140: heredoc bodies are DATA, not further shell syntax — a markdown
# blockquote line ("> word") inside a quoted heredoc must not read as a
# redirect, and prose words must not be mistaken for cp/mv/tee destinations.
check 0 Bash command "gh pr create --title x --body \"\$(cat <<'EOF'
Some prose mentioning graphify, Serena, and grep/Read as bare words.
> A markdown blockquote line that looks like a redirect.
EOF
)\""

# Should still BLOCK — a REAL redirect on the line that OPENS the heredoc
# (outside the body) is unaffected by body-blanking.
check 2 Bash command "cat >> $CONV/src/notes.md <<'EOF'
> this blockquote line must not itself be scanned
EOF"

# --- #143: a leading `cd <dir> &&` changes the effective directory a
# relative write-target resolves against — it must not be judged against the
# hook process's own cwd.

# Should ALLOW — cd into a linked worktree, then write a RELATIVE path; the
# write lands inside the worktree, not the main tree.
check 0 Bash command "cd $CONV/.worktrees/wt && cat >> notes.md <<'EOF'
some content
EOF"

# Should BLOCK — cd into the MAIN tree, then a relative write still lands in
# the main tree.
check 2 Bash command "cd $CONV/src && cat >> notes.md <<'EOF'
some content
EOF"

# Should ALLOW — chained cd's (cd a && cd b) accumulate into the worktree.
check 0 Bash command "cd $CONV && cd .worktrees/wt && echo hi > notes.md"

# Should ALLOW — an unresolvable `cd` target (a variable) makes the guard
# refuse to judge anything relative afterward, rather than guess a root.
# An unresolvable `cd` still BLOCKS: the destination is unknowable, and
# unknowable is the risk — `$VAR` can expand into a sibling worktree. This
# case used to assert allow, which would have let exactly that through; what
# was actually wrong was the MESSAGE, which told the operator to use an
# absolute path they do not have. It now says which case it is (#320).
check 2 Bash command "cd \$SOME_VAR && echo hi > notes.md"
check 2 Bash command "cd - && echo hi > notes.md"

# Should still BLOCK — an ABSOLUTE write-target after an unresolvable `cd`
# is unaffected (never depended on the tracked base to begin with).
check 2 Bash command "cd \$SOME_VAR && echo hi > $CONV/src/absolute.md"

# --- MuscleBuddy#3962: a write-target whose LEADING segment is an unexpanded
# shell expansion decides nothing about which tree it lands in, so climbing it
# for a real ancestor bottoms out at the hook's own cwd. Run from a convention
# main tree, that reinterpreted a target anywhere on disk (a /tmp scratchpad)
# as a main-tree write. These run with cwd INSIDE the main tree, which is the
# only way the misresolution reproduces.
(
  cd "$CONV" || exit 1
  check 0 Bash command 'D=/tmp/somewhere/scratchpad; echo hi > $D/railway.json'
  check 0 Bash command 'echo hi > $HOME/notes.md'
  check 0 Bash command 'echo hi > `pwd`/notes.md'

  # Should still BLOCK — a plain relative target IS resolvable against cwd, and
  # resolving it is the coverage that keeps a bare `echo x > src/f.ts` guarded.
  check 2 Bash command 'echo hi > src/relative.ts'

  # Should still BLOCK — an expansion PAST the leading segment leaves a real
  # ancestor to climb to, so it is judged normally rather than skipped.
  check 2 Bash command 'echo hi > src/$name.ts'
  exit "$fail"
) || fail=1

# Should still BLOCK — an ABSOLUTE path carrying a later expansion still climbs
# to its real ancestor; only the leading-segment case is unresolvable.
check 2 Bash command "echo hi > $CONV/src/\$name.ts"

# Should BLOCK — a leading `~` IS resolvable, so it is expanded rather than
# skipped. HOME points at the convention main tree for this one case.
(
  export HOME="$CONV"
  check 2 Bash command 'echo hi > ~/src/tilde.ts'
  exit "$fail"
) || fail=1

# --- #166: an agent's Bash cwd resets between calls and has been observed
# pointing into a SIBLING worktree the agent never entered, so a RELATIVE
# write-target resolved against it lands in another agent's tree — and resolving
# it that way CLEARS the guard, because a linked worktree is exactly what the
# guard wants to see. Standing in a linked worktree, a relative target with no
# tracked `cd` base must be blocked rather than resolved.
(
  cd "$CONV/.worktrees/wt" || exit 1

  # Should BLOCK — the drift shape: relative target, untrustworthy cwd.
  check 2 Bash command 'echo hi > notes.md'
  check 2 Bash command 'sed -i s/a/b/ src/app.ts'
  check 2 Bash command "cat >> packages/engine/src/index.ts <<'EOF'
some content
EOF"

  # Should ALLOW — naming the tree makes the target attributable again, which
  # is the whole point of the block. Both spellings the message recommends.
  check 0 Bash command "echo hi > $CONV/.worktrees/wt/notes.md"
  check 0 Bash command "cd $CONV/.worktrees/wt && echo hi > notes.md"

  # Should still BLOCK — an absolute main-tree target is judged on its own path,
  # not on the cwd it was issued from.
  check 2 Bash command "echo hi > $CONV/src/absolute.ts"

  # Should ALLOW — no write pattern at all, and the escape hatch still works.
  check 0 Bash command 'cat notes.md'
  check 0 Bash command 'echo hi > notes.md' 1

  # Should ALLOW — a leading shell expansion is still unresolvable rather than
  # relative-to-cwd, so it keeps passing unjudged (MuscleBuddy#3962).
  check 0 Bash command 'D=/tmp/somewhere; echo hi > $D/railway.json'
  exit "$fail"
) || fail=1

# Should ALLOW — same relative write from a linked worktree of a repo that does
# NOT use the convention. The untrusted-cwd block is scoped to the convention,
# exactly as every other rule here is.
git -C "$PLAIN" worktree add -q "$PLAIN/wt" -b feat-plain 2>/dev/null
(
  cd "$PLAIN/wt" || exit 1
  check 0 Bash command 'echo hi > notes.md'
  exit "$fail"
) || fail=1

# Should ALLOW — the config-repo exemption reached THROUGH a directory symlink,
# exactly as production does (~/.claude/hooks -> dotclaude/hooks). Invokes the
# guard via a symlinked parent dir so readlink -f must resolve the chain to find
# the real repo root. A regression here would silently block edits to ~/dotclaude.
ln -s "$HERE" "$TMP/hooks-link"
if ! printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$HERE/../CLAUDE.md" \
     | "$TMP/hooks-link/worktree-guard.sh" >/dev/null 2>&1; then
  echo "FAIL: config-repo exemption did not fire through a symlinked hooks dir"
  fail=1
fi

# --- NetWorthy#223: a Bash command that merely REFERENCES a credential-shaped
# env var name (e.g. $NW_DATABASE_URL, the documented `export DATABASE_URL=
# $NW_DATABASE_URL` pattern from that repo's agent-credentials skill) must not
# be treated as a write pattern by this hook — it has no env-var-name
# deny-list at all, only the write-pattern scan above. The block reported in
# #223 was traced to Claude Code's own built-in worktree-isolation Bash
# safety check (compiled into the CLI binary, outside this repo) misfiring on
# that variable name — NOT to this script. These are characterization tests:
# they must keep passing so a future "fix" for #223 doesn't get misdirected
# into this hook.
check 0 Bash command 'export DATABASE_URL="$NW_DATABASE_URL"'
check 0 Bash command 'export XYZ="$NW_DATABASE_URL"'
check 0 Bash command 'echo "$NW_DATABASE_URL" | wc -c'
check 0 Bash command 'export FOO=bar'
check 0 Bash command 'export XYZ="$HOME"'

# --- #267: an absolute target ignores a leading `cd` base -------------------
# `cd /repo && cat > /tmp/x` writes to /tmp. Joining base onto an already
# absolute path produced `/repo//tmp/x`, which climbed to /repo and blocked a
# legitimate scratchpad write.
check 0 Bash command "cd $CONV && echo hi > /tmp/guard-abs-probe.txt"
check 0 Bash command "cd $CONV/.worktrees/wt && cat > /tmp/guard-abs-probe.txt"
# The same shape with a RELATIVE target still resolves into the tree and blocks.
check 2 Bash command "cd $CONV && echo hi > src/thing.ts"

# --- a `>` inside a quoted argument is data, not a redirect ------------------
# jq/awk/git filters carry `>` in their program text. The operator is never
# quoted, so `> "file"` must still be seen.
check 0 Bash command "cd $CONV && gh issue list --jq '.[]|select(.updatedAt > \"2026-01-01\")'"
check 0 Bash command "cd $CONV && awk '\$1 > 5 {print}' data.txt"
check 2 Bash command "cd $CONV && echo hi > \"src/quoted target.ts\""

if [ "$fail" = 0 ]; then
  
echo "worktree-guard: all cases passed"
fi
exit "$fail"
