---
description: GitHub Actions CI conventions — concurrency, draft/ready gating, required checks, caching, capability gates
paths:
  - "**/.github/workflows/**"
  - "**/action.yml"
  - "**/action.yaml"
---

# CI conventions (GitHub Actions)

Battle-tested in MuscleBuddy. Adopt the ones that fit the repo — the monorepo/Turbo items are conditional.

## Concurrency — always

Every workflow gets a concurrency group so rapid pushes don't stack runs:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true   # idempotent test/validate/build workflows
```

Use `cancel-in-progress: false` (queue, never cancel) for **state-mutating** deploy/release/seed workflows that must not race on tags or the DB.

## PR gating — open ready, not draft

The global workflow opens PRs **ready after local self-review** (see CLAUDE.md), so CI runs on the first push. Still:

- Include `ready_for_review` in the trigger `types` (`opened, synchronize, reopened, ready_for_review`) so a repo that *does* receive a draft still fires CI when it's marked ready.
- **The event payload's `draft` field lags the `ready_for_review` transition.** A run created right after "ready" can still see `github.event.pull_request.draft == true` and silently skip gated jobs. Where a *required* check depends on a draft gate, read live state via `gh pr view --json isDraft` instead, and fail open (API hiccup → treat as ready → run the gates).

## Required checks — a skipped job is not a passing job

**A skipped GitHub Actions job satisfies a required status check of the same name.** So if you path-filter jobs behind a required check, a PR where the check was *skipped* can merge unverified. Defend it:

- Gate merges on a single aggregate `ci-success` job that `needs:` all real jobs, and make *that* the one required check — so adding/splitting jobs never means editing the branch ruleset.
- Have `ci-success` (a) run only on `pull_request` events, and (b) explicitly **fail if a job that had work to do was `skipped`** — don't rely on the individual jobs as required checks.

## Change-detection — skip unaffected jobs

In a monorepo, gate each expensive job on a `dorny/paths-filter` job scoped to what that job can actually be affected by (a web-only job shouldn't run on a backend-only PR; docs-only PRs skip everything). Multiple granularities are fine (`code` / `e2e` / a narrower `a11y` on `apps/web/**` + `packages/**`).

## Caching gotchas

- Cache **nested workspace `node_modules`** (`apps/*/node_modules`, `packages/*/node_modules`), not just the root — key on the lockfile (+ Prisma schema where relevant); gate `npm ci`/`pnpm i` on a cache miss.
- Key the **Playwright browser cache on the lockfile-resolved version** (read it from the lockfile), not a hardcoded string, or it silently goes stale.
- Give **parallel jobs separate Turbo cache namespaces** (`turbo-lint-*`, `turbo-test-*`) so they don't collide on one key.
- **Warm the cache on the integration branch** with a `push:` trigger — feature PRs restore from it instead of starting cold.
- Use Turbo **remote cache** (`TURBO_TOKEN`/`TURBO_TEAM`) for cross-runner reuse.

## Capability-gated workflows

A workflow that needs not-yet-provisioned secrets or a data-plane ships **off by default** behind a `RUN_*` repo variable (`workflow_dispatch` always runs), with a guard step that fails clearly if the variable is on but the required secrets are missing. Lets you commit the workflow before its infra exists without it erroring on every push.

## Other reusable bits

- Put `timeout-minutes` on long jobs (e2e, a11y) so a hang doesn't burn the full runner budget.
- For a bundled Node service, add a **boot smoke test**: run the built bundle in CI and assert it dies at the env-guard — proving every module initialized (catches CJS / `import.meta.url` / cron module-init crashes a green build can't see).
- For squash-merge repos, lint the **PR title** (it becomes the squash commit subject) with `amannn/action-semantic-pull-request` — see `rules/monorepo-hosting.md`.

## Never use CI as the debugging loop

Reproduce and fix failures locally; `workflow_dispatch`/re-runs are for validating something that genuinely can't run locally (a hosted data-plane), not debug-by-rerun. (Also in CLAUDE.md.)
