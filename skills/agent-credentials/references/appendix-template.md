# Credentials appendix template

A product repo's `.claude/credentials.md` carries only what is true of that repo. The mechanics — how `agent.env`, `ops.env` and `cloud.env` are built, Railway and Vercel access, the OPS channel, GitHub Packages, missing CLIs — are the shared `agent-credentials` skill's, and are not restated here. Every claim is verified against the repo's `.claude/repo.json` and the builder's own output, not copied from another repo.

```markdown
# <Repo> credentials

Prefix `<PREFIX>_`, state dir `~/.<name>/` (see `.claude/repo.json`).

## In the shell

| Name | Source | Points at |
|---|---|---|
| `<PREFIX>_SUPABASE_URL` / `_ANON_KEY` / `_SERVICE_KEY` | local `.env`, else Railway `<service>` | the `<project>` Supabase project |
| `<PREFIX>_PROD_DATABASE_URL` | local `.env`, else Railway | production Postgres — there is no local database |
| `<KEY>` (OPS channel) | Vercel `OPS_<KEY>` | what it unlocks |

## Fetched on demand, never on disk

- `<KEY>`, `<KEY>` — Railway service `<service>`, environment `production`.
- `<KEY>` — Vercel project `<project>` (`npx vercel env pull --environment=<env>`).

## Traps specific to this repo

- <one line each: the fact, and what it breaks>
```
