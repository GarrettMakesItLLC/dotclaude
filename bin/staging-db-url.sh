#!/usr/bin/env bash
# Mint a product repo's staging Postgres URL on demand, on any machine.
#
#   export STAGING_DATABASE_URL="$(~/.claude/bin/staging-db-url.sh)"
#
# Staging is a Supabase BRANCH of the repo's project. Storing its URL means a
# paste synced to every box that rots whenever the branch password is reset;
# deriving it from the Supabase Management PAT (SUPABASE_ACCESS_TOKEN, already
# in every agent shell) means nothing to register per machine and a URL that is
# always current.
#
# The project and branch come from the repo's `.claude/repo.json`
# (`supabase.projectName`, `supabase.stagingBranch`, default "staging"); the
# environment variables STAGING_SUPABASE_PROJECT_NAME / STAGING_BRANCH_NAME
# override them. The project is resolved by NAME so a re-created project needs
# no edit here.
#
# The SESSION pooler on :5432, never the direct host or :6543. The branch's
# direct host (db.<ref>.supabase.co) resolves IPv6-only and agent boxes are
# IPv4-only, so a direct URL fails "Network is unreachable" before auth. The
# pooler host is IPv4-reachable; session mode (5432) is what Prisma and a seed's
# prepared statements need, while the 6543 transaction pooler breaks them. The
# API reports 6543; this keeps the host and forces 5432.
#
# The request sends a real User-Agent: api.supabase.com 403s the default
# `Python-urllib/x` agent before it looks at the token, which is indistinguishable
# from a revoked PAT.
#
# SUPABASE_API_URL overrides the API base (the self-test points it at a stub).
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=bin/lib/repo-manifest.sh
. "$HERE/lib/repo-manifest.sh"

if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  echo "staging-db-url: SUPABASE_ACCESS_TOKEN is not set (the Supabase Management PAT, from ~/.config/secrets/)." >&2
  exit 1
fi

project_name="${STAGING_SUPABASE_PROJECT_NAME:-}"
branch_name="${STAGING_BRANCH_NAME:-}"
if manifest_find >/dev/null 2>&1; then
  [ -n "$project_name" ] || project_name="$(manifest_get supabase.projectName || true)"
  [ -n "$branch_name" ] || branch_name="$(manifest_get supabase.stagingBranch || true)"
fi
branch_name="${branch_name:-staging}"
if [ -z "$project_name" ]; then
  echo "staging-db-url: no Supabase project name — set supabase.projectName in .claude/repo.json or STAGING_SUPABASE_PROJECT_NAME." >&2
  exit 1
fi

PROJECT_NAME="$project_name" BRANCH_NAME="$branch_name" python3 - <<'PY'
import json, os, sys, urllib.parse, urllib.request

API = os.environ.get("SUPABASE_API_URL", "https://api.supabase.com").rstrip("/")
TOKEN = os.environ["SUPABASE_ACCESS_TOKEN"]
PROJECT_NAME = os.environ["PROJECT_NAME"]
BRANCH_NAME = os.environ["BRANCH_NAME"]


def get(path):
    req = urllib.request.Request(
        API + path,
        headers={"Authorization": f"Bearer {TOKEN}", "User-Agent": "dotclaude-staging-db-url/1"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except Exception as e:  # noqa: BLE001 - surface any API/network failure by path
        sys.exit(f"staging-db-url: GET {path} failed: {e}")


project = next((p for p in get("/v1/projects") if p.get("name") == PROJECT_NAME), None)
if project is None:
    sys.exit(f"staging-db-url: no Supabase project named {PROJECT_NAME!r}")

branch = next((b for b in get(f"/v1/projects/{project['id']}/branches") if b.get("name") == BRANCH_NAME), None)
if branch is None:
    sys.exit(f"staging-db-url: no branch named {BRANCH_NAME!r} on project {PROJECT_NAME!r}")
branch_ref = branch["project_ref"]

password = get(f"/v1/branches/{branch['id']}").get("db_pass")
if not password:
    sys.exit("staging-db-url: the branch detail carried no db_pass")

pooler = get(f"/v1/projects/{branch_ref}/config/database/pooler")
entries = pooler if isinstance(pooler, list) else [pooler]
primary = next((e for e in entries if e.get("database_type") == "PRIMARY"), entries[0] if entries else {})
host = primary.get("db_host")
if not host:
    sys.exit("staging-db-url: the pooler config carried no db_host")

print(f"postgresql://postgres.{branch_ref}:{urllib.parse.quote(password, safe='')}@{host}:5432/postgres")
PY
