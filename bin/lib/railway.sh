# shellcheck shell=bash
# Read a Railway service's variables as KEY=value lines. Sourced, never run.
#
#   railway_kv <service> <environment> [<project-id>]
#
# Two routes, tried in order, because each works where the other does not:
#
#   1. Railway's GraphQL API with $RAILWAY_TOKEN, when a project id is given. A
#      PROJECT token is valid for project-scoped queries but the CLI rejects it,
#      because the CLI insists on a user-scoped `me` query first. The Railway MCP
#      is no substitute: connected as an OAuth app it redacts every value.
#   2. The `railway` CLI on its interactive login, with every token variable
#      stripped. A bare RAILWAY_TOKEN in the environment overrides the login, and
#      a stale one denies every call while blaming permissions. `sh -c`, never
#      `bash -c`: BASH_ENV=~/.bashrc would make a bash child re-source the
#      profile and put the token straight back.
#
# Prints nothing and returns 1 when neither answers. Never prints a value to
# stderr. Bounded by RAILWAY_TIMEOUT (default 25s) per route, since callers run
# at session start.
#
# RAILWAY_API_URL overrides the endpoint (the self-test points it at a stub).

railway_kv() {
  local service="$1" environment="$2" project_id="${3:-}" out=""
  local timeout_s="${RAILWAY_TIMEOUT:-25}"

  if [ -n "$project_id" ] && [ -n "${RAILWAY_TOKEN:-}" ] && command -v python3 >/dev/null 2>&1; then
    out="$(RW_PROJECT="$project_id" RW_SERVICE="$service" RW_ENV="$environment" \
      RW_TIMEOUT="$timeout_s" timeout "$((timeout_s + 5))" python3 - <<'PY' 2>/dev/null || true
import json, os, sys, urllib.request

api = os.environ.get("RAILWAY_API_URL", "https://backboard.railway.com/graphql/v2")
token = os.environ["RAILWAY_TOKEN"]
t = float(os.environ.get("RW_TIMEOUT", "25"))

def gql(query, variables):
    req = urllib.request.Request(
        api,
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "dotclaude-railway-kv/1",
        },
    )
    with urllib.request.urlopen(req, timeout=t) as r:
        return json.load(r)

try:
    proj = gql(
        "query($id: String!) { project(id: $id) { environments { edges { node { id name } } } services { edges { node { id name } } } } }",
        {"id": os.environ["RW_PROJECT"]},
    )["data"]["project"]
    env = next(e["node"]["id"] for e in proj["environments"]["edges"] if e["node"]["name"] == os.environ["RW_ENV"])
    svc = next(s["node"]["id"] for s in proj["services"]["edges"] if s["node"]["name"] == os.environ["RW_SERVICE"])
    variables = gql(
        "query($p: String!, $e: String!, $s: String) { variables(projectId: $p, environmentId: $e, serviceId: $s) }",
        {"p": os.environ["RW_PROJECT"], "e": env, "s": svc},
    )["data"]["variables"]
except Exception:
    sys.exit(1)
for k, v in (variables or {}).items():
    if v is None or "\n" in str(v):
        continue
    print(f"{k}={v}")
PY
)"
  fi

  if [ -z "$out" ] && command -v railway >/dev/null 2>&1; then
    out="$(timeout "$timeout_s" env -u RAILWAY_TOKEN -u RAILWAY_API_TOKEN -u BASH_ENV \
      RW_SERVICE="$service" RW_ENV="$environment" \
      sh -c 'railway variables --service "$RW_SERVICE" --environment "$RW_ENV" --kv' 2>/dev/null || true)"
  fi

  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# KEY's value out of railway_kv output held in "$2". Quotes stripped; rc 1 when
# absent or empty.
railway_value() {
  local key="$1" kv="$2" line val
  [ -n "$kv" ] || return 1
  line="$(printf '%s\n' "$kv" | grep -E "^${key}=" | tail -1 || true)"
  [ -n "$line" ] || return 1
  val="${line#*=}"
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  [ -n "$val" ] || return 1
  printf '%s' "$val"
}
