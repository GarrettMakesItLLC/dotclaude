#!/usr/bin/env bash
# Self-test for staging-db-url.sh against a local stub of the Supabase
# Management API: project and branch come from the manifest, env overrides win,
# the URL uses the session pooler on 5432 with an escaped password, a real
# User-Agent is sent, and a missing token/project/branch fails by name.
#   bash bin/staging-db-url.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDU="$HERE/staging-db-url.sh"
TMP="$(mktemp -d)"
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

unset BASH_ENV
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset REPO_MANIFEST STAGING_SUPABASE_PROJECT_NAME STAGING_BRANCH_NAME

cat >"$TMP/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ROUTES = {
    "/v1/projects": [{"id": "prodref", "name": "Demo"}, {"id": "other", "name": "Other"}],
    "/v1/projects/prodref/branches": [{"id": "b1", "name": "staging", "project_ref": "stgref"},
                                      {"id": "b2", "name": "qa", "project_ref": "qaref"}],
    "/v1/branches/b1": {"db_pass": "p@ss/w:rd"},
    "/v1/branches/b2": {"db_pass": "qa"},
    "/v1/projects/stgref/config/database/pooler": [{"database_type": "PRIMARY", "db_host": "aws-0.pooler.supabase.com", "db_port": 6543}],
    "/v1/projects/qaref/config/database/pooler": {"database_type": "PRIMARY", "db_host": "qa.pooler", "db_port": 6543},
}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        ua = self.headers.get("User-Agent", "")
        if ua.startswith("Python-urllib") or self.headers.get("Authorization") != "Bearer pat":
            self.send_response(403); self.end_headers(); return
        body = ROUTES.get(self.path)
        if body is None:
            self.send_response(404); self.end_headers(); return
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(data)

srv = HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$TMP/stub.py" "$TMP/port" & STUB=$!
trap 'kill "$STUB" 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
SUPABASE_API_URL="http://127.0.0.1:$(cat "$TMP/port")"
export SUPABASE_API_URL NO_PROXY=127.0.0.1 no_proxy=127.0.0.1

REPO="$TMP/repo"
git init -q "$REPO"
mkdir -p "$REPO/.claude"
echo '{ "supabase": { "projectName": "Demo" } }' >"$REPO/.claude/repo.json"
run() { OUT="$(cd "$REPO" && env "$@" "$SDU" 2>&1)"; RC=$?; }

echo "staging-db-url: mints the session-pooler URL for the manifest's project"
run SUPABASE_ACCESS_TOKEN=pat
[ "$RC" = 0 ] && ok "exits 0" || bad "rc=$RC $OUT"
[ "$OUT" = "postgresql://postgres.stgref:p%40ss%2Fw%3Ard@aws-0.pooler.supabase.com:5432/postgres" ] && ok "5432, branch ref user, escaped password" || bad "url: $OUT"

echo "staging-db-url: env overrides the branch; a single-object pooler config works"
run SUPABASE_ACCESS_TOKEN=pat STAGING_BRANCH_NAME=qa
[ "$RC" = 0 ] && grep -q '@qa.pooler:5432/' <<<"$OUT" && ok "branch override" || bad "rc=$RC $OUT"

echo "staging-db-url: failures are named"
run SUPABASE_ACCESS_TOKEN=
[ "$RC" != 0 ] && grep -q 'SUPABASE_ACCESS_TOKEN is not set' <<<"$OUT" && ok "no token" || bad "rc=$RC $OUT"
run SUPABASE_ACCESS_TOKEN=pat STAGING_SUPABASE_PROJECT_NAME=Nope
[ "$RC" != 0 ] && grep -q "no Supabase project named 'Nope'" <<<"$OUT" && ok "unknown project" || bad "rc=$RC $OUT"
run SUPABASE_ACCESS_TOKEN=pat STAGING_BRANCH_NAME=gone
[ "$RC" != 0 ] && grep -q "no branch named 'gone'" <<<"$OUT" && ok "unknown branch" || bad "rc=$RC $OUT"
run SUPABASE_ACCESS_TOKEN=wrong
[ "$RC" != 0 ] && grep -q 'GET /v1/projects failed' <<<"$OUT" && ok "a rejected token names the call" || bad "rc=$RC $OUT"
rm "$REPO/.claude/repo.json"
run SUPABASE_ACCESS_TOKEN=pat
[ "$RC" != 0 ] && grep -q 'no Supabase project name' <<<"$OUT" && ok "no manifest and no override" || bad "rc=$RC $OUT"

exit "$fail"
