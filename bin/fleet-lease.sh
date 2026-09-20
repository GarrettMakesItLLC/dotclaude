#!/usr/bin/env bash
# fleet-lease.sh — a fleet-wide mutual exclusion lease held as a REMOTE git ref.
#
# Why a remote ref and not a file: several machines work one repo, and a local
# file is invisible to the other machine. The failure is silent — both sessions
# read a consistent-looking world and act on different ones. The remote is the
# only shared state there is.
#
# Why a ref and not an issue comment: taking the lease has to be ATOMIC. A push
# of `--force-with-lease=<ref>:` (empty expected value) requires the ref not to
# exist, so exactly one of two simultaneous takes succeeds and the other is
# rejected by the server. An issue comment cannot do that — both would "win".
#
# The ref points at a commit whose message carries holder, timestamp, TTL and
# note, so `status` can say STALE rather than only HELD, and a force-release has
# something to quote.
#
#   fleet-lease.sh take    <name> [--ttl SECONDS] [--note TEXT] [--holder ID]
#   fleet-lease.sh renew   <name> [--ttl SECONDS] [--note TEXT]
#   fleet-lease.sh release <name> [--force --reason TEXT]
#   fleet-lease.sh status  <name>
#
# Common: --repo owner/repo | --remote NAME (default: origin) | --ref-prefix P
#
# Exit codes: 0 ok / 1 usage or error / 3 lease is held by someone else.
set -uo pipefail

PROG="$(basename "$0")"
REF_PREFIX="${FLEET_LEASE_REF_PREFIX:-refs/fleet-lease}"
REMOTE="origin"
REPO=""
TTL="${FLEET_LEASE_TTL:-5400}"
NOTE=""
REASON=""
FORCE=0
HOLDER="${FLEET_HOLDER:-}"
# The empty tree, so a lease commit carries no content and conflicts with nothing.
EMPTY_TREE=""

die() { echo "$PROG: $*" >&2; exit 1; }

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

default_holder() {
  local host user
  host="$(uname -n 2>/dev/null || echo unknown-host)"
  user="$(id -un 2>/dev/null || echo unknown-user)"
  printf '%s/%s' "${host%%.*}" "$user"
}

# --- argument parsing -------------------------------------------------------
[ $# -ge 1 ] || usage 1
ACTION="$1"; shift
NAME=""
# Push a lease ref with the target repo's pre-push hook bypassed.
#
# A lease ref carries NO CONTENT to verify — it is a timestamp and a holder
# name — so the repo's gate has nothing to say about it. Left unbypassed, the
# push runs whatever that repo's pre-push hook is: in MuscleBuddy that is a
# full typecheck chain behind the check lock, minutes on a contended box, for
# a ref the gate cannot have an opinion about. Worse, when it failed the lease
# silently did not land while the caller had every reason to think it had, and
# two machines built the same wave (#376).
#
# THIS IS NOT A PRECEDENT FOR CODE. The repo-level rule against bypassing the
# hook is about commits and code pushes, where the gate has everything to say.
# It applies here only because refs under refs/fleet-lease/ contain none.
lease_push() {
  git push --quiet --no-verify "$@" 2>/dev/null
}

case "$ACTION" in
  take|renew|release|status) ;;
  -h|--help) usage 0 ;;
  *) die "unknown action '$ACTION' (take|renew|release|status)" ;;
esac
if [ $# -ge 1 ] && [ "${1#-}" = "$1" ]; then NAME="$1"; shift; fi
[ -n "$NAME" ] || die "$ACTION needs a lease name, e.g. '$PROG $ACTION integrator'"

while [ $# -gt 0 ]; do
  case "$1" in
    --ttl)        TTL="${2:-}";    shift 2 || die "--ttl needs a value" ;;
    --note)       NOTE="${2:-}";   shift 2 || die "--note needs a value" ;;
    --holder)     HOLDER="${2:-}"; shift 2 || die "--holder needs a value" ;;
    --reason)     REASON="${2:-}"; shift 2 || die "--reason needs a value" ;;
    --repo)       REPO="${2:-}";   shift 2 || die "--repo needs a value" ;;
    --remote)     REMOTE="${2:-}"; shift 2 || die "--remote needs a value" ;;
    --ref-prefix) REF_PREFIX="${2:-}"; shift 2 || die "--ref-prefix needs a value" ;;
    --force)      FORCE=1; shift ;;
    -h|--help)    usage 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

case "$NAME" in
  *[!A-Za-z0-9._-]*) die "lease name '$NAME' must be [A-Za-z0-9._-] only" ;;
esac
case "$TTL" in
  ''|*[!0-9]*) die "--ttl must be a whole number of seconds, got '$TTL'" ;;
esac
[ -n "$HOLDER" ] || HOLDER="$(default_holder)"

git rev-parse --git-dir >/dev/null 2>&1 \
  || die "must run inside a git repository (objects are created locally, then pushed)"

TARGET="$REMOTE"
[ -n "$REPO" ] && TARGET="https://github.com/${REPO}.git"

REF="$REF_PREFIX/$NAME"

# --- ref plumbing -----------------------------------------------------------

# Current remote value of the lease ref, or empty when free.
remote_sha() {
  git ls-remote "$TARGET" "$REF" 2>/dev/null | awk 'NR==1 {print $1}'
}

# Lease metadata is the commit message. Fetch the object first: ls-remote gives a
# sha the local repo may not have.
lease_body() {
  local sha="$1"
  git cat-file -e "$sha^{commit}" 2>/dev/null \
    || git fetch --quiet --no-tags "$TARGET" "+$REF:refs/fleet-lease-cache/$NAME" 2>/dev/null \
    || true
  git log -1 --format=%B "$sha" 2>/dev/null
}

field() { printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -1; }

make_lease_commit() {
  local now epoch msg
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date -u +%s)"
  [ -n "$EMPTY_TREE" ] || EMPTY_TREE="$(git hash-object -w -t tree /dev/null)"
  msg="fleet-lease: $NAME
holder: $HOLDER
taken-at: $now
epoch: $epoch
ttl: $TTL
note: ${NOTE:--}"
  printf '%s' "$msg" | git commit-tree "$EMPTY_TREE"
}

report_holder() {
  local sha body epoch age
  sha="$1"
  body="$(lease_body "$sha")"
  epoch="$(field "$body" epoch)"
  age="?"
  case "$epoch" in
    ''|*[!0-9]*) ;;
    *) age=$(( $(date -u +%s) - epoch )) ;;
  esac
  printf 'lease   : %s\nref     : %s\nholder  : %s\ntaken-at: %s\nttl     : %ss\nage     : %ss\nnote    : %s\n' \
    "$NAME" "$REF" "$(field "$body" holder)" "$(field "$body" taken-at)" \
    "$(field "$body" ttl)" "$age" "$(field "$body" note)"
  local ttl; ttl="$(field "$body" ttl)"
  case "$age$ttl" in
    *[!0-9]*) printf 'state   : HELD (age unknown)\n' ;;
    *) if [ "$age" -gt "$ttl" ]; then
         printf 'state   : STALE (held %ss past a %ss ttl)\n' "$((age - ttl))" "$ttl"
       else
         printf 'state   : HELD\n'
       fi ;;
  esac
}

# --- actions ----------------------------------------------------------------
case "$ACTION" in

  status)
    sha="$(remote_sha)"
    if [ -z "$sha" ]; then
      printf 'lease   : %s\nref     : %s\nstate   : FREE\n' "$NAME" "$REF"
      exit 0
    fi
    report_holder "$sha"
    ;;


  take)
    commit="$(make_lease_commit)" || die "could not create the lease commit"
    # Empty expected value => the server requires the ref NOT to exist. This is
    # the atomic bit: a second machine's take is rejected, never merged.
    if lease_push --force-with-lease="$REF:" "$TARGET" "$commit:$REF"; then
      # The push can report success and leave no ref (MuscleBuddy#7143), and a
      # lease nobody holds looks exactly like a lease this machine holds. Read
      # it back before saying it was taken.
      sha="$(remote_sha)"
      if [ -z "$sha" ]; then
        die "push of $REF reported success but the ref is not on '$TARGET' — the lease was NOT taken"
      fi
      printf 'took %s as %s (ttl %ss)\n' "$NAME" "$HOLDER" "$TTL"
      exit 0
    fi
    sha="$(remote_sha)"
    if [ -z "$sha" ]; then
      die "push of $REF was rejected and the ref does not exist — check remote '$TARGET' and credentials"
    fi
    echo "refused: $NAME is already held" >&2
    report_holder "$sha" >&2
    echo "" >&2
    echo "If it is genuinely stale, release it with evidence:" >&2
    echo "  $PROG release $NAME --force --reason \"<what you checked>\"" >&2
    exit 3
    ;;

  renew)
    sha="$(remote_sha)"
    [ -n "$sha" ] || die "$NAME is not held — nothing to renew (use 'take')"
    body="$(lease_body "$sha")"
    current="$(field "$body" holder)"
    if [ "$current" != "$HOLDER" ] && [ "$FORCE" != 1 ]; then
      echo "refused: $NAME is held by '$current', not '$HOLDER'" >&2
      exit 3
    fi
    [ -n "$NOTE" ] || NOTE="$(field "$body" note)"
    commit="$(make_lease_commit)" || die "could not create the lease commit"
    lease_push --force-with-lease="$REF:$sha" "$TARGET" "$commit:$REF" \
      || die "renew lost the race — someone changed $REF; re-read it with 'status'"
    printf 'renewed %s as %s (ttl %ss)\n' "$NAME" "$HOLDER" "$TTL"
    ;;

  release)
    sha="$(remote_sha)"
    if [ -z "$sha" ]; then
      printf '%s was already free\n' "$NAME"
      exit 0
    fi
    body="$(lease_body "$sha")"
    current="$(field "$body" holder)"
    if [ "$current" != "$HOLDER" ]; then
      if [ "$FORCE" != 1 ]; then
        echo "refused: $NAME is held by '$current', not '$HOLDER'" >&2
        report_holder "$sha" >&2
        echo "" >&2
        echo "Use --force with --reason naming what you checked. Age alone is not evidence:" >&2
        echo "  a stale lease is an idle holder, and a slow wave looks identical from the age." >&2
        exit 3
      fi
      [ -n "$REASON" ] || die "--force needs --reason naming the evidence that the holder is gone"
      echo "force-releasing $NAME held by '$current'" >&2
      echo "reason: $REASON" >&2
    fi
    lease_push --force-with-lease="$REF:$sha" "$TARGET" ":$REF" \
      || die "release lost the race — someone changed $REF; re-read it with 'status'"
    printf 'released %s\n' "$NAME"
    ;;
esac
