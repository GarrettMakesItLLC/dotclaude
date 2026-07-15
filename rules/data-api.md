---
description: Data & API-boundary conventions — Prisma, Zod, Supabase auth clients, secrets
paths:
  - "**/*.prisma"
  - "**/api/**"
  - "**/route.ts"
  - "**/route.tsx"
  - "**/actions/**"
  - "**/server/**"
---

# Data & API-boundary conventions

- **Prisma** for all database access — no raw SQL.
- **Run `prisma generate`** after `npm ci` / `pnpm install` and after any schema change.
- **Zod at every API boundary.** Never trust raw `req.body` or untyped query params.
- **Supabase Auth** where present. Two clients, never crossed: `supabaseServer()` (RSC / actions / handlers) vs `supabaseBrowser()` (`'use client'` only). Service-role key is server-only.
- Integration tests hit a **real database** — never mock Prisma.
- Never expose Supabase service-role keys, Stripe secret keys, or Vercel tokens in client-bundled code.

## Migrations & data operations

- **Expand-then-contract.** Migrations run against the *old* server (typically a pre-deploy step), so a migration must never write data the currently-deployed client can't read. Split every change: **DDL in the migration** (additive / nullable / metadata-only) + the **data change in a backfill run after the new code is live**. The contracting migration (drop the old column) comes a deploy later.
- **Forward-fix only.** Prisma has no down-migrations — prefer expand-then-contract so a code rollback never hits a missing column, and snapshot the DB before any destructive migration.
- **A fix to a data invariant ships a backfill for the rows already violating it.** A schema/logic fix that strands bad rows is a half-fix.
- **Backfills / one-off scripts:** dry-run by default, `--apply` to write; idempotent and re-runnable; kept in `scripts/backfill/`.
- **Guard scripts that can reach prod.** A local reset/seed/backfill gets a `guard-not-production` check that refuses a production `DATABASE_URL`; export prod DB URLs **namespaced** (e.g. `PROD_DATABASE_URL`) so a bare `DATABASE_URL` never silently pins a script to prod.

## Feature flags & kill switches

Three distinct kinds — keep them distinct:

- **Unreleased-feature gates** — default *off*; merge dark, flip on when ready. Money-moving features stay off by default.
- **Ops kill switches** — default *on*; flip to disable a subsystem (e.g. return 503) without a redeploy. The kill-switch read must not itself depend on the thing it guards.
- **Capability gates** — a feature self-appears once all its required env is present.

Validate flags at boot: a set-but-invalid value should refuse to start (fail closed) rather than silently misbehave.
