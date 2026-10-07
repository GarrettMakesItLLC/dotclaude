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
#   - manifestSha256 == sha256 of the BASE branch's manifest, read from GitHub now.
#                       The job list is the gate, so it comes from the branch being
#                       merged INTO: a head that drops or neuters a job in its own
#                       manifest would otherwise produce a verdict that authorizes
#                       itself. A PR that changes the manifest is still judged by
#                       the base's: run `ci-replica.sh --manifest <base's copy>` on
#                       the head, and the new job list gates the PRs after it lands.
#
# It then publishes the verdict as a comment on the PR, reads it back, and refuses to
# lift if that write fails: the replica's verdict.json lives in the validator's
# throwaway worktree, so without this a merged head has no file to check afterwards.
# The comment is the durable record; `#8137`'s ALL GREEN cites it, not a bare hash.
#
# (A private repo on a plan without rulesets answers the rules endpoint with the
# "Upgrade to GitHub Pro" 403; that is read as "no gating rulesets", so nothing is
# lifted and the merge is still pinned to the verdict SHA.)
#
# Then it lifts every ruleset on the base branch that carries a merge gate
# (required checks, merge queue, pull request rule) by adding an OrganizationAdmin
# bypass, merges pinned to the verdict SHA, restores each ruleset's original
# bypass_actors — from an EXIT trap, so a failed merge still restores — and reads
# them back.
#
# An EXIT trap cannot fire on SIGKILL (an OOM kill lands exactly there), so each
# lift is also a durable record, written BEFORE the ruleset is touched:
#   ${FLEET_MERGE_STATE_DIR:-${XDG_STATE_HOME:-~/.local/state}/fleet-merge}/<owner>-<repo>/<org|repo>-<id>.json
# holding the before-state bypass_actors, the pid, the PR and a timestamp. A record
# is removed only after a restore read back equal. Every invocation first restores
# any record whose pid is dead; a record whose pid is alive is another merge in
# flight and is left alone (and blocks a second lift of the same ruleset).
#
#   fleet-merge.sh <PR> --verdict <verdict.json> [--repo OWNER/NAME]
#                  [--manifest-path .claude/ci-replica.json]
#                  [--allow-not-run JOB]... [--method squash|merge|rebase] [--title T]
#                  [--dry-run]
#
# --dry-run checks the verdict and names the rulesets it would lift, and changes
# nothing.
#
# --method defaults to `merge` for a promotion (head is a trunk — dev, develop,
# staging, release/* — and base is main, master, production or release/*) and to
# `squash` for everything else. A squash onto main leaves it sharing no history
# with dev, so the next promotion conflicts on every file both sides touched. An
# explicit --method always wins.
#
# Token: the org ruleset needs admin:org, which an ambient GH_TOKEN usually lacks.
# Set FLEET_MERGE_GH_TOKEN (not GH_TOKEN=, which a profile or BASH_ENV can
# re-export under the script) to a credential that has it; it is exported as
# GH_TOKEN for every call. An org call that fails under it is retried once on the
# stored gh credential. The source used is printed. If neither reaches the org
# ruleset the error names the token scope: GitHub answers 404, not 403, for an
# org ruleset the token cannot see, so a 404 does not mean no ruleset exists.
#
# Exit: 0 merged (or dry-run clean), 1 refused, 2 usage, 3 merge or restore failed.
set -uo pipefail

usage() { sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "fleet-merge: $*" >&2; exit 2; }
refuse() { echo "fleet-merge: REFUSED — $*" >&2; exit 1; }

PR="" VERDICT="" REPO="" MANIFEST_PATH=".claude/ci-replica.json" METHOD="" TITLE="" DRY=0 ACTION=merge
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
    --restore-pending) ACTION=restore; shift ;;
    --list-pending) ACTION=list; shift ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$PR" ] || die "one PR at a time"; PR="$1"; shift ;;
  esac
done
if [ "$ACTION" = merge ]; then
  [[ "$PR" =~ ^[0-9]+$ ]] || usage
  [ -n "$VERDICT" ] || die "--verdict <verdict.json> is required: the verdict is the authorization"
  [ -f "$VERDICT" ] || refuse "no verdict file at $VERDICT"
fi
command -v jq >/dev/null || die "jq is required (verdict, ruleset and merge JSON are all read with it) — install it: sudo apt install jq"
if [ -n "${FLEET_MERGE_GH_TOKEN:-}" ]; then
  export GH_TOKEN="$FLEET_MERGE_GH_TOKEN"; TOKEN_SRC="FLEET_MERGE_GH_TOKEN"
elif [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  TOKEN_SRC="ambient GH_TOKEN/GITHUB_TOKEN"
else
  TOKEN_SRC="stored gh credential"
fi

STATE_ROOT="${FLEET_MERGE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/fleet-merge}"

# Organization rulesets need `admin:org`. An agent shell exports GH_TOKEN, which
# does not carry it, while the stored gh credential does. So an org call that
# fails under an ambient token is retried once without it, which makes gh fall
# back to the keyring. Repo rulesets go straight through.
gh_ruleset() {
  local a org=0 out
  for a in "$@"; do case "$a" in orgs/*) org=1 ;; esac; done
  [ "$org" = 1 ] || { gh api "$@"; return; }
  # Captured, not streamed: a refused call still prints its error body on stdout,
  # and that must not precede the retry's real answer.
  if out="$(gh api "$@" 2>/dev/null)"; then printf '%s\n' "$out"; return 0; fi
  if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
    echo "fleet-merge: org call failed under $TOKEN_SRC; retrying on the stored gh credential" >&2
    if out="$(env -u GH_TOKEN -u GITHUB_TOKEN gh api "$@" 2>/dev/null)"; then printf '%s\n' "$out"; return 0; fi
  fi
  echo "fleet-merge: org ruleset call failed (tried $TOKEN_SRC, then the stored gh credential). GitHub answers 404 for an org ruleset the token cannot see, so this means the token lacks admin:org, not that the ruleset is absent. Set FLEET_MERGE_GH_TOKEN to a credential with admin:org." >&2
  return 1
}

# ruleset_path <Organization|Repository> <id> <owner/name>
ruleset_path() {
  if [ "$1" = Organization ]; then echo "orgs/${3%%/*}/rulesets/$2"; else echo "repos/$3/rulesets/$2"; fi
}

# --- durable lift records ---------------------------------------------------
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//'; }
# A pid is alive only if it is running AND is the process that wrote the record
# (start time matches), so a recycled pid does not shield a dead lift.
record_owner_alive() {  # record_owner_alive <record.json>
  local pid start
  pid="$(jq -r '.pid // empty' "$1" 2>/dev/null)"; start="$(jq -r '.pidStart // empty' "$1" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  [ -z "$start" ] || [ "$(proc_start "$pid")" = "$start" ]
}
record_dir() { echo "$STATE_ROOT/${1//\//-}"; }
record_file() {  # record_file <owner/name> <Organization|Repository> <id>
  local kind=repo; [ "$2" = Organization ] && kind=org
  echo "$(record_dir "$1")/$kind-$3.json"
}
# pending_records [owner/name] -> paths of dead-owner records
pending_records() {
  local f d
  if [ -n "${1:-}" ]; then d="$(record_dir "$1")"; else d="$STATE_ROOT/*"; fi
  # shellcheck disable=SC2086
  for f in $d/*.json; do
    [ -f "$f" ] || continue
    record_owner_alive "$f" || echo "$f"
  done
}
# restore_record <record.json>: PUT the recorded bypass_actors back, read them
# back, and remove the record only when they match.
restore_record() {
  local rec="$1" repo src id p want got
  repo="$(jq -r .repo "$rec")"; src="$(jq -r .source "$rec")"; id="$(jq -r .id "$rec")"
  p="$(ruleset_path "$src" "$id" "$repo")"
  want="$(mktemp)"
  jq -c '{bypass_actors: .before}' "$rec" > "$want"
  if ! gh_ruleset -X PUT "$p" --input "$want" >/dev/null; then
    echo "fleet-merge: RESTORE FAILED for $p — record kept at $rec" >&2; rm -f "$want"; return 3
  fi
  got="$(gh_ruleset "$p" | jq -c '.bypass_actors')"
  if [ "$got" = "$(jq -c .bypass_actors "$want")" ]; then
    rm -f "$rec" "$want"
    echo "fleet-merge: restored $p (bypass_actors read back: $(jq 'length' <<<"$got"))"
  else
    echo "fleet-merge: RESTORE MISMATCH for $p: $got — record kept at $rec" >&2; rm -f "$want"; return 3
  fi
}
restore_pending() {  # restore_pending [owner/name]
  local rc=0 rec
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    echo "fleet-merge: found an orphaned lift (pid $(jq -r .pid "$rec") is gone, PR #$(jq -r .pr "$rec"), $(jq -r .ts "$rec")); restoring"
    restore_record "$rec" || rc=3
  done < <(pending_records "${1:-}")
  return "$rc"
}

case "$ACTION" in
  list)
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      echo "$(jq -r '"\(.repo) \(.source) ruleset \(.id) still LIFTED (fleet-merge pid \(.pid) died, PR #\(.pr), \(.ts))"' "$rec")"
    done < <(pending_records "$REPO")
    exit 0 ;;
  restore)
    restore_pending "$REPO"; exit $? ;;
esac
# Self-heal: a previous fleet-merge killed between lift and restore.
if [ "$DRY" = 0 ]; then restore_pending "" || echo "fleet-merge: WARNING — an orphaned lift could not be restored (see above)" >&2; fi

if [ -z "$REPO" ] && [ "$ACTION" = merge ]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || die "cannot infer --repo"
fi

jq -e . "$VERDICT" >/dev/null 2>&1 || refuse "$VERDICT is not valid JSON"

pr_json="$(gh api "repos/$REPO/pulls/$PR")" || die "cannot read PR #$PR"
head_sha="$(jq -r .head.sha <<<"$pr_json")"
base_ref="$(jq -r .base.ref <<<"$pr_json")"
head_ref="$(jq -r .head.ref <<<"$pr_json")"
state="$(jq -r .state <<<"$pr_json")"
if [ -z "$METHOD" ]; then
  case "$head_ref:$base_ref" in
    dev:main|dev:master|dev:production|dev:release/*|develop:main|develop:master|develop:production|develop:release/*|\
    staging:main|staging:master|staging:production|release/*:main|release/*:master|release/*:production) METHOD=merge ;;
    *) METHOD=squash ;;
  esac
  echo "fleet-merge: merge method $METHOD (default for $head_ref -> $base_ref; --method overrides)"
fi
case "$METHOD" in squash|merge|rebase) ;; *) die "--method must be squash, merge or rebase, not '$METHOD'" ;; esac
echo "fleet-merge: GitHub token source: $TOKEN_SRC"
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

# Written to a file, not captured: `$(...)` strips the trailing newline the
# replica hashed, and a failed read piped into sha256sum hashes nothing and exits 0.
base_manifest="$(mktemp)"
gh api -H 'Accept: application/vnd.github.raw' "repos/$REPO/contents/$MANIFEST_PATH?ref=$base_ref" \
  > "$base_manifest" 2>/dev/null && [ -s "$base_manifest" ] \
  || { rm -f "$base_manifest"; refuse "cannot read $MANIFEST_PATH on the base $base_ref; the verdict is judged against the base's manifest, so a base without one has no gate to merge on"; }
base_manifest_sha="$(sha256sum "$base_manifest" | cut -d' ' -f1)"; rm -f "$base_manifest"
[ "$(v .manifestSha256)" = "$base_manifest_sha" ] \
  || refuse "the verdict ran a different manifest than $base_ref's $MANIFEST_PATH. The job list comes from the base, not the head: re-run with \`ci-replica.sh --manifest <$MANIFEST_PATH as of $base_ref>\` on the head"

echo "fleet-merge: verdict OK for PR #$PR @ $head_sha ($(jq '[.jobs[]|select(.result=="PASS")]|length' "$VERDICT") PASS, $(jq '[.jobs[]|select(.result=="NOT-RUN")]|length' "$VERDICT") NOT-RUN)"

# Rulesets on the base branch that gate a merge. Organization-level ones are
# the trap: lifting only the repo's leaves "Required status check ... is failing"
# naming a rule the repo cannot see.
# A private repo on a plan without rulesets answers this one 403: it has no
# rulesets to lift, so the base is ungated. Any other failure still aborts.
rules_err="$(mktemp)"
if ! rules="$(gh api "repos/$REPO/rules/branches/$base_ref" 2>"$rules_err")"; then
  if grep -qF 'Upgrade to GitHub Pro or make this repository public to enable this feature' "$rules_err" \
     && grep -qF 'HTTP 403' "$rules_err"; then
    echo "fleet-merge: $REPO's plan has no rulesets (GitHub answered 403 \"Upgrade to GitHub Pro\"); treating $base_ref as ungated, nothing to lift"
    rules='[]'
  else
    cat "$rules_err" >&2; rm -f "$rules_err"; die "cannot read rules for $base_ref"
  fi
fi
rm -f "$rules_err"
mapfile -t targets < <(jq -r '
  [.[] | select(.type=="required_status_checks" or .type=="merge_queue" or .type=="pull_request")
       | "\(.ruleset_source_type)\t\(.ruleset_id)"] | unique | .[]' <<<"$rules")

for t in "${targets[@]+"${targets[@]}"}"; do echo "fleet-merge: will lift $(ruleset_path "${t%%	*}" "${t##*	}" "$REPO")"; done
if [ "$DRY" = 1 ]; then echo "fleet-merge: --dry-run, nothing changed"; exit 0; fi

# A live record is another merge holding this ruleset lifted: lifting it again
# would record the lifted state as "before". Checked for every target up front.
for t in "${targets[@]+"${targets[@]}"}"; do
  rec="$(record_file "$REPO" "${t%%	*}" "${t##*	}")"
  if [ -f "$rec" ] && record_owner_alive "$rec"; then
    echo "fleet-merge: $(ruleset_path "${t%%	*}" "${t##*	}" "$REPO") is already lifted by another fleet-merge (pid $(jq -r .pid "$rec")); nothing was lifted" >&2
    exit 3
  fi
done

WORK="$(mktemp -d)"
LIFTED=()

# Publish the verdict before anything is lifted. Marker line first so a later
# fleet-verify can find it by head SHA; the JSON is the whole file, verbatim.
verdict_sha256="$(sha256sum "$VERDICT" | cut -d' ' -f1)"
comment_body="$(printf '<!-- fleet-verdict sha=%s sha256=%s -->\nReplica verdict for `%s` (sha256 `%s`), the authorization for this merge:\n\n```json\n%s\n```\n' \
  "$head_sha" "$verdict_sha256" "$head_sha" "$verdict_sha256" "$(jq . "$VERDICT")")"
jq -n --arg body "$comment_body" '{body:$body}' > "$WORK/comment.json"
posted="$(gh api -X POST "repos/$REPO/issues/$PR/comments" --input "$WORK/comment.json" 2>&1)" \
  || { rm -rf "$WORK"; refuse "cannot publish the verdict to PR #$PR ($posted); nothing was lifted"; }
comment_id="$(jq -r '.id // empty' <<<"$posted" 2>/dev/null)"
[ -n "$comment_id" ] || { rm -rf "$WORK"; refuse "the verdict comment on PR #$PR returned no id; nothing was lifted"; }
readback="$(gh api "repos/$REPO/issues/comments/$comment_id" --jq .body 2>/dev/null)" || readback=""
grep -qF "sha256=$verdict_sha256" <<<"$readback" \
  || { rm -rf "$WORK"; refuse "the verdict comment $comment_id did not read back; nothing was lifted"; }
echo "fleet-merge: verdict published as comment $comment_id on PR #$PR (sha256 $verdict_sha256)"

restore() {
  local rc=0 rec
  for rec in "${LIFTED[@]+"${LIFTED[@]}"}"; do
    restore_record "$rec" || rc=3
  done
  LIFTED=()
  return "$rc"
}
trap 'restore; rm -rf "$WORK"' EXIT

for t in "${targets[@]+"${targets[@]}"}"; do
  src="${t%%	*}"; id="${t##*	}"
  p="$(ruleset_path "$src" "$id" "$REPO")"
  rec="$(record_file "$REPO" "$src" "$id")"
  gh_ruleset "$p" > "$WORK/$id.before.json" || die "cannot read $p"
  # The record exists before the ruleset is touched, so a kill at any point
  # after this line leaves the before-state on disk.
  mkdir -p "$(dirname "$rec")"
  jq -n --arg repo "$REPO" --arg source "$src" --argjson id "$id" --argjson pid "$$" \
    --arg pidStart "$(proc_start $$)" --argjson pr "$PR" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile b "$WORK/$id.before.json" \
    '{repo:$repo, source:$source, id:$id, pid:$pid, pidStart:$pidStart, pr:$pr, ts:$ts, before:$b[0].bypass_actors}' \
    > "$rec.tmp" && mv "$rec.tmp" "$rec" || die "cannot write the lift record $rec; nothing lifted"
  jq -c '{bypass_actors: (.bypass_actors + [{"actor_id":1,"actor_type":"OrganizationAdmin","bypass_mode":"always"}])}' \
    "$WORK/$id.before.json" > "$WORK/$id.lift.json"
  LIFTED+=("$rec")
  gh_ruleset -X PUT "$p" --input "$WORK/$id.lift.json" >/dev/null || { echo "fleet-merge: cannot lift $p" >&2; exit 3; }
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
