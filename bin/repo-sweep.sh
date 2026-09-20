#!/usr/bin/env bash
# repo-sweep.sh — fast-forward every repo in the fleet, and say plainly which
# ones it would not touch and why.
#
# THE PROBLEM THIS SOLVES
#   `dsync` covers the two dot repos. Everything else drifts silently: one
#   machine's `platform` checkout sat 52 commits behind its default branch for
#   three weeks while every repo that consumes it built against the old one.
#   Nothing was broken enough to notice.
#
#   Pulling the fleet has been attempted before and was dropped after
#   intermittent errors, so THE FAILURE HANDLING IS THE DELIVERABLE, not the
#   pull. Every repo either moves, is already current, or is skipped with one
#   line naming the reason — and the run never aborts on any of them, because a
#   sweep that stops at the first awkward checkout tells you nothing about the
#   other nine. The skipped-with-reason rows are the product: they are what says
#   a machine has drifted, and why.
#
#   ONE implementation, two entry points. `bin/dot-sync.sh` calls it after
#   pulling the dot repos; dotfiles' `bootstrap/device.sh` calls it instead of
#   its own inline pull. Nothing here is a third path.
#
# WHAT IT REFUSES TO DO
#   Only `--ff-only`, ever. Never a merge, never a rebase, never a force, never
#   a branch switch, never a stash — `refs/stash` is shared by every worktree of
#   a repo, so a sweep that stashed would pop a sibling agent's work.
#
#   And it never pulls a checkout with ACTIVE LINKED WORKTREES. Sibling agents
#   resolve `node_modules` upward from the main checkout, so moving it under
#   them invalidates installs in trees that are mid-flight. That case is not
#   hypothetical: it is live on this box most days.
#
#   Usage:
#     bin/repo-sweep.sh                  # sweep the roster, report, change no deps
#     bin/repo-sweep.sh --deps           # also install where a repo actually moved
#     bin/repo-sweep.sh --only platform  # one repo
#     bin/repo-sweep.sh --dry-run        # decide and report, fetch nothing, pull nothing
#
#   Options:
#     --roster PATH     repos.tsv to read (default: $DOTFILES_DIR/bootstrap/repos.tsv)
#     --workspace PATH  where checkouts live (default: $WORKSPACE, else ~/workspace)
#     --all             include repos the roster marks `archive`
#
# Exit 0 whenever the sweep ran, whatever it found. A skip is an answer.
set -uo pipefail

PROG="$(basename "$0")"

WORKSPACE_DIR="${WORKSPACE:-$HOME/workspace}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
ROSTER="${REPO_SWEEP_ROSTER:-$DOTFILES_DIR/bootstrap/repos.tsv}"
DO_DEPS=0
DRY_RUN=0
INCLUDE_ARCHIVE=0
ONLY=""

die() { echo "$PROG: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --deps)      DO_DEPS=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --all)       INCLUDE_ARCHIVE=1 ;;
    --only)      ONLY="${2:-}"; shift ;;
    --roster)    ROSTER="${2:-}"; shift ;;
    --workspace) WORKSPACE_DIR="${2:-}"; shift ;;
    -h|--help)   sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown option '$1' (try --help)" ;;
  esac
  shift
done

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
work() { printf '  \033[36m..\033[0m    %s\n' "$*"; }
skip() { printf '  \033[33mskip\033[0m  %s\n' "$*"; }

# rows: "<name>\t<branch>\t<result>"
rows=()
moved=0
record() { rows+=("$1"$'\t'"$2"$'\t'"$3"); }

# --------------------------------------------------------------------------
# Which repos, and where. The roster is data (dotfiles' repos.tsv); discovery
# is the fallback for a machine whose dotfiles checkout is missing or older
# than a repo that was added since. Discovery never invents an entry the roster
# already has.
# --------------------------------------------------------------------------
declare -A seen_dir=()
targets=()   # "<name>\t<dir>\t<pm>"

add_target() {
  local name="$1" dir="$2" pm="$3"
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || return 0
  [ -n "${seen_dir[$dir]:-}" ] && return 0
  seen_dir[$dir]=1
  if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then return 0; fi
  targets+=("$name"$'\t'"$dir"$'\t'"$pm")
}

if [ -f "$ROSTER" ]; then
  while IFS=$'\t' read -r slug role pm _boot; do
    case "${slug:-}" in ''|\#*) continue ;; esac
    [ "$role" = archive ] && [ "$INCLUDE_ARCHIVE" -eq 0 ] && continue
    name="${slug##*/}"
    # Same layout rule device.sh uses: product repos flat, infra/archive under
    # Tools/, except one already checked out flat (a machine set up before the
    # split), which stays where it is rather than being duplicated.
    if [ "$role" = product ] || [ "$name" = dotfiles ]; then
      dir="$WORKSPACE_DIR/$name"
    else
      dir="$WORKSPACE_DIR/Tools/$name"
      [ -d "$WORKSPACE_DIR/$name/.git" ] && dir="$WORKSPACE_DIR/$name"
    fi
    add_target "$name" "$dir" "${pm:-none}"
  done < "$ROSTER"
else
  echo "  note: no roster at $ROSTER — falling back to discovery under $WORKSPACE_DIR"
fi

# Discovery: anything in the workspace with a GitHub remote that the roster did
# not already name. A repo added to the fleet last week is not a reason for this
# to miss it.
for d in "$WORKSPACE_DIR"/* "$WORKSPACE_DIR"/Tools/*; do
  # `.git` as a FILE is a linked worktree. Kept rather than filtered out: a
  # worktree sitting in the workspace root is worth a row saying whose it is,
  # not a silent omission that reads as "this machine does not have that repo".
  { [ -d "$d/.git" ] || [ -f "$d/.git" ]; } || continue
  git -C "$d" remote get-url origin 2>/dev/null | grep -q 'github\.com' || continue
  add_target "$(basename "$d")" "$d" none
done

if [ "${#targets[@]}" -eq 0 ]; then
  echo "$PROG: no checkouts found under $WORKSPACE_DIR"
  exit 0
fi

# One repo checked out at two paths is not a display problem, it is the
# "silently fork the checkout in two places" hazard the roster's layout rule
# exists to avoid — and it is live on this box. Label each by its
# workspace-relative path so the table names which one it is talking about, and
# say so once at the top.
declare -A name_count=()
for t in "${targets[@]}"; do
  IFS=$'\t' read -r n _ _ <<<"$t"
  name_count[$n]=$(( ${name_count[$n]:-0} + 1 ))
done
dupes=()
relabelled=()
for t in "${targets[@]}"; do
  IFS=$'\t' read -r n d p <<<"$t"
  if [ "${name_count[$n]}" -gt 1 ]; then
    case " ${dupes[*]:-} " in *" $n "*) : ;; *) dupes+=("$n") ;; esac
    n="${d#"$WORKSPACE_DIR"/}"
  fi
  relabelled+=("$n"$'\t'"$d"$'\t'"$p")
done
targets=("${relabelled[@]}")

# --------------------------------------------------------------------------
# The default branch, read from the REMOTE. platform's is `dev`, not `main`,
# and that single assumption is enough to make a sweep wrong everywhere.
# Prefers the local symref (free); falls back to asking the remote (one network
# call) and caches the answer back into the checkout.
# --------------------------------------------------------------------------
default_branch() {
  local dir="$1" def
  def="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  def="${def#origin/}"
  if [ -z "$def" ]; then
    def="$(git -C "$dir" ls-remote --symref origin HEAD 2>/dev/null \
           | awk '$1 == "ref:" { sub("refs/heads/", "", $2); print $2; exit }')"
    [ -n "$def" ] && git -C "$dir" symbolic-ref "refs/remotes/origin/HEAD" \
      "refs/remotes/origin/$def" 2>/dev/null
  fi
  printf '%s' "$def"
}

# --------------------------------------------------------------------------
# One repo. Every early return is a recorded reason, never an abort.
# --------------------------------------------------------------------------
sweep_one() {
  local name="$1" dir="$2" pm="$3"
  local branch def dirty ahead behind counts wt

  # A checkout that is itself a linked worktree must never be pulled: its HEAD
  # belongs to whoever is working in it, and the shared checkout is elsewhere.
  if [ -f "$dir/.git" ]; then
    record "$name" "-" "skipped — this checkout is a linked worktree, not the main one"
    skip "$name: a linked worktree — its owner drives it"
    return
  fi

  # Sibling agents resolve node_modules upward from here. Pulling under them
  # invalidates installs in trees that are mid-flight, with no error anywhere.
  wt="$(git -C "$dir" worktree list --porcelain 2>/dev/null | grep -c '^worktree ')"
  if [ "${wt:-1}" -gt 1 ]; then
    record "$name" "-" "skipped — $((wt - 1)) active worktree(s); siblings resolve node_modules upward"
    skip "$name: $((wt - 1)) active worktree(s) — pulling under them would invalidate their installs"
    return
  fi

  branch="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)"
  if [ -z "$branch" ]; then
    record "$name" "-" "skipped — detached HEAD"
    skip "$name: detached HEAD"
    return
  fi

  dirty="$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null | grep -c .)"
  if [ "${dirty:-0}" -gt 0 ]; then
    record "$name" "$branch" "skipped — $dirty uncommitted file(s)"
    skip "$name: $dirty uncommitted file(s) on $branch"
    return
  fi

  def="$(default_branch "$dir")"
  if [ -z "$def" ]; then
    record "$name" "$branch" "skipped — could not read the default branch from the remote"
    skip "$name: could not read origin's default branch (network or auth)"
    return
  fi
  if [ "$branch" != "$def" ]; then
    # Not an error and not something to correct. The owner is mid-feature.
    record "$name" "$branch" "skipped — on $branch, default is $def (probably mid-feature)"
    skip "$name: on $branch, not the default $def"
    return
  fi

  if [ "$DRY_RUN" = 1 ]; then
    record "$name" "$branch" "dry run — would fast-forward $def"
    work "$name: dry run"
    return
  fi

  # One fetch. No retry loop: an intermittent network error is a skip with a
  # reason, and retrying is what turned the last attempt at this into something
  # that hung instead of reporting.
  if ! git -C "$dir" fetch --quiet --no-tags origin "$def" 2>/dev/null; then
    record "$name" "$branch" "skipped — fetch failed (network or auth)"
    skip "$name: fetch failed — network or auth, not retried"
    return
  fi

  counts="$(git -C "$dir" rev-list --left-right --count "HEAD...origin/$def" 2>/dev/null)"
  ahead="${counts%%	*}"
  behind="${counts##*	}"
  if [ -z "$counts" ]; then
    record "$name" "$branch" "skipped — could not compare against origin/$def"
    skip "$name: could not compare against origin/$def"
    return
  fi
  if [ "${ahead:-0}" -gt 0 ]; then
    record "$name" "$branch" "skipped — diverged: $ahead ahead, $behind behind"
    skip "$name: diverged — $ahead ahead, $behind behind origin/$def"
    return
  fi
  if [ "${behind:-0}" -eq 0 ]; then
    record "$name" "$branch" "already current"
    return
  fi

  if git -C "$dir" merge --ff-only --quiet "origin/$def" 2>/dev/null; then
    record "$name" "$branch" "pulled $behind commit(s)"
    ok "$name: fast-forwarded $behind commit(s) on $def"
    moved=$((moved + 1))
  else
    record "$name" "$branch" "skipped — fast-forward refused"
    skip "$name: fast-forward refused despite being $behind behind"
    return
  fi

  # Dependencies only where the tree actually moved, and only on request:
  # installs are slow and contend with every other agent on the box.
  [ "$DO_DEPS" = 1 ] || return
  case "$pm" in
    npm)
      work "$name: npm ci"
      # The shared @gmi/* packages need GitHub Packages auth even for this
      # org's own package, and an EMPTY token exits 0 having omitted them.
      if [ -z "${NODE_AUTH_TOKEN:-}" ] && [ -z "${GH_TOKEN:-}" ]; then
        skip "$name: no NODE_AUTH_TOKEN/GH_TOKEN — install skipped rather than run half of it"
        return
      fi
      if ( cd "$dir" && NODE_AUTH_TOKEN="${NODE_AUTH_TOKEN:-$GH_TOKEN}" npm ci >/dev/null 2>&1 ); then
        ok "$name: dependencies installed"
      else
        skip "$name: npm ci failed — run it by hand to see why"
      fi
      ;;
    pnpm)
      work "$name: pnpm install"
      if ( cd "$dir" && pnpm install --frozen-lockfile >/dev/null 2>&1 ); then
        ok "$name: dependencies installed"
      else
        skip "$name: pnpm install failed — run it by hand to see why"
      fi
      ;;
  esac
}

printf '\n\033[1mRepo sweep\033[0m  (%s)\n' "$WORKSPACE_DIR"
if [ "${#dupes[@]}" -gt 0 ]; then
  for n in "${dupes[@]}"; do
    echo "  note: $n is checked out at more than one path — two checkouts of one repo drift apart silently"
  done
fi
for t in "${targets[@]}"; do
  IFS=$'\t' read -r name dir pm <<<"$t"
  sweep_one "$name" "$dir" "$pm"
done

# --------------------------------------------------------------------------
# The table. This is the deliverable — a machine that has drifted, and why.
# --------------------------------------------------------------------------
echo
printf '  %-24s %-18s %s\n' "REPO" "BRANCH" "RESULT"
for r in "${rows[@]}"; do
  IFS=$'\t' read -r name branch result <<<"$r"
  printf '  %-24s %-18.18s %s\n' "$name" "$branch" "$result"
done
echo
if [ "$moved" -eq 0 ] && [ "$DRY_RUN" = 0 ]; then
  echo "  Nothing moved — every repo was already current or skipped for the reason above."
fi
exit 0
