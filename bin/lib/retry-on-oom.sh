# shellcheck shell=sh
# retry_on_oom <command> [args…] — sourced, never run.
#
# Re-runs a check that the kernel OOM-killed (exit 137), up to twice, with a
# growing pause between attempts. The memory floor in with-check-lock.sh decides
# ADMISSION; a check admitted with headroom can still be killed minutes later
# when the box starves around it, and that SIGKILL is the box, not the diff.
#
# Only 137 is retried. A real failure (a type error is 1 or 2) and the lock's own
# 75 ("retry me later") pass straight through on the first attempt: retrying 75
# in-process only re-queues behind the contention that produced it.
#
# POSIX sh, so a husky hook (`sh -e`) can source it:
#   . "$HOME/.claude/bin/lib/retry-on-oom.sh"
#   retry_on_oom ~/.claude/bin/with-check-lock.sh npm run typecheck
#
# OOM_RETRY_BACKOFF_SECS (default 45) is the pause before the first retry; the
# second waits twice that.
retry_on_oom() {
  _oom_attempt=1
  while :; do
    _oom_status=0
    "$@" || _oom_status=$?
    if [ "$_oom_status" -eq 0 ]; then return 0; fi
    if [ "$_oom_status" -ne 137 ] || [ "$_oom_attempt" -ge 3 ]; then return "$_oom_status"; fi
    echo "⚠ check was OOM-killed (137) — the box, not your diff. Retry $_oom_attempt of 2 in $((_oom_attempt * ${OOM_RETRY_BACKOFF_SECS:-45}))s…" >&2
    sleep $((_oom_attempt * ${OOM_RETRY_BACKOFF_SECS:-45}))
    _oom_attempt=$((_oom_attempt + 1))
  done
}
