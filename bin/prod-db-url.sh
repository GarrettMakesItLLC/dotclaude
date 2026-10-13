#!/usr/bin/env bash
# Fetch a product repo's production WRITER database URL, on demand.
#
#   DATABASE_URL="$(~/.claude/bin/prod-db-url.sh --writer)" npm run backfill:x -- --apply
#
# Agents read production through the read-only role (`MB_PROD_READONLY_URL`-style
# variables in the agent bundle). The writer URL — the owner role that migrations
# and backfills need — is never exported into a shell: it is fetched for one
# command, so a stray `psql "$URL"` or a prompt-injected script cannot reach for
# it. The value comes from the repo's Railway service (`credentials.railway` in
# `.claude/repo.json`), the same place the server reads it, with the pgbouncer
# query stripped so psql and Prisma accept it.
#
# `--writer` is required, so the call site says what it is asking for. The key
# defaults to DIRECT_URL (the :5432 owner connection); the manifest's
# `credentials.writerKey` overrides it. The URL prints on stdout only; capture it
# with `$(…)` (secret-read-guard.sh refuses the bare form).
#
# RAILWAY_API_URL overrides the endpoint (the self-test points it at a stub).
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=bin/lib/repo-manifest.sh
. "$HERE/lib/repo-manifest.sh"
# shellcheck source=bin/lib/railway.sh
. "$HERE/lib/railway.sh"

die() { echo "prod-db-url: $*" >&2; exit 1; }

[ "${1:-}" = "--writer" ] || die "usage: prod-db-url.sh --writer   (the owner URL for a migration or backfill; reads use the read-only variable in the agent bundle)"

manifest_find >/dev/null || die "no .claude/repo.json governs $PWD — this repo has not opted in (docs/repo-manifest.md)."
service="$(manifest_get credentials.railway.service || true)"
[ -n "$service" ] || die "the manifest has no credentials.railway.service to read the writer URL from."
environment="$(manifest_get credentials.railway.environment || echo production)"
project_id="$(manifest_get credentials.railway.projectId || true)"
key="$(manifest_get credentials.writerKey || echo DIRECT_URL)"

kv="$(railway_kv "$service" "$environment" "$project_id" || true)"
url="$(railway_value "$key" "$kv" || true)"
[ -n "$url" ] || die "Railway returned no $key for $service/$environment (no project token and no interactive 'railway login'?)."

printf '%s\n' "${url%%\?pgbouncer*}"
