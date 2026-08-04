---
description: GitHub Actions CI conventions — concurrency, draft/ready gating, required checks, caching, capability gates
paths:
  - "**/.github/workflows/**"
  - "**/action.yml"
  - "**/action.yaml"
---

# CI conventions (GitHub Actions)

## Shared actions (`GarrettMakesItLLC/ci`)

Composite actions and reusable workflows common to the product repos (e.g. `setup-node-workspace`) live in `GarrettMakesItLLC/ci`, tagged `@v1`. Consumers pin `@v1`, never `@main` — there is no staging tier for a shared action, so `@main` would let an in-progress change break every consumer's CI simultaneously. A private repo calling another private repo's `uses:` needs Actions access explicitly granted (repo settings → Actions → Access), or every `uses:` 404s.

## Trigger events

**Validation runs once per change, on the PR.** A `push` re-run against a sha a PR already validated pays twice for one answer.

- **`pull_request` into any branch** — full validation. This is the gate.
- **`merge_group`** — the merge-queue lane (Tier 2). Runs once a PR has already passed the `pull_request` gate and entered the queue, against GitHub's batched merge result. See "Two-tier check model" below.
- **`push` to `main`** — full validation: the post-merge safety net, and it warms the cache for the next branch.
- **`push` to `dev`** — no validation re-run; every commit arrived through a PR that ran the same jobs on the same sha. What a `dev` push *does* trigger is the **staging deploy**, which is a separate workflow.
- **`push` to a release branch** — nothing beyond the PR that opened it, unless a release-only job (artifact build, migration dry-run) genuinely can't run on a feature PR.

Deploy and release workflows are the exception to the concurrency rule below — they queue rather than cancel.

## Two-tier check model

CI splits into two tiers by trigger, so the PR gate stays fast and the slow suites still run before merge — but both tiers report through **one** required check, not two.

- **Tier 1 — PR lane (`pull_request`).** Fast jobs only: path-filtered lint, typecheck, unit tests, PR-title lint — anything that reliably finishes in a few minutes.
- **Tier 2 — merge-queue lane (`merge_group`).** Everything Tier 1 already proved, plus the suites too slow for a PR: e2e, a11y, any other integration-depth job.

**One required check for both: `CI Success`.** GitHub's merge queue re-validates every check listed in a ruleset's `required_status_checks` against the merge group's synthetic commit — a check whose workflow has no `merge_group` trigger simply never posts there, and the queue entry hangs until `check_response_timeout_minutes` expires it. Rather than carrying a second required-check name (`Queue CI Success`) for the queue lane, every repo runs a **single** `ci-success` job, triggered by both `pull_request` and `merge_group` (`if: always() && (github.event_name == 'pull_request' || github.event_name == 'merge_group')`), that `needs:` the full job list (Tier 1 + `lint-pr-title` + Tier 2). Its "did anything skip that shouldn't have" verification step is event-aware:

- On `pull_request`: Tier 1 jobs (and `lint-pr-title`) must not have skipped when they had real work; Tier 2 jobs are *expected* to be skipped (they only run on `merge_group`).
- On `merge_group`: Tier 1 jobs (and `lint-pr-title`) are *expected* to be skipped (already validated before the PR could queue); Tier 2 jobs must not have skipped when they had real work.

One name, one ruleset entry, no second aggregate to keep in sync, no republish tricks for anything that can be pulled into this job's own `needs:` graph.

A PR entering the queue already passed Tier 1 — that's what let it queue. The queue runs Tier 2 against the batched merge result GitHub is about to produce, which is strictly better signal than PR-branch-only e2e. A queue failure kicks that PR out of the queue; the rest proceed. The author fixes and requeues.

**`merge_group` is a ref-update trigger, not a PR event.** Jobs it triggers don't see `github.event.pull_request` — anything moved into a Tier 2 job that reads PR context (PR number, labels, diff) needs adjusting to read from the merge-queue ref instead.

**Nothing runs twice.** A suite lives in exactly one tier. A nightly/weekly/post-merge lane that duplicates what the queue now covers should be removed — the queue is faster feedback on the same signal. A lane checking something the queue genuinely can't (real-device smoke, dependency drift, staleness) stays as-is; this is a placement change, not "add more CI everywhere."

Don't wire `merge_group` into `ci-success` until at least one real Tier 2 job exists for it to `needs:` — a job with nothing to need is the same "skipped job satisfies a required check" trap as below, just at the trigger level. Until then, `ci-success` stays `pull_request`-only.

## PR-title lint folds into ci.yml

`Semantic PR Title` used to be a separately-required ruleset check, produced by a standalone `pr-title-lint.yml` workflow. Being a *separate required check*, it has the exact same merge-queue re-validation problem `CI Success` solves — and `needs:` can't reach across workflow files to fold it into another workflow's aggregate. So the fix is to stop it being separate.

Every repo gets (or keeps, moved) a `lint-pr-title` job **inside `ci.yml`**, gated `if: github.event_name == 'pull_request'` — a PR's title cannot change once queued, so there's nothing to re-check on `merge_group`; the job is expected to skip there, same as any other Tier 1 job. It becomes one of `ci-success`'s `needs:`. Any standalone `pr-title-lint.yml` workflow file is deleted. `Semantic PR Title` is dropped as an independently required ruleset check — `CI Success` is the only required status check left, everywhere.

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

- Require exactly one aggregate `ci-success` job that `needs:` all real jobs (Tier 1 + `lint-pr-title`, plus Tier 2 once it exists — see "Two-tier check model" above), so adding or splitting jobs never means editing the branch ruleset.
- A repo with no Tier 2 job yet: `ci-success` runs only on `pull_request` and **fails if a job that had work to do was `skipped`**.
- A repo running the two-tier model: `ci-success` runs on both `pull_request` and `merge_group`, and its skip-check is event-aware — Tier 1/`lint-pr-title` must not skip on `pull_request` (Tier 2 is expected to skip there); Tier 2 must not skip on `merge_group` (Tier 1/`lint-pr-title` is expected to skip there).

## Change detection

Gate each expensive job on a `dorny/paths-filter` job scoped to what that job can actually be affected by; multiple granularities are fine (`code` / `e2e` / a narrower `a11y`).

## Caching

- Cache **nested workspace `node_modules`** (`apps/*/node_modules`, `packages/*/node_modules`), not just the root — key on the lockfile (+ Prisma schema where relevant); gate install on a cache miss.
- Key the **Playwright browser cache on the lockfile-resolved version**, read from the lockfile — a hardcoded version goes stale silently.
- Give parallel jobs **separate Turbo cache namespaces** (`turbo-lint-*`, `turbo-test-*`).
- Warm the cache on the integration branch with a `push:` trigger; use Turbo remote cache (`TURBO_TOKEN`/`TURBO_TEAM`) for cross-runner reuse.

## Capability gates

A workflow needing not-yet-provisioned secrets or a data-plane ships **off by default** behind a `RUN_*` repo variable (`workflow_dispatch` always runs), with a guard step that fails clearly when the variable is on but the secrets are missing.

## Branch rulesets

Every repo carries the same three rulesets: `StagePR`, `ProdPR`, and `Copilot review for default branch`. Set `allowed_merge_methods` on each — squash on the default branch, merge-commit only on `main` — so squashing a promotion (which breaks version computation) is structurally impossible rather than a documented hope. Org-level rulesets aren't available yet (`integrations.md`), so this is set by hand, per repo.

## Other

- `timeout-minutes` on long jobs (e2e, a11y).
- A bundled Node service gets a **boot smoke test**: run the built bundle in CI and assert it dies at the env-guard, proving every module initialized. A green build does not prove the bundle boots.
- PR-title lint for squash-merge repos: see `rules/monorepo-hosting.md`.
