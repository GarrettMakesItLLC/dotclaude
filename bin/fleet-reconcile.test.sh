#!/usr/bin/env bash
# Self-test for fleet-reconcile.sh. Drives the script against a stub `gh` that
# serves canned API responses and records every write, plus a real throwaway git
# repo for the branch-containment half. Asserts the behaviours the fix depends
# on: dry run writes nothing, `Closes #A, #B` is read the way GitHub reads it,
# an open-but-shipped issue is closed WITH evidence, status labels are cleared
# and percent-encoded, and only contained branches with closed issues are
# deleted.
#   bash bin/fleet-reconcile.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REC="$HERE/fleet-reconcile.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

FIX="$TMP/fixtures"; mkdir -p "$FIX"
WRITES="$TMP/writes.log"

cat > "$TMP/gh-stub" <<'STUB'
#!/usr/bin/env python3
"""Stand-in for `gh`. Reads fixtures from $FIX, appends writes to $WRITES."""
import json, os, sys

fix = os.environ["FIX"]
writes = os.environ["WRITES"]
argv = sys.argv[1:]

def out(s):
    sys.stdout.write(s if s.endswith("\n") else s + "\n")

if argv[:1] == ["repo"]:
    out(json.load(open(os.path.join(fix, "repo.json")))["nameWithOwner"])
    sys.exit(0)

if argv[0] != "api":
    sys.exit(2)
argv = argv[1:]

method = "GET"
jq = None
path = None
fields = {}
i = 0
while i < len(argv):
    a = argv[i]
    if a == "-X":
        method = argv[i + 1]; i += 2
    elif a == "--jq":
        jq = argv[i + 1]; i += 2
    elif a == "-f":
        k, _, v = argv[i + 1].partition("="); fields[k] = v; i += 2
    elif a == "--silent":
        i += 1
    elif path is None:
        path = a; i += 1
    else:
        i += 1

if method != "GET":
    with open(writes, "a") as fh:
        fh.write(f"{method} {path} {json.dumps(fields, sort_keys=True)}\n")
    # Mutate the fixtures the way the real API would, so a later read in the
    # same run sees the write. Without this the test would assert against a
    # world the script never actually produces.
    parts = path.strip("/").split("/")
    def fx(name):
        return os.path.join(fix, name.replace("/", "_") + ".json")
    if method == "PATCH" and len(parts) == 5 and parts[3] == "issues":
        f = fx(path)
        if os.path.exists(f):
            d = json.load(open(f)); d.update(fields); json.dump(d, open(f, "w"))
    if method == "DELETE" and "/labels/" in path:
        base, _, label = path.partition("/labels/")
        import urllib.parse
        label = urllib.parse.unquote(label)
        f = fx(base + "/labels")
        if os.path.exists(f):
            d = [x for x in json.load(open(f)) if x["name"] != label]
            json.dump(d, open(f, "w"))
    sys.exit(0)

key = path.replace("/", "_").replace("?", "_").replace("&", "_").replace("=", "_")
f = os.path.join(fix, key + ".json")
if not os.path.exists(f):
    sys.stderr.write(f"stub: no fixture for GET {path} (looked for {f})\n")
    sys.exit(1)
data = json.load(open(f))

if jq is None:
    out(json.dumps(data))
elif jq == ".state":
    out(data["state"])
elif jq == ".[].name":
    for x in data:
        out(x["name"])
elif jq == ".nameWithOwner":
    out(data["nameWithOwner"])
elif "merged_at" in jq:
    for x in data:
        if x.get("merged_at"):
            out(str(x["number"]))
else:
    sys.stderr.write(f"stub: unsupported --jq {jq!r}\n")
    sys.exit(1)
STUB
chmod +x "$TMP/gh-stub"
export FIX WRITES
export FLEET_GH="$TMP/gh-stub"

echo '{"nameWithOwner":"acme/widget"}' > "$FIX/repo.json"

# --- a real repo so branch containment is answered from real objects ---------
BARE="$TMP/bare.git"; WORK="$TMP/work"
git init --quiet --bare "$BARE"
git init --quiet "$WORK"
git -C "$WORK" config user.email t@test; git -C "$WORK" config user.name t
git -C "$WORK" remote add origin "$BARE"
echo one > "$WORK/a"; git -C "$WORK" add a; git -C "$WORK" commit --quiet -m base
git -C "$WORK" branch -M main
git -C "$WORK" checkout --quiet -b feature/101-thing
echo two > "$WORK/b"; git -C "$WORK" add b; git -C "$WORK" commit --quiet -m work
git -C "$WORK" checkout --quiet main
git -C "$WORK" merge --quiet --no-ff feature/101-thing -m "merge 101"
MERGE_SHA="$(git -C "$WORK" rev-parse HEAD)"
# a branch that is NOT contained in the merge
git -C "$WORK" checkout --quiet -b feature/999-live
echo three > "$WORK/c"; git -C "$WORK" add c; git -C "$WORK" commit --quiet -m live
git -C "$WORK" checkout --quiet main
git -C "$WORK" push --quiet origin main feature/101-thing feature/999-live

cat > "$FIX/repos_acme_widget_pulls_7.json" <<JSON
{"number":7,"title":"fix: the thing","merged_at":"2026-09-18T10:00:00Z",
 "merge_commit_sha":"$MERGE_SHA","head":{"ref":"feature/101-thing"},
 "body":"Closes #101, #102\n\nFixes #103\nResolves #104\nSee also #105"}
JSON
mk_issue() { printf '{"number":%s,"state":"%s"}\n' "$1" "$2" > "$FIX/repos_acme_widget_issues_$1.json"; }
mk_labels() { printf '%s\n' "$2" > "$FIX/repos_acme_widget_issues_$1_labels.json"; }
mk_issue 101 open;   mk_labels 101 '[{"name":"status:in-progress"},{"name":"type:bug"}]'
mk_issue 102 open;   mk_labels 102 '[]'
mk_issue 103 closed; mk_labels 103 '[{"name":"status:in-review"}]'
mk_issue 104 closed; mk_labels 104 '[{"name":"type:task"}]'
mk_issue 105 open;   mk_labels 105 '[]'
mk_issue 999 open;   mk_labels 999 '[]'

run() { OUT="$(cd "$WORK" && "$REC" --repo acme/widget "$@" 2>&1)"; RC=$?; }

echo "fleet-reconcile: dry run"
: > "$WRITES"
run --pr 7
[ "$RC" = 0 ] && ok "dry run exits 0" || bad "rc=$RC: $OUT"
[ ! -s "$WRITES" ] && ok "dry run performs no writes at all" || bad "dry run wrote: $(cat "$WRITES")"
printf '%s' "$OUT" | grep -q 'WOULD close #101' && ok "names the shipped-but-open issue" || bad "no #101 line: $OUT"
printf '%s' "$OUT" | grep -q 'dry run' && ok "says it is a dry run" || bad "no dry-run notice"

echo "fleet-reconcile: closing keywords are read the way GitHub reads them"
printf '%s' "$OUT" | grep -q '#103' && ok "a repeated keyword (Fixes #103) is a reference" || bad "missed #103"
printf '%s' "$OUT" | grep -q '#104' && ok "Resolves #104 is a reference" || bad "missed #104"
printf '%s' "$OUT" | grep -q '#105' && bad "a bare '#105' with no keyword must NOT be treated as closing" \
  || ok "a bare mention is not a closing reference"
# #102 is the trap: `Closes #101, #102` closes only #101 on GitHub, so #102 is a
# bare mention and must not be auto-closed by this script either.
printf '%s' "$OUT" | grep -q 'close #102' && bad "#102 after a comma is not a GitHub closing reference" \
  || ok "the 'Closes #A, #B' trap is not papered over"

echo "fleet-reconcile: --apply"
: > "$WRITES"
run --pr 7 --apply
[ "$RC" = 0 ] && ok "apply exits 0" || bad "rc=$RC: $OUT"
grep -q 'POST repos/acme/widget/issues/101/comments' "$WRITES" \
  && ok "the close is preceded by a comment (evidence, not a silent close)" || bad "no evidence comment: $(cat "$WRITES")"
grep 'POST repos/acme/widget/issues/101/comments' "$WRITES" | grep -q '#7' \
  && ok "the evidence names the shipping PR" || bad "comment does not cite the PR"
grep -q 'PATCH repos/acme/widget/issues/101 .*"state": "closed"' "$WRITES" \
  && ok "#101 is closed" || bad "no close PATCH: $(cat "$WRITES")"
grep -q '"state_reason": "completed"' "$WRITES" \
  && ok "closed as completed, not as not-planned" || bad "wrong state_reason"
grep -q 'PATCH repos/acme/widget/issues/105' "$WRITES" && bad "closed a bare mention" \
  || ok "a bare mention is never closed"

echo "fleet-reconcile: status labels on closed issues"
grep -q 'DELETE repos/acme/widget/issues/103/labels/status%3Ain-review' "$WRITES" \
  && ok "a stale status label is removed, percent-encoded" || bad "label not removed/encoded: $(cat "$WRITES")"
grep -q 'labels/type%3Atask' "$WRITES" && bad "removed a non-status label" || ok "only status:* labels are touched"
grep -q 'labels/status:in-review' "$WRITES" && bad "unencoded label path would 404 and report success" \
  || ok "no unencoded label path is ever sent"

echo "fleet-reconcile: branches"
grep -q 'DELETE repos/acme/widget/git/refs/heads/feature/101-thing' "$WRITES" \
  && ok "a contained branch whose issue is closed is deleted" || bad "branch not deleted: $(cat "$WRITES")"
grep -q 'refs/heads/feature/999-live' "$WRITES" && bad "deleted a branch not contained in the merge" \
  || ok "a branch not contained in the merge is left alone"
grep -q 'refs/heads/main' "$WRITES" && bad "deleted a protected branch" || ok "protected branches are never deleted"

: > "$WRITES"
run --pr 7 --apply --no-branches
grep -q 'refs/heads' "$WRITES" && bad "--no-branches still deleted a branch" || ok "--no-branches skips branch cleanup"

echo "fleet-reconcile: an unmerged PR is skipped"
cat > "$FIX/repos_acme_widget_pulls_8.json" <<'JSON'
{"number":8,"title":"wip","merged_at":null,"merge_commit_sha":null,
 "head":{"ref":"feature/202-wip"},"body":"Closes #101"}
JSON
: > "$WRITES"
run --pr 8 --apply
[ ! -s "$WRITES" ] && ok "an unmerged PR produces no writes" || bad "wrote for an unmerged PR: $(cat "$WRITES")"
printf '%s' "$OUT" | grep -q 'not merged' && ok "and says so" || bad "silent skip: $OUT"

echo "fleet-reconcile: a clean tracker reports clean"
mk_issue 101 closed; mk_labels 101 '[{"name":"type:bug"}]'
mk_labels 103 '[]'
cat > "$FIX/repos_acme_widget_pulls_9.json" <<JSON
{"number":9,"title":"clean","merged_at":"2026-09-18T11:00:00Z",
 "merge_commit_sha":"$MERGE_SHA","head":{"ref":"feature/101-thing"},"body":"Fixes #101"}
JSON
: > "$WRITES"
run --pr 9
printf '%s' "$OUT" | grep -q 'already closed' && ok "reports an already-closed issue as such" || bad "$OUT"

echo "fleet-reconcile: usage"
run --pr notanumber; [ "$RC" != 0 ] && ok "a non-numeric --pr is rejected" || bad "accepted a bad --pr"
run --last x;        [ "$RC" != 0 ] && ok "a non-numeric --last is rejected" || bad "accepted a bad --last"
run --bogus;         [ "$RC" != 0 ] && ok "an unknown option is rejected" || bad "accepted a bogus option"

[ "$fail" = 0 ] && echo "fleet-reconcile: all cases passed"
exit "$fail"
