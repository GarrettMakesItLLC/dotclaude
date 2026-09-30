#!/usr/bin/env bash
#
# Gate, then push, then prove it landed.
#
# Usage: bin/git-push.sh [any git push arguments]
#
# Two failures this exists for, both of which leave the ref unmoved:
#
# 1. A slow pre-push hook. git opens the transport BEFORE it runs the hook, so a
#    hook that runs for minutes holds an idle connection that gets dropped: the
#    push exits 141 or "Connection closed" although the gate had passed, and the
#    rerun pays for the whole gate again. So the hook runs FIRST, on its own,
#    fed the stdin git would feed it; only after it passes does
#    `git push --no-verify` open a connection, which then lives for the transfer
#    alone. The hook is the literal file git would have run (`core.hooksPath`
#    or `.git/hooks/pre-push`), never a copy of its checks.
#
# 2. A push whose exit code lies: 141, a closed connection, or exit 0 with no
#    `To <remote>` line and the branch still ahead. So whatever `git push` exits,
#    every pushed ref is compared against `git ls-remote` and a mismatch fails.
#
# Every run writes its own log under a fresh `mktemp -d`, stamped with a nonce and
# checked again at exit, so a caller that redirects output to a path another
# session also uses cannot read someone else's evidence as its own. The log path
# is printed on the first line.
#
# Forms whose landed state is not one local-vs-remote comparison (--delete,
# --dry-run, --mirror, --all, --tags, --prune) push as-is and say verification
# was skipped.
set -uo pipefail

push_log_dir="$(mktemp -d "${TMPDIR:-/tmp}/git-push-log.XXXXXX" 2>/dev/null || true)"
push_log=""
push_nonce=""
if [ -n "$push_log_dir" ]; then
  push_log="$push_log_dir/push.log"
  push_nonce="$$-$(date +%s%N 2>/dev/null || date +%s)-$RANDOM"
  printf 'nonce:%s\n' "$push_nonce" >"$push_log" 2>/dev/null || { push_log=""; push_nonce=""; }
fi

say() {
  printf '%s\n' "$*" >&2
  [ -z "$push_log" ] || printf '%s\n' "$*" >>"$push_log" 2>/dev/null || true
}

verify_push_log() {
  [ -n "$push_log" ] || return 0
  local first_line
  first_line="$(head -n1 "$push_log" 2>/dev/null || true)"
  [ "$first_line" = "nonce:$push_nonce" ] && return 0
  printf '✗ push log collision: %s no longer starts with the nonce this run stamped.\n' "$push_log" >&2
  printf '  Found instead: %s\n' "${first_line:-<empty>}" >&2
  printf '  Treat every line in it as UNTRUSTED, including any push evidence, and re-run.\n' >&2
  return 1
}

[ -z "$push_log" ] || say "→ push log: $push_log"

remote=''
refspecs=()
skip_reason=''
expect_value_next=0
for arg in "$@"; do
  if [ "$expect_value_next" -eq 1 ]; then expect_value_next=0; continue; fi
  case "$arg" in
    --delete | -d) skip_reason='a deletion' ;;
    --dry-run | -n) skip_reason='--dry-run' ;;
    --mirror) skip_reason='--mirror' ;;
    --all) skip_reason='--all' ;;
    --tags) skip_reason='--tags' ;;
    --prune) skip_reason='--prune' ;;
    -o | --push-option | --receive-pack | --exec | --repo) expect_value_next=1 ;;
    -*) ;;
    *) if [ -z "$remote" ]; then remote="$arg"; else refspecs+=("$arg"); fi ;;
  esac
done

# Closed readers become ordinary write errors instead of SIGPIPE, and the output
# is captured so nothing downstream can close the reader mid-push.
push_output=$(mktemp "${TMPDIR:-/tmp}/git-push.XXXXXX")
cleanup_and_verify_exit() {
  local status=$?
  rm -f "$push_output"
  verify_push_log || status=1
  exit "$status"
}
trap cleanup_and_verify_exit EXIT

# Keepalives keep the transfer's own SSH connection alive. A caller's
# GIT_SSH_COMMAND or `core.sshCommand` wins; this only fills in the default.
if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -z "$(git config core.sshCommand 2>/dev/null)" ]; then
  export GIT_SSH_COMMAND='ssh -o ServerAliveInterval=20 -o ServerAliveCountMax=90'
fi

# Where a bare `git push` sends this branch is decided by `push.default`, not by
# the upstream alone: a branch stacked on a sibling has a different upstream than
# its own name. Resolved before the push, because the hook's stdin needs the same
# target and a detached HEAD must refuse before anything is pushed.
branch=$(git symbolic-ref --quiet --short HEAD || true)
if [ -z "$skip_reason" ]; then
  if [ -z "$remote" ]; then
    remote=$(git config "branch.$branch.remote" 2>/dev/null || true)
    [ -n "$remote" ] || remote=origin
  fi
  if [ "${#refspecs[@]}" -eq 0 ]; then
    if [ -z "$branch" ]; then
      say "✗ cannot verify a push from a detached HEAD without an explicit refspec."
      say "  Re-run naming one: bin/git-push.sh $remote HEAD:refs/heads/<branch>"
      exit 1
    fi
    push_default=$(git config push.default 2>/dev/null || true)
    [ -n "$push_default" ] || push_default=simple
    case "$push_default" in
      upstream | tracking)
        upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
        refspecs=("${branch}:${upstream#"$remote"/}")
        ;;
      *) refspecs=("${branch}:${branch}") ;;
    esac
    [ -n "${refspecs[0]#*:}" ] || refspecs=("${branch}:${branch}")
  fi
fi

# A refspec as its local source and fully-qualified remote destination, shared by
# the hook preflight and the verification loop so they cannot disagree.
resolve_spec() {
  local spec="$1" src dst
  spec="${spec#+}"
  if [ "${spec#*:}" = "$spec" ]; then src="$spec"; dst="$spec"; else src="${spec%%:*}"; dst="${spec#*:}"; fi
  if [ "$dst" = "HEAD" ]; then
    [ -n "$branch" ] || return 1
    dst="$branch"
  fi
  case "$dst" in
    refs/*) : ;;
    *)
      if git rev-parse --verify --quiet "refs/tags/$dst" >/dev/null; then dst="refs/tags/$dst"; else dst="refs/heads/$dst"; fi
      ;;
  esac
  printf '%s\t%s\n' "$src" "$dst"
}

# `core.hooksPath` when set (relative to the worktree root, as husky installs it),
# else the repo's own hooks directory.
resolve_git_hook_file() {
  local configured toplevel hooks_path
  configured="$(git config core.hooksPath 2>/dev/null || true)"
  if [ -n "$configured" ]; then
    case "$configured" in
      /*) hooks_path="$configured" ;;
      *)
        toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
        hooks_path="$toplevel/$configured"
        ;;
    esac
  else
    hooks_path="$(git rev-parse --git-path hooks 2>/dev/null)" || return 1
  fi
  printf '%s/pre-push' "$hooks_path"
}

zero=0000000000000000000000000000000000000000
preflight_no_verify=""
if [ -z "$skip_reason" ] && hook_file=$(resolve_git_hook_file) && [ -x "$hook_file" ]; then
  remote_url=$(git remote get-url "$remote" 2>/dev/null || printf '%s' "$remote")
  hook_stdin=""
  hook_resolve_ok=1
  for spec in "${refspecs[@]}"; do
    # An unresolvable spec fails the real push the same way; let it say so.
    resolved=$(resolve_spec "$spec") || { hook_resolve_ok=0; break; }
    spec_src="${resolved%%$'\t'*}"
    spec_dst="${resolved#*$'\t'}"
    spec_local_sha=""
    spec_local_ref=""
    if [ -n "$spec_src" ]; then
      spec_local_sha=$(git rev-parse --verify --quiet "$spec_src" 2>/dev/null || true)
      spec_local_ref=$(git rev-parse --symbolic-full-name --verify --quiet "$spec_src" 2>/dev/null || true)
    fi
    [ -n "$spec_local_ref" ] || spec_local_ref="$spec_dst"
    # Hooks read only the local sha (all zeros means a deletion), so the remote
    # side is a placeholder.
    hook_stdin="${hook_stdin}${spec_local_ref} ${spec_local_sha:-$zero} ${spec_dst} ${zero}
"
  done

  if [ "$hook_resolve_ok" -eq 1 ]; then
    hook_output=$(mktemp "${TMPDIR:-/tmp}/git-push-hook.XXXXXX")
    printf '%s' "$hook_stdin" | (trap '' PIPE; "$hook_file" "$remote" "$remote_url") >"$hook_output" 2>&1
    hook_status=$?
    cat "$hook_output" >&2
    [ -z "$push_log" ] || cat "$hook_output" >>"$push_log" 2>/dev/null || true
    rm -f "$hook_output"
    if [ "$hook_status" -ne 0 ]; then
      say "✗ pre-push hook failed (code $hook_status) — nothing was pushed."
      say "  It ran on its own, before any connection to $remote opened, so this is the check"
      say "  failing on your diff, not a transport problem. Fix it and push again through this wrapper."
      exit "$hook_status"
    fi
    preflight_no_verify=1
  fi
fi

if [ -n "$preflight_no_verify" ]; then
  (trap '' PIPE; git push --no-verify "$@") >"$push_output" 2>&1
else
  (trap '' PIPE; git push "$@") >"$push_output" 2>&1
fi
push_status=$?
cat "$push_output" >&2
[ -z "$push_log" ] || cat "$push_output" >>"$push_log" 2>/dev/null || true

if [ -n "$skip_reason" ]; then
  say "ℹ push verification skipped ($skip_reason) — check the remote yourself."
  exit "$push_status"
fi

# `ls-remote` reaches the network too, and the failures this guards against are
# transient, so a guard that cannot read the remote says so instead of passing.
read_remote_ref() {
  local ref="$1" attempt=1 out backoff="${GIT_PUSH_VERIFY_BACKOFF_S:-3}"
  while :; do
    if out=$(git ls-remote "$remote" "$ref" 2>/dev/null); then
      printf '%s' "$(printf '%s' "$out" | awk 'NR==1{print $1}')"
      return 0
    fi
    [ "$attempt" -lt 3 ] || return 1
    sleep $((attempt * backoff))
    attempt=$((attempt + 1))
  done
}

status=0
for spec in "${refspecs[@]}"; do
  if ! resolved=$(resolve_spec "$spec"); then
    say "✗ cannot verify '$spec' from a detached HEAD — name the destination ref explicitly."
    status=1
    continue
  fi
  src="${resolved%%$'\t'*}"
  dst_ref="${resolved#*$'\t'}"

  local_sha=''
  if [ -n "$src" ]; then
    local_sha=$(git rev-parse --verify --quiet "$src" || true)
    if [ -z "$local_sha" ]; then
      say "✗ cannot verify $dst_ref: '$src' does not resolve locally."
      status=1
      continue
    fi
  fi

  if ! remote_sha=$(read_remote_ref "$dst_ref"); then
    say "✗ push verification could not run: three attempts to read $remote $dst_ref failed."
    say "  The push reported exit $push_status, which is not evidence it landed. Read the ref"
    say "  yourself before opening a PR: git ls-remote $remote $dst_ref"
    status=1
    continue
  fi

  if [ "$remote_sha" = "$local_sha" ]; then
    if [ "$push_status" -ne 0 ]; then
      say "ℹ git push exited $push_status, but $remote $dst_ref already matches $local_sha."
    else
      say "✓ $remote $dst_ref is at $local_sha"
    fi
    continue
  fi

  say "✗ the push did NOT land, whatever it printed."
  say "    local  $src = ${local_sha:-<none>}"
  say "    remote $dst_ref = ${remote_sha:-<absent>}"
  say "    git push exited $push_status"
  case "$(cat "$push_output")" in
    *'[rejected]'* | *'non-fast-forward'* | *'fetch first'* | *'stale info'*)
      say "  git REJECTED this ref: the remote holds commits yours does not, so retrying changes"
      say "  nothing. Integrate first: git fetch $remote && git rebase $remote/${dst_ref#refs/heads/}"
      say "  then push again. A force-push over a shared branch is not the remedy."
      ;;
    *)
      say "  An exit code is not evidence a push landed; the remote ref is. Retry through this"
      say "  wrapper, and do not open or re-arm a PR until it says ✓. If a second attempt also"
      say "  leaves $remote $dst_ref at ${remote_sha:-<absent>}, the failure is deterministic:"
      say "  push over HTTPS instead, which is stateless (it reruns the hook, but survives it):"
      say "    git -c credential.helper='!gh auth git-credential' push https://github.com/<owner>/<repo>.git ${src:-HEAD}:$dst_ref"
      ;;
  esac
  status=1
done

if [ "$status" -ne 0 ]; then exit "$status"; fi
exit "$push_status"
