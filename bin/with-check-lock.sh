#!/usr/bin/env bash
#
#   ~/.claude/bin/with-check-lock.sh [--writer|-w|--light|-l] [--no-drift] <command> [args…]
#
# Bound how many memory-heavy checks run at once across every worktree of a repo
# on this box.
#
# PER-REPO NAMING. The repo's `.claude/repo.json` `envPrefix` (docs/repo-manifest.md)
# names the lock files `<prefix>-check.*` (lowercased) and the drift marker
# `<prefix>-verification-stale`, and every `CHECK_*` knob below is also read as
# `<PREFIX>_CHECK_*`. So a repo that still carries its own copy of this wrapper
# and one that calls this shared copy contend for the SAME slots while it
# migrates. With no manifest the names are `check.*` and `verification-stale`.
# `CHECK_*` wins over `<PREFIX>_CHECK_*` when both are set.
#
# eslint's type-aware program and each `tsc` project peak past 1 GB, so several
# agent sessions reaching a hook together used to hand the box to the OOM killer
# — which kills the largest process, usually an unrelated session's `tsc` or an
# agent itself (MuscleBuddy#2857). The box runs a couple of checks comfortably; it is the
# unbounded pile-up that kills it.
#
# So this is a counting semaphore, not a mutex: a mutex would cap the box at one
# working agent, which is the problem restated. CHECK_SLOTS holders run
# concurrently and the rest queue.
#
# `--writer` (`-w`) takes the whole box instead of one slot: an install rewrites
# the very `node_modules` every concurrent check reads, so a check racing it sees
# a half-written tree and fails on files the branch never touched. Writers
# exclude every reader and readers exclude the writer; readers never block each
# other. Run `npm ci` this way.
#
# The lock files live in the shared git dir, which every linked worktree resolves
# to the same absolute path — per-worktree locks would bound nothing.
# `CHECK_LOCK_DIR` overrides it, which is how the guards get an isolated set
# rather than contending with the box's live checks, and how a second CLONE on
# the same box joins the agents' set instead of running a disjoint one of its own
# (MuscleBuddy#3966). A semaphore per clone bounds each clone and nothing about the machine
# both are eating.
#
# A slot bounds two things, not one: how many checks run (the semaphore) and how
# much heap each may take (the NODE_OPTIONS pin below, MuscleBuddy#3282). Bounding only the
# count still let one check inside a slot take the box down.
#
# A lock is an `flock` on a file descriptor, and a descriptor is INHERITED by
# every descendant — so the command runs as a CHILD with the lock fds closed,
# never as an `exec` (MuscleBuddy#4164, see `run_command`).
set -euo pipefail

# Writer mode: the caller mutates what every other holder reads (`npm ci`), so it
# takes every slot rather than one of them.
#
# `--no-drift`: the caller is not a verification, so HEAD moving under it says
# nothing about whether a check described a tree that held still —
# `setup-worktree.sh`'s nested-dep mirror `cp` is the case this exists for
# (MuscleBuddy#8740). It still takes the lock: the exclusion against a concurrent
# `--writer npm ci` racing a read of `$main_tree`'s node_modules is real and
# has nothing to do with drift bookkeeping. It just never writes or clears
# `<prefix>-verification-stale`, so a copy can never retire a check nobody re-ran,
# and a copy racing a real commit can never manufacture a false refusal either.
writer=""
light=""
record_drift=1
while :; do
  case "${1:-}" in
    --writer | -w)
      writer=1
      shift
      ;;
    # Light mode: the caller READS what an install rewrites (copying
    # `node_modules` into a worktree) but is no memory-heavy check. It needs the
    # writer excluded and nothing else, so it holds the gate shared and never takes
    # a slot — a `cp` queued behind two 5-minute typechecks while the box had 13 GB
    # free is the waste this removes (MuscleBuddy#8600).
    --light | -l)
      light=1
      shift
      ;;
    --no-drift)
      record_drift=""
      shift
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -gt 0 ] || {
  echo "usage: with-check-lock.sh [--writer|-w|--light|-l] [--no-drift] <command> [args…]" >&2
  exit 64
}

# The repo's env prefix, from its manifest when there is one. Read directly
# rather than through bin/lib/repo-manifest.sh so the wrapper keeps working when
# it is copied or symlinked on its own.
ENV_PREFIX=""
if command -v python3 >/dev/null 2>&1; then
  _top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  _manifest="${REPO_MANIFEST:-${_top:+$_top/.claude/repo.json}}"
  if [ -n "$_manifest" ] && [ -f "$_manifest" ]; then
    ENV_PREFIX="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("envPrefix") or "")' "$_manifest" 2>/dev/null || true)"
  fi
fi
case "$ENV_PREFIX" in *[!A-Za-z0-9_]*) ENV_PREFIX="" ;; esac
if [ -n "$ENV_PREFIX" ]; then
  LOCK_NAME="$(printf '%s' "$ENV_PREFIX" | tr '[:upper:]' '[:lower:]')-check"
  STALE_MARKER="${LOCK_NAME%-check}-verification-stale"
else
  LOCK_NAME="check"
  STALE_MARKER="verification-stale"
fi

# Every knob answers to CHECK_<X> first, then <PREFIX>_CHECK_<X>.
for _knob in SLOTS LOCK_DIR LOCK_HELD TIMEOUT REPORT_SECS NARROWED_TIMEOUT IDLE_STALL_SECS \
  MAX_LOAD MIN_AVAIL_MB MEM_WAIT; do
  _generic="CHECK_$_knob"
  _prefixed="${ENV_PREFIX:+${ENV_PREFIX}_CHECK_$_knob}"
  if [ -z "${!_generic:-}" ] && [ -n "$_prefixed" ] && [ -n "${!_prefixed:-}" ]; then
    printf -v "$_generic" '%s' "${!_prefixed}"
    export "${_generic?}"
  fi
done
unset _knob _generic _prefixed _top _manifest

# `turbo run` defaults its filesystem cache to a location it derives from the
# repo's git identity — and every linked worktree shares one git common dir
# (MuscleBuddy#3966 above), so without an override every worktree reads and writes the
# SAME physical `.turbo/cache`, printing "using shared worktree cache" as it
# does it. Cache entries are keyed by task input hash, so this is silent RIGHT
# UP UNTIL a hash collision or a race lets one worktree's `typecheck` replay
# another worktree's cached logs as its own — measured as 14 TypeScript errors
# in files a branch never touched (MuscleBuddy#8204). `--cache-dir` (mirrored by
# `TURBO_CACHE_DIR`) is resolved against the CALLER's cwd, not the broken repo
# inference, so pinning it here — once, for every turbo invocation this wrapper
# ever runs — gives each worktree an isolated cache without touching the
# `turbo run …` command lines the ratchet suite pins verbatim. Only fills in a
# caller that has not already chosen one.
: "${TURBO_CACHE_DIR:=.turbo/cache}"
export TURBO_CACHE_DIR

# How many slots the box can actually afford, derived from the hardware rather
# than hard-coded, so one script sizes itself on a 16 GB laptop, a 23 GB desktop
# and a 64 GB workstation alike.
#
# Memory is the binding constraint, not CPU: eslint's type-aware program and
# each `tsc` project peak past 1 GB. An OOM kill takes out the largest process,
# which is usually an unrelated session's `tsc` or an agent itself, so the count
# is sized from the heaviest holder there is. Measured (MuscleBuddy#8600): a pre-push
# typecheck runs its projects one at a time, and the largest, `apps/server`,
# peaks at 3.6 GB cold and 1.8 GB warm now that every project is incremental —
# so a holder is budgeted at 4 GB, out of 75% of RAM (the rest is the OS and the
# agent sessions themselves). CPU caps it at half the cores: past that, holders
# only thrash each other. Floor of 2.
#
# The count is the steady-state answer. The MemAvailable floor below is what
# protects a box that is busier than MemTotal suggests (other repos' worktrees,
# a big eslint run): it holds admission while memory is short, whatever the
# count says. `CHECK_SLOTS` still wins if it is set.
default_slots() {
  local kb cores
  kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null) || true
  [ -n "${kb:-}" ] || { echo 2; return; }

  local gb=$((kb / 1024 / 1024))
  local n=$((gb * 3 / 4 / 4))
  cores="$(nproc 2>/dev/null || echo 4)"
  local cap=$((cores / 2))
  [ "$cap" -lt 2 ] && cap=2
  [ "$n" -gt "$cap" ] && n="$cap"
  [ "$n" -lt 2 ] && n=2
  echo "$n"
}

slots="${CHECK_SLOTS:-$(default_slots)}"

# The heap ceiling every check inside a slot runs under (MuscleBuddy#3282).
#
# The semaphore bounded how many checks run; it did not bound how much memory any
# one of them took. Node sizes its default heap from memory *available at
# start-up*, so on a loaded box a check that passes when the box is idle aborts on
# the V8 heap limit (exit 134) or is OOM-killed (137) — on a diff that is not the
# cause. Pinning per caller was the workaround, and it is hand-maintained: every
# new check has to remember, and the ones that forgot are exactly the ones that
# died.
#
# So the ceiling becomes a property of the slot. Anything run through this wrapper
# is pinned by construction.
#
# **A caller's own pin always wins.** The values in `package.json` are measured
# (`lint:root` carries 4096 and the per-package `lint` tasks 2048-6144), and a
# derived number must never quietly lower a measured one. A measured pin above
# the derived cap is the system working as intended, not a contradiction. This only fills in the
# checks that had no pin at all — where the alternative is not a bigger heap but
# an unpredictable one.
default_heap_mb() {
  local kb gb per
  kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null) || true
  # No /proc/meminfo (macOS, some containers): Node's own default is ~2 GB, so
  # state it explicitly rather than leaving it to whatever is free.
  [ -n "${kb:-}" ] || { echo 2048; return; }

  gb=$((kb / 1024 / 1024))
  # 75% of the box, divided by the holders that may run at once. The 25% margin is
  # the OS, the agent sessions themselves, and every allocation outside V8's old
  # space. Dividing by `slots` is the point: the two knobs have to move together,
  # because N concurrent holders at a per-process ceiling authorise N times it.
  per=$((gb * 768 / slots))
  [ "$per" -lt 2048 ] && per=2048
  [ "$per" -gt 6144 ] && per=6144
  echo "$per"
}

case "${NODE_OPTIONS:-}" in
  *--max-old-space-size=*) ;;
  *)
    heap_mb="$(default_heap_mb)"
    export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--max-old-space-size=$heap_mb"
    ;;
esac

# Already inside a slot (a wrapped script invoking another wrapped script): run
# through. Taking a second slot would deadlock at CHECK_SLOTS=1. The heap pin
# above is already exported and inherited, so it still applies.
if [ -n "${CHECK_LOCK_HELD:-}" ]; then
  exec "$@"
fi

# No flock (macOS, minimal containers): run unbounded rather than block the
# commit. Losing the semaphore is a performance problem; refusing to commit is not.
# The heap pin still applies — it is worth having without the semaphore.
if ! command -v flock >/dev/null 2>&1; then
  exec "$@"
fi

# The override names a path on the BOX, not in the checkout, so a workflow that
# carries it is carrying one machine's layout. A run on a different machine —
# the lane's hosted `only_evidence` mode — inherits a path it cannot create, and
# there the right answer is this clone's own lock set, not a failed step.
lock_dir="${CHECK_LOCK_DIR:-}"
if [ -n "$lock_dir" ] && ! mkdir -p "$lock_dir" 2>/dev/null; then
  echo "with-check-lock: CHECK_LOCK_DIR=$lock_dir is not usable here; using this clone's own lock set" >&2
  lock_dir=""
fi
[ -n "$lock_dir" ] || lock_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$lock_dir"
export CHECK_LOCK_HELD=1
[ -z "$ENV_PREFIX" ] || export "${ENV_PREFIX}_CHECK_LOCK_HELD=1"

# What a waiter is told, and how long it is willing to wait (MuscleBuddy#3594).
#
# Waiting here is normal; waiting *in silence* is what costs a session. A queued
# `git commit` printed one line and then said nothing for twenty minutes, and an
# agent's five-minute tool timeout killed it with no way to tell "queued behind a
# long install" from "wedged on a lock nobody holds" — so nothing was committed
# and nothing explained why. A writer makes that worse by construction: an
# install holds every slot for minutes.
#
# So a waiter names what holds the lock and how long it has held it, on a
# heartbeat, and gives up rather than hanging forever. Giving up exits 75
# (EX_TEMPFAIL) *without running the command* — a caller that is told to retry is
# strictly better off than one killed mid-wait, and running the check anyway
# would reopen the hole the lock exists to close. `CHECK_TIMEOUT=0` waits
# indefinitely.
lock_timeout="${CHECK_TIMEOUT:-900}"
report_secs="${CHECK_REPORT_SECS:-15}"

# The deadline while the semaphore is NARROWED to one slot (MuscleBuddy#5922).
#
# 900s is sized for the ordinary case: a couple of holders running concurrently,
# each a few minutes, so a waiter is in within one or two of them. Narrowing
# makes the queue SERIAL by design — that is the whole point of it — and eight
# agents each needing three minutes is then a twenty-four minute queue that the
# same 900s budget refuses two thirds of the way through. The budget and the
# admission width have to move together, or the wrapper spends its own timeout
# rejecting callers for doing exactly what it told them to do.
#
# Applied only while narrowed, and re-evaluated every poll, so a queue that
# formed under load goes back to the ordinary deadline the moment load lifts.
# `CHECK_TIMEOUT=0` still waits indefinitely, and an explicitly set
# `CHECK_NARROWED_TIMEOUT` still wins.
narrowed_timeout="${CHECK_NARROWED_TIMEOUT:-$((lock_timeout * 3))}"

# How long a wait has to run, with the box idle, before the wrapper says out loud
# that this is not ordinary contention (MuscleBuddy#4164).
idle_stall_secs="${CHECK_IDLE_STALL_SECS:-120}"

# Wall-clock time is not safe to diff against itself here: every deadline below
# is `now() - <earlier now()>`, and an NTP correction or a WSL2 host-sleep
# resync steps `date +%s` forward by minutes with no real time having passed.
# That reads as hours of waiting in a single tick and gives up on a lock that
# has been held for seconds — the exact shape of MuscleBuddy#5456, reproduced by stubbing
# `date` to jump mid-wait in `check-lock-writer.test.ts`.
#
# `/proc/uptime`'s first field is seconds since boot off the kernel's own
# monotonic accounting: it never steps for a wall-clock correction, only for
# real elapsed time. No `/proc` (macOS, some containers) falls back to the wall
# clock, which is what this always did there.
now() {
  awk '{print int($1)}' /proc/uptime 2>/dev/null || date +%s
}

human() { printf '%dm%02ds' "$(($1 / 60))" "$(($1 % 60))"; }

# Integer 1-minute load. Every threshold here is coarse (a whole multiple of the
# core count), so truncating is exact enough and keeps this to shell arithmetic.
current_load() {
  awk '{print int($1)}' /proc/loadavg 2>/dev/null || echo 0
}

# Waiting on a BUSY box is the semaphore working. Waiting on an IDLE one is not
# contention at all — it is a lock held by something that has no work left to do,
# and it is indistinguishable from ordinary queueing in the heartbeat alone. That
# ambiguity is what made MuscleBuddy#4164 invisible for over an hour: agents read "waiting…"
# as normal and kept waiting while the box sat at load 2.4.
#
# Said once, not on every heartbeat: it is a diagnosis, not a progress report.
idle_note_shown=""
note_if_idle() {
  local waited="$1" load
  [ -z "$idle_note_shown" ] || return 0
  [ "$waited" -ge "$idle_stall_secs" ] || return 0
  load="$(current_load)"
  [ "$load" -lt 2 ] || return 0
  idle_note_shown=1
  echo "⚠ with-check-lock: $(human "$waited") of waiting while the box is IDLE (load $load)." >&2
  echo "  Contention would keep the box busy. An idle box means the lock is held by a" >&2
  echo "  process with no work left to do. Find the holders:" >&2
  echo "    ls -l /proc/*/fd/* 2>/dev/null | grep -- -check." >&2
}

# Record who holds a lock, for whoever ends up waiting on it.
#
# Only the first two words of the command — enough to tell `npm ci` from `turbo
# run lint`, without pasting an agent's whole argv into someone else's terminal.
#
# A pid alone does not identify a process for as long as a stamp outlives one.
# This box's `pid_max` is 32768 and it sits near the top of that range, so a pid
# is reused within minutes — and `kill -0` then answers about whoever inherited
# it (MuscleBuddy#4265). The kernel's own start time for the process is what disambiguates:
# field 22 of `/proc/<pid>/stat`, in clock ticks since boot, unique for the life
# of the boot. Stamping it lets a reader ask "is THIS process still running?"
# rather than "is something running under this number?".
#
# `comm` (field 2) is parenthesised and may itself contain spaces and
# parentheses, so everything up to the LAST `)` is dropped before splitting.
# After that, the first remaining field is `state` (3), which puts `starttime`
# at the 20th.
#
# Empty on any platform without /proc (macOS, some containers) — the reader
# falls back to the pid alone there rather than calling every holder dead.
proc_starttime() {
  local line
  is_pid "${1:-}" || return 0
  read -r line <"/proc/$1/stat" 2>/dev/null || return 0
  line="${line##*) }"
  awk '{print $20}' <<<"$line"
}

stamp_file=""
stamp() {
  local file="$1"
  shift
  # Via a temp file and `mv`, not a direct `>"$file"`: shell redirection opens
  # with O_TRUNC before the `printf` write lands, so a `describe()` racing this
  # can open the file in the truncated gap and read nothing — every field empty,
  # which `is_pid` rejects, reporting an ACTIVELY HELD slot as "free — an
  # unreadable holder record" (MuscleBuddy#5456). `mv` within the same directory renames
  # rather than writes, so a reader only ever sees the old content or the new,
  # never a half-written file in between.
  local tmp="$file.$$.tmp"
  printf '%s\t%s\t%s\t%s\n' "$(now)" "$$" "${1:-?}${2:+ $2}" "$(proc_starttime "$$")" >"$tmp"
  mv -f "$tmp" "$file"
  stamp_file="$file"
}

# Drop this process's own stamp on the way out.
#
# The wrapper used to `exec`, so there was no "after" in which to clean up and a
# stamp outlived its holder by construction — which is how the liveness dir came
# to hold nothing but rows for dead processes (MuscleBuddy#4164). Running the command as a
# child gives the wrapper an after, so a stamp now ends with its holder.
#
# Only if the row still names THIS pid: a second writer stamps the gate while the
# first is still running it, and the first must not delete the newcomer's row.
reap_stamp() {
  local started pid cmd since
  [ -n "$stamp_file" ] || return 0
  if IFS=$'\t' read -r started pid cmd since <"$stamp_file" 2>/dev/null && [ "$pid" = "$$" ]; then
    rm -f "$stamp_file"
  fi
}
trap reap_stamp EXIT

# Whether the process a stamp names is still running.
#
# A stamp can still outlive its holder when that holder dies without running its
# trap — SIGKILL, an OOM kill. The lock itself is NOT leaked when that happens:
# it is an `flock` on a file descriptor, and the kernel drops it however the
# holder exits. Admission never reads a pid, only `flock -n`, so a dead holder
# cannot starve anyone (MuscleBuddy#4097).
#
# What a stale stamp does do is lie to whoever is waiting: it renders as a holder
# that has been running for two days, which reads exactly like a leaked slot and
# sent one session hunting a bug that was not there. So liveness is checked at
# the point it is actually used — the message.
#
# A row can also be torn or malformed — the liveness dir has held a pid of
# `4194303`, which is PID_MAX and can never name a live process. `kill -0` already
# rejects that one, but a non-numeric field would make it an error rather than an
# answer, so the shape is checked before the kernel is asked (MuscleBuddy#4164).
is_pid() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

#
# The pid is necessary and not sufficient. `kill -0` answers "is something
# running under this number?", and on a box whose pids wrap in minutes that is a
# different question from "is the stamped holder still running?" — which is how a
# slot kept reporting a 35-minute holder whose pid `ps` could not find and whose
# flock `fuser` showed free (MuscleBuddy#4265). So a stamp that carries a start time must
# match it: the same pid with a different start time is a DIFFERENT process, and
# the holder it names is gone.
#
# A stamp with no start time (an older wrapper, or a platform with no /proc)
# falls back to the pid alone, which is what it has always done.
holder_alive() {
  local pid="${1:-}" since="${2:-}"
  is_pid "$pid" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$since" ] || return 0
  [ "$(proc_starttime "$pid")" = "$since" ]
}

describe() {
  local file="$1" started pid cmd since
  if [ -r "$file" ] && IFS=$'\t' read -r started pid cmd since <"$file"; then
    if ! is_pid "$pid" || ! is_pid "$started"; then
      echo "free — an unreadable holder record"
    elif holder_alive "$pid" "$since"; then
      echo "$cmd (pid $pid), held $(human "$(($(now) - started))")"
    else
      echo "free — last used by $cmd (pid $pid, no longer running)"
    fi
  else
    echo "an unnamed holder"
  fi
}

# The holder of every slot a waiter is actually contending for.
#
# Takes the CANDIDATE count rather than `$slots`: under load the wrapper narrows
# admission to one slot, and listing the slots it is not even trying is what
# produced "all 1 check slots busy" above a list of two — the count and the list
# disagreeing is the same bug reported twice.
readers() {
  local candidates="${1:-$slots}" slot
  for slot in $(seq 1 "$candidates"); do
    echo "     slot $slot: $(describe "$lock_dir/$LOCK_NAME.$slot.info")"
  done
  if [ "$candidates" -lt "$slots" ]; then
    echo "     (slots $((candidates + 1))-$slots parked: the box is over its load threshold)"
  fi
}

give_up() {
  echo "✗ with-check-lock: gave up after $(human "$1") — nothing was run." >&2
  echo "$2" >&2
  echo "  Retry when it finishes, or set CHECK_TIMEOUT=0 to wait indefinitely." >&2
  exit 75
}

# Block on a lock with a heartbeat and a deadline. `flock -w` does the sleeping,
# so this is a wait rather than a poll.
wait_lock() {
  local fd="$1" mode="$2" holder="$3" waited=0
  while ! flock -w "$report_secs" "$mode" "$fd"; do
    waited=$((waited + report_secs))
    echo "⏳ with-check-lock: waiting $(human "$waited") on $(describe "$holder")"
    note_if_idle "$waited"
    if [ "$lock_timeout" -gt 0 ] && [ "$waited" -ge "$lock_timeout" ]; then
      give_up "$waited" "  The check lock is held by $(describe "$holder")."
    fi
  done
}

# Run the wrapped command holding the lock, then exit with its status.
#
# NOT `exec`. A lock here is an `flock` on a file descriptor, and a descriptor is
# inherited by every descendant — so `exec`ing handed fds 7/8/9 to the command
# and to everything it spawned. Any process that outlived it (a turbo daemon, an
# esbuild service, a stray background job) went on holding the gate and its slot
# with no work left to do, and nothing could reclaim them: the wrapper was gone,
# and its stamp named a pid that had already exited. The box then reads as
# "everyone waiting, nothing running" — load 2.4 with fourteen queued wrappers,
# readers stacked behind a writer stuck on `flock -x 7` forever (MuscleBuddy#4164).
#
# So the command runs as a child with the lock fds explicitly closed, and this
# shell stays alive holding them. The lock now ends exactly when the wrapper
# does, and nothing the command spawns can extend it past that.
#
# Closing an fd the wrapper never opened (8, once a reader has released intent)
# is a no-op, so the same three closures are correct on every path.
# Record whether HEAD moved while the wrapped command ran (MuscleBuddy#7227).
#
# Every verification habit this repo has built guards the TRANSPORT: `git-push.sh`
# confirms a push moved the ref, `git-commit-guard.sh` refuses an empty commit.
# None of them notices that the thing you verified and the thing you shipped are
# different trees. The observed case: an agent with a clean tree ran a four-minute
# a11y lane and was about to push, while a second agent committed and pushed on the
# same branch in the same worktree. Its "569 passed" would have described a tree
# that no longer existed — and the `git ls-remote` habit catches a bad push, never
# a GOOD push of a tree someone else edited after you tested it.
#
# So the sha is read either side of the command and the verdict is left in the
# worktree's own admin directory, where `bin/git-push.sh` reads it immediately
# before pushing. A run whose HEAD did not move CLEARS the marker, which is what
# keeps this self-healing: re-running the check is both the fix and the proof.
#
# Best-effort throughout. Outside a git repo, or with an unreadable admin dir,
# there is nothing to record and the check simply does not exist for that run.
stale_marker_path() {
  local admin
  admin="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  [ -n "$admin" ] || return 1
  printf '%s/%s' "$admin" "$STALE_MARKER"
}

head_sha() { git rev-parse HEAD 2>/dev/null || true; }

record_head_drift() {
  local before="$1" after="$2" marker recorded
  shift 2
  marker="$(stale_marker_path)" || return 0
  if [ -z "$before" ] || [ -z "$after" ] || [ "$before" = "$after" ]; then
    # Clearing the marker is the claim "the check has been re-run against a
    # tree that held still" — and that is only true of the SAME check. Any
    # wrapped command clearing it meant a `lint:paths -- one-file`, or
    # setup-worktree's own wrapped `cp`, lifted bin/git-push.sh's refusal on
    # behalf of a four-minute lane nobody re-ran (#7454i). So the marker
    # carries the argv that set it, and only that argv retires it. A marker
    # with no command recorded is an older one; clearing it is the safe
    # fallback, since the alternative is a refusal nothing can lift.
    if [ -f "$marker" ]; then
      recorded="$(sed -n 3p "$marker" 2>/dev/null || true)"
      if [ -n "$recorded" ] && [ "$recorded" != "$*" ]; then return 0; fi
    fi
    rm -f "$marker" 2>/dev/null || true
    return 0
  fi
  {
    printf '%s\n' "$before"
    printf '%s\n' "$after"
    printf '%s\n' "$*"
  } > "$marker" 2>/dev/null || return 0
  echo "⚠ with-check-lock: HEAD moved while this ran — ${before:0:12} → ${after:0:12}." >&2
  echo "  Whatever this check reported describes a tree that no longer exists. Another session" >&2
  echo "  committed on this branch in this worktree (MuscleBuddy#7227). bin/git-push.sh will refuse until" >&2
  echo "  the check is re-run against the tree you are actually shipping." >&2
}

run_command() {
  local child status head_before head_after

  head_before="$(head_sha)"

  "$@" 7>&- 8>&- 9>&- &
  child=$!

  # Signals aimed at the wrapper have to reach the command: a caller that TERMs
  # the wrapper to free a held slot means the work to stop, and the command is
  # what needs to hear about it.
  trap 'kill -TERM "$child" 2>/dev/null || true' TERM
  trap 'kill -INT "$child" 2>/dev/null || true' INT
  trap 'kill -HUP "$child" 2>/dev/null || true' HUP

  # `wait` returns as soon as a trap fires, before the child has actually gone,
  # so keep waiting until it really has. Otherwise the reported status would be
  # the interrupted wait's, not the command's.
  while :; do
    status=0
    wait "$child" || status=$?
    if [ "$status" -gt 128 ] && kill -0 "$child" 2>/dev/null; then
      continue
    fi
    break
  done

  head_after="$(head_sha)"
  if [ -n "$record_drift" ]; then
    record_head_drift "$head_before" "$head_after" "$*"
  fi

  exit "$status"
}

# Reader/writer exclusion rides on one gate file: readers hold it shared for as
# long as they run, the writer holds it exclusive. That is the whole mutual
# exclusion — the writer never touches a slot file, so it cannot sit holding half
# the slots while it waits for the rest.
#
# The intent file in front of the gate is what stops the writer starving. `flock`
# grants no priority to a waiting exclusive request, so a steady stream of
# readers can hold the gate shared forever. Every acquirer passes through the
# intent lock first; the writer *keeps* it while it waits, which shuts the door
# on new readers and lets the ones already inside drain.
#
# Order is always intent → gate → slot, and only the writer ever holds intent
# past the gate, so there is no cycle to deadlock on.
gate() {
  local mode="$1" holder="$2"
  exec 8>"$lock_dir/$LOCK_NAME.intent.lock"
  wait_lock 8 -x "$holder"

  exec 7>"$lock_dir/$LOCK_NAME.gate.lock"
  wait_lock 7 "$mode" "$holder"
}

if [ -n "$writer" ]; then
  # Stamped before the wait, not after it: a reader blocked at the door has to be
  # able to name the install that is coming, not just the one already running.
  stamp "$lock_dir/$LOCK_NAME.gate.info" "$@"
  gate -x "$lock_dir/$LOCK_NAME.gate.info"
  # Re-stamped now that the gate is actually held: the row above announced a
  # queued install, and a reader that arrives during the run needs the one that
  # is running. It also re-takes ownership of the row from any writer that queued
  # behind us and overwrote it, so `reap_stamp` clears it on the way out.
  stamp "$lock_dir/$LOCK_NAME.gate.info" "$@"
  # fds 7 and 8 are held by THIS shell for as long as the install runs, and
  # released by the kernel when it exits, however it exits.
  run_command "$@"
fi

gate -s "$lock_dir/$LOCK_NAME.gate.info"

if [ -n "$light" ]; then
  exec 8>&-
  run_command "$@"
fi
# The intent lock has done its job; holding it would serialise readers, which is
# exactly what the semaphore exists not to do.
exec 8>&-

# Admission control (MuscleBuddy#3282): the semaphore counts holders and knows nothing about
# what the box is already doing. Slots are sized from RAM at start-up, so two
# checks are affordable on an idle box and the same two thrash one at load 29 —
# which is how `apps/web` unit tests timed out in files the diff never touched,
# a failure indistinguishable from a regression until it is re-run in isolation.
#
# Above the threshold the semaphore NARROWS to one holder rather than refusing to
# start. Refusing needs a decision about what to do at the deadline, and the two
# available answers are the ones this wrapper already spends a timeout on: fail
# the caller, or proceed into the thrash anyway. Narrowing drains the same queue
# serially instead — slower per check, but each one gets the box, and no caller
# ever waits on a threshold only other processes can clear.
#
# Re-evaluated on every poll, so a queue that formed under load widens again the
# moment it lifts. One slot is the floor by construction: nothing here can reach
# zero and stall the box. A writer is unaffected — it takes the gate, not slots.
default_max_load() {
  local cores
  cores="$(nproc 2>/dev/null || echo 4)"
  echo $((cores * 2))
}

max_load="${CHECK_MAX_LOAD:-$(default_max_load)}"

# The memory floor (MuscleBuddy#4176, MuscleBuddy#4224): load is not the constraint this wrapper exists
# to bound, memory is, and the admission decision above reads only load.
#
# Load narrowing hands the single remaining slot to whoever is next, so a box at
# 23G/23G RAM and 8G/8G swap still admits a check — which the kernel then kills
# mid-run. What that reports is not a queue stall but `Killed`, surfacing as
# `Task failed to spawn: eslint …` or a bare exit 137 from `tsc`, i.e. something
# that reads exactly like a defect in the caller's own diff.
#
# The slot count cannot close this on its own. It is sized from MemTotal at
# start-up and keyed off THIS clone's git dir, so it is blind both to what the
# box is doing later and to the other repos' worktrees on the same machine
# eating the RAM (MuscleBuddy#4224). MemAvailable is the one number that sees all of it.
#
# So: below the floor, admit NOBODY for a while. This is the one place the
# admitted count reaches zero — the load path floors at one because a caller must
# never wait on a threshold only other processes can clear, and memory is exactly
# such a threshold. Which is why the hold is BOUNDED and then yields.
#
# Holding indefinitely was tried and is wrong. A memory hold frees no slot, so it
# does nothing for anyone else; it only backs off and hopes. That works against
# this repo's own spikes, and starves against the other repos' worktrees, which
# never back off and never see this lock. Measured on the box in MuscleBuddy#4224: available
# memory oscillated 634-1936 MB for a quarter of an hour, so a pre-push spent the
# whole CHECK_TIMEOUT under the floor and refused a legitimate push with 75.
# A gate that stops real work is a gate that gets disabled.
#
# The wrapper already answers this question for load — narrow, don't refuse — and
# the same answer applies. After CHECK_MEM_WAIT under the floor the hold gives
# up its veto and admission falls back to the load-narrowed count (one holder on
# a busy box), loudly. That is strictly better than the old behaviour on both
# sides: the transient spike, where most OOM kills happen, is waited out; the
# sustained squeeze proceeds exactly as it did before this gate existed rather
# than turning into a hard stop.
#
# 1.5 GiB sits just above the ~1 GB available at the observed kill, and a single
# `tsc` project or eslint program peaks past 1 GB with the OS needing the rest.
# `CHECK_MIN_AVAIL_MB` retunes it; `0` disables the gate.
min_avail_mb="${CHECK_MIN_AVAIL_MB:-1536}"

# How long the floor may hold before it yields. Well under CHECK_TIMEOUT on
# purpose: the wait budget belongs to slot contention, which clears, not to a
# memory reading this caller cannot influence.
mem_wait_secs="${CHECK_MEM_WAIT:-180}"

# MemAvailable, in MB — the kernel's own estimate of what a new allocation can
# get without swapping, which is the question being asked. MemFree is not: it
# reads near zero on a healthy box that has given the rest to page cache.
#
# `-1` means "cannot tell" (no /proc/meminfo — macOS, some containers), and the
# gate then does nothing rather than blocking every check on an unknown.
available_mb() {
  awk '/^MemAvailable:/ {print int($2 / 1024); found = 1; exit} END {if (!found) print -1}' \
    /proc/meminfo 2>/dev/null || echo -1
}

# The background single-slot waiter, if one is queued (see the admission loop).
queue_pid=""
drop_queue() {
  [ -n "$queue_pid" ] || return 0
  kill "$queue_pid" 2>/dev/null || true
  wait "$queue_pid" 2>/dev/null || true
  queue_pid=""
}
trap 'drop_queue; reap_stamp' EXIT

waited=0
started_at="$(now)"
next_report="$report_secs"
narrowed=""
load_narrowed=""
mem_held=""
mem_yielded=""
while :; do
  admitted="$slots"
  # Set per iteration, unlike `narrowed` (which latches, so its message is said
  # once): the widened deadline below must follow the CURRENT admission width,
  # so a queue that formed under load returns to the ordinary deadline the
  # moment load lifts.
  load_narrowed=""
  if [ "$(current_load)" -gt "$max_load" ]; then
    admitted=1
    load_narrowed=1
    if [ -z "$narrowed" ]; then
      echo "⏳ load $(current_load) is over $max_load — running checks one at a time…"
      narrowed=1
    fi
  fi

  # Only read it when the gate is on: this is a subprocess on every poll of a
  # loop that is already running on a contended box.
  avail=-1
  if [ "$min_avail_mb" -gt 0 ]; then
    avail="$(available_mb)"
  fi

  if [ "$avail" -ge 0 ] && [ "$avail" -lt "$min_avail_mb" ]; then
    if [ -z "$mem_held" ]; then
      mem_held="$(now)"
      echo "⏳ only ${avail}MB of memory is available, under the ${min_avail_mb}MB floor — holding every check until it frees (this is memory pressure, not CPU, and it may be another repo's worktrees)."
    fi
    if [ "$(($(now) - mem_held))" -lt "$mem_wait_secs" ]; then
      admitted=0
    elif [ -z "$mem_yielded" ]; then
      echo "⚠ memory has been under the ${min_avail_mb}MB floor for $(human "$mem_wait_secs") — proceeding anyway on $admitted slot(s). If this check dies with 137 or a bare 'Killed', that is the box, not your diff."
      mem_yielded=1
    fi
  elif [ -n "$mem_held" ]; then
    echo "▶ memory recovered (${avail}MB available) — admitting checks again."
    mem_held=""
    mem_yielded=""
  fi

  # `seq 1 0` emits nothing, so a zero admitted count skips straight to the wait.
  #
  # With more than one candidate the scan has to be non-blocking: blocking on
  # slot 1 while slot 2 sits free would be strictly worse than spinning.
  #
  # With exactly ONE candidate there is nothing to scan, and a non-blocking poll
  # is then a lottery rather than a queue (MuscleBuddy#5922). `flock -n` in a 2-second loop
  # grants no order: the caller that has waited twelve minutes is no likelier to
  # win the next release than one that arrived a second ago, so with six or eight
  # agents behind a narrowed semaphore a waiter can be starved right through
  # CHECK_TIMEOUT and be told "nothing was run" — which is the one outcome
  # that leaves it with no verification signal at all. Blocking hands the
  # ordering to the kernel, which does queue, so every waiter is admitted in
  # turn.
  #
  # The place in that queue has to survive the heartbeat. A `flock -w` that
  # times out leaves the queue, and a newcomer arriving while the loop re-reads
  # load and memory is queued ahead of a waiter that has been there for minutes.
  # So ONE blocking `flock` runs in the background for the whole wait, on the
  # open file description this shell also holds: when it is granted, the lock
  # belongs to that description and stays held after the helper exits. The loop
  # only watches it, so it still re-reads load, memory and the deadline.
  if [ "$admitted" -eq 1 ]; then
    if [ -z "$queue_pid" ]; then
      exec 9>"$lock_dir/$LOCK_NAME.1.lock"
      flock 9 7>&- &
      queue_pid=$!
    fi
    for _ in $(seq 1 "$report_secs"); do
      kill -0 "$queue_pid" 2>/dev/null || break
      sleep 1
    done
    if ! kill -0 "$queue_pid" 2>/dev/null; then
      queue_status=0
      wait "$queue_pid" || queue_status=$?
      queue_pid=""
      if [ "$queue_status" -eq 0 ]; then
        stamp "$lock_dir/$LOCK_NAME.1.info" "$@"
        run_command "$@"
      fi
    fi
  else
    # Admission widened (or memory is holding it at zero): leave the queue.
    drop_queue
    for slot in $(seq 1 "$admitted"); do
      # Reopening fd 9 drops the previous candidate's lock, which is correct — we
      # only ever hold one, and only once flock succeeds.
      exec 9>"$lock_dir/$LOCK_NAME.$slot.lock"
      if flock -n 9; then
        stamp "$lock_dir/$LOCK_NAME.$slot.info" "$@"
        # fds 7 and 9 are held by THIS shell for as long as the check runs, and
        # released by the kernel when it exits, however it exits.
        run_command "$@"
      fi
    done
  fi

  waited=$(($(now) - started_at))
  # Narrowing serialises the queue, so the deadline widens with it. Keyed on the
  # LOAD narrowing rather than on `admitted` alone: an operator who sets
  # CHECK_SLOTS=1 has chosen one slot and their CHECK_TIMEOUT means what
  # it says.
  deadline="$lock_timeout"
  if [ -n "$load_narrowed" ] && [ "$lock_timeout" -gt 0 ]; then
    deadline="$narrowed_timeout"
  fi
  if [ "$waited" -ge "$next_report" ]; then
    if [ "$admitted" -eq 0 ]; then
      echo "⏳ with-check-lock: waiting $(human "$waited") — ${avail}MB available, under the ${min_avail_mb}MB memory floor. No slot was taken; running now would risk an OOM kill."
    else
      echo "⏳ with-check-lock: waiting $(human "$waited") — all $admitted check slots busy:"
      readers "$admitted"
      note_if_idle "$waited"
    fi
    next_report=$((waited + report_secs))
  fi
  if [ "$lock_timeout" -gt 0 ] && [ "$waited" -ge "$deadline" ]; then
    if [ "$admitted" -eq 0 ]; then
      give_up "$waited" "  Available memory stayed under the ${min_avail_mb}MB floor (${avail}MB now).
  This is box-wide memory pressure — check \`free -h\` and \`ps aux --sort=-%mem\`; other repos'
  worktrees on this machine are outside this repo's semaphore and count against the same RAM."
    elif [ -n "$load_narrowed" ]; then
      give_up "$waited" "  The box is over its load threshold ($(current_load) > $max_load), so the semaphore is
  narrowed to one slot and the queue is serial. It is held by:
$(readers "$admitted")
  This is box-wide contention, not your diff. CI runs on isolated runners and
  remains the authoritative gate."
    else
      give_up "$waited" "  All $admitted check slots are busy:
$(readers "$admitted")"
    fi
  fi
  # A single candidate already slept inside `flock -w`, queued in the kernel.
  # Sleeping again OUTSIDE the queue hands a newcomer that window to jump ahead
  # of a waiter that has been queued for minutes — the lottery the blocking
  # wait exists to remove.
  [ "$admitted" -eq 1 ] || sleep 2
done
