# Database & migrations

The question: **can every migration in the chain run against production without loss, and does production's catalog still match what the schema and the docs say?** Domain invariants (a counter that drifts, a formula that lies) belong to `data-integrity-safety`; this realm is the storage layer itself.

Shares surfaces with `security-access-control` (RLS and grants — file there if the consequence is data exposure, here if it is drift), `performance-ops` (a missing index whose consequence is a slow endpoint belongs there; a missing index that the schema claims to have belongs here), and `privacy-data-processing` (retention crons).

## Checklist

- **Migration safety against the running server.** Read every migration since the last promoted release (`git log main..dev -- prisma/migrations`). Flag: a column dropped or renamed while the old client still reads it; a `NOT NULL` added without a default on a populated table; an enum value used in the same transaction it was added; a data write inside a migration (should be a backfill); a long-running lock (`ALTER TABLE ... TYPE`, index build without `CONCURRENTLY` on a big table).
- **Drift between schema and catalog.** With read access: `prisma migrate diff --from-url --to-schema-datamodel` or a manual comparison of `information_schema.columns` vs `schema.prisma`; `_prisma_migrations` rows vs the migration directory (applied-but-missing, missing-but-applied, failed rows, rolled-back rows).
- **Indexes.** Every `@relation` foreign key column without an index; every `WHERE`/`ORDER BY` column on a hot route without one (`pg_stat_user_tables.seq_scan` vs `idx_scan` on tables over ~100k rows); duplicate or redundant indexes (`pg_indexes` where one is a prefix of another); unused indexes (`pg_stat_user_indexes.idx_scan = 0` older than a month).
- **Constraints the code assumes.** Uniqueness the code relies on via `findFirst` where the schema has no `@unique`; `onDelete` behavior (`Cascade` vs `Restrict` vs `SetNull`) vs what the deletion code expects; check constraints for enums stored as strings.
- **Backfills.** Every `scripts/backfill/*`: is it idempotent, does it dry-run by default, is it row-bounded, and has it been run (a backfill that fixes an invariant should leave zero violating rows — count them live).
- **Bloat and vacuum.** `pg_stat_user_tables.n_dead_tup` vs `n_live_tup`; last autovacuum on the largest tables; tables that have never been analyzed.
- **Sizes and growth.** Top 15 tables by `pg_total_relation_size`; any table growing unboundedly with no retention cron (join with the retention register in `docs/compliance/`).
- **Connection posture.** Pooler vs direct URL usage per process; `max_connections` vs the sum of every pool size across Railway replicas + crons + Vercel functions.
- **Backups and PITR.** What the provider dashboard says (owner action if unreadable); whether the documented RTO has been exercised (ledger check first).
- **RLS and grants.** Every table: `relrowsecurity`, and the grants on `anon` / `authenticated`. A previous audit may have verified this — re-verify against the live catalog since new tables landed.
- **Storage buckets.** Each bucket's public flag, MIME allow-list, size cap, and the RLS policy on `storage.objects`, vs. what the `docs/security/*.sql` files claim.

## Gates that fit this realm

A CI job running `prisma migrate diff` against a fresh shadow DB and against the sandbox; a test that every FK column has an index; a `scripts/migrations/*` guard for unsafe DDL patterns (already partly present as the timestamp guard — check what it covers); a nightly drift check between the live catalog and `schema.prisma`; each `docs/security/*.sql` paired with a posture workflow that reads the bucket back.
