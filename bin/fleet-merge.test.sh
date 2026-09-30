#!/usr/bin/env bash
# Self-test for fleet-merge.sh against a stub `gh` that records every call.
# What is under test is the refusal: every refused case must make NO write call,
# and the happy path must lift, merge pinned to the head SHA, then restore.
#   bash bin/fleet-merge.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM="$HERE/fleet-merge.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Lift records are durable state; the tests must never touch the real one.
export FLEET_MERGE_STATE_DIR="$TMP/state"
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MANIFEST='{"version":1,"jobs":[]}'
printf '%s' "$MANIFEST" > "$TMP/manifest"
MSHA="$(sha256sum "$TMP/manifest" | cut -d' ' -f1)"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
put=0; path=""; input=""; prev=""
for a in "$@"; do
  case "$a" in PUT) put=1 ;; repos/*|orgs/*) [ -z "$path" ] && path="$a" ;; esac
  [ "$prev" = --input ] && input="$a"
  prev="$a"
done
# (The tests run with BASH_ENV=/dev/null: a bash stub would otherwise re-source the
# user's profile and get GH_TOKEN back, which the real gh binary never does.)
# An org ruleset is unreadable/unwritable under an ambient GH_TOKEN (no admin:org);
# only the keyring credential, i.e. GH_TOKEN unset, has it.
if [ "${STUB_ORG_KEYRING_ONLY:-0}" = 1 ] && [ -n "${GH_TOKEN:-}" ]; then
  case "$path" in orgs/*) echo '{"message":"Not Found"}'; echo "gh: needs admin:org" >&2; exit 1 ;; esac
fi
case "$*" in *"-X POST"*/comments*)
  [ "${STUB_COMMENT_FAIL:-0}" = 1 ] && { echo '{"message":"denied"}'; exit 1; }
  cat "$input" > "$STUB_DIR/comment.json"; echo '{"id":4242}'; exit 0 ;;
esac
if [ "$put" = 1 ]; then
  case "$path" in
    */merge) [ "${STUB_MERGE_HANG:-0}" = 1 ] && { echo $$ > "$STUB_DIR/hang.pid"; exec sleep 60; }
             [ "${STUB_MERGE_FAIL:-0}" = 1 ] && { echo '{"message":"nope"}'; exit 1; }
             echo '{"merged":true,"sha":"mmmm"}' ;;
    *) if [ -n "$input" ] && [ "$input" != - ]; then cat "$input"; else cat; fi > "$STUB_DIR/last-put.json"; cp "$STUB_DIR/last-put.json" "$STUB_DIR/state-$(basename "$path").json"; echo '{}' ;;
  esac
  exit 0
fi
case "$path" in
  */issues/comments/*) jq -r .body "$STUB_DIR/comment.json" ;;
  */pulls/*) printf '{"head":{"sha":"%s"},"base":{"ref":"dev"},"state":"open"}\n' "$STUB_HEAD" ;;
  */contents/*) cat "$STUB_DIR/manifest" ;;
  */rules/branches/*) echo '[{"type":"merge_queue","ruleset_source_type":"Repository","ruleset_id":11},{"type":"required_status_checks","ruleset_source_type":"Organization","ruleset_id":22},{"type":"deletion","ruleset_source_type":"Repository","ruleset_id":33}]' ;;
  */rulesets/*) id="$(basename "$path")"
                if [ -f "$STUB_DIR/state-$id.json" ]; then cat "$STUB_DIR/state-$id.json"; else echo '{"bypass_actors":[]}'; fi ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$TMP/bin/gh"

verdict() {  # jq filter applied to a good verdict
  jq -n --arg sha "$HEAD" --arg m "$MSHA" '{schema:1, sha:$sha, treeClean:true, full:true, dataPlane:true,
    manifestSha256:$m, exit:0, jobs:[{name:"lint",result:"PASS",local:true},
    {name:"e2e",result:"PASS",local:true,needsDataPlane:true},{name:"ios",result:"NOT-RUN",local:false}]}' \
    | jq "$1" > "$TMP/verdict.json"
}
run() {
  : > "$TMP/calls"; rm -f "$TMP"/state-*.json
  OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" \
    "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" "$@" 2>&1)"; RC=$?
}
writes() { grep -c -- '-X PUT' "$TMP/calls" || true; }

echo "fleet-merge: refusals make no write"
for case in '.sha="bbbb"|sha mismatch' '.full=false|--job subset' '.treeClean=false|dirty tree' \
            '.exit=1|failed run' '.jobs[0].result="FAIL"|a FAIL row' '.jobs[1].result="NOT-RUN"|an unmeasured local job' \
            '.manifestSha256="x"|a different manifest'; do
  verdict "${case%%|*}"; run
  [ "$RC" = 1 ] && [ "$(writes)" = 0 ] && ok "refuses ${case##*|}" || bad "${case##*|}: rc=$RC writes=$(writes) $OUT"
done
rm -f "$TMP/verdict.json"; run
[ "$RC" = 1 ] && [ "$(writes)" = 0 ] && ok "refuses a missing verdict file" || bad "missing verdict: rc=$RC"

echo "fleet-merge: an excused data-plane job is allowed, and said so"
verdict '.jobs[1].result="NOT-RUN"'; run --allow-not-run e2e
[ "$RC" = 0 ] && grep -q 'excused by --allow-not-run' <<<"$OUT" && ok "--allow-not-run excuses visibly" || bad "allow: rc=$RC $OUT"
verdict '.'; run --allow-not-run nosuch
[ "$RC" = 1 ] && [ "$(writes)" = 0 ] && ok "--allow-not-run of an unknown job refuses" || bad "unknown allow: rc=$RC"

echo "fleet-merge: the happy path lifts, merges pinned, restores"
verdict '.'; run
[ "$RC" = 0 ] && ok "merges on a good verdict" || bad "rc=$RC $OUT"
grep -q -- "-X PUT repos/o/r/pulls/7/merge -f sha=$HEAD" "$TMP/calls" && ok "the merge is pinned to the head SHA" || bad "unpinned: $(cat "$TMP/calls")"
grep -q 'orgs/o/rulesets/22' "$TMP/calls" && grep -q 'repos/o/r/rulesets/11' "$TMP/calls" \
  && ok "both the org and the repo ruleset are lifted" || bad "rulesets: $(cat "$TMP/calls")"
grep -q 'rulesets/33' "$TMP/calls" && bad "lifted a ruleset with no merge gate" || ok "a non-gating ruleset is left alone"
order="$(grep -n -- '-X PUT' "$TMP/calls" | sed 's/:.*-X PUT / /' | awk '{print $2}' | tr '\n' ' ')"
[[ "$order" == *rulesets/11*rulesets/22*pulls/7/merge*rulesets/11*rulesets/22* ]] || [[ "$order" == *rulesets/*rulesets/*merge*rulesets/*rulesets/* ]] \
  && ok "lift, merge, restore happen in that order" || bad "order: $order"
[ "$(jq -c .bypass_actors "$TMP/state-22.json")" = '[]' ] && ok "the org ruleset's bypass_actors are restored to []" || bad "not restored: $(cat "$TMP/state-22.json")"

echo "fleet-merge: an org ruleset an ambient GH_TOKEN cannot reach is retried on the keyring credential"
verdict '.'; : > "$TMP/calls"; rm -f "$TMP"/state-*.json
OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" STUB_ORG_KEYRING_ONLY=1 \
  BASH_ENV=/dev/null GH_TOKEN=ambient GITHUB_TOKEN=ambient "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "merges although the ambient token lacks admin:org" || bad "rc=$RC $OUT"
[ "$(jq -c .bypass_actors "$TMP/state-22.json")" = '[]' ] && ok "and the org ruleset is restored" || bad "not restored: $(cat "$TMP"/state-22.json 2>&1)"
OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" STUB_ORG_KEYRING_ONLY=1 \
  "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" --dry-run 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "no ambient token still works" || bad "rc=$RC $OUT"

echo "fleet-merge: the verdict is published before the first lift, and a failed publish writes nothing"
verdict '.'; run
first_post="$(grep -n -- '-X POST' "$TMP/calls" | head -1 | cut -d: -f1)"
first_put="$(grep -n -- '-X PUT' "$TMP/calls" | head -1 | cut -d: -f1)"
[ -n "$first_post" ] && [ "$first_post" -lt "$first_put" ] && ok "the verdict comment precedes the first ruleset PUT" || bad "publish order: post=$first_post put=$first_put"
grep -q "fleet-verdict sha=$HEAD" "$TMP/comment.json" && jq -e '.body|contains("\"treeClean\": true")' "$TMP/comment.json" >/dev/null \
  && ok "the comment carries the head SHA marker and the full verdict JSON" || bad "comment body: $(cat "$TMP/comment.json")"
verdict '.'; : > "$TMP/calls"; rm -f "$TMP"/state-*.json
OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" STUB_COMMENT_FAIL=1 \
  "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" 2>&1)"; RC=$?
[ "$RC" = 1 ] && [ "$(writes)" = 0 ] && ok "a failed publish refuses with zero ruleset writes" || bad "failed publish: rc=$RC writes=$(writes) $OUT"

echo "fleet-merge: a failed merge still restores"
verdict '.'; : > "$TMP/calls"; rm -f "$TMP"/state-*.json
OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" STUB_MERGE_FAIL=1 \
  "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" 2>&1)"; RC=$?
[ "$RC" = 3 ] && ok "a failed merge exits 3" || bad "rc=$RC $OUT"
[ "$(jq -c .bypass_actors "$TMP/state-11.json")" = '[]' ] && [ "$(jq -c .bypass_actors "$TMP/state-22.json")" = '[]' ] \
  && ok "and both rulesets are restored anyway" || bad "left lifted: $(cat "$TMP"/state-*.json)"

echo "fleet-merge: --dry-run changes nothing"
verdict '.'; run --dry-run
[ "$RC" = 0 ] && [ "$(writes)" = 0 ] && ! grep -q -- '-X POST' "$TMP/calls" && ok "dry run writes nothing" || bad "dry run: rc=$RC writes=$(writes)"

echo "fleet-merge: a SIGKILL between lift and restore leaves a record, and the next run restores"
SEED11='[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]'
kill_between_lift_and_restore() {
  rm -rf "$TMP/state" "$TMP/hang.pid"; : > "$TMP/calls"; rm -f "$TMP"/state-*.json
  printf '{"bypass_actors":%s}\n' "$SEED11" > "$TMP/state-11.json"
  echo '{"bypass_actors":[]}' > "$TMP/state-22.json"
  verdict '.'
  PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" STUB_MERGE_HANG=1 \
    "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" >"$TMP/killed.out" 2>&1 &
  FMPID=$!
  for _ in $(seq 1 100); do [ -f "$TMP/hang.pid" ] && break; sleep 0.1; done
  kill -9 "$FMPID" 2>/dev/null; wait "$FMPID" 2>/dev/null
  [ -f "$TMP/hang.pid" ] && kill "$(cat "$TMP/hang.pid")" 2>/dev/null
  return 0
}
kill_between_lift_and_restore
[ -f "$TMP/hang.pid" ] && ok "the merge was in flight when the process was killed" || bad "never reached the merge: $(cat "$TMP/killed.out")"
jq -e '.bypass_actors|any(.actor_type=="OrganizationAdmin")' "$TMP/state-22.json" >/dev/null \
  && ok "the org ruleset is left lifted (the trap could not fire)" || bad "not lifted: $(cat "$TMP/state-22.json")"
[ "$(ls "$TMP"/state/o-r/*.json 2>/dev/null | wc -l)" = 2 ] && ok "one durable record per lifted ruleset" || bad "records: $(ls "$TMP"/state/o-r 2>&1)"
[ "$(jq -c .before "$TMP/state/o-r/repo-11.json")" = "$SEED11" ] && ok "the record holds the before-state" || bad "record: $(cat "$TMP/state/o-r/repo-11.json")"
LISTED="$("$FM" --list-pending)"
grep -q 'ruleset 22 still LIFTED' <<<"$LISTED" && grep -q 'ruleset 11 still LIFTED' <<<"$LISTED" && ok "--list-pending names both" || bad "list: $LISTED"

: > "$TMP/calls"
OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" "$FM" --restore-pending 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "--restore-pending exits 0" || bad "rc=$RC $OUT"
[ "$(jq -c .bypass_actors "$TMP/state-11.json")" = "$SEED11" ] && [ "$(jq -c .bypass_actors "$TMP/state-22.json")" = '[]' ] \
  && ok "both rulesets are back to their before-state" || bad "state: $(cat "$TMP"/state-11.json "$TMP"/state-22.json)"
[ -z "$(ls "$TMP"/state/o-r/*.json 2>/dev/null)" ] && ok "records are removed after a verified restore" || bad "records remain"
[ -z "$("$FM" --list-pending)" ] && ok "--list-pending is silent when nothing is pending" || bad "still listing"

kill_between_lift_and_restore
verdict '.'; run --dry-run
[ -n "$(ls "$TMP"/state/o-r/*.json 2>/dev/null)" ] && ok "--dry-run does not self-heal" || bad "dry-run restored"
verdict '.'
OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" 2>&1)"; RC=$?
grep -q 'found an orphaned lift' <<<"$OUT" && ok "the next merge restores the orphan first" || bad "no self-heal: $OUT"
[ "$RC" = 0 ] && [ -z "$(ls "$TMP"/state/o-r/*.json 2>/dev/null)" ] && ok "and completes with no record left" || bad "rc=$RC $OUT"

echo "fleet-merge: a record whose pid is alive is another merge in flight"
mkdir -p "$TMP/state/o-r"
jq -n --argjson pid "$$" '{repo:"o/r",source:"Repository",id:11,pid:$pid,pr:9,ts:"now",before:[]}' > "$TMP/state/o-r/repo-11.json"
[ -z "$("$FM" --list-pending)" ] && ok "a live owner is not reported as pending" || bad "live owner listed"
verdict '.'; run
[ "$RC" = 3 ] && [ "$(writes)" = 0 ] && ok "a second lift of the same ruleset is refused with no write" || bad "rc=$RC writes=$(writes) $OUT"
rm -rf "$TMP/state"

[ "$fail" = 0 ] && echo "fleet-merge: all cases passed"
exit "$fail"
