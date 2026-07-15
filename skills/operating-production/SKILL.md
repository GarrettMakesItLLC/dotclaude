---
name: operating-production
description: Use when operating, monitoring, or recovering a deployed production service — responding to an incident or outage, deciding rollback vs. forward-fix, adding health checks or alerting, or setting up a repo's production runbook. Rollback-first incident posture for Vercel/Railway-hosted apps.
---

# Operating production

Standard hygiene for a deployed service. The specifics (URLs, env, coach-billing playbooks) live per-repo in `docs/RUNBOOK.md`; this is the reusable posture.

## Incident response — rollback first

When production is broken, **favor the fastest safe recovery over root-causing on a live system.** Roll back to the last-good deploy, confirm the symptom clears, *then* investigate the bad deploy at leisure on a branch. Root-causing while users are down trades their time for your curiosity.

- **Vercel:** promote the previous production deployment (instant rollback), or redeploy the last-good ref.
- **Railway:** redeploy the previous successful deployment.
- If the cause is data, not code, a code rollback won't help — but a rollback still buys time. Pair it with an ops **kill switch** (see `rules/data-api.md`) to disable the affected subsystem without a redeploy.
- Only forward-fix-in-place when a rollback is impossible (e.g. an already-run irreversible migration) — and then expand-then-contract so the next rollback is safe.

## RUNBOOK.md — a standard artifact

Every production repo carries `docs/RUNBOOK.md` with:

- **Per-platform rollback recipe** (the exact Vercel/Railway steps above, filled in).
- **First-5-minutes triage** — where to look, in order: platform deploy status → runtime logs → error tracker (Sentry) → DB health.
- **Log/signal source table** — which dashboard shows what.
- **RPO/RTO** and **snapshot-before-destructive-migration** reminders.

## Health checks

- `/health` — **liveness**: process is up. Cheap, no dependencies.
- `/health/ready` — **readiness**: returns 503 when a hard dependency is down (e.g. `SELECT 1` fails). Load balancers and uptime monitors watch this one.

## Alerting — two independent sources

Deploys run from the platforms' own git integrations, not GitHub Actions, so Actions can't see a deploy crash. Cover both:

1. **External uptime monitor** (e.g. UptimeRobot) hitting `/health/ready` — catches "the app is down" regardless of cause.
2. **Platform-native deploy/crash notifications** (Vercel + Railway) — catches "the deploy failed / the process is crash-looping."
