#!/usr/bin/env bash
# Self-test for npm-install-guard.sh against fixture repos, a stub `npm`, and a
# local stub of the GitHub Packages registry: the lockfile-pin rule (blocks a
# rewriting command under the wrong npm major, allows `npm ci`, the corepack
# path and an unpinned repo, refuses `npx npm@<pin>`), and the token rule
# (empty, gh-derived, invalid and valid tokens; files a login shell would source).
#   bash hooks/npm-install-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/npm-install-guard.sh"
TMP="$(mktemp -d)"
fail=0

unset BASH_ENV NODE_AUTH_TOKEN GITHUB_TOKEN
export HOME="$TMP/home" TMPDIR="$TMP" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME" "$TMP/bin"
printf '#!/bin/sh\n[ "$1" = --version ] && echo 11.4.0\n' >"$TMP/bin/npm"
printf '#!/bin/sh\n[ "$1 $2" = "auth token" ] && echo gho_fromgh\n' >"$TMP/bin/gh"
chmod +x "$TMP/bin/npm" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

cat >"$TMP/registry.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        ok = self.headers.get("Authorization") == "Bearer ghp_good"
        self.send_response(200 if ok else 401); self.end_headers()
srv = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$TMP/registry.py" "$TMP/port" & REG=$!
trap 'kill "$REG" 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
NPM_TOKEN_PROBE_URL="http://127.0.0.1:$(cat "$TMP/port")/pkg"
export NPM_TOKEN_PROBE_URL NO_PROXY=127.0.0.1 no_proxy=127.0.0.1

PINNED="$TMP/pinned"; mkdir -p "$PINNED"
echo '{ "name": "p", "packageManager": "npm@10.8.2" }' >"$PINNED/package.json"
echo '//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}' >"$PINNED/.npmrc"
FREE="$TMP/free"; mkdir -p "$FREE"
echo '{ "name": "f" }' >"$FREE/package.json"

check() {
  local want="$1" dir="$2" cmd="$3" got
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))' "$cmd" "$dir" \
    | (cd "$dir" && "$GUARD") >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: want exit $want, got $got in $(basename "$dir") (NODE_AUTH_TOKEN=${NODE_AUTH_TOKEN:-unset}): $cmd"
    fail=1
  fi
}

echo "npm-install-guard: token rule"
check 2 "$PINNED" "npm ci"
check 2 "$PINNED" 'NODE_AUTH_TOKEN="$(gh auth token)" npm ci'
check 0 "$FREE" "npm ci"
export NODE_AUTH_TOKEN=ghp_bad
check 2 "$PINNED" "npm ci"
export NODE_AUTH_TOKEN=ghp_good
check 0 "$PINNED" "npm ci"
check 0 "$PINNED" "npm run build"
unset NODE_AUTH_TOKEN
mkdir -p "$HOME/.config/secrets"
echo 'export NODE_AUTH_TOKEN=ghp_good' >"$HOME/.config/secrets/gmi.env"
check 0 "$PINNED" "npm ci"
rm "$HOME/.config/secrets/gmi.env"
mkdir -p "$PINNED/.claude" "$HOME/.pin"
echo '{ "stateDir": "~/.pin" }' >"$PINNED/.claude/repo.json"
git init -q "$PINNED"
echo "export NODE_AUTH_TOKEN='ghp_good'" >"$HOME/.pin/agent.env"
check 0 "$PINNED" "npm ci"
rm "$HOME/.pin/agent.env"

echo "npm-install-guard: lockfile pin"
export NODE_AUTH_TOKEN=ghp_good
check 2 "$PINNED" "npm install lodash"
check 2 "$PINNED" "npm i"
check 2 "$PINNED" "npm update"
check 2 "$PINNED" "npm --prefix . install"
check 2 "$PINNED" "npm audit fix"
check 2 "$PINNED" "npx npm@10.8.2 install"
check 0 "$PINNED" "corepack npm@10.8.2 install"
check 0 "$PINNED" "npm audit"
check 0 "$PINNED" "pnpm install"
check 0 "$FREE" "npm install lodash"
check 2 "$TMP" "cd $PINNED && npm install"

printf 'not json' | "$GUARD" >/dev/null 2>&1 || { echo "FAIL: garbage input did not fail open"; fail=1; }

[ "$fail" = 0 ] && echo "npm-install-guard: all cases passed"
exit "$fail"
