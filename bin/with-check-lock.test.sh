#!/usr/bin/env bash
# Self-test for with-check-lock.sh against a scratch lock dir, so it never
# contends with a real check on the box: the semaphore admits at most SLOTS
# readers, a writer excludes readers, the command's exit status comes back, a
# nested call runs through, a timed-out wait runs nothing and exits 75, HEAD
# moving mid-run leaves the drift marker, and a repo's manifest prefix names the
# lock files and answers for the knobs.
#   bash bin/with-check-lock.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="$HERE/with-check-lock.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

command -v flock >/dev/null 2>&1 || { echo "  skip: no flock on this box (the wrapper runs unbounded here)"; exit 0; }

unset BASH_ENV
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset REPO_MANIFEST CHECK_LOCK_HELD
for v in $(env | sed -n 's/^\([A-Z]*_CHECK_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
export CHECK_LOCK_DIR="$TMP/locks" CHECK_SLOTS=2 CHECK_TIMEOUT=30 CHECK_REPORT_SECS=1
export CHECK_MAX_LOAD=999999 CHECK_MIN_AVAIL_MB=0
mkdir -p "$CHECK_LOCK_DIR"

REPO="$TMP/repo"
git init -q -b main "$REPO"
git -C "$REPO" commit -q --allow-empty -m one
cd "$REPO" || exit 1

now_ms() { date +%s%3N; }
probe() { echo "$(now_ms)" >"$1.start"; sleep "$2"; echo "$(now_ms)" >"$1.end"; }
export -f probe now_ms

echo "with-check-lock: at most CHECK_SLOTS readers run at once"
runs="$TMP/readers"; mkdir -p "$runs"
for i in 1 2 3; do "$LOCK" bash -c "probe '$runs/$i' 1" >/dev/null & done
wait
max=0
for i in 1 2 3; do
  si=$(cat "$runs/$i.start"); ei=$(cat "$runs/$i.end"); n=0
  for j in 1 2 3; do
    sj=$(cat "$runs/$j.start"); ej=$(cat "$runs/$j.end")
    lo=$((si > sj ? si : sj)); hi=$((ei < ej ? ei : ej))
    [ "$hi" -gt "$lo" ] && n=$((n + 1))
  done
  [ "$n" -gt "$max" ] && max=$n
done
[ "$max" -le 2 ] && ok "max concurrent readers: $max (limit 2)" || bad "max concurrent readers $max > 2"

echo "with-check-lock: a writer excludes readers"
ex="$TMP/excl"; mkdir -p "$ex"
"$LOCK" --writer bash -c "probe '$ex/w' 1" >/dev/null & wpid=$!
sleep 0.3
"$LOCK" bash -c "probe '$ex/r' 0.1" >/dev/null & rpid=$!
wait "$wpid" "$rpid"
[ "$(cat "$ex/r.start")" -ge "$(cat "$ex/w.end")" ] && ok "the reader started after the writer released" || bad "reader ran inside the writer's window"

echo "with-check-lock: the command's status is the wrapper's"
"$LOCK" sh -c 'exit 7' >/dev/null 2>&1; rc=$?
[ "$rc" = 7 ] && ok "exit 7 comes back" || bad "rc=$rc"

echo "with-check-lock: a nested call runs through instead of taking a second slot"
out="$(CHECK_SLOTS=1 "$LOCK" "$LOCK" echo inner 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q '^inner$' <<<"$out" && ok "no self-deadlock at one slot" || bad "rc=$rc $out"

echo "with-check-lock: a timed-out wait runs nothing and exits 75"
"$LOCK" --writer sleep 3 >/dev/null & hold=$!
sleep 0.3
out="$(CHECK_TIMEOUT=1 "$LOCK" touch "$TMP/should-not-exist" 2>&1)"; rc=$?
wait "$hold"
[ "$rc" = 75 ] && [ ! -e "$TMP/should-not-exist" ] && ok "gave up without running" || bad "rc=$rc exists=$([ -e "$TMP/should-not-exist" ] && echo y) $out"

echo "with-check-lock: HEAD moving under a check leaves the drift marker; only that check, re-run still, clears it"
marker="$(git rev-parse --absolute-git-dir)/verification-stale"
check='if [ -f move ]; then git commit -q --allow-empty -m moved; fi'
touch move
"$LOCK" sh -c "$check" >/dev/null 2>&1
[ -f "$marker" ] && ok "marker written when HEAD moved" || bad "no marker at $marker"
rm -f move
"$LOCK" --no-drift true
[ -f "$marker" ] && ok "--no-drift neither sets nor clears it" || bad "--no-drift cleared the marker"
"$LOCK" sh -c 'git status >/dev/null' >/dev/null 2>&1
[ -f "$marker" ] && ok "a DIFFERENT check holding still does not retire it" || bad "cleared by another command"
"$LOCK" sh -c "$check" >/dev/null 2>&1
[ ! -f "$marker" ] && ok "the same check re-run against a still tree clears it" || bad "marker survived the re-run"

echo "with-check-lock: the manifest prefix names the files and answers for the knobs"
mkdir -p .claude
echo '{ "envPrefix": "DM" }' >.claude/repo.json
unset CHECK_SLOTS
DM_CHECK_SLOTS=1 "$LOCK" true
[ -e "$CHECK_LOCK_DIR/dm-check.1.lock" ] && ok "lock files are dm-check.*" || bad "files: $(ls "$CHECK_LOCK_DIR")"
[ -e "$CHECK_LOCK_DIR/dm-check.2.lock" ] && bad "DM_CHECK_SLOTS=1 ignored (slot 2 used)" || ok "DM_CHECK_SLOTS is honoured"
out="$(DM_CHECK_LOCK_HELD=1 CHECK_SLOTS=1 "$LOCK" sh -c 'echo "held=$CHECK_LOCK_HELD/$DM_CHECK_LOCK_HELD"' 2>&1)"
grep -q 'held=1/1' <<<"$out" && ok "an outer repo-local wrapper's HELD flag is honoured and both are exported" || bad "$out"
touch move
"$LOCK" sh -c "$check" >/dev/null 2>&1
[ -f "$(git rev-parse --absolute-git-dir)/dm-verification-stale" ] && ok "drift marker is dm-verification-stale" || bad "marker not prefixed"

exit "$fail"
