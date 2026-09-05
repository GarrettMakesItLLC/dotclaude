# Observability & cost

The question: **when something goes wrong in production, does a signal reach a human with enough context to act, and does the operator know what each part costs?** Uptime and RTO belong to `performance-ops`; this realm is signal coverage and spend.

## Checklist
- **Error capture coverage.** Sentry (or equivalent) init on every process: API, crons, workers, web, service worker, native. Sampling rates; PII scrubbing config; source maps uploaded per release (check a live event's stack). `catch` sites that log to console only on a server path.
- **Signal-to-noise.** Top 20 Sentry issues by volume in the last 14 days: each is either actionable or noise that should be filtered. Unresolved issues older than 30 days with >100 events.
- **Alerting.** What pages or emails a human: rules, thresholds, recipients. Alert rules that target a channel nobody reads. A cron that fails silently (no error report) or loudly on every run (alert fatigue).
- **Logging.** Structured vs free-text; request IDs propagated across API → DB → vendor call; log levels used correctly; secrets or PII in logs (grep log calls for token/email/password fields).
- **Metrics.** Request latency, error rate, queue depth, cron duration — where are they and who looks. Health endpoints that return 200 while a dependency is down.
- **LLM spend.** Per-feature token budgets, per-user caps, the cost ledger: does every model call path record cost? A path that calls a model and skips the ledger is a finding. Model choices per feature vs task complexity (an expensive model on a trivial classification).
- **Vendor spend.** Every metered vendor: is there a provider-side budget alert (ledger check first — may be owner action), and a code-side circuit breaker?
- **Retention of telemetry.** Log/event retention vs the privacy register; a telemetry table with no retention cron.
- **Runtime env drift.** Railway/Vercel env vars vs `.env.example` (a config-drift workflow may exist — read its last runs); a variable set in prod that no code reads.

## Gates
A test that every cron/queue entry point is wrapped in the error reporter; a test that every model-call site writes to the cost ledger; a spend-check lane that files an issue past threshold; a Sentry-noise ratchet.
