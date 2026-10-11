---
description: Prisma migrations and backfills — timestamped, forward-only, pre-deploy-safe migrations; the backfill contract; applying DDL; client freshness
paths:
  - "**/*.prisma"
  - "**/prisma/migrations/**"
  - "**/prisma.config.ts"
  - "**/scripts/backfill/**"
---

# Prisma migrations & backfills

A repo's own invariants (which relations may cascade, which tables a seed owns, its catalog-drift scripts) live in that repo's `.claude/rules/`. This file is what holds in every Prisma repo.

## Authoring a migration

- **Schema changes go through timestamped migrations** — `prisma/migrations/<UTC timestamp>_<name>/migration.sql`. Never `prisma db push` against a shared database: it records no migration, the deployed schema drifts from the chain, and the next `migrate deploy` dies on objects that already exist. `db-push-guard.sh` blocks it against anything non-local.
- **Prisma applies directories in lexicographic order**, not authoring order. A new directory sorts after every existing one (`ls prisma/migrations | sort | tail -1`), on a non-round timestamp (`20260710163722`, not `20260710160000` — concurrent agents all reach for the round hour), in UTC, and no further ahead than that forces. A future-dated one merges unopposed and then blocks every migration authored before its nominal time. `migration-guard.sh` enforces this at write time; CI re-checks it against the PR's base, because a branch in review can be overtaken. A flagged directory is **renamed** to a later timestamp, not rebased — free until applied somewhere.
- **An applied migration is checksum-locked.** Every database that ran it records a sha256 of its bytes in `_prisma_migrations`; an edit (a comment included) puts every ledger out of step, which `migrate deploy` never notices and any ledger comparison or replay reports forever. Write a new migration forward. The one exception is a migration that **failed**: fix the file, `prisma migrate resolve --rolled-back <name>`, deploy again. `--applied` is the wrong half of that pair — it marks the migration done while its DDL never ran, turning a P3009 into a runtime P2022.
- **Forward-fix only** — Prisma has no down-migrations. Snapshot the database before a destructive one.
- Run `npx prisma generate` after any schema edit and after merging a schema change. A stale client produces type and lint errors that read as code bugs; `prisma-client-freshness.sh` reports one at session start.

## Migrations run pre-deploy, against the OLD server

The platform applies migrations before the new container is healthy, and the previous one keeps serving until it is. So a migration must never write data the currently deployed client cannot read:

- **Expand, then contract.** DDL in the migration — additive, nullable, metadata-only. The data change in a backfill run after the new code is live. Dropping the old column is a later migration, a deploy later. Making a column nullable and NULLing rows in one migration makes every bare `findMany` on the table throw `Field X is required to return data, got null` for the length of the deploy.
- **No `UPDATE`/`DELETE`/`TRUNCATE` in a migration**, and no `INSERT` except into a table the same migration creates or an idempotent `ON CONFLICT` catalog seed.
- **Every multi-statement migration opens `BEGIN;` and closes `COMMIT;`.** Prisma `migrate deploy` sends a migration one statement at a time, each its own autocommitting query. With no transaction of the file's own, a failure at statement N leaves statements 1..N-1 committed while `_prisma_migrations.applied_steps_count` reads 0. The wrapper makes the file atomic. Its cost: Prisma's write of `logs` lands inside the aborted block and fails (25P02), so the ledger's `logs` is NULL and Prisma prints `current transaction is aborted`; the real error is only in the Postgres log. A pre-deploy that auto-resolves a failed migration `--rolled-back` keys on the file being wrapped, never on `applied_steps_count` or the SQLSTATE.
- **A statement that takes a heavy lock is preceded by `SET LOCAL lock_timeout = '5s';` inside that `BEGIN; … COMMIT;` wrapper.** `ALTER TABLE`, `DROP` and a plain `CREATE INDEX` need `ACCESS EXCLUSIVE`; a *pending* request for it blocks every new lock on the table, so the reads the old server is still serving queue behind it and the table is down until the migration gets its lock. Bounded, the migration fails, the platform keeps the previous deployment, and the site stays up. Outside the wrapper `SET LOCAL` is a no-op (Postgres warns 25P01) and bounds nothing. A session-level `SET lock_timeout = '5s';` (no `LOCAL`) does bound every later statement on the connection.
- **`CREATE INDEX CONCURRENTLY` is the only statement in its migration**, unwrapped and with no `lock_timeout` prefix — every other migration is wrapped in `BEGIN; … COMMIT;`, and a concurrent build cannot run inside that wrapper. A failed one leaves an INVALID index under its name, so `migrate resolve --rolled-back` then `deploy` dies on `42P07 already exists`: `DROP INDEX CONCURRENTLY "<name>"` first.
- **`ADD COLUMN ... NOT NULL` on an existing table carries a `DEFAULT`** (or is `GENERATED`). The migration runs before the new code, against every row the table holds; without one it fails mid-deploy on a non-empty table. Add the column nullable, backfill, and set `NOT NULL` a deploy later.
- **No `ALTER COLUMN ... SET NOT NULL` on an existing table.** It scans the whole table under `ACCESS EXCLUSIVE`. Add `CHECK (col IS NOT NULL) NOT VALID`, `VALIDATE CONSTRAINT` in a later migration, then `SET NOT NULL` (Postgres 12+ skips the scan).
- **An enum value added by `ALTER TYPE ... ADD VALUE` is not used in the same migration** — Postgres refuses it inside the adding transaction. Use it in the next migration.
- `hooks/migration-guard.sh` refuses a new `migration.sql` that breaks any rule above; it agrees with CI's `check-migration-locks` run with `require-begin: 'true'` (off by default there, so a repo with bare `SET LOCAL` history can adopt it after wrapping), whose opt-in `strict-constraints` (`ADD CONSTRAINT ... CHECK | FOREIGN KEY` without `NOT VALID`) the hook does not apply, because Prisma generates that plain foreign key. A table the same migration creates is exempt, unless a foreign key reaches an existing one. Run `bin/migration-lock-check.py --require-begin --since <timestamp> prisma/migrations/*/migration.sql` to check a repo's history from a cutoff.
- **`ADD COLUMN … NOT NULL` needs a `DEFAULT`**, or it fails against the existing rows.
- **A new relation gets an index leading with its referencing column.** Postgres indexes the referenced side of a foreign key, never the referencing one, so an uncovered column is walked by every cascade and join through it.
- **State `onDelete` on every optional relation to a core model.** Required relations default to `Restrict`; optional ones default to `SetNull`, which orphans the child instead of blocking the delete. `Cascade` from a core entity (a user, a tenant, an event) destroys history silently — choose it deliberately, never by default.
- A partial index, an expression index or a `CHECK` constraint is invisible to `prisma migrate diff` (the datamodel cannot represent it), so schema-drift comparisons never see it. A repo that relies on one checks the catalog itself.

## Applying DDL by hand

- `prisma migrate deploy` over the **session** pooler (port 5432) or a direct connection; the Supabase transaction pooler (6543) hangs `migrate`. Retry on P1001.
- **Close drift through the ledger, never around it.** DDL applied outside `migrate deploy` (a `migrate diff` piped to `db execute`) creates objects the ledger does not record, and the next deploy re-runs the owning migration, dies on `already exists`, and leaves a failed row that blocks every later migration (P3009). Where objects already exist unrecorded, `prisma migrate resolve --applied <name>` adopts them.
- A `rolled_back_at` row next to a successful re-apply of the same migration is history Prisma keeps by design, not a fault to repair.
- Opt into a database per command — `DATABASE_URL="$<PREFIX>_PROD_DATABASE_URL" npx prisma migrate status` — never by exporting a bare `DATABASE_URL` (`agent-credentials`).

## Backfills

Every `scripts/backfill/*` and maintenance job follows one contract, and each script's header is its documentation — read it before running one:

- **Dry-run by default, `--apply` to write**; idempotent and re-runnable; per-row failures isolated; bulk work chunked.
- **A fix to a data invariant or lifecycle cascade ships a backfill for the rows already violating it**, in the same PR. Fixing the code only stops new violations.
- **Dry-run against production too**, not just staging — seeded rows prove nothing about real data, and a dry run is read-only. Then `--apply`, verify, and re-run to confirm idempotency.
- Run a backfill **after** the new code is healthy, never in the pre-deploy step.
- **The tracking issue stays open until the backfill has been applied**, not when the code merges. A bare dry run exits non-zero while any row still violates the invariant, so the command that reports the pending count is also the check that it is still pending.
- **A one-shot backfill is deleted once spent, and only against a query**: a production query returning zero rows in the state it targets, quoted in the PR. "Looks old" is not evidence, and re-running a spent one that writes without `--apply` is a live corruption path.
