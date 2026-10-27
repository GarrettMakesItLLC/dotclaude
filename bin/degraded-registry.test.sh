#!/usr/bin/env bash
# Self-test for degraded-registry.sh and the mirror behind it.
#
# The claim worth testing is the routing one: a project .npmrc that pins the
# scope to GitHub Packages, plus a lockfile whose `resolved` is a GitHub
# download URL, still installs from the mirror once the switch is on. So the
# last case runs a real `npm ci` against a throwaway mirror on a free port.
# No network: the fixture package has no dependencies.
#
# Run:  bash bin/degraded-registry.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/degraded-registry.sh"
fail=0
check() { if eval "$2"; then :; else echo "FAIL ($1)"; fail=1; fi; }

TMP="$(mktemp -d)"
export DEGRADED_REGISTRY_NPMRC="$TMP/npmrc"
export GMI_REGISTRY_HOME="$TMP/store" GMI_REGISTRY_STATE="$TMP/state"
export GMI_REGISTRY_REMOTE="$TMP/no-remote.git"
GMI_REGISTRY_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
export GMI_REGISTRY_PORT
cleanup() { "$CLI" stop >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT
BASE="http://127.0.0.1:${GMI_REGISTRY_PORT}"

# --- a fixture package, packed the way npm packs ------------------------------
mkdir -p "$TMP/pkg"
cat >"$TMP/pkg/package.json" <<'EOF'
{ "name": "@garrettmakesitllc/fixture", "version": "1.2.3", "main": "index.js" }
EOF
echo 'module.exports = 42;' >"$TMP/pkg/index.js"

# --- the ~/.npmrc block ----------------------------------------------------------
printf 'engine-strict=true\n' >"$DEGRADED_REGISTRY_NPMRC"
on_out="$("$CLI" on 2>&1)" || echo "  \`on\` failed: $on_out"
check "on writes registry" "grep -qx 'registry=${BASE}/' '$DEGRADED_REGISTRY_NPMRC'"
check "on writes host rewrite" "grep -qx 'replace-registry-host=always' '$DEGRADED_REGISTRY_NPMRC'"
check "on keeps other lines" "grep -qx 'engine-strict=true' '$DEGRADED_REGISTRY_NPMRC'"
"$CLI" on >/dev/null 2>&1
check "on is idempotent" "[ \"\$(grep -c '^registry=' '$DEGRADED_REGISTRY_NPMRC')\" = 1 ]"
check "status --quiet when on" "'$CLI' status --quiet"
check "banner when on" "'$CLI' banner | grep -q 'DEGRADED REGISTRY ON'"
"$CLI" off >/dev/null 2>&1
check "off removes the block" "! grep -q 'degraded-registry\|^registry=' '$DEGRADED_REGISTRY_NPMRC'"
check "off keeps other lines" "grep -qx 'engine-strict=true' '$DEGRADED_REGISTRY_NPMRC'"
check "off stops the mirror" "! curl -s --max-time 2 '$BASE/-/ping' >/dev/null"
check "banner silent when off" "[ -z \"\$('$CLI' banner)\" ]"
rm -f "$DEGRADED_REGISTRY_NPMRC"
"$CLI" on >/dev/null 2>&1; "$CLI" off >/dev/null 2>&1
check "off leaves no empty npmrc" "[ ! -e '$DEGRADED_REGISTRY_NPMRC' ]"
# A mirror that misses its startup budget fails `on` loudly and writes nothing (#545).
# shellcheck disable=SC2034  # read by the check below, through eval
budget_out="$(DEGRADED_REGISTRY_START_SECS=0 "$CLI" on 2>&1)"; budget_rc=$?
check "a missed startup budget fails on" "[ $budget_rc -ne 0 ] && grep -q 'within 0s' <<<\"\$budget_out\""
check "and writes no block" "[ ! -e '$DEGRADED_REGISTRY_NPMRC' ] || ! grep -q '^registry=' '$DEGRADED_REGISTRY_NPMRC'"
"$CLI" off >/dev/null 2>&1
printf 'registry=https://example.invalid/\n' >"$DEGRADED_REGISTRY_NPMRC"
check "on refuses a foreign registry= line" "! '$CLI' on >/dev/null 2>&1"
rm -f "$DEGRADED_REGISTRY_NPMRC"

# --- publish and serve ---------------------------------------------------------------
"$CLI" start >/dev/null 2>&1
check "publish a package dir" "'$CLI' publish '$TMP/pkg' >/dev/null 2>&1"
TGZ="$GMI_REGISTRY_HOME/packages/fixture/fixture-1.2.3.tgz"
check "tarball lands in the store" "[ -f '$TGZ' ]"
check "republishing identical bytes is a no-op" "'$CLI' publish '$TGZ' >/dev/null 2>&1"
cp "$TGZ" "$TMP/other.tgz"; printf 'x' >>"$TMP/other.tgz"
mkdir -p "$TMP/x" && tar -xzf "$TGZ" -C "$TMP/x" && echo '// changed' >>"$TMP/x/package/index.js" \
  && tar -czf "$TMP/changed.tgz" -C "$TMP/x" package
check "a version is immutable" "! '$CLI' publish '$TMP/changed.tgz' >/dev/null 2>&1"
SHA1="$(sha1sum "$TGZ" | cut -c1-40)"
INTEGRITY="sha512-$(openssl dgst -sha512 -binary "$TGZ" | base64 -w0)"

doc="$(curl -s "$BASE/@garrettmakesitllc%2ffixture")"
check "packument dist.tarball is GitHub's URL form" \
  "printf '%s' '$doc' | grep -qF 'https://npm.pkg.github.com/download/@garrettmakesitllc/fixture/1.2.3/$SHA1'"
check "packument carries the integrity" "printf '%s' '$doc' | grep -qF '$INTEGRITY'"
check "download path serves the bytes" \
  "curl -sf '$BASE/download/@garrettmakesitllc/fixture/1.2.3/$SHA1' | cmp -s - '$TGZ'"
check "wrong sha1 is refused" \
  "[ \"\$(curl -s -o /dev/null -w '%{http_code}' '$BASE/download/@garrettmakesitllc/fixture/1.2.3/$(printf '0%.0s' {1..40})')\" = 404 ]"
check "unknown scoped package is 404, not proxied" \
  "[ \"\$(curl -s -o /dev/null -w '%{http_code}' '$BASE/@garrettmakesitllc%2fnope')\" = 404 ]"
check "everything else redirects to npmjs" \
  "curl -s -o /dev/null -w '%{http_code} %{redirect_url}' '$BASE/react' | grep -qx '307 https://registry.npmjs.org/react'"

# --- verify, and populate from a cache ----------------------------------------------------
mkdir -p "$TMP/consumer"
cat >"$TMP/consumer/package.json" <<'EOF'
{ "name": "consumer", "version": "0.0.0", "dependencies": { "@gmi/fixture": "npm:@garrettmakesitllc/fixture@1.2.3" } }
EOF
cat >"$TMP/consumer/package-lock.json" <<EOF
{ "name": "consumer", "version": "0.0.0", "lockfileVersion": 3, "requires": true,
  "packages": {
    "": { "name": "consumer", "version": "0.0.0", "dependencies": { "@gmi/fixture": "npm:@garrettmakesitllc/fixture@1.2.3" } },
    "node_modules/@gmi/fixture": { "name": "@garrettmakesitllc/fixture", "version": "1.2.3",
      "resolved": "https://npm.pkg.github.com/download/@garrettmakesitllc/fixture/1.2.3/$SHA1",
      "integrity": "$INTEGRITY" } } }
EOF
check "verify passes when the store serves every pin" "'$CLI' verify '$TMP/consumer/package-lock.json' >/dev/null"
mv "$TGZ" "$TMP/held.tgz"
check "verify fails on a gap" "! '$CLI' verify '$TMP/consumer/package-lock.json' >/dev/null"
HEX="$(openssl dgst -sha512 -binary "$TMP/held.tgz" | xxd -p -c 256)"
CACHE="$TMP/cache/_cacache/content-v2/sha512/${HEX:0:2}/${HEX:2:2}"
mkdir -p "$CACHE" && cp "$TMP/held.tgz" "$CACHE/${HEX:4}"
check "populate copies a pin from an npm cache" \
  "'$CLI' populate --lockfile '$TMP/consumer/package-lock.json' --cache '$TMP/cache' 2>/dev/null | grep -q 'copied from cache: 1'"
check "populated bytes are the cached bytes" "cmp -s '$TGZ' '$TMP/held.tgz'"

# --- sync: per-machine branches, since the org ruleset rejects pushes to main (#596) ----------
SYNC="$TMP/sync"; mkdir -p "$SYNC"
git init -q --bare -b main "$SYNC/remote.git"
# Stand-in for the org ruleset: main takes no direct pushes.
printf '%s\n' '#!/bin/sh' \
  'while read old new ref; do' \
  '  [ "$ref" = refs/heads/main ] && { echo "GH013: Changes must be made through a pull request" >&2; exit 1; }' \
  'done' 'exit 0' >"$SYNC/remote.git/hooks/pre-receive"
chmod +x "$SYNC/remote.git/hooks/pre-receive"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Seed main past the hook, as the repo's initial commit would be.
git clone -q "$SYNC/remote.git" "$SYNC/seed" 2>/dev/null
git -C "$SYNC/seed" commit -q --allow-empty -m init
git -C "$SYNC/seed" push -q "$SYNC/remote.git" HEAD:refs/heads/seed-main 2>/dev/null
rm -f "$SYNC/remote.git/hooks/pre-receive.off"
mv "$SYNC/remote.git/hooks/pre-receive" "$SYNC/remote.git/hooks/pre-receive.off"
git -C "$SYNC/seed" push -q "$SYNC/remote.git" HEAD:refs/heads/main 2>/dev/null
mv "$SYNC/remote.git/hooks/pre-receive.off" "$SYNC/remote.git/hooks/pre-receive"
mk_tgz() { mkdir -p "$1/packages/$2"; printf '%s' "$3" >"$1/packages/$2/$2-$3.tgz"; }
store_a="$SYNC/a"; store_b="$SYNC/b"
mk_tgz "$store_a" alpha 1.0.0
sync_as() { # store host
  GMI_REGISTRY_HOME="$1" GMI_REGISTRY_REMOTE="$SYNC/remote.git" GMI_REGISTRY_HOST="$2" "$CLI" sync 2>&1
}
out="$(sync_as "$store_a" desk)"; rc=$?
check "sync succeeds though main rejects pushes (log: $out)" "[ $rc = 0 ]"
check "sync pushes a per-machine store/ branch" \
  "git -C '$SYNC/remote.git' for-each-ref --format='%(refname)' refs/heads/store/ | grep -q '^refs/heads/store/desk-'"
git clone -q "$SYNC/remote.git" "$store_b" 2>/dev/null
mk_tgz "$store_b" beta 2.0.0
out="$(sync_as "$store_b" lap)"; rc=$?
check "second machine sync succeeds (log: $out)" "[ $rc = 0 ]"
check "second machine received the first machine's tarball" "[ -f '$store_b/packages/alpha/alpha-1.0.0.tgz' ]"
out="$(sync_as "$store_a" desk)"; rc=$?
check "first machine sync succeeds again (log: $out)" "[ $rc = 0 ]"
check "first machine received the second machine's tarball" "[ -f '$store_a/packages/beta/beta-2.0.0.tgz' ]"
mk_tgz "$store_a" gamma 3.0.0
out="$(GMI_REGISTRY_HOME="$store_a" GMI_REGISTRY_REMOTE="$SYNC/nowhere.git" "$CLI" sync 2>&1)"; rc=$?
check "an unreachable remote exits non-zero and says the commit stays local" \
  "[ $rc -ne 0 ] && grep -qi 'unreachable' <<<\"\$out\""
check "and the tarball is committed locally" \
  "git -C '$store_a' ls-files packages/gamma | grep -q gamma-3.0.0.tgz"

# --- the routing claim, end to end ----------------------------------------------------------
# The consumer pins the scope to GitHub Packages exactly as every real repo does.
printf '@garrettmakesitllc:registry=https://npm.pkg.github.com\n' >"$TMP/consumer/.npmrc"
"$CLI" on >/dev/null 2>&1
if command -v npm >/dev/null 2>&1; then
  (cd "$TMP/consumer" && NPM_CONFIG_USERCONFIG="$DEGRADED_REGISTRY_NPMRC" \
     npm ci --no-audit --no-fund --cache "$TMP/npm-cache" >"$TMP/ci.log" 2>&1)
  rc=$?
  check "npm ci through the mirror exits 0 (log: $(tr '\n' ' ' <"$TMP/ci.log" | cut -c1-300))" "[ $rc = 0 ]"
  check "the aliased package is installed" \
    "[ \"\$(node -p 'require(\"$TMP/consumer/node_modules/@gmi/fixture\")')\" = 42 ]"
  check "the lockfile still names GitHub's URL" \
    "grep -qF 'https://npm.pkg.github.com/download/@garrettmakesitllc/fixture/1.2.3/$SHA1' '$TMP/consumer/package-lock.json'"
else
  echo "skip: npm not on PATH, end-to-end install not exercised"
fi
"$CLI" off >/dev/null 2>&1

if [ "$fail" = 0 ]; then
  echo "degraded-registry: all cases passed"
fi
exit "$fail"
