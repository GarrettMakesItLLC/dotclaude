#!/usr/bin/env bash
# Self-test for with-check-lock.sh against a scratch lock dir, so it never
# contends with a real check on the box: the semaphore admits at most SLOTS
# readers, a writer excludes readers, the command's exit status comes back, a
# nested call runs through, a timed-out wait runs nothing and exits 75, HEAD
# moving mid-run leaves the drift marker, and a repo's manifest prefix names the
# lock files and answers for the knobs. Also: light mode, load narrowing and its
# widened deadline, the memory floor, retry_on_oom, the heap pin and slot sizing,
# holder liveness, the heartbeat and slot list, FIFO admission, and a wall-clock
# jump mid-wait (#452).
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

# ---------------------------------------------------------------------------
# #452: cases ported from MuscleBuddy's deleted TypeScript suites
# (check-lock-writer, check-slot-admission, check-slot-heap, check-slot-liveness).
# Each case gets its own scratch lock dir so no holder leaks into the next.
nl_n=0
newlock() { nl_n=$((nl_n + 1)); CHECK_LOCK_DIR="$TMP/lk$nl_n"; mkdir -p "$CHECK_LOCK_DIR"; export CHECK_LOCK_DIR; }
# Wait (bounded) until a file exists, or until it carries a given pid field.
wait_for() { local i; for i in $(seq 1 150); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
wait_stamp() { local i; for i in $(seq 1 150); do grep -q "	$2	" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
# A wrapper function, sliced out of the script and run with stubbed inputs.
fn_src() { sed -n "/^$1() {/,/^}/p" "$LOCK"; }
# fn_run <fn> <meminfo-file> [prelude] — run one wrapper function against a fake
# /proc/meminfo, with an optional prelude (a stubbed nproc, a slot count).
fn_run() {
  local f="$TMP/fn-$1.sh"
  { printf '%s\n' "${3:-}"; fn_src "$1" | sed "s|/proc/meminfo|$2|"; printf '%s\n' "$1"; } >"$f"
  bash "$f"
}
DEAD_PID=4194303

echo "with-check-lock: light mode runs while every slot is held, and still waits for a writer"
newlock
"$LOCK" sleep 3 >/dev/null 2>&1 & h1=$!
"$LOCK" sleep 3 >/dev/null 2>&1 & h2=$!
wait_stamp "$CHECK_LOCK_DIR/check.1.info" "$h1" || wait_stamp "$CHECK_LOCK_DIR/check.1.info" "$h2"
wait_for "$CHECK_LOCK_DIR/check.2.info"
"$LOCK" --light touch "$TMP/light1" >/dev/null 2>&1 & lp=$!
sleep 1
[ -e "$TMP/light1" ] && ok "a light caller took no slot" || bad "a light caller queued for a slot"
wait "$h1" "$h2" "$lp"
newlock
"$LOCK" --writer sleep 2 >/dev/null 2>&1 & wp=$!
wait_for "$CHECK_LOCK_DIR/check.gate.info"; sleep 0.3
"$LOCK" --light touch "$TMP/light2" >/dev/null 2>&1 & lp=$!
sleep 1
[ ! -e "$TMP/light2" ] && ok "a light caller waits out an install" || bad "a light caller ran during an install"
wait "$wp" "$lp"
[ -e "$TMP/light2" ] && ok "and runs once it finishes" || bad "the light caller never ran"

echo "with-check-lock: load narrows the semaphore to one holder, and only above the threshold"
newlock
out="$(CHECK_MAX_LOAD=-1 "$LOCK" true 2>&1)"
grep -q 'running checks one at a time' <<<"$out" && ok "over the threshold: one at a time, said out loud" || bad "no narrowing message: $out"
out="$(CHECK_MAX_LOAD=100000 "$LOCK" true 2>&1)"
grep -q 'one at a time' <<<"$out" && bad "narrowing message under the threshold: $out" || ok "silent under the threshold"
got="$(fn_run default_max_load /dev/null "nproc() { echo 6; }")"
[ "$got" = 12 ] && ok "threshold is twice the core count (6 cores -> 12)" || bad "default_max_load gave $got"
load_branch="$(sed -n '/if \[ "$(current_load)" -gt "$max_load" \]/,/avail="$(available_mb)"/p' "$LOCK")"
grep -q 'admitted=1' <<<"$load_branch" && ! grep -q 'admitted=0' <<<"$load_branch" \
  && ok "load narrowing floors at one holder" || bad "load branch can reach zero holders"
loop_at="$(grep -n '^while :; do$' "$LOCK" | tail -1 | cut -d: -f1)"
adm_at="$(grep -n 'admitted="$slots"' "$LOCK" | head -1 | cut -d: -f1)"
[ -n "$loop_at" ] && [ -n "$adm_at" ] && [ "$adm_at" -gt "$loop_at" ] \
  && ok "admission is re-read every poll, so a queue widens once load lifts" || bad "admission computed outside the wait loop"

echo "with-check-lock: the give-up deadline widens only while load has narrowed the semaphore"
newlock
CHECK_SLOTS=1 "$LOCK" sleep 6 >/dev/null 2>&1 & hp=$!
wait_stamp "$CHECK_LOCK_DIR/check.1.info" "$hp"
CHECK_SLOTS=1 CHECK_TIMEOUT=2 "$LOCK" touch "$TMP/nt1" >/dev/null 2>&1; rc=$?
[ "$rc" = 75 ] && [ ! -e "$TMP/nt1" ] && ok "one configured slot: CHECK_TIMEOUT means what it says" || bad "rc=$rc"
kill -TERM "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
newlock
CHECK_MAX_LOAD=-1 "$LOCK" sleep 12 >/dev/null 2>&1 & hp=$!
wait_stamp "$CHECK_LOCK_DIR/check.1.info" "$hp"
CHECK_MAX_LOAD=-1 CHECK_TIMEOUT=2 CHECK_NARROWED_TIMEOUT=6 "$LOCK" touch "$TMP/nt2" >"$TMP/nt2.out" 2>&1 & qp=$!
sleep 3.5
grep -q 'gave up' "$TMP/nt2.out" && bad "gave up on the ordinary deadline while narrowed" || ok "waits past CHECK_TIMEOUT while narrowed"
wait "$qp"; rc=$?
[ "$rc" = 75 ] && grep -q 'narrowed to one slot' "$TMP/nt2.out" && grep -q 'CI runs on isolated runners' "$TMP/nt2.out" \
  && ok "then gives up at CHECK_NARROWED_TIMEOUT, saying why" || bad "rc=$rc $(cat "$TMP/nt2.out")"
kill -TERM "$hp" 2>/dev/null; wait "$hp" 2>/dev/null

echo "with-check-lock: the memory floor"
newlock
out="$(CHECK_MIN_AVAIL_MB=99999999 CHECK_MEM_WAIT=600 CHECK_TIMEOUT=4 CHECK_REPORT_SECS=2 "$LOCK" echo THE-COMMAND-RAN 2>&1)"; rc=$?
[ "$rc" = 75 ] && ! grep -q THE-COMMAND-RAN <<<"$out" && ok "holds every slot under the floor" || bad "rc=$rc $out"
grep -q 'memory floor' <<<"$out" && grep -q 'memory pressure, not CPU' <<<"$out" \
  && ok "says memory, not CPU" || bad "message: $out"
out="$(CHECK_MIN_AVAIL_MB=99999999 CHECK_MEM_WAIT=2 CHECK_TIMEOUT=60 CHECK_REPORT_SECS=30 "$LOCK" echo THE-COMMAND-RAN 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'proceeding anyway' <<<"$out" && grep -q THE-COMMAND-RAN <<<"$out" \
  && ok "yields after CHECK_MEM_WAIT and runs" || bad "rc=$rc $out"
grep -q 'that is the box, not your diff' <<<"$out" && ok "warns that a later kill is the box" || bad "no kill warning: $out"
out="$(CHECK_MIN_AVAIL_MB=1 "$LOCK" true 2>&1)"
grep -q 'memory floor' <<<"$out" && bad "floor fired above it: $out" || ok "silent above the floor"
out="$(CHECK_MIN_AVAIL_MB=0 "$LOCK" true 2>&1)"
grep -q 'memory floor' <<<"$out" && bad "0 did not disable the floor" || ok "0 disables the floor"
printf 'MemTotal: 16000000 kB\nMemFree: 10240 kB\nMemAvailable: 5242880 kB\n' >"$TMP/meminfo"
got="$(fn_run available_mb "$TMP/meminfo")"
[ "$got" = 5120 ] && ok "reads MemAvailable, not MemFree" || bad "available_mb gave $got"
printf 'MemTotal: 16000000 kB\nMemFree: 10240 kB\n' >"$TMP/meminfo-old"
got="$(fn_run available_mb "$TMP/meminfo-old")"
[ "$got" = -1 ] && grep -q '\[ "$avail" -ge 0 \]' "$LOCK" && ok "an unreadable reading gates nothing" || bad "available_mb gave $got"

echo "with-check-lock: retry_on_oom (bin/lib/retry-on-oom.sh) around the wrapper"
RETRY="$HERE/lib/retry-on-oom.sh"
newlock
out="$(OOM_RETRY_BACKOFF_SECS=0 sh -e -c ". '$RETRY'; retry_on_oom '$LOCK' sh -c 'echo ATTEMPT; exit 137'" 2>&1)"; rc=$?
[ "$rc" = 137 ] && [ "$(grep -c ATTEMPT <<<"$out")" = 3 ] && ok "a 137 is retried twice, then reported" || bad "rc=$rc $out"
out="$(OOM_RETRY_BACKOFF_SECS=0 sh -e -c ". '$RETRY'; retry_on_oom '$LOCK' sh -c 'echo ATTEMPT; exit 2'" 2>&1)"; rc=$?
[ "$rc" = 2 ] && [ "$(grep -c ATTEMPT <<<"$out")" = 1 ] && ok "a real type error passes through unretried" || bad "rc=$rc $out"
out="$(OOM_RETRY_BACKOFF_SECS=0 sh -e -c ". '$RETRY'; retry_on_oom sh -c 'echo ATTEMPT; exit 75'" 2>&1)"; rc=$?
[ "$rc" = 75 ] && [ "$(grep -c ATTEMPT <<<"$out")" = 1 ] && ok "the lock's own 75 is not retried" || bad "rc=$rc $out"
: >"$TMP/oom-n"
OOM_RETRY_BACKOFF_SECS=0 sh -e -c ". '$RETRY'; retry_on_oom sh -c 'echo x >>\"$TMP/oom-n\"; [ \$(wc -l <\"$TMP/oom-n\") -ge 2 ] || exit 137'" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "a retry that clears succeeds" || bad "rc=$rc"

echo "with-check-lock: the heap pin"
opts() { CHECK_LOCK_HELD=1 NODE_OPTIONS="$1" "$LOCK" sh -c 'printf %s "$NODE_OPTIONS"'; }
grep -Eq -- '^--max-old-space-size=[0-9]+$' <<<"$(opts '')" && ok "pins a heap for a caller that set none" || bad "got '$(opts '')'"
[ "$(opts '--max-old-space-size=7168')" = '--max-old-space-size=7168' ] && ok "never lowers a caller's pin" || bad "got '$(opts '--max-old-space-size=7168')'"
o="$(opts '--enable-source-maps')"
grep -q -- '--enable-source-maps' <<<"$o" && grep -Eq -- '--max-old-space-size=[0-9]+' <<<"$o" && ok "appends to other NODE_OPTIONS" || bad "got '$o'"
heap_for() {
  printf 'MemTotal: %d kB\n' "$(($1 * 1024 * 1024))" >"$TMP/mi-heap"
  fn_run default_heap_mb "$TMP/mi-heap" "slots=$2"
}
[ "$(heap_for 16 3)" = 4096 ] && [ "$(heap_for 64 16)" = 3072 ] && ok "divides the box by the slot count" || bad "16/3=$(heap_for 16 3) 64/16=$(heap_for 64 16)"
[ "$(heap_for 8 4)" = 2048 ] && [ "$(heap_for 256 2)" = 6144 ] && ok "within a 2048 floor and a 6144 ceiling" || bad "8/4=$(heap_for 8 4) 256/2=$(heap_for 256 2)"
got="$(fn_run default_heap_mb "$TMP/no-such-meminfo" "slots=2")"
[ "$got" = 2048 ] && ok "states 2048 when memory cannot be read" || bad "got $got"
pin_at="$(grep -n 'heap_mb="$(default_heap_mb)"' "$LOCK" | cut -d: -f1)"
held_at="$(grep -n 'if \[ -n "${CHECK_LOCK_HELD:-}" \]' "$LOCK" | cut -d: -f1)"
noflock_at="$(grep -n 'if ! command -v flock' "$LOCK" | cut -d: -f1)"
[ -n "$pin_at" ] && [ "$pin_at" -lt "$held_at" ] && [ "$pin_at" -lt "$noflock_at" ] \
  && ok "pins before the held and no-flock early exits" || bad "pin at ${pin_at:-?}, held ${held_at:-?}, no-flock ${noflock_at:-?}"
slots_for() {
  printf 'MemTotal: %d kB\n' "$(($1 * 1024 * 1024))" >"$TMP/mi-slots"
  fn_run default_slots "$TMP/mi-slots" "nproc() { echo $2; }"
}
s1="$(slots_for 16 8)" s2="$(slots_for 64 16)" s3="$(slots_for 8 4)" s4="$(slots_for 23 8)" s5="$(slots_for 128 4)"
[ "$s1/$s2/$s3/$s4/$s5" = 3/8/2/4/2 ] && ok "slots follow the hardware (16/8->3, 64/16->8, 8/4->2, 23/8->4, 128/4->2)" || bad "got $s1/$s2/$s3/$s4/$s5"

echo "with-check-lock: holder liveness"
newlock
now_up="$(awk '{print int($1)}' /proc/uptime)"
# A stamp's start time is seconds on the wrapper's uptime clock. A fresh CI
# runner has been up for less than the ages below, so clamp to 1: a negative
# stamp is "unreadable", not "old".
ago() { local t=$((now_up - $1)); [ "$t" -gt 0 ] || t=1; echo "$t"; }
printf '%s\t%s\tnpx turbo\n' "$(ago 180432)" "$DEAD_PID" >"$CHECK_LOCK_DIR/check.1.info"
printf '%s\t%s\tnpm run\n' "$(ago 180432)" "$DEAD_PID" >"$CHECK_LOCK_DIR/check.2.info"
out="$(CHECK_TIMEOUT=5 "$LOCK" echo ran 2>&1)"
grep -q '^ran$' <<<"$out" && ! grep -q 'check slots busy' <<<"$out" && ok "a dead holder's slot is acquired at once" || bad "$out"
grep -q 'free — last used by' "$LOCK" && ok "a dead holder's stamp is reported as free" || bad "no free wording"
newlock
printf 'notatime\tnotapid\tnpx turbo\n' >"$CHECK_LOCK_DIR/check.1.info"
printf '%s\t%s\tsleep 30\n' "$now_up" "$DEAD_PID" >"$CHECK_LOCK_DIR/check.2.info"
out="$(CHECK_TIMEOUT=5 "$LOCK" echo ran 2>&1)"
grep -q '^ran$' <<<"$out" && ok "an unparseable stamp does not hold the slot" || bad "$out"
newlock
CHECK_SLOTS=1 "$LOCK" sleep 30 >/dev/null 2>&1 & hp=$!
if wait_stamp "$CHECK_LOCK_DIR/check.1.info" "$hp"; then
  st="$(awk '{print $20}' <<<"$(sed 's/^.*) //' /proc/$$/stat)")"
  printf '%s\t%s\tnpm run\t%s\n' "$(ago 1127)" "$$" "$((st + 1))" >"$CHECK_LOCK_DIR/check.1.info"
  out="$(CHECK_SLOTS=1 CHECK_TIMEOUT=4 "$LOCK" true 2>&1)"
  [ "$(grep -c 'slot 1: free — last used by npm run' <<<"$out")" -ge 2 ] && ! grep -Eq 'held [0-9]+m[0-9]+s' <<<"$out" \
    && ok "a recycled pid does not resurrect the slot, cycle after cycle" || bad "$out"
  printf 'notatime\tnotapid\tnpx turbo\n' >"$CHECK_LOCK_DIR/check.1.info"
  out="$(CHECK_SLOTS=1 CHECK_TIMEOUT=3 "$LOCK" true 2>&1)"
  grep -q 'slot 1: free — an unreadable holder record' <<<"$out" && ! grep -Eq 'held [0-9]+m[0-9]+s' <<<"$out" \
    && ok "a garbage stamp reads as free, not as its garbage" || bad "$out"
else
  bad "the holder never stamped slot 1"
fi
kill -TERM "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
newlock
"$LOCK" echo ran >/dev/null 2>&1
[ ! -e "$CHECK_LOCK_DIR/check.1.info" ] && ok "an ordinary exit reaps its slot stamp" || bad "slot stamp left behind"
"$LOCK" --writer echo ran >/dev/null 2>&1
[ ! -e "$CHECK_LOCK_DIR/check.gate.info" ] && ok "and a writer's gate stamp" || bad "gate stamp left behind"

echo "with-check-lock: what a waiter is told, and in what order it is admitted"
newlock
printf '%s\t%s\tnpx turbo\n' "$(ago 180432)" "$DEAD_PID" >"$CHECK_LOCK_DIR/check.2.info"
CHECK_MAX_LOAD=-1 "$LOCK" sleep 30 >/dev/null 2>&1 & hp=$!
wait_stamp "$CHECK_LOCK_DIR/check.1.info" "$hp"
out="$(CHECK_MAX_LOAD=-1 CHECK_TIMEOUT=4 CHECK_NARROWED_TIMEOUT=4 "$LOCK" true 2>&1)"
grep -Eq 'waiting [0-9]+m[0-9]+s' <<<"$out" && ok "heartbeat: waiting NmNs" || bad "no heartbeat: $out"
grep -q 'all 1 check slots busy' <<<"$out" && grep -q 'slot 1:' <<<"$out" && ! grep -q 'slot 2: npx turbo' <<<"$out" \
  && grep -q 'slots 2-2 parked' <<<"$out" && ok "lists only the slots contended for, and names the parked ones" || bad "$out"
kill -TERM "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
newlock
fifo="$TMP/fifo"; mkdir -p "$fifo"
CHECK_SLOTS=1 "$LOCK" sleep 2 >/dev/null 2>&1 & hp=$!
wait_stamp "$CHECK_LOCK_DIR/check.1.info" "$hp"
CHECK_SLOTS=1 "$LOCK" bash -c "probe '$fifo/a' 0.5" >"$fifo/a.out" 2>&1 & ap=$!
sleep 1
CHECK_SLOTS=1 "$LOCK" bash -c "probe '$fifo/b' 0.1" >/dev/null 2>&1 & bp=$!
wait "$hp" "$ap" "$bp"
[ "$(cat "$fifo/b.start")" -ge "$(cat "$fifo/a.end")" ] && ok "a narrowed semaphore admits waiters in arrival order" || bad "the newcomer ran ahead of the queued waiter"
beats="$(grep -c 'waiting' "$fifo/a.out")"
[ "$beats" -le 3 ] && ok "no spinning: $beats heartbeat(s) for a ~1s wait" || bad "$beats heartbeats for a ~1s wait"

echo "with-check-lock: a wall-clock jump mid-wait does not cause an early give-up"
newlock
fake="$TMP/fakedate"; mkdir -p "$fake"
cat >"$fake/date" <<FAKE
#!/usr/bin/env bash
n=0; [ -f "$fake/n" ] && n=\$(cat "$fake/n"); n=\$((n + 1)); echo "\$n" >"$fake/n"
real=\$(command -p date +%s)
[ "\$n" -le 1 ] && echo "\$real" || echo "\$((real + 1000000))"
FAKE
chmod +x "$fake/date"
CHECK_SLOTS=1 "$LOCK" sleep 30 >/dev/null 2>&1 & hp=$!
wait_stamp "$CHECK_LOCK_DIR/check.1.info" "$hp"
PATH="$fake:$PATH" CHECK_SLOTS=1 CHECK_TIMEOUT=30 "$LOCK" touch "$TMP/jumped" >"$TMP/jump.out" 2>&1 & qp=$!
sleep 2.5
[ ! -e "$TMP/jumped" ] && ! grep -q 'gave up' "$TMP/jump.out" && ok "still waiting after the jump" || bad "$(cat "$TMP/jump.out")"
kill -TERM "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
wait "$qp"; rc=$?
[ "$rc" = 0 ] && [ -e "$TMP/jumped" ] && ok "and admitted when the holder leaves" || bad "rc=$rc"
export CHECK_LOCK_DIR="$TMP/locks"

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
