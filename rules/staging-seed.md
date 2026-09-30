---
description: Staging seeds — a minted (never pasted) staging URL, slice-per-file breadth, dates relative to the run, deletes that converge from any prior state
paths:
  - "**/staging-seed/**"
  - "**/seed-staging*"
  - "**/scripts/seed*/**"
---

# Staging seeds

What a repo's seed covers, its personas and the tables it owns live in that repo's `.claude/rules/`. This file is what holds for every staging seed.

- **`STAGING_DATABASE_URL` is minted, never pasted or synced**: `export STAGING_DATABASE_URL="$(~/.claude/bin/staging-db-url.sh)"`. It derives a fresh URL from the Supabase Management PAT, so it survives a branch password reset and needs no per-machine registration. It is the **session pooler on 5432**: the branch's direct host is IPv6-only (unreachable from IPv4 agent boxes) and the 6543 transaction pooler breaks prepared statements.
- **The seed refuses to run when a differing `DATABASE_URL` is also set**, and validates its target before the first write, so a wrong value aborts with the database untouched.
- **A fresh staging branch gets its schema the way production does**: `DATABASE_URL="$STAGING_DATABASE_URL" npx prisma migrate deploy`, then the seed.
- **Add breadth as a new slice file** (`slices/<nn>-<name>.slice.ts`, auto-discovered, ordered by prefix). Never edit the shared spine every slice builds on: it is a merge-conflict point for every parallel agent.
- **Every seeded date is relative to the run** (`daysFromNow`, `isoDate`). A hard-coded date goes stale and renders as the past. A seed that dates things relative to the run also has to be re-run on a schedule, or "this week" drifts.
- **A delete-then-insert clears by the table's unique constraint, not by the ids the slice minted.** An id-scoped delete converges only from states this exact code produced; a row left by an older version of the slice, or by the app on staging, collides on insert forever and aborts a serial seed half-way. Where a live process can also write the row, **upsert on the unique column** instead — a delete leaves a gap in time a live writer can fill. Delete-then-insert only where the seed is provably the sole writer.
- **Seeded rows leave the state the app's own write path would**: the side rows, ledgers and derived values that path writes. A seed that skips them fails every invariant check that runs against a staging snapshot.
- **The seed is single-flight** — take a database advisory lock before the first write (released when the connection closes, however the process exits) so two runs cannot interleave their deletes and inserts.
- **A seed reporting success is not staging exercising the product.** A coverage check that walks the schema's models and signs in as each persona to read real routes catches the "rows present, screen empty" gap the seed cannot see in itself. Missing probe credentials fail that check rather than skipping it silently.
