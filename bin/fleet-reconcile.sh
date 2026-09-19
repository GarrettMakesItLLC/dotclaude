#!/usr/bin/env bash
# fleet-reconcile.sh — make the tracker match what actually shipped.
#
# The failure this fixes: issues that shipped and never closed. Three ways it
# happens, all silent, all in the direction of looking like more work remains
# than does:
#   - a merge with the branch rules lifted skips the workflow that closes issues
#     and clears status labels, because that workflow needs Actions;
#   - `Closes #A, #B` on one line closes only #A — GitHub wants the keyword
#     repeated per issue, and the one-line form reads correct to a human;
#   - a merged branch survives its PR, so the branch list stops meaning anything.
#
# For a merged PR (or the last N merges) this verifies every closing reference
# in the body actually closed, closes what did not with evidence, clears
# `status:*` labels from closed issues, and deletes remote branches fully
# contained in the merged commit whose issues are closed.
#
#   fleet-reconcile.sh [--repo owner/repo] [--pr N | --last N] [--apply]
#                      [--no-branches] [--base BRANCH]
#
# Dry run by default. Nothing is written until --apply.
# Exit 0 when the tracker is consistent (or was made so), 1 on an error.
set -uo pipefail

PROG="$(basename "$0")"
GH="${FLEET_GH:-gh}"
REPO=""
PR=""
LAST=5
APPLY=0
DO_BRANCHES=1
BASE=""

die() { echo "$PROG: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)        REPO="${2:-}"; shift 2 || die "--repo needs owner/repo" ;;
    --pr)          PR="${2:-}"; shift 2 || die "--pr needs a number" ;;
    --last)        LAST="${2:-}"; shift 2 || die "--last needs a number" ;;
    --base)        BASE="${2:-}"; shift 2 || die "--base needs a branch" ;;
    --apply)       APPLY=1; shift ;;
    --no-branches) DO_BRANCHES=0; shift ;;
    -h|--help)     sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

case "$LAST" in ''|*[!0-9]*) die "--last must be a number, got '$LAST'" ;; esac
[ -z "$PR" ] || case "$PR" in *[!0-9]*) die "--pr must be a number, got '$PR'" ;; esac

if [ -z "$REPO" ]; then
  REPO="$("$GH" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
    || die "could not determine the repo; pass --repo owner/repo"
fi
[ -n "$REPO" ] || die "could not determine the repo; pass --repo owner/repo"

api() { "$GH" api "$@"; }

# Percent-encode a label for the final path segment. `gh api .../labels/status:x`
# 404s on a label that exists, so an unencoded DELETE reports success at doing
# nothing — the exact shape of bug this script exists to clean up.
urlenc() {
  LC_ALL=C python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

say()  { printf '%s\n' "$*"; }
act()  { if [ "$APPLY" = 1 ]; then printf '  DO   %s\n' "$*"; else printf '  WOULD %s\n' "$*"; fi; }

changes=0
errors=0

# --- which PRs -------------------------------------------------------------
prs=""
if [ -n "$PR" ]; then
  prs="$PR"
else
  q="repos/$REPO/pulls?state=closed&sort=updated&direction=desc&per_page=$((LAST * 3))"
  [ -n "$BASE" ] && q="$q&base=$BASE"
  prs="$(api "$q" --jq '.[] | select(.merged_at != null) | .number' 2>/dev/null | head -n "$LAST")" \
    || die "could not list merged PRs for $REPO"
fi
[ -n "$prs" ] || { say "no merged PRs to reconcile in $REPO"; exit 0; }

say "fleet-reconcile: $REPO  ($([ "$APPLY" = 1 ] && echo APPLY || echo 'dry run'))"
say ""

# Fetch once, so branch containment is answered from real objects rather than a
# guess about what the remote holds.
if [ "$DO_BRANCHES" = 1 ]; then
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git fetch --quiet --prune origin 2>/dev/null || true
  else
    say "note: not inside a git checkout — skipping branch cleanup"
    DO_BRANCHES=0
  fi
fi

protected_branch() {
  case "$1" in
    main|master|dev|develop|trunk) return 0 ;;
    release/*|hotfix/*|gh-readonly-queue/*) return 0 ;;
    *) return 1 ;;
  esac
}

for n in $prs; do
  json="$(api "repos/$REPO/pulls/$n" 2>/dev/null)" || { say "PR #$n: could not read"; errors=1; continue; }
  merged="$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("merged_at") or "")')"
  if [ -z "$merged" ]; then
    say "PR #$n: not merged — skipping"
    continue
  fi
  sha="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("merge_commit_sha") or "")')"
  head_ref="$(printf '%s' "$json" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("head") or {}).get("ref") or "")')"
  title="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("title") or "")')"

  # Closing keywords, per GitHub's own rule: the keyword must be repeated for
  # each issue. A bare `#B` after a comma is NOT a closing reference, and this
  # script must read it the way GitHub does or it would paper over the bug.
  refs="$(printf '%s' "$json" | python3 -c '
import json, re, sys
body = (json.load(sys.stdin).get("body") or "")
pat = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+#(\d+)", re.I)
seen, out = set(), []
for m in pat.finditer(body):
    if m.group(1) not in seen:
        seen.add(m.group(1)); out.append(m.group(1))
print(" ".join(out))
')"

  say "PR #$n  $title"
  say "  merged $merged as ${sha:0:12}"
  if [ -z "$refs" ]; then
    say "  no closing references in the body"
  fi

  all_closed=1
  for issue in $refs; do
    istate="$(api "repos/$REPO/issues/$issue" --jq .state 2>/dev/null)" || istate=""
    if [ -z "$istate" ]; then
      say "  #$issue: could not read"; errors=1; all_closed=0; continue
    fi
    if [ "$istate" = "open" ]; then
      all_closed=0
      changes=1
      act "close #$issue — shipped in #$n (${sha:0:12}) but still open"
      if [ "$APPLY" = 1 ]; then
        body="Shipped in #$n (\`${sha:0:12}\`), merged $merged, but the issue stayed open — the workflow that closes it needs Actions, or the PR body used a single keyword for several issues. Closed by \`fleet-reconcile.sh\`."
        api -X POST "repos/$REPO/issues/$issue/comments" -f "body=$body" --silent 2>/dev/null \
          || { say "  #$issue: comment failed"; errors=1; }
        api -X PATCH "repos/$REPO/issues/$issue" -f state=closed -f state_reason=completed --silent 2>/dev/null \
          || { say "  #$issue: close failed"; errors=1; }
      fi
    else
      say "  #$issue: already closed"
    fi

    # A closed issue carrying status:in-progress reads as live work to every
    # census and every next-issue pick.
    labels="$(api "repos/$REPO/issues/$issue/labels" --jq '.[].name' 2>/dev/null | grep '^status:' || true)"
    for label in $labels; do
      changes=1
      act "remove label '$label' from closed #$issue"
      if [ "$APPLY" = 1 ]; then
        api -X DELETE "repos/$REPO/issues/$issue/labels/$(urlenc "$label")" --silent 2>/dev/null \
          || { say "  #$issue: could not remove '$label'"; errors=1; }
      fi
    done
  done

  # --- branches ------------------------------------------------------------
  if [ "$DO_BRANCHES" = 1 ] && [ -n "$sha" ]; then
    if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
      say "  (merge commit not in this checkout — skipping branch cleanup for #$n)"
      continue
    fi
    while read -r bsha bref; do
      [ -n "$bref" ] || continue
      branch="${bref#refs/heads/}"
      protected_branch "$branch" && continue
      git cat-file -e "$bsha^{commit}" 2>/dev/null || continue
      git merge-base --is-ancestor "$bsha" "$sha" 2>/dev/null || continue

      # Only delete a branch whose issues are demonstrably closed. A branch that
      # names no issue is left alone: it may be someone's live work that happens
      # to be an ancestor.
      bissues="$(printf '%s' "$branch" | grep -oE '[0-9]{2,}' | sort -u)"
      if [ -z "$bissues" ]; then
        if [ "$branch" = "$head_ref" ] && [ "$all_closed" = 1 ] && [ -n "$refs" ]; then
          : # this PR's own head, and everything it closed is closed
        else
          continue
        fi
      else
        for bi in $bissues; do
          st="$(api "repos/$REPO/issues/$bi" --jq .state 2>/dev/null)" || st=""
          [ "$st" = "closed" ] || { bissues=""; break; }
        done
        [ -n "$bissues" ] || continue
      fi

      changes=1
      act "delete remote branch '$branch' (contained in ${sha:0:12}, issues closed)"
      if [ "$APPLY" = 1 ]; then
        api -X DELETE "repos/$REPO/git/refs/heads/$branch" --silent 2>/dev/null \
          || { say "  could not delete '$branch'"; errors=1; }
      fi
    done < <(git ls-remote --heads origin 2>/dev/null)
  fi
  say ""
done

if [ "$changes" = 0 ]; then
  say "nothing to reconcile — the tracker matches what shipped"
elif [ "$APPLY" != 1 ]; then
  say "dry run. Re-run with --apply to act on the WOULD lines above."
fi
exit "$errors"
