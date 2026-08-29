---
description: Data & API-boundary conventions — Prisma, Zod, Supabase auth clients, migrations, feature flags
paths:
  - "**/*.prisma"
  - "**/api/**"
  - "**/route.ts"
  - "**/route.tsx"
  - "**/actions/**"
  - "**/server/**"
  - "**/*.test.ts"
  - "**/*.spec.ts"
  - "**/tests/**"
  - "**/e2e/**"
---

# Data & API-boundary conventions

- **Prisma** for all database access — no raw SQL.
- **Zod at every API boundary.** Never trust raw `req.body` or untyped query params.
- **Supabase Auth**: two clients, never crossed — `supabaseServer()` (RSC / actions / handlers) vs `supabaseBrowser()` (`'use client'` only). Service-role key is server-only.
- **Integration tests hit a real database** — never mock Prisma.
- **JSON responses are compressed.** Verify `content-encoding` on the deployed endpoint; a platform that compresses static assets automatically often does not compress an API route's response, and a separately-hosted backend never does by default.
- **Select the fields the surface uses**, not the whole row so the client can pick three.

## Write paths

- **A multi-step write is one transaction.** Three sequential `await`s that must all succeed, with no transaction around them, is a bug waiting on the day one of them throws.
- **Every externally-triggered write is idempotent, keyed**, with a uniqueness constraint behind the key. Webhooks retry, jobs re-run, users double-click, and a client timeout is indistinguishable from a failure.
- **Read-modify-write happens in the database** — atomic increment or an optimistic-concurrency version column. `SELECT`, add one in JS, `UPDATE` loses writes under any real concurrency; check every counter, balance, quota and streak.
- **No per-keystroke writes.** Debounce, batch, or save on blur/submit.
- **Derived values are computed, not stored** — unless stored deliberately, with a recompute path, a backfill, and a reconciliation job that reports drift rather than silently correcting it.
- **Soft vs. hard delete is decided once per model** and every query path filters accordingly. Cascade behavior is declared in the schema, not implied by delete order in application code.
- **Bulk operations are chunked and bounded**, with a stated partial-failure outcome.
- **Every outbound call has an explicit timeout**; retries are bounded, backed off, jittered, and only on idempotent operations. The client default is usually "forever," and a hung upstream becomes an exhausted connection pool and a total outage.

## Migrations & data operations

- **Expand-then-contract.** Migrations run pre-deploy against the *old* server, so a migration must never write data the currently-deployed client can't read. DDL in the migration (additive / nullable / metadata-only); the data change in a backfill run after the new code is live; the contracting migration (drop the old column) a deploy later.
- **Forward-fix only** — Prisma has no down-migrations. Snapshot the DB before any destructive migration.
- **A fix to a data invariant ships a backfill for the rows already violating it.** A schema/logic fix that strands bad rows is a half-fix.
- **Backfills / one-off scripts:** dry-run by default, `--apply` to write; idempotent and re-runnable; kept in `scripts/backfill/`.
- **Guard scripts that can reach prod.** A local reset/seed/backfill gets a `guard-not-production` check that refuses a production `DATABASE_URL`; export prod DB URLs **namespaced** (e.g. `PROD_DATABASE_URL`) so a bare `DATABASE_URL` never silently pins a script to prod.

## Feature flags & kill switches

Three distinct kinds — keep them distinct:

- **Unreleased-feature gates** — the exception, not the habit. A finished feature ships on; add a gate only when release genuinely has to be decoupled from merge (a coordinated launch, money movement, a migration that lands first). Every gate is something to remember to flip and then delete, and gating by default is what lets half-built work merge and sit.
- **Ops kill switches** — default *on*; flip to disable a subsystem (e.g. return 503) without a redeploy. The kill-switch read must not itself depend on the thing it guards.
- **Capability gates** — a feature self-appears once all its required env is present.

Validate flags at boot: a set-but-invalid value refuses to start (fail closed) rather than silently misbehaving.
