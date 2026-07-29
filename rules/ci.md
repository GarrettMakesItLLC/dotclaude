---
description: GitHub Actions CI conventions — concurrency, draft/ready gating, required checks, caching, capability gates
paths:
  - "**/.github/workflows/**"
  - "**/action.yml"
  - "**/action.yaml"
---

# CI conventions (GitHub Actions)

## Trigger events

**Validation runs once per change, on the PR.** A `push` re-run against a sha a PR already validated pays twice for one answer.

- **`pull_request` into any branch** — full validation. This is the gate.
- **`push` to `main`** — full validation: the post-merge safety net, and it warms the cache for the next branch.
- **`push` to `dev`** — no validation re-run; every commit arrived through a PR that ran the same jobs on the same sha. What a `dev` push *does* trigger is the **staging deploy**, which is a separate workflow.
- **`push` to a release branch** — nothing beyond the PR that opened it, unless a release-only job (artifact build, migration dry-run) genuinely can't run on a feature PR.

Deploy and release workflows are the exception to the concurrency rule below — they queue rather than cancel.

## Concurrency

Every workflow gets a concurrency group:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true   # idempotent test/validate/build workflows
```

State-mutating deploy/release/seed workflows use `cancel-in-progress: false` — queue, never cancel.

## PR gating

- Trigger `types: [opened, synchronize, reopened, ready_for_review]`.
- **The event payload's `draft` field lags the `ready_for_review` transition** — a run created right after "ready" can still see `draft == true` and silently skip gated jobs. Where a *required* check depends on a draft gate, read live state via `gh pr view --json isDraft` and fail open (API hiccup → treat as ready).

## Required checks

**A skipped job satisfies a required status check of the same name** — a path-filtered job that skipped lets a PR merge unverified.

- Require exactly one aggregate `ci-success` job that `needs:` all real jobs, so adding or splitting jobs never means editing the branch ruleset.
- `ci-success` runs only on `pull_request` and **fails if a job that had work to do was `skipped`**.

## Change detection

Gate each expensive job on a `dorny/paths-filter` job scoped to what that job can actually be affected by; multiple granularities are fine (`code` / `e2e` / a narrower `a11y`).

## Caching

- Cache **nested workspace `node_modules`** (`apps/*/node_modules`, `packages/*/node_modules`), not just the root — key on the lockfile (+ Prisma schema where relevant); gate install on a cache miss.
- Key the **Playwright browser cache on the lockfile-resolved version**, read from the lockfile — a hardcoded version goes stale silently.
- Give parallel jobs **separate Turbo cache namespaces** (`turbo-lint-*`, `turbo-test-*`).
- Warm the cache on the integration branch with a `push:` trigger; use Turbo remote cache (`TURBO_TOKEN`/`TURBO_TEAM`) for cross-runner reuse.

## Capability gates

A workflow needing not-yet-provisioned secrets or a data-plane ships **off by default** behind a `RUN_*` repo variable (`workflow_dispatch` always runs), with a guard step that fails clearly when the variable is on but the secrets are missing.

## Other

- `timeout-minutes` on long jobs (e2e, a11y).
- A bundled Node service gets a **boot smoke test**: run the built bundle in CI and assert it dies at the env-guard, proving every module initialized. A green build does not prove the bundle boots.
- PR-title lint for squash-merge repos: see `rules/monorepo-hosting.md`.
