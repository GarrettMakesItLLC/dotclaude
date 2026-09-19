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
run() {
  local m="$1"; shift
  OUT="$(cd "$TMP/$m" && "$LEASE" "$@" 2>&1)"; RC=$?
}

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

[ "$fail" = 0 ] && echo "fleet-lease: all cases passed"
exit "$fail"
