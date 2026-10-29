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
  */pulls/*) printf '{"head":{"sha":"%s","ref":"%s"},"base":{"ref":"%s"},"state":"open"}\n' "$STUB_HEAD" "${STUB_HEAD_REF:-feat/x}" "${STUB_BASE_REF:-dev}" ;;
  # The base's manifest is `manifest`; a head that changed its own is `manifest-head`.
  */contents/*\?ref=$STUB_HEAD) if [ -f "$STUB_DIR/manifest-head" ]; then cat "$STUB_DIR/manifest-head"; else cat "$STUB_DIR/manifest"; fi ;;
  */contents/*) [ "${STUB_NO_BASE_MANIFEST:-0}" = 1 ] && { echo '{"message":"Not Found"}' >&2; exit 1; }
                cat "$STUB_DIR/manifest" ;;
  */rules/branches/*)
    if [ -n "${STUB_RULES_ERR:-}" ]; then
      echo "{\"message\":\"$STUB_RULES_ERR\",\"status\":\"${STUB_RULES_STATUS:-403}\"}"
      echo "gh: $STUB_RULES_ERR (HTTP ${STUB_RULES_STATUS:-403})" >&2; exit 1
    fi
    echo '[{"type":"merge_queue","ruleset_source_type":"Repository","ruleset_id":11},{"type":"required_status_checks","ruleset_source_type":"Organization","ruleset_id":22},{"type":"deletion","ruleset_source_type":"Repository","ruleset_id":33}]' ;;
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

echo "fleet-merge: the job list is the BASE's manifest, not the head's"
# A head that drops a failing job from its own manifest, then runs the replica on
# that manifest, must not authorize its own merge.
printf '%s\n' '{"version":1,"jobs":[{"name":"lint","commands":["npm run lint"]},{"name":"unit","commands":["npm test"]}]}' > "$TMP/manifest"
printf '%s\n' '{"version":1,"jobs":[{"name":"lint","commands":["npm run lint"]}]}' > "$TMP/manifest-head"
BASE_MSHA="$(sha256sum "$TMP/manifest" | cut -d' ' -f1)"; HEAD_MSHA="$(sha256sum "$TMP/manifest-head" | cut -d' ' -f1)"
verdict ".manifestSha256=\"$HEAD_MSHA\""; run
[ "$RC" = 1 ] && [ "$(writes)" = 0 ] && grep -q "different manifest than dev's" <<<"$OUT" \
  && ok "refuses a verdict run on a head manifest that dropped a job" || bad "head-manifest verdict: rc=$RC writes=$(writes) $OUT"
verdict ".manifestSha256=\"$BASE_MSHA\""; run
[ "$RC" = 0 ] && ok "accepts a verdict run on the base's manifest while the head changes its own" || bad "base-manifest verdict: rc=$RC $OUT"
verdict ".manifestSha256=\"$BASE_MSHA\""; STUB_NO_BASE_MANIFEST=1 run
[ "$RC" = 1 ] && [ "$(writes)" = 0 ] && ok "refuses when the base has no manifest" || bad "no base manifest: rc=$RC $OUT"
printf '%s' "$MANIFEST" > "$TMP/manifest"; rm -f "$TMP/manifest-head"

echo "fleet-merge: an excused data-plane job is allowed, and said so"
verdict '.jobs[1].result="NOT-RUN"'; run --allow-not-run e2e
[ "$RC" = 0 ] && grep -q 'excused by --allow-not-run' <<<"$OUT" && ok "--allow-not-run excuses visibly" || bad "allow: rc=$RC $OUT"
verdict '.'; run --allow-not-run nosuch
[ "$RC" = 1 ] && [ "$(writes)" = 0 ] && ok "--allow-not-run of an unknown job refuses" || bad "unknown allow: rc=$RC"

echo "fleet-merge: a lone --job verdict names the jobs it leaves uncovered"
verdict '.full=false|.jobs[1].result="NOT-RUN"|.jobs[1].detail="not selected (--job)"'; run
[ "$RC" = 1 ] && [ "$(writes)" = 0 ] && grep -q 'came from a --job subset' <<<"$OUT" && grep -q 'uncovered: e2e' <<<"$OUT" \
  && ok "refuses and names e2e" || bad "lone partial: rc=$RC writes=$(writes) $OUT"

echo "fleet-merge: one full verdict still authorizes alone"
verdict '.schema=2|.machine="desk"|.jobs[0].finishedAt="2026-01-01T00:00:00Z"'; run
[ "$RC" = 0 ] && grep -q "lint PASS at 2026-01-01T00:00:00Z from $TMP/verdict.json (machine desk)" <<<"$OUT" \
  && ok "a single full schema-2 verdict merges and is attributed" || bad "single full: rc=$RC $OUT"
verdict '.'; run
[ "$RC" = 0 ] && grep -q "machine unrecorded" <<<"$OUT" && ok "a single full schema-1 verdict merges" || bad "single old: rc=$RC $OUT"

echo "fleet-merge: several per-job verdicts for one SHA"
# The base manifest gates: lint and native run locally, ios does not. The desktop
# runs lint, the laptop (the one with /dev/kvm) runs native.
printf '%s\n' '{"version":1,"jobs":[{"name":"lint","commands":["true"]},{"name":"native","commands":["true"]},{"name":"ios","local":false,"localReason":"macOS","commands":[]}]}' > "$TMP/manifest"
MM="$(sha256sum "$TMP/manifest" | cut -d' ' -f1)"
T1=2026-01-01T00:10:00Z T2=2026-01-01T00:20:00Z T3=2026-01-01T00:30:00Z
# pv <file> <machine> <lint result> <lint finishedAt> <native result> <native finishedAt> [jq filter]
# A NOT-RUN row is written the way ci-replica.sh writes a deselected job.
pv() {
  jq -n --arg sha "$HEAD" --arg m "$MM" --arg mach "$2" --arg lr "$3" --arg lt "$4" --arg nr "$5" --arg nt "$6" '
    def row($n; $r; $t): {name:$n, result:$r, local:true, selected:($r!="NOT-RUN"),
      detail:(if $r=="NOT-RUN" then "not selected (--job)" else "" end),
      startedAt:(if $r=="NOT-RUN" then null else $t end), finishedAt:(if $r=="NOT-RUN" then null else $t end)};
    {schema:2, sha:$sha, machine:$mach, treeClean:true, full:false, manifestSha256:$m, finishedAt:$T3,
     exit:(if $lr=="FAIL" or $nr=="FAIL" then 1 else 0 end),
     jobs:[row("lint"; $lr; $lt), row("native"; $nr; $nt),
           {name:"ios", result:"NOT-RUN", local:false, selected:false, detail:"not selected (--job)", startedAt:null, finishedAt:null}]}' \
    --arg T3 "$T3" | jq "${7:-.}" > "$1"
}
runm() {  # runm <verdict>... [-- args...]
  local vs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do vs+=(--verdict "$1"); shift; done
  [ "${1:-}" = -- ] && shift
  : > "$TMP/calls"; rm -f "$TMP"/state-*.json "$TMP/comment.json"
  OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" \
    "$FM" 7 --repo o/r "${vs[@]}" "$@" 2>&1)"; RC=$?
}
refused() {  # refused <label> <expected output fragment>
  [ "$RC" = 1 ] && [ "$(writes)" = 0 ] && ! grep -q -- '-X POST' "$TMP/calls" && grep -qF -- "$2" <<<"$OUT" \
    && ok "refuses $1" || bad "$1: rc=$RC writes=$(writes) $OUT"
}
D="$TMP/desk.json" L="$TMP/lap.json" L2="$TMP/lap2.json"

pv "$D" desk PASS "$T1" NOT-RUN ""; pv "$L" lap NOT-RUN "" PASS "$T2"
runm "$D" "$L"
[ "$RC" = 0 ] && grep -q -- "-X PUT repos/o/r/pulls/7/merge -f sha=$HEAD" "$TMP/calls" \
  && ok "accepts a union that covers every local job" || bad "union: rc=$RC $OUT"
grep -q "lint PASS at $T1 from $D (machine desk)" <<<"$OUT" && grep -q "native PASS at $T2 from $L (machine lap)" <<<"$OUT" \
  && ok "the output names the file and machine behind each job" || bad "attribution: $OUT"
grep -q "verdict file $L: machine lap" <<<"$OUT" && ok "and each verdict file's machine" || bad "machines: $OUT"
body="$(jq -r .body "$TMP/comment.json" 2>/dev/null)"
grep -qF "| \`native\` | PASS | $T2 | \`$L\` | \`lap\` |" <<<"$body" \
  && grep -qF "sha256 \`$(sha256sum "$D" | cut -d' ' -f1)\`" <<<"$body" && grep -qF "sha256 \`$(sha256sum "$L" | cut -d' ' -f1)\`" <<<"$body" \
  && grep -q "fleet-verdict sha=$HEAD" <<<"$body" \
  && ok "the comment carries the attribution table and every verdict with its hash" || bad "comment: $body"

pv "$L" lap NOT-RUN "" NOT-RUN ""
runm "$D" "$L"; refused "a union with a gap, naming the job" "no verdict covers with a PASS: native"
pv "$L" lap NOT-RUN "" PASS "$T2" '.jobs[1].result="NOT-RUN"|.jobs[1].detail="unmeasured: exit 75"'
runm "$D" "$L"; refused "a union whose only native row is unmeasured" "no verdict covers with a PASS: native"
pv "$L" lap NOT-RUN "" NOT-RUN ""
runm "$D" "$L" -- --allow-not-run native
[ "$RC" = 0 ] && grep -q 'native was not measured by any verdict, excused by --allow-not-run' <<<"$OUT" \
  && ok "--allow-not-run excuses a gap in the union, visibly" || bad "union allow: rc=$RC $OUT"
runm "$D" "$L" -- --allow-not-run nosuch; refused "an --allow-not-run naming no base job" "names no job in dev's"

pv "$L" lap NOT-RUN "" PASS "$T2" '.sha="bbbb"'
runm "$D" "$L"; refused "a verdict from another SHA" "verdict $L is for bbbb"
pv "$L" lap NOT-RUN "" PASS "$T2" '.manifestSha256="x"'
runm "$D" "$L"; refused "verdicts that ran different manifests" "the verdicts ran different manifests"
pv "$D" desk PASS "$T1" NOT-RUN "" '.manifestSha256="y"'; pv "$L" lap NOT-RUN "" PASS "$T2" '.manifestSha256="y"'
runm "$D" "$L"; refused "verdicts that agree on a manifest the base does not have" "different manifest than dev's"
pv "$D" desk PASS "$T1" NOT-RUN ""
pv "$L" lap NOT-RUN "" PASS "$T2" '.treeClean=false'
runm "$D" "$L"; refused "a set with one dirty-tree verdict" "verdict $L measured a dirty working tree"

pv "$L" lap NOT-RUN "" PASS "$T2"; pv "$L2" lap FAIL "$T3" NOT-RUN ""
runm "$D" "$L" "$L2"; refused "a PASS then a later FAIL for the same job" "jobs FAILed: lint (latest: $L2 on lap at $T3)"
pv "$D" desk FAIL "$T1" NOT-RUN ""; pv "$L2" lap PASS "$T3" NOT-RUN ""
runm "$D" "$L" "$L2"
[ "$RC" = 0 ] && grep -q "lint PASS at $T3 from $L2 (machine lap)" <<<"$OUT" \
  && ok "accepts a FAIL then a later PASS, attributed to the later file" || bad "fail then pass: rc=$RC $OUT"
pv "$D" desk PASS "$T1" NOT-RUN ""; pv "$L2" lap FAIL "$T1" NOT-RUN ""
runm "$D" "$L" "$L2"; refused "a PASS and a FAIL at the same time (FAIL wins the tie)" "jobs FAILed: lint"
pv "$D" desk PASS "$T1" NOT-RUN ""; pv "$L2" lap NOT-RUN "" NOT-RUN "" '.finishedAt="2027-01-01T00:00:00Z"'
runm "$D" "$L" "$L2"
[ "$RC" = 0 ] && ok "a newer verdict's NOT-RUN rows do not override earlier PASSes" || bad "not-run override: rc=$RC $OUT"

echo "fleet-merge: old-format (schema 1) verdicts still combine"
# No machine, no per-job timestamps: rows are ordered by the verdict's finishedAt.
old() {  # old <file> <finishedAt> <lint result> <native result>
  jq -n --arg sha "$HEAD" --arg m "$MM" --arg t "$2" --arg lr "$3" --arg nr "$4" '
    def row($n; $r): {name:$n, result:$r, seconds:0, local:true, needsDataPlane:false,
      detail:(if $r=="NOT-RUN" then "not selected (--job)" else "" end)};
    {schema:1, sha:$sha, treeClean:true, full:false, dataPlane:false, base:null, manifestSha256:$m, finishedAt:$t,
     jobs:[row("lint"; $lr), row("native"; $nr), {name:"ios", result:"NOT-RUN", seconds:0, local:false, needsDataPlane:false, detail:"not selected (--job)"}],
     exit:(if $lr=="FAIL" or $nr=="FAIL" then 1 else 0 end)}' > "$1"
}
old "$D" "$T1" PASS NOT-RUN; old "$L" "$T2" NOT-RUN PASS
runm "$D" "$L"
[ "$RC" = 0 ] && grep -q "native PASS at $T2 from $L (machine unrecorded)" <<<"$OUT" \
  && ok "accepts two old --job verdicts whose union is complete" || bad "old union: rc=$RC $OUT"
old "$L2" "$T3" FAIL NOT-RUN
runm "$D" "$L" "$L2"; refused "an old verdict's later FAIL, ordered by the verdict's finishedAt" "jobs FAILed: lint"
pv "$D" desk PASS "$T1" NOT-RUN ""
runm "$D" "$L"
[ "$RC" = 0 ] && ok "a schema-2 and a schema-1 verdict combine" || bad "mixed schemas: rc=$RC $OUT"
printf '%s' "$MANIFEST" > "$TMP/manifest"

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

echo "fleet-merge: the merge method defaults to merge for a promotion, squash otherwise, and --method wins"
method_of() { grep -o 'merge_method=[a-z]*' "$TMP/calls" | tail -1; }
runref() {  # runref <head-ref> <base-ref> [args...]
  local h="$1" b="$2"; shift 2
  : > "$TMP/calls"; rm -f "$TMP"/state-*.json
  OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" STUB_HEAD_REF="$h" STUB_BASE_REF="$b" \
    "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" "$@" 2>&1)"; RC=$?
}
verdict '.'
for c in 'dev main merge' 'release/1.2 main merge' 'dev release/1.2 merge' 'feat/x dev squash' 'feat/x main squash' 'wave/1 dev squash'; do
  set -- $c; runref "$1" "$2"
  [ "$RC" = 0 ] && [ "$(method_of)" = "merge_method=$3" ] && ok "$1 -> $2 defaults to $3" || bad "$1 -> $2: rc=$RC $(method_of) $OUT"
done
runref dev main --method squash
[ "$(method_of)" = merge_method=squash ] && ok "explicit --method squash overrides a promotion default" || bad "override: $(method_of)"
runref feat/x dev --method merge
[ "$(method_of)" = merge_method=merge ] && ok "explicit --method merge overrides the squash default" || bad "override: $(method_of)"
runref feat/x dev --method bogus
[ "$RC" = 2 ] && [ "$(writes)" = 0 ] && ok "an unknown --method is a usage error with no write" || bad "bogus method: rc=$RC"

echo "fleet-merge: the token source is named, and an unreachable org ruleset names the scope"
verdict '.'; : > "$TMP/calls"; rm -f "$TMP"/state-*.json
OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" STUB_ORG_KEYRING_ONLY=1 \
  BASH_ENV=/dev/null GH_TOKEN=ambient FLEET_MERGE_GH_TOKEN=explicit "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" 2>&1)"; RC=$?
grep -q 'token source: FLEET_MERGE_GH_TOKEN' <<<"$OUT" && ok "FLEET_MERGE_GH_TOKEN is preferred and named" || bad "source: $OUT"
[ "$RC" = 0 ] && ok "and the org call still recovers on the keyring credential" || bad "rc=$RC $OUT"
OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" BASH_ENV=/dev/null GH_TOKEN=ambient "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" --dry-run 2>&1)"
grep -q 'token source: ambient GH_TOKEN' <<<"$OUT" && ok "an ambient token is named as such" || bad "ambient source: $OUT"
mv "$TMP/bin/gh" "$TMP/bin/gh-real"
cat > "$TMP/bin/gh" <<'S404'
#!/usr/bin/env bash
case "$*" in *orgs/*) echo '{"message":"Not Found"}'; exit 1 ;; esac
exec "$STUB_REAL_GH" "$@"
S404
chmod +x "$TMP/bin/gh"; export STUB_REAL_GH="$TMP/bin/gh-real"
: > "$TMP/calls"; rm -f "$TMP"/state-*.json
OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" BASH_ENV=/dev/null GH_TOKEN=ambient "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" 2>&1)"; RC=$?
grep -q 'lacks admin:org' <<<"$OUT" && grep -q 'FLEET_MERGE_GH_TOKEN' <<<"$OUT" && ok "a 404 on the org ruleset names the token-scope cause" || bad "404 message: $OUT"
[ "$(writes)" = 0 ] && ok "and nothing was written" || bad "wrote despite unreachable org ruleset: $(writes)"
mv "$TMP/bin/gh-real" "$TMP/bin/gh"; unset STUB_REAL_GH

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

echo "fleet-merge: a free-plan private repo (rules endpoint 403 \"Upgrade to GitHub Pro\") has no gating rulesets"
UPGRADE='Upgrade to GitHub Pro or make this repository public to enable this feature'
verdict '.'; : > "$TMP/calls"; rm -f "$TMP"/state-*.json; rm -rf "$TMP/state"
OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" STUB_RULES_ERR="$UPGRADE" \
  "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "merges instead of aborting" || bad "rc=$RC $OUT"
[ "$(grep -c 'has no rulesets' <<<"$OUT")" = 1 ] && ok "logs the ungated base once" || bad "log: $OUT"
grep -q -- "-X PUT repos/o/r/pulls/7/merge -f sha=$HEAD" "$TMP/calls" && ok "the merge is pinned to the verdict SHA" || bad "unpinned: $(cat "$TMP/calls")"
[ "$(grep -c -- '-X PUT' "$TMP/calls")" = 1 ] && ! grep -q 'rulesets/' "$TMP/calls" && ok "no ruleset is read, lifted or restored" || bad "ruleset calls: $(cat "$TMP/calls")"
grep -q -- '-X POST' "$TMP/calls" && ok "the verdict is still published" || bad "no verdict comment"
echo "fleet-merge: any other 403 or 404 on the rules endpoint still fails"
for c in 'Resource not accessible by integration|403' 'Not Found|404' "$UPGRADE|404"; do
  verdict '.'; : > "$TMP/calls"; rm -f "$TMP"/state-*.json
  OUT="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" STUB_HEAD="$HEAD" STUB_RULES_ERR="${c%%|*}" STUB_RULES_STATUS="${c##*|}" \
    "$FM" 7 --repo o/r --verdict "$TMP/verdict.json" 2>&1)"; RC=$?
  [ "$RC" = 2 ] && grep -q 'cannot read rules for dev' <<<"$OUT" && [ "$(writes)" = 0 ] && ! grep -q -- '-X POST' "$TMP/calls" \
    && ok "${c%%|*} (HTTP ${c##*|}) aborts with no write" || bad "${c}: rc=$RC writes=$(writes) $OUT"
done
verdict '.'; run --dry-run
[ "$RC" = 0 ] && ok "the gated path is unchanged by the stub's new branch" || bad "rc=$RC"

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
