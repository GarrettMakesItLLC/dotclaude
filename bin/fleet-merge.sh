#!/usr/bin/env bash
# fleet-merge.sh — merge one PR in degraded mode, but only on a verdict ARTIFACT.
#
# In degraded mode (skills/operating-a-fleet) CI cannot be the gate, so a local
# replica run is, and the merge happens with branch protection lifted by hand.
# When the authorization was a hand-written `ALL GREEN @ <sha>` comment, nothing
# checked that a full passing run existed for the merged head: four PRs merged
# with no replica run at all, and three wave verdicts were assembled from jobs
# carried over from other SHAs (MuscleBuddy#8955). This script is the lift, and
# it refuses unless `ci-replica.sh`'s own `verdict.json` says:
#
#   - sha            == the PR's head SHA, read from GitHub now
#   - full           == true   (no --job subset)
#   - treeClean      == true   (the run measured a commit, not a working copy)
#   - exit           == 0 and no job FAILed
#   - every local job PASSed   (a data-plane job may be NOT-RUN only when named
#                               with --allow-not-run, which is printed)
#   - manifestSha256 == sha256 of the head's own manifest, so a verdict from a
#                       run whose job list differs from the head's cannot pass
#
# Then it lifts every ruleset on the base branch that carries a merge gate
# (required checks, merge queue, pull request rule) by adding an OrganizationAdmin
# bypass, merges pinned to the verdict SHA, restores each ruleset's original
# bypass_actors — from an EXIT trap, so a failed merge still restores — and reads
# them back.
#
#   fleet-merge.sh <PR> --verdict <verdict.json> [--repo OWNER/NAME]
#                  [--manifest-path .claude/ci-replica.json]
#                  [--allow-not-run JOB]... [--method squash|merge] [--title T]
#                  [--dry-run]
#
# --dry-run checks the verdict and names the rulesets it would lift, and changes
# nothing. FLEET_MERGE_GH_TOKEN, when set, is used as GH_TOKEN for every call
# (the org ruleset needs admin:org; see the fleet skill for which credential has it).
#
# Exit: 0 merged (or dry-run clean), 1 refused, 2 usage, 3 merge or restore failed.
set -uo pipefail

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "fleet-merge: $*" >&2; exit 2; }
refuse() { echo "fleet-merge: REFUSED — $*" >&2; exit 1; }

PR="" VERDICT="" REPO="" MANIFEST_PATH=".claude/ci-replica.json" METHOD="squash" TITLE="" DRY=0
ALLOW=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --verdict) VERDICT="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --manifest-path) MANIFEST_PATH="${2:-}"; shift 2 ;;
    --allow-not-run) ALLOW+=("${2:-}"); shift 2 ;;
    --method) METHOD="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$PR" ] || die "one PR at a time"; PR="$1"; shift ;;
  esac
done
[[ "$PR" =~ ^[0-9]+$ ]] || usage
[ -n "$VERDICT" ] || die "--verdict <verdict.json> is required: the verdict is the authorization"
[ -f "$VERDICT" ] || refuse "no verdict file at $VERDICT"
command -v jq >/dev/null || die "jq is required"
[ -n "${FLEET_MERGE_GH_TOKEN:-}" ] && export GH_TOKEN="$FLEET_MERGE_GH_TOKEN"

if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || die "cannot infer --repo"
fi
OWNER="${REPO%%/*}"

jq -e . "$VERDICT" >/dev/null 2>&1 || refuse "$VERDICT is not valid JSON"

pr_json="$(gh api "repos/$REPO/pulls/$PR")" || die "cannot read PR #$PR"
head_sha="$(jq -r .head.sha <<<"$pr_json")"
base_ref="$(jq -r .base.ref <<<"$pr_json")"
state="$(jq -r .state <<<"$pr_json")"
[ "$state" = open ] || refuse "PR #$PR is $state"

v() { jq -r "$1" "$VERDICT"; }
[ "$(v .sha)" = "$head_sha" ] \
  || refuse "the verdict is for $(v .sha), but PR #$PR's head is $head_sha. Re-run the replica on the head."
[ "$(v .full)" = true ] || refuse "the verdict came from a --job subset, not a full run"
[ "$(v .treeClean)" = true ] || refuse "the verdict measured a dirty working tree, not the commit"
[ "$(v .exit)" = 0 ] || refuse "the verdict's run exited $(v .exit)"
fails="$(jq -r '[.jobs[]|select(.result=="FAIL")|.name]|join(", ")' "$VERDICT")"
[ -z "$fails" ] || refuse "jobs FAILed: $fails"

allowed_json="$(printf '%s\n' "${ALLOW[@]+"${ALLOW[@]}"}" | jq -R . | jq -sc 'map(select(. != ""))')"
unmeasured="$(jq -r --argjson allow "$allowed_json" \
  '[.jobs[]|select(.local and .result!="PASS" and ((.name|IN($allow[]))|not))|.name]|join(", ")' "$VERDICT")"
[ -z "$unmeasured" ] || refuse "local jobs were not measured: $unmeasured (a data-plane job may be excused with --allow-not-run, visibly)"
for a in "${ALLOW[@]+"${ALLOW[@]}"}"; do
  r="$(jq -r --arg n "$a" '.jobs[]|select(.name==$n)|.result' "$VERDICT")"
  [ -n "$r" ] || refuse "--allow-not-run $a names no job in the verdict"
  [ "$r" = PASS ] || echo "fleet-merge: NOTE — $a was not measured ($r), excused by --allow-not-run"
done

head_manifest_sha="$(gh api -H 'Accept: application/vnd.github.raw' \
  "repos/$REPO/contents/$MANIFEST_PATH?ref=$head_sha" | sha256sum | cut -d' ' -f1)" \
  || refuse "cannot read $MANIFEST_PATH at $head_sha"
[ "$(v .manifestSha256)" = "$head_manifest_sha" ] \
  || refuse "the verdict ran a different manifest than the head's $MANIFEST_PATH"

echo "fleet-merge: verdict OK for PR #$PR @ $head_sha ($(jq '[.jobs[]|select(.result=="PASS")]|length' "$VERDICT") PASS, $(jq '[.jobs[]|select(.result=="NOT-RUN")]|length' "$VERDICT") NOT-RUN)"

# Rulesets on the base branch that gate a merge. Organization-level ones are
# the trap: lifting only the repo's leaves "Required status check ... is failing"
# naming a rule the repo cannot see.
rules="$(gh api "repos/$REPO/rules/branches/$base_ref")" || die "cannot read rules for $base_ref"
mapfile -t targets < <(jq -r '
  [.[] | select(.type=="required_status_checks" or .type=="merge_queue" or .type=="pull_request")
       | "\(.ruleset_source_type)\t\(.ruleset_id)"] | unique | .[]' <<<"$rules")

ruleset_path() {
  if [ "$1" = Organization ]; then echo "orgs/$OWNER/rulesets/$2"; else echo "repos/$REPO/rulesets/$2"; fi
}

for t in "${targets[@]+"${targets[@]}"}"; do echo "fleet-merge: will lift $(ruleset_path ${t%%	*} ${t##*	})"; done
if [ "$DRY" = 1 ]; then echo "fleet-merge: --dry-run, nothing changed"; exit 0; fi

WORK="$(mktemp -d)"
LIFTED=()
restore() {
  local rc=0 t p want got
  for t in "${LIFTED[@]+"${LIFTED[@]}"}"; do
    p="$(ruleset_path "${t%%	*}" "${t##*	}")"
    want="$WORK/${t##*	}.bypass.json"
    jq -c '{bypass_actors: .bypass_actors}' "$WORK/${t##*	}.before.json" > "$want"
    if ! gh api -X PUT "$p" --input "$want" >/dev/null; then
      echo "fleet-merge: RESTORE FAILED for $p — restore its bypass_actors by hand from $want" >&2
      rc=3; continue
    fi
    got="$(gh api "$p" | jq -c '.bypass_actors')"
    if [ "$got" = "$(jq -c .bypass_actors "$want")" ]; then
      echo "fleet-merge: restored $p (bypass_actors read back: $(jq 'length' <<<"$got"))"
    else
      echo "fleet-merge: RESTORE MISMATCH for $p: $got" >&2; rc=3
    fi
  done
  LIFTED=()
  return "$rc"
}
trap 'restore; rm -rf "$WORK"' EXIT

for t in "${targets[@]+"${targets[@]}"}"; do
  p="$(ruleset_path "${t%%	*}" "${t##*	}")"
  gh api "$p" > "$WORK/${t##*	}.before.json" || die "cannot read $p"
  jq -c '{bypass_actors: (.bypass_actors + [{"actor_id":1,"actor_type":"OrganizationAdmin","bypass_mode":"always"}])}' \
    "$WORK/${t##*	}.before.json" > "$WORK/${t##*	}.lift.json"
  LIFTED+=("$t")
  gh api -X PUT "$p" --input "$WORK/${t##*	}.lift.json" >/dev/null || { echo "fleet-merge: cannot lift $p" >&2; exit 3; }
  echo "fleet-merge: lifted $p"
done

args=(-X PUT "repos/$REPO/pulls/$PR/merge" -f "sha=$head_sha" -f "merge_method=$METHOD")
[ -n "$TITLE" ] && args+=(-f "commit_title=$TITLE")
merge_out="$(gh api "${args[@]}" 2>&1)"; merge_rc=$?
restore; restore_rc=$?

if [ "$merge_rc" -ne 0 ] || [ "$(jq -r '.merged // false' <<<"$merge_out" 2>/dev/null)" != true ]; then
  echo "fleet-merge: MERGE FAILED: $merge_out" >&2
  exit 3
fi
echo "fleet-merge: merged PR #$PR as $(jq -r .sha <<<"$merge_out"), pinned to $head_sha"
[ "$restore_rc" = 0 ] || exit 3
exit 0
