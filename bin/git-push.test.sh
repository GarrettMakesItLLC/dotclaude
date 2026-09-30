#!/usr/bin/env bash
# Self-test for git-push.sh against a local bare remote: the hook runs first and
# on its own, a failing hook pushes nothing, the hook gets git's stdin, a push
# that did not land is reported as such, and the log names itself.
#   bash bin/git-push.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GP="$HERE/git-push.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

export GIT_PUSH_VERIFY_BACKOFF_S=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q --bare "$TMP/remote.git"
git init -q -b work "$TMP/repo"
cd "$TMP/repo" || exit 1
git remote add origin "$TMP/remote.git"
mkdir -p .hooks
git config core.hooksPath .hooks
git commit -q --allow-empty -m one

HOOKLOG="$TMP/hook.log"
cat > .hooks/pre-push <<H
#!/usr/bin/env bash
echo "args: \$1 \$2" >> "$HOOKLOG"
cat >> "$HOOKLOG"
exit \${HOOK_EXIT:-0}
H
chmod +x .hooks/pre-push

remote_sha() { git --git-dir="$TMP/remote.git" rev-parse --verify --quiet "refs/heads/$1" || true; }
run() { OUT="$("$GP" "$@" 2>&1)"; RC=$?; }

echo "git-push: a passing hook runs first, then the push lands and is verified"
: > "$HOOKLOG"
run origin work
[ "$RC" = 0 ] && ok "exits 0" || bad "rc=$RC $OUT"
[ "$(remote_sha work)" = "$(git rev-parse HEAD)" ] && ok "the ref moved" || bad "ref did not move"
grep -q "✓ origin refs/heads/work is at" <<<"$OUT" && ok "the landing is stated" || bad "no ✓: $OUT"
grep -q "^refs/heads/work $(git rev-parse HEAD) refs/heads/work " "$HOOKLOG" && ok "the hook got git's stdin: local ref, sha, remote ref" || bad "hook stdin: $(cat "$HOOKLOG")"
[ "$(grep -c '^args: origin ' "$HOOKLOG")" = 1 ] && ok "the hook ran exactly once (the push itself skips it)" || bad "hook runs: $(cat "$HOOKLOG")"

echo "git-push: a bare invocation resolves the branch and remote"
git commit -q --allow-empty -m two
git config branch.work.remote origin
git config branch.work.merge refs/heads/work
: > "$HOOKLOG"
run
[ "$RC" = 0 ] && [ "$(remote_sha work)" = "$(git rev-parse HEAD)" ] && ok "pushes the current branch to origin" || bad "bare: rc=$RC $OUT"

echo "git-push: a failing hook pushes nothing and its code is returned"
git commit -q --allow-empty -m three
before="$(remote_sha work)"
HOOK_EXIT=7 run origin work
[ "$RC" = 7 ] && ok "exit code is the hook's" || bad "rc=$RC $OUT"
[ "$(remote_sha work)" = "$before" ] && ok "the remote is untouched" || bad "pushed past a failing hook"
grep -q 'nothing was pushed' <<<"$OUT" && ok "says nothing was pushed" || bad "message: $OUT"

echo "git-push: a rejected push is reported as not landed"
git init -q --bare "$TMP/strict.git"
printf '#!/bin/sh\nexit 1\n' > "$TMP/strict.git/hooks/pre-receive"; chmod +x "$TMP/strict.git/hooks/pre-receive"
git remote add strict "$TMP/strict.git"
run strict work
[ "$RC" != 0 ] && grep -q 'the push did NOT land' <<<"$OUT" && ok "exit non-zero and the mismatch is named" || bad "rejected: rc=$RC $OUT"

echo "git-push: a remote the verifier cannot read is not a pass"
git remote add ghost "$TMP/does-not-exist.git"
run ghost work
[ "$RC" != 0 ] && ok "a failed push to an unreadable remote fails" || bad "ghost: rc=$RC $OUT"

echo "git-push: forms it cannot verify push as-is and say so"
run --dry-run origin work
[ "$RC" = 0 ] && grep -q 'verification skipped (--dry-run)' <<<"$OUT" && ok "--dry-run is skipped, named" || bad "dry-run: rc=$RC $OUT"

echo "git-push: a detached HEAD without a refspec refuses before anything runs"
git checkout -q --detach
: > "$HOOKLOG"
run
[ "$RC" = 1 ] && [ ! -s "$HOOKLOG" ] && ok "refused; the hook did not run" || bad "detached: rc=$RC $OUT"
git checkout -q work

echo "git-push: the log names itself and starts with a nonce"
log="$(sed -n 's/^→ push log: //p' <<<"$OUT" | head -1)"
[ -n "$log" ] && head -1 "$log" | grep -q '^nonce:' && ok "log path printed, nonce first" || bad "log: $log"

[ "$fail" = 0 ] && echo "git-push: all cases passed"
exit "$fail"
