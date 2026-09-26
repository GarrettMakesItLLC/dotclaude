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
if [ "$put" = 1 ]; then
  case "$path" in
    */merge) [ "${STUB_MERGE_FAIL:-0}" = 1 ] && { echo '{"message":"nope"}'; exit 1; }
             echo '{"merged":true,"sha":"mmmm"}' ;;
    *) if [ -n "$input" ] && [ "$input" != - ]; then cat "$input"; else cat; fi > "$STUB_DIR/last-put.json"; cp "$STUB_DIR/last-put.json" "$STUB_DIR/state-$(basename "$path").json"; echo '{}' ;;
  esac
  exit 0
fi
case "$path" in
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

echo "fleet-merge: a failed merge still restores"
verdict '.'; : > "$TMP/calls"; rm -f "$TMP"/state-*.json
OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" STUB_MERGE_FAIL=1 \
  "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" 2>&1)"; RC=$?
[ "$RC" = 3 ] && ok "a failed merge exits 3" || bad "rc=$RC $OUT"
[ "$(jq -c .bypass_actors "$TMP/state-11.json")" = '[]' ] && [ "$(jq -c .bypass_actors "$TMP/state-22.json")" = '[]' ] \
  && ok "and both rulesets are restored anyway" || bad "left lifted: $(cat "$TMP"/state-*.json)"

echo "fleet-merge: --dry-run changes nothing"
verdict '.'; run --dry-run
[ "$RC" = 0 ] && [ "$(writes)" = 0 ] && ok "dry run writes nothing" || bad "dry run: rc=$RC writes=$(writes)"

[ "$fail" = 0 ] && echo "fleet-merge: all cases passed"
exit "$fail"
