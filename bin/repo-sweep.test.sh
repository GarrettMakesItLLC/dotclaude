#!/usr/bin/env bash
# Self-test for repo-sweep.sh. The failure handling IS the deliverable, so every
# skip reason gets its own fixture and its own assertion — a sweep that silently
# did nothing would otherwise pass a test that only checked the happy path.
#
# Fully local: bare repos as remotes, no network, no GitHub.
# Run:  bash bin/repo-sweep.test.sh
# The scripts under test are bash, and BASH_ENV (set to ~/.bashrc on agent boxes) makes every
# bash child re-source it and re-export the real keys this suite unsets. Without this the
# suite measures the caller's shell, not the script.
unset BASH_ENV
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/repo-sweep.sh"
fail=0

ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WS="$TMP/workspace"; mkdir -p "$WS"
ROSTER="$TMP/repos.tsv"; : > "$ROSTER"

# make_repo <name> <default-branch>  — a bare origin plus a clone in $WS.
make_repo() {
  local name="$1" def="$2"
  local origin="$TMP/remotes/github.com/$name.git" dir="$WS/$name"
  # The path carries `github.com` so the discovery fallback recognises these
  # fixtures as fleet repos without any network.
  mkdir -p "$TMP/remotes/github.com"
  git init --quiet --bare --initial-branch="$def" "$origin"
  git clone --quiet "$origin" "$dir" 2>/dev/null
  git -C "$dir" config user.email t@e.com
  git -C "$dir" config user.name t
  git -C "$dir" checkout -q -B "$def"
  echo one > "$dir/f"; git -C "$dir" add f; git -C "$dir" commit -q -m one
  git -C "$dir" push -q origin "$def"
  git -C "$dir" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$def"
  # The roster is real data, so exercise the real parser.
  printf '%s\t%s\t%s\t%s\n' "GarrettMakesItLLC/$name" product none - >> "$ROSTER"
  printf '%s' "$dir"
}

# advance <name> <branch> — move the remote forward by one commit.
advance() {
  local name="$1" def="$2"
  local tmp="$TMP/adv-$name"
  git clone --quiet "$TMP/remotes/github.com/$name.git" "$tmp"
  git -C "$tmp" config user.email t@e.com; git -C "$tmp" config user.name t
  echo two >> "$tmp/f"; git -C "$tmp" commit -q -am two
  git -C "$tmp" push -q origin "HEAD:$def"
  rm -rf "$tmp"
}

sweep() { "$SCRIPT" --roster "$ROSTER" --workspace "$WS" "$@" 2>&1 | strip; }
row() { grep -E "^  $1 " <<<"$2"; }

# --- 1. The happy path: behind the remote, clean, on the default branch. ----
d="$(make_repo behind main)"; advance behind main
out="$(sweep)"
grep -q "behind .* pulled 1 commit" <<<"$(row behind "$out")" \
  || bad "a clean behind repo should be fast-forwarded, got: $(row behind "$out")"
[ "$(git -C "$d" rev-list --count HEAD)" = 2 ] || bad "the tree did not actually move"
ok "clean + behind: fast-forwarded"

# --- 2. Already current says so, and says nothing moved. -------------------
out="$(sweep --only behind)"
grep -q "already current" <<<"$out" || bad "a current repo should read 'already current', got: $out"
grep -q "Nothing moved" <<<"$out" || bad "a no-op sweep should say nothing moved, got: $out"
ok "already current: reported, and the fast path says nothing moved"

# --- 3. The default branch is read from the REMOTE, not assumed to be main.
d="$(make_repo devrepo dev)"; advance devrepo dev
out="$(sweep --only devrepo)"
grep -q "pulled 1 commit" <<<"$(row devrepo "$out")" \
  || bad "a repo whose default is dev must still be swept, got: $(row devrepo "$out")"
ok "default branch read from the remote (dev, not main)"

# --- 4. Dirty tree: skipped with a file count, and never touched. ----------
d="$(make_repo dirty main)"; advance dirty main
echo local-change >> "$d/f"
out="$(sweep --only dirty)"
grep -q "uncommitted file" <<<"$(row dirty "$out")" || bad "a dirty tree should be skipped by count, got: $(row dirty "$out")"
grep -q local-change "$d/f" || bad "a dirty tree must never be touched"
[ "$(git -C "$d" rev-list --count HEAD)" = 1 ] || bad "a dirty tree must not be pulled"
ok "dirty tree: skipped with a file count, left alone"

# --- 5. Not on the default branch: named, not corrected. ------------------
d="$(make_repo sidebranch main)"; advance sidebranch main
git -C "$d" checkout -q -b feature/wip
out="$(sweep --only sidebranch)"
grep -q "on feature/wip, default is main" <<<"$(row sidebranch "$out")" \
  || bad "should name the branch it found, got: $(row sidebranch "$out")"
[ "$(git -C "$d" symbolic-ref --short HEAD)" = feature/wip ] || bad "must never switch branches"
ok "off the default branch: named, never switched"

# --- 6. Diverged: ahead/behind counts, no merge, no rebase, no force. -----
d="$(make_repo diverged main)"; advance diverged main
echo mine >> "$d/f"; git -C "$d" commit -q -am mine
out="$(sweep --only diverged)"
grep -q "diverged: 1 ahead, 1 behind" <<<"$(row diverged "$out")" \
  || bad "diverged should report both counts, got: $(row diverged "$out")"
[ "$(git -C "$d" rev-parse HEAD)" = "$(git -C "$d" rev-parse refs/heads/main)" ] || bad "diverged must not be rewritten"
ok "diverged: both counts reported, nothing rewritten"

# --- 7. Detached HEAD. ----------------------------------------------------
d="$(make_repo detached main)"
git -C "$d" checkout -q --detach HEAD
out="$(sweep --only detached)"
grep -q "detached HEAD" <<<"$(row detached "$out")" || bad "detached HEAD should be its own reason, got: $(row detached "$out")"
ok "detached HEAD: skipped with its own reason"

# --- 8. Active linked worktrees — the one that matters most on this box.
#        Sibling agents resolve node_modules upward from the main checkout. ---
d="$(make_repo hasworktrees main)"; advance hasworktrees main
git -C "$d" worktree add -q "$WS/wt-a" -b wt-a
git -C "$d" worktree add -q "$WS/wt-b" -b wt-b
out="$(sweep --only hasworktrees)"
grep -q "2 active worktree" <<<"$(row hasworktrees "$out")" \
  || bad "should count the linked worktrees, got: $(row hasworktrees "$out")"
grep -q "node_modules" <<<"$(row hasworktrees "$out")" || bad "should say WHY, not just that it skipped"
[ "$(git -C "$d" rev-list --count HEAD)" = 1 ] || bad "must not pull under active worktrees"
ok "active worktrees: counted, skipped, and the reason is the why"

# --- 9. A linked worktree handed in directly is not the main checkout. ----
out="$(sweep --only wt-a)"
grep -q "linked worktree" <<<"$out" || bad "a worktree should never be swept as if it were the checkout, got: $out"
ok "a linked worktree is never driven as the main checkout"

# --- 10. A broken remote is a skip with a reason, not a retry loop or an
#         abort that costs every later repo its report. --------------------
d="$(make_repo broken main)"
git -C "$d" remote set-url origin "$TMP/does-not-exist.git"
git -C "$d" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null
out="$(sweep)"
grep -qE "skipped — (fetch failed|could not read the default branch)" <<<"$(row broken "$out")" \
  || bad "an unreachable remote should skip with a reason, got: $(row broken "$out")"
grep -q "^  behind " <<<"$out" || bad "one broken repo must not cost the others their rows"
ok "unreachable remote: skipped with a reason, the run continues"

# --- 11. --dry-run decides and reports, and changes nothing. --------------
d="$(make_repo dryrun main)"; advance dryrun main
out="$(sweep --only dryrun --dry-run)"
grep -q "would fast-forward" <<<"$(row dryrun "$out")" || bad "--dry-run should say what it would do, got: $(row dryrun "$out")"
[ "$(git -C "$d" rev-list --count HEAD)" = 1 ] || bad "--dry-run must not move anything"
ok "--dry-run: decides and reports, moves nothing"

# --- 12. Deps are off by default, and only run where a repo actually moved.
d="$(make_repo depsrepo main)"; advance depsrepo main
sed -i 's|^GarrettMakesItLLC/depsrepo\tproduct\tnone|GarrettMakesItLLC/depsrepo\tproduct\tnpm|' "$ROSTER"
BIN="$TMP/stubbin"; mkdir -p "$BIN"
cat > "$BIN/npm" <<STUB
#!/usr/bin/env bash
echo "npm \$*" >> "$TMP/npm-calls"
exit 0
STUB
chmod +x "$BIN/npm"
PATH="$BIN:$PATH" NODE_AUTH_TOKEN=stub sweep --only depsrepo >/dev/null
[ -f "$TMP/npm-calls" ] && bad "deps must be off by default"
git -C "$d" reset --hard -q HEAD~1
PATH="$BIN:$PATH" NODE_AUTH_TOKEN=stub sweep --only depsrepo --deps >/dev/null
grep -q "npm ci" "$TMP/npm-calls" 2>/dev/null || bad "--deps should install where the repo moved"
ok "--deps: off by default, and only after a repo moved"

# --- 13. An empty token is worse than a missing one: skip, do not half-install.
git -C "$d" reset --hard -q HEAD~1 2>/dev/null
rm -f "$TMP/npm-calls"
out="$(env -u NODE_AUTH_TOKEN -u GH_TOKEN PATH="$BIN:$PATH" "$SCRIPT" \
        --roster "$ROSTER" --workspace "$WS" --only depsrepo --deps 2>&1 | strip)"
[ -f "$TMP/npm-calls" ] && bad "must not run npm ci with no packages token"
grep -q "no NODE_AUTH_TOKEN" <<<"$out" || bad "should say why the install was skipped, got: $out"
ok "no packages token: install skipped rather than silently half-done"

# --- 14. Two checkouts of one repo are surfaced, not silently merged into
#         one ambiguous row. -----------------------------------------------
mkdir -p "$WS/Tools"
git clone --quiet "$TMP/remotes/github.com/behind.git" "$WS/Tools/behind" 2>/dev/null
out="$(sweep)"
grep -q "checked out at more than one path" <<<"$out" \
  || bad "two checkouts of one repo should be called out, got: $out"
grep -q "Tools/behind" <<<"$out" || bad "the duplicate row should name its path"
ok "one repo at two paths: both rows labelled, and the hazard named"

# --- 15. Usage. -----------------------------------------------------------
"$SCRIPT" --help >/dev/null 2>&1 || bad "--help should exit 0"
"$SCRIPT" --nonsense >/dev/null 2>&1 && bad "an unknown option should be refused"
ok "usage: --help exits 0, an unknown option is refused"

if [ "$fail" = 0 ]; then
  echo "repo-sweep: all cases passed"
fi
exit "$fail"
