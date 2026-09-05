# Performance & operability audit

These findings almost always arrive inside a multi-domain audit rather than standalone, and they are the ones most often filed and never actioned. File fewer, with numbers.

**This file is the server side** — queries, indexes, jobs, capacity, the things a load test finds. Everything between the origin and the user's eye (rendering strategy, compression, image delivery, caching layers, bundle, perceived performance) is `web-delivery-performance.md`; single points of failure, timeouts, fallbacks, and spend concentration are `resilience-dependencies.md`. A product can pass this file completely and still feel slow, which is why the split exists.

## Performance

Every finding carries a measurement and a target, or it is an opinion.

- **Full-table scans on hot paths** — leaderboards, counts, and aggregates computed per request. The gate is an index plus a query plan assertion, not a memo.
- **Unbounded queries** — any `findMany`/`select` with no limit on a path whose row count grows with usage.
- **Missing indexes on foreign keys** and on every column used in a filter or sort. Derive the list from the schema; don't eyeball it.
- **Per-request recomputation** that could be cached or memoized within the request (the auth-user lookup is the classic).
- **N+1 access patterns** across the ORM boundary.
- **Write amplification** — a mutation that triggers a fan-out of recomputation, a write per keystroke with no debounce, or a read-back after every write. See `data-integrity-safety.md`'s write-paths section: the correctness half is filed there, the cost half here.
- **Unbounded response payloads** — a list endpoint selecting every column so the client can use three. The wire side of this (compression, shape) is `web-delivery-performance.md`; the query side is here.
- Bundle, image delivery, and caching layers: `web-delivery-performance.md`.
- Targets worth stating: API p95 per hot endpoint, query-plan assertions on the aggregates, and a ceiling on job-queue depth. Client-side targets (Core Web Vitals, Lighthouse, bundle budget) live with the delivery audit.

## Cost per request

The capacity question stated in money, and the one nobody asks until the invoice.

- **A per-request cost estimate for the three most expensive endpoints.** Without that number capacity isn't being decided, it's being discovered.
- Metered third-party calls (LLM inference, geocoding, SMS, email) on any path a user can trigger, each with a budget alert on the provider side. Concentration and guardrails are `resilience-dependencies.md`'s, rate limiting is `security-access-control.md`'s; what belongs here is the number.

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
