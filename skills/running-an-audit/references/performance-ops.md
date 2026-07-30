# Performance & operability audit

These findings almost always arrive inside a multi-domain audit rather than standalone, and they are the ones most often filed and never actioned. File fewer, with numbers.

## Performance

Every finding carries a measurement and a target, or it is an opinion.

- **Full-table scans on hot paths** — leaderboards, counts, and aggregates computed per request. The gate is an index plus a query plan assertion, not a memo.
- **Unbounded queries** — any `findMany`/`select` with no limit on a path whose row count grows with usage.
- **Missing indexes on foreign keys** and on every column used in a filter or sort. Derive the list from the schema; don't eyeball it.
- **Per-request recomputation** that could be cached or memoized within the request (the auth-user lookup is the classic).
- **N+1 access patterns** across the ORM boundary.
- Bundle: entry chunk against the bundler's own warning threshold, code splitting, lazy loading below the fold, modern image formats with fallback.
- Targets worth stating: page load, Lighthouse desktop and mobile, bundle budget per entry. Enforce the bundle budget in CI — that one *can* be gated, so it must be.

## Operability

The recurring theme: the system fails silently in exactly the places nobody is watching.

- **Cron and background-job failures reach the error tracker.** A cron that throws into the void is the most common ops finding.
- **Multi-instance cron guard** — a scheduled job with no lock runs N times on N instances.
- **Request timeouts and connection-pool ceilings** set explicitly, not left to defaults that differ between local and production.
- **Uptime monitoring and post-deploy smoke checks** — and note that these are usually configured *outside* the repo, so check the dashboard or the ledger before filing (see the dedupe protocol in `SKILL.md`).
- Health endpoints split liveness from readiness; alerting has two independent sources. Detail in the **operating-production** skill.
- Log and signal sources documented well enough that triage doesn't start with "where would I look".

## Where the guards run

A distinct and worthwhile audit: for every check the repo owns, establish **where it runs** — local hook, PR gate, nightly, or nowhere — and whether it is a *required* check. The findings are always the same two shapes: a check that only runs locally so it never blocks anything, and a check that runs in CI but isn't required so a red run merges. Both are guards that exist and don't fire.
