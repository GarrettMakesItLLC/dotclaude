---
name: operating-production
description: Use when operating, monitoring, or recovering a deployed production service — responding to an incident or outage, deciding rollback vs. forward-fix, adding health checks or alerting, or setting up a repo's production runbook. Rollback-first incident posture for Vercel/Railway-hosted apps.
allowed-tools: mcp__plugin_vercel_vercel__list_deployments, mcp__plugin_vercel_vercel__get_deployment, mcp__plugin_vercel_vercel__get_runtime_logs, mcp__plugin_vercel_vercel__get_runtime_errors, mcp__plugin_railway_railway__get-status, mcp__plugin_railway_railway__get-logs, mcp__plugin_railway_railway__list-deployments, mcp__plugin_railway_railway__redeploy, mcp__plugin_sentry_sentry__search_issues, mcp__plugin_sentry_sentry__search_events
---

# Operating production

The reusable posture. Per-repo specifics — URLs, env, domain playbooks — live in that repo's `docs/RUNBOOK.md`.

## Incident response — rollback first

**Favor the fastest safe recovery over root-causing on a live system.** Roll back to the last-good deploy, confirm the symptom clears, then investigate the bad deploy on a branch. Root-causing while users are down trades their time for your curiosity.

- **Vercel:** promote the previous production deployment (instant), or redeploy the last-good ref.
- **Railway:** redeploy the previous successful deployment.
- **Data-caused, not code-caused:** a rollback won't fix it but still buys time. Pair it with an ops kill switch (`rules/data-api.md`) to disable the affected subsystem without a redeploy.
- Forward-fix in place only when rollback is impossible (e.g. an already-run irreversible migration) — then expand-then-contract so the *next* rollback is safe.

## RUNBOOK.md — a standard artifact

Every production repo carries `docs/RUNBOOK.md` with:

- Per-platform rollback recipe, filled in.
- **First-5-minutes triage** in order: platform deploy status → runtime logs → error tracker → DB health.
- Log/signal source table — which dashboard shows what.
- RPO/RTO, and snapshot-before-destructive-migration.

## Health checks

- `/health` — **liveness**: process is up. Cheap, no dependencies.
- `/health/ready` — **readiness**: 503 when a hard dependency is down (e.g. `SELECT 1` fails). This is the one monitors and load balancers watch.

## Alerting — two independent sources

Deploys run from the platforms' own git integrations, so GitHub Actions cannot see a deploy crash. Cover both:

1. **External uptime monitor** hitting `/health/ready` — catches "the app is down", whatever the cause.
2. **Platform-native deploy/crash notifications** (Vercel, Railway) — catches "the deploy failed / the process is crash-looping."
