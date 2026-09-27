#!/usr/bin/env bash
# Self-test for fleet-lease.sh. Stands up a bare repo as the "remote" and two
# working copies as two machines, then asserts the properties the procedure
# depends on: a take is atomic, a second machine loses loudly, a lease carries
# holder and timestamp, renew and release refuse someone else's lease, and a
# forced release needs a reason.
#   bash bin/fleet-lease.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEASE="$HERE/fleet-lease.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

ok()   { echo "  ok: $1"; }
bad()  { echo "  FAIL: $1"; fail=1; }

git init --quiet --bare "$TMP/remote.git"
for m in alpha beta; do
  git init --quiet "$TMP/$m"
  git -C "$TMP/$m" config user.email "$m@test"
  git -C "$TMP/$m" config user.name "$m"
  git -C "$TMP/$m" remote add origin "$TMP/remote.git"
done

# machine, args...  -> stdout+stderr in $OUT, status in $RC
# Every run names its repo the way a real caller must (dotclaude#426); `run_bare`
# drops that, to test the refusal.
run() {
  local m="$1"; shift
  OUT="$(cd "$TMP/$m" && FLEET_LEASE_REPO="$TMP/remote.git" "$LEASE" "$@" 2>&1)"; RC=$?
}
run_bare() {
  local m="$1"; shift
  OUT="$(cd "$TMP/$m" && env -u FLEET_LEASE_REPO "$LEASE" "$@" 2>&1)"; RC=$?
}

# A target repo whose pre-push hook REFUSES. The lease must still be takeable:
# a lease ref carries no content for that hook to have an opinion about, and
# before #376 the push ran it — in MuscleBuddy a full typecheck chain — then
# silently failed to land while the caller believed it had.
git init --quiet "$TMP/hooked"
git -C "$TMP/hooked" config user.email hooked@test
git -C "$TMP/hooked" config user.name hooked
git -C "$TMP/hooked" remote add origin "$TMP/remote.git"
mkdir -p "$TMP/hooked/.git/hooks"
cat > "$TMP/hooked/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
echo "pre-push hook ran (it must not, for a lease ref)" >&2
exit 1
HOOK
chmod +x "$TMP/hooked/.git/hooks/pre-push"

echo "fleet-lease: a refusing pre-push hook does not block a lease (#376)"
run hooked take hooked-lease --ttl 60 --holder hooked
[ "$RC" = 0 ] && ok "take succeeds through a failing pre-push hook" \
  || bad "the repo's pre-push hook blocked the lease, rc=$RC: $OUT"
grep -q 'pre-push hook ran' <<<"$OUT" \
  && bad "the hook ran — the bypass is not in effect: $OUT" \
  || ok "the hook did not run"

run hooked status hooked-lease
grep -q 'holder  : hooked' <<<"$OUT" \
  && ok "and the lease actually landed on the remote" \
  || bad "take reported success but the ref is not there: $OUT"

run hooked release hooked-lease --holder hooked
[ "$RC" = 0 ] && ok "release works through the hook too" || bad "release failed rc=$RC: $OUT"

echo "fleet-lease: free lease"
run alpha status integrator
[ "$RC" = 0 ] && grep -q 'FREE' <<<"$OUT" \
  && ok "status reports FREE before anyone takes it" \
  || bad "expected FREE, rc=$RC: $OUT"

echo "fleet-lease: taking"
run alpha take integrator --ttl 60 --holder alpha --note "wave 1"
[ "$RC" = 0 ] && ok "alpha takes the lease" || bad "take failed rc=$RC: $OUT"

run alpha status integrator
grep -q 'holder  : alpha' <<<"$OUT" && ok "holder is recorded" || bad "no holder: $OUT"
grep -q 'taken-at: 20' <<<"$OUT"     && ok "timestamp is recorded" || bad "no timestamp: $OUT"
grep -q 'note    : wave 1' <<<"$OUT" && ok "note is recorded" || bad "no note: $OUT"
grep -q 'state   : HELD' <<<"$OUT"   && ok "state is HELD inside the ttl" || bad "not HELD: $OUT"

echo "fleet-lease: a second machine loses loudly"
run beta take integrator --holder beta
[ "$RC" = 3 ] && ok "beta's take exits 3, not 0" || bad "expected rc=3, got $RC: $OUT"
grep -q 'already held' <<<"$OUT" && ok "says the lease is held" || bad "silent refusal: $OUT"
grep -q 'alpha' <<<"$OUT"        && ok "names the holder" || bad "does not name holder: $OUT"
grep -q 'force' <<<"$OUT"        && ok "points at the force-release escape" || bad "no escape hatch: $OUT"
# and the ref still belongs to alpha
run alpha status integrator
grep -q 'holder  : alpha' <<<"$OUT" && ok "a lost take does not overwrite the holder" || bad "holder clobbered: $OUT"

echo "fleet-lease: renew"
run beta renew integrator --holder beta
[ "$RC" = 3 ] && ok "beta cannot renew alpha's lease" || bad "expected rc=3, got $RC: $OUT"
run alpha renew integrator --holder alpha --ttl 90
[ "$RC" = 0 ] && ok "alpha renews its own lease" || bad "renew failed rc=$RC: $OUT"
run alpha status integrator
grep -q 'ttl     : 90s' <<<"$OUT" && ok "renew updates the ttl" || bad "ttl not updated: $OUT"
grep -q 'note    : wave 1' <<<"$OUT" && ok "renew keeps the existing note" || bad "note lost on renew: $OUT"

echo "fleet-lease: release"
run beta release integrator --holder beta
[ "$RC" = 3 ] && ok "beta cannot release alpha's lease" || bad "expected rc=3, got $RC: $OUT"
run beta release integrator --holder beta --force
[ "$RC" != 0 ] && grep -q 'reason' <<<"$OUT" \
  && ok "--force without --reason is refused" || bad "forced release needs a reason: rc=$RC $OUT"
run beta release integrator --holder beta --force --reason "alpha idle 3h, no pushes"
[ "$RC" = 0 ] && ok "--force with --reason releases" || bad "forced release failed rc=$RC: $OUT"
grep -q 'alpha idle 3h' <<<"$OUT" && ok "the reason is echoed for the record" || bad "reason not echoed: $OUT"
run alpha status integrator
grep -q 'FREE' <<<"$OUT" && ok "the lease is free again" || bad "still held: $OUT"

echo "fleet-lease: staleness"
run alpha take integrator --ttl 0 --holder alpha
[ "$RC" = 0 ] && ok "alpha re-takes the freed lease" || bad "re-take failed rc=$RC: $OUT"
sleep 1
run beta status integrator
grep -q 'state   : STALE' <<<"$OUT" && ok "a lease past its ttl reads STALE, not HELD" || bad "not STALE: $OUT"
run alpha release integrator --holder alpha
[ "$RC" = 0 ] || bad "owner release failed rc=$RC: $OUT"
run alpha release integrator --holder alpha
[ "$RC" = 0 ] && grep -q 'already free' <<<"$OUT" \
  && ok "releasing a free lease is a no-op, not an error" || bad "double release: rc=$RC $OUT"

echo "fleet-lease: input validation"
run alpha take "bad name" --holder alpha
[ "$RC" != 0 ] && ok "a lease name with a space is rejected" || bad "accepted a bad name"
run alpha take integrator --ttl notanumber --holder alpha
[ "$RC" != 0 ] && ok "a non-numeric ttl is rejected" || bad "accepted a bad ttl"
run alpha bogus integrator
[ "$RC" != 0 ] && ok "an unknown action is rejected" || bad "accepted a bogus action"
run alpha take
[ "$RC" != 0 ] && ok "take with no lease name is rejected" || bad "accepted a nameless take"

# Two leases with different names must not collide.
run alpha take integrator --holder alpha; [ "$RC" = 0 ] || bad "setup take failed: $OUT"
run beta  take release-driver --holder beta; [ "$RC" = 0 ] \
  && ok "a differently-named lease is independent" || bad "name collision: rc=$RC $OUT"

echo "fleet-lease: the repo must be named for take and force-release (dotclaude#426)"
run_bare alpha take guarded --holder alpha
[ "$RC" != 0 ] && grep -q -- '--repo OWNER/NAME' <<<"$OUT" \
  && ok "a take with no named repo is refused, pointing at --repo" \
  || bad "take with no repo was accepted, rc=$RC: $OUT"
run alpha status guarded
grep -q 'state   : FREE' <<<"$OUT" && ok "and nothing was taken" || bad "a refused take left a lease: $OUT"

run alpha take guarded --holder alpha; [ "$RC" = 0 ] || bad "setup take failed: $OUT"
run_bare beta release guarded --holder beta --force --reason "looks idle"
[ "$RC" != 0 ] && grep -q -- '--repo OWNER/NAME' <<<"$OUT" \
  && ok "a force-release with no named repo is refused" \
  || bad "force-release with no repo was accepted, rc=$RC: $OUT"
run alpha status guarded
grep -q 'holder  : alpha' <<<"$OUT" && ok "and the holder was not evicted" || bad "evicted anyway: $OUT"
run_bare alpha release guarded --holder alpha
[ "$RC" = 0 ] && ok "a holder's own plain release needs no --repo" || bad "own release refused rc=$RC: $OUT"

echo "fleet-lease: --repo acts on the repo named, not the cwd's origin"
git init --quiet --bare "$TMP/other.git"
OUT="$(cd "$TMP/alpha" && "$LEASE" take crossrepo --repo "$TMP/other.git" --holder alpha --note "other wave" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "take on another repo from this checkout succeeds" || bad "cross-repo take failed rc=$RC: $OUT"
grep -q "note: acting on '$TMP/other'" <<<"$OUT" && ok "and says it is not this checkout's repo" \
  || bad "no cross-repo note: $OUT"
grep -q "took crossrepo on $TMP/other as alpha" <<<"$OUT" && ok "the take output names the repo" \
  || bad "take output does not name the repo: $OUT"
git ls-remote "$TMP/other.git" refs/fleet-lease/crossrepo | grep -q . \
  && ok "the lease landed on the named repo" || bad "no lease on the named repo"
run alpha status crossrepo
grep -q 'state   : FREE' <<<"$OUT" && ok "and the checkout's own repo is untouched" \
  || bad "the cwd repo's lease moved: $OUT"
OUT="$(cd "$TMP/alpha" && "$LEASE" status crossrepo --repo "$TMP/other.git" 2>&1)"
grep -q "repo    : $TMP/other" <<<"$OUT" && ok "status prints the repo" || bad "status has no repo line: $OUT"
git -C "$TMP/alpha" fetch --quiet "$TMP/other.git" "+refs/fleet-lease/crossrepo:refs/check/other"
git -C "$TMP/alpha" log -1 --format=%B refs/check/other | grep -q "^repo: $TMP/other" \
  && ok "the lease commit records its repo" || bad "lease commit has no repo field"

[ "$fail" = 0 ] && echo "fleet-lease: all cases passed"
exit "$fail"
