#!/usr/bin/env bash
# Self-test for doctor.sh on a fixture repo, with stub optional CLIs so nothing
# slow or networked runs: the npm-ls classifier, manifest-driven checks and env
# files, the three-state tool probe, the worktree `.env` exemption, and the exit
# status (warnings alone pass, any blocker fails).
#   bash bin/doctor.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="$HERE/doctor.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

unset BASH_ENV REPO_MANIFEST DATABASE_URL
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$TMP/bin"
for t in jq psql shellcheck vercel corepack; do printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/$t"; done
printf '#!/bin/sh\nexit 127\n' >"$TMP/bin/railway"   # a shim whose binary never arrived
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"

echo "doctor: --classify-npm-ls"
cat >"$TMP/lock.json" <<'J'
{ "packages": { "node_modules/@wasm/opt": { "optional": true }, "node_modules/stray": {} } }
J
out="$(printf '%s' '{"dependencies":{"@wasm/opt":{"extraneous":true},"stray":{"extraneous":true},"bad":{"invalid":true},"fine":{}}}' | "$DOC" --classify-npm-ls "$TMP/lock.json")"
grep -qx 'warn @wasm/opt extraneous' <<<"$out" && grep -qx 'block stray extraneous' <<<"$out" && grep -qx 'block bad invalid' <<<"$out" && ! grep -q fine <<<"$out" \
  && ok "optional residue warns; other extraneous and invalid block" || bad "classify: $out"

R="$TMP/repo"
git init -q -b main "$R"
mkdir -p "$R/.claude"
cat >"$R/.claude/repo.json" <<'J'
{ "stateDir": "~/.demo",
  "doctor": {
    "envFiles": [ { "path": ".env", "fix": "copy .env.example" }, { "path": "apps/web/.env.local", "fix": "vercel env pull" } ],
    "checks": [ { "name": "soft thing", "run": "test -f soft", "fix": "touch soft", "severity": "warn" },
                { "name": "hard thing", "run": "test -f hard", "fix": "touch hard" } ] } }
J
git -C "$R" add . && git -C "$R" commit -q -m init
run() { OUT="$(cd "${RUN_DIR:-$R}" && "$DOC" 2>&1)"; RC=$?; }

echo "doctor: a failing blocking check fails the run"
run
[ "$RC" = 1 ] && grep -q '✗.*hard thing' <<<"$OUT" && grep -q 'touch hard' <<<"$OUT" && ok "blocker reported with its fix" || bad "rc=$RC $OUT"
grep -q '!.*soft thing' <<<"$OUT" && ok "a warn-severity check warns" || bad "soft: $OUT"
grep -q '!.*apps/web/.env.local missing' <<<"$OUT" && grep -q 'vercel env pull' <<<"$OUT" && ok "missing env file warns with the manifest's fix" || bad "env: $OUT"
grep -q 'railway present on PATH but NOT RUNNABLE' <<<"$OUT" && ok "a tool that cannot report its version is flagged, not called present" || bad "railway: $OUT"
grep -q 'agent shell credentials not built' <<<"$OUT" && ok "missing agent.env noted" || bad "agent.env: $OUT"

echo "doctor: warnings alone pass"
touch "$R/hard"
run
[ "$RC" = 0 ] && grep -q 'warning(s), nothing blocking' <<<"$OUT" && ok "exit 0 with warnings" || bad "rc=$RC $OUT"

echo "doctor: a bare DATABASE_URL in the shell warns"
OUT="$(cd "$R" && DATABASE_URL=postgres://x "$DOC" 2>&1)"
grep -q 'DATABASE_URL is exported' <<<"$OUT" && ok "flagged" || bad "$OUT"

echo "doctor: in a worktree, a missing root .env is expected"
git -C "$R" worktree add -q "$R/.worktrees/w" -b w
touch "$R/.worktrees/w/hard"
RUN_DIR="$R/.worktrees/w" run
grep -q 'no root .env — correct in a worktree' <<<"$OUT" && ! grep -q '! .env missing' <<<"$OUT" && ok "noted, not warned" || bad "$OUT"

echo "doctor: NODE_AUTH_TOKEN is judged by a registry GET, not by its source"
cat >"$TMP/registry.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        auth = self.headers.get("Authorization")
        self.send_response(200 if auth == "Bearer tok_good" else 403 if auth else 401); self.end_headers()
srv = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$TMP/registry.py" "$TMP/port" & REG=$!
trap 'kill "$REG" 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PROBE_PORT="$(cat "$TMP/port")"
export DOCTOR_PACKAGES_PROBE_URL="http://127.0.0.1:$PROBE_PORT/pkg" NO_PROXY=127.0.0.1 no_proxy=127.0.0.1
echo '//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}' >"$R/.npmrc"
tokrun() { OUT="$(cd "$R" && NODE_AUTH_TOKEN="$1" "$DOC" 2>&1)"; }
tokrun tok_good
grep -q 'NODE_AUTH_TOKEN reads @garrettmakesitllc packages' <<<"$OUT" && ok "an accepted token passes" || bad "good: $OUT"
tokrun tok_bad_value
grep -q 'NODE_AUTH_TOKEN is rejected.*HTTP 403' <<<"$OUT" && ok "a rejected token warns with the status" || bad "bad: $OUT"
! grep -q 'tok_bad_value' <<<"$OUT" && ok "the token is never printed" || bad "token leaked: $OUT"
OUT="$(cd "$R" && env -u NODE_AUTH_TOKEN "$DOC" 2>&1)"
grep -q 'NODE_AUTH_TOKEN is unset' <<<"$OUT" && ok "an empty token warns" || bad "unset: $OUT"
OUT="$(cd "$R" && NODE_AUTH_TOKEN=tok_good DOCTOR_PACKAGES_PROBE_URL=http://127.0.0.1:1/x "$DOC" 2>&1)"
grep -q 'registry check was inconclusive' <<<"$OUT" && ok "an unreachable registry is inconclusive, not a rejection" || bad "unreachable: $OUT"

exit "$fail"
