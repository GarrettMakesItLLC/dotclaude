# CI merge-queue standard (GitHub Enterprise)

## Why

GitHub Enterprise raised the Actions budget from 3k to 50k minutes/month and unlocked merge
queues. musclebuddy had already started working around the old 3k-minute ceiling (self-hosted
`desktop-lane`, a separate `weekly-lane`, e2e held off the PR path entirely) — those workarounds
were budget-driven, not architecturally desired. With 10x the budget, the standard shifts back
toward "run more in hosted CI, less locally": local pre-PR validation shrinks to a fast typecheck,
full validation (lint/unit/build) runs on every PR, and the suites too slow for a PR (e2e, a11y)
gate the merge queue instead of running post-merge/nightly/never. Agents stop burning tokens and
risking OOM running full suites locally; CI absorbs that cost with budget that now exists for it.

Applies to: musclebuddy, redthread, adventureos, networthy, and the `bootstrapping-a-product-repo`
skill's scaffold template — one consistent shape across the fleet, scaled to what each repo
actually has today.

## Two-tier check model — one required check name

**Tier 1 — PR lane (`pull_request` trigger).** Fast jobs only: path-filtered lint, typecheck,
unit tests, PR-title lint, any job that reliably finishes in a few minutes.

**Tier 2 — merge-queue lane (`merge_group` trigger).** Everything Tier 1 already proved, **plus**
the slow suites: e2e, a11y, and any other integration-depth job currently living on a nightly/
post-merge/manual trigger because it was previously too expensive to run per-PR.

**One required check for both: `CI Success`.** GitHub's merge queue re-validates every check listed
in a ruleset's `required_status_checks` against the merge group's synthetic commit — a check whose
workflow has no `merge_group` trigger simply never posts there, and the queue entry hangs until
`check_response_timeout_minutes` expires it (confirmed against GitHub's docs: "you need to update
the workflows to include the `merge_group` event... otherwise... the merge will fail as the
required status check will not be reported"). Rather than carrying a second required-check name
(`Queue CI Success`) for this, every repo runs a **single** `ci-success` job, triggered by both
`pull_request` and `merge_group`, that `needs:` the full job list (Tier 1 + PR-title-lint + Tier 2).
Its "did anything skip that shouldn't have" verification step is event-aware:

- On `pull_request`: Tier 1 jobs (and PR-title-lint) must not have skipped when they had real work;
  Tier 2 jobs are *expected* to be skipped (they only run on `merge_group`).
- On `merge_group`: Tier 1 jobs (and PR-title-lint) are *expected* to be skipped (already validated
  before the PR could queue); Tier 2 jobs must not have skipped when they had real work.

One name, one ruleset entry, no second aggregate to keep in sync, no republish tricks for anything
that can be pulled into this job's own `needs:` graph.

A PR entering the queue has already passed Tier 1 (that's what let it queue). The queue is where
the change gets to run against what's actually about to be `dev`/`main` — GitHub batches queued
PRs and runs Tier 2 against the merged result, which is strictly better signal than PR-branch-only
e2e. A queue failure kicks that PR out of the queue and the rest proceed; the author fixes and
requeues.

**Nothing runs twice.** A suite lives in exactly one tier. Nightly/weekly/desktop lanes that
duplicate what the queue now covers get removed (see per-repo mapping below); lanes that check
something the queue genuinely can't (real-device smoke, dependency-drift, staleness) stay as-is —
this is a placement change, not "add more CI everywhere."

## PR-title lint folds into `ci.yml`

`Semantic PR Title` is today a separately-required ruleset check, produced either by a standalone
`pr-title-lint.yml` workflow (musclebuddy, networthy, adventureos — via the shared
`GarrettMakesItLLC/ci/actions/pr-title-lint@v1` composite) or, in redthread's case, by nothing this
repo's workflows produce at all (no `pr-title-lint.yml` exists there, yet the ruleset requires the
check — a pre-existing gap this rollout fixes). Being a *separate required check*, it has the exact
same merge-queue re-validation problem `CI Success` does, and `needs:` can't reach across workflow
files to fold it into another workflow's aggregate — so the fix is to stop it being separate.

Every repo gets (or keeps, moved) a `lint-pr-title` job **inside `ci.yml`**, calling the same shared
`GarrettMakesItLLC/ci/actions/pr-title-lint@v1` composite action, gated `if: github.event_name ==
'pull_request'` (a PR's title cannot change once queued, so there's nothing to re-check on
`merge_group` — the job is expected to skip there, same as any other Tier 1 job). It becomes one of
`ci-success`'s `needs:`. The standalone `pr-title-lint.yml` workflow file is deleted in every repo
that has one. The ruleset drops `Semantic PR Title` as an independently required check — `CI
Success` is the only required status check left, everywhere. redthread gets real title linting for
the first time as a side effect of closing this gap.

## Repo config changes

Each repo's branch ruleset for `dev` (and `main` where PRs target it directly):

- Enable merge queue (`merge_method`, queue depth default — GitHub's defaults are fine to start).
- Required checks: `CI Success` only — the single check described above. `Semantic PR Title` is
  removed as an independently-required check (see "PR-title lint folds into `ci.yml`").
- `merge_group` is a *ref update* trigger, not a PR event — jobs triggered by it don't see
  `github.event.pull_request`; anything in a moved job that reads PR context needs adjusting.

## Shared `ci` repo changes

`GarrettMakesItLLC/ci` (`actions/ci-success`) has no event gating of its own today — the
`pull_request`-only restriction lives in the README's documented example and in this repo's own
`self-check.yml`, not in the composite action itself. No code change is needed there: a consumer
repo's single `ci-success` job simply gates itself `if: always() && (github.event_name ==
'pull_request' || github.event_name == 'merge_group')` and calls the same composite either way. The
README's "Consuming it" section gets rewritten to document this one-job, one-name pattern instead of
the two-job pattern an earlier draft of this design proposed.

## Local validation change

`rules/ci.md` and global `CLAUDE.md` ("Verify before a handoff") both update: local pre-PR
validation drops from "typecheck + affected tests (+ build if build-affecting)" to **typecheck
only**. `verify-reminder.sh`'s nudge text updates to match — it currently tells agents to run
"typecheck + the tests affected by your change"; that becomes "typecheck (CI runs the rest)".
Build-affecting changes no longer need a local build either — Tier 1 CI catches it, same as tests.

## Per-repo mapping

**musclebuddy** (most mature, most to reshape):
- `ci.yml`'s `preflight`/`lint`/`test`/`native` stay Tier 1 (PR).
- `e2e-suite.yml`'s promotion-gate caller moves from wherever it currently gates promotion to a
  `merge_group`-triggered job in `ci.yml`, folded into the single `ci-success` job's `needs:` (see
  "Two-tier check model" above). Its nightly desktop-lane caller is a *different* concern
  (self-hosted, broader/APK-inclusive) and stays.
- `pr-title-lint.yml` folds into `ci.yml` as a `lint-pr-title` job per "PR-title lint folds into
  `ci.yml`" above; the standalone workflow file is deleted.
- `desktop-lane.yml` / `weekly-lane.yml` / `nightly-staleness.yml`: self-hosted runner, effectively
  free minutes, checking things the hosted queue lane won't (APK boot smoke, deep/weekly-cadence
  signal). These stay — they were never the workaround for hosted-minute scarcity, `e2e-suite`'s
  gating position was. Re-verify overlap during implementation and drop anything the queue now
  makes redundant.
- `dev-push-report` (push-to-dev job) stays per `rules/ci.md`'s existing "push to dev triggers
  staging deploy, not re-validation" rule — unaffected by this change.

**redthread, adventureos**: split existing single `ci.yml` into the two tiers; whatever's
currently e2e/a11y-equivalent (if anything) moves to `merge_group`, folded into the single
`ci-success` job's `needs:`. Both fold `pr-title-lint.yml` into `ci.yml` per the PR-title section
above — redthread has no such workflow today despite the ruleset requiring the check (a gap this
closes for real; adventureos already has one to fold in). adventureos has no e2e/a11y-equivalent
suite yet, so per the "networthy" pattern above it widens `ci-success` to also cover `merge_group`
immediately rather than deferring the whole queue. Enable merge queue in branch rulesets.

**networthy**: new app, `ci.yml` is 80 lines, likely no e2e/a11y yet. `pr-title-lint.yml` folds into
`ci.yml` per "PR-title lint folds into `ci.yml`" above; the single `ci-success` job widens to also
run on `merge_group` (trivial today — nothing new to check, since there's no Tier 2 job yet) so
`CI Success` covers the queue lane immediately even with no slow suite. Add a commented, inactive
placeholder showing exactly where a future `merge_group`-only Tier 2 job goes (e.g. `e2e`) and how
it joins `ci-success`'s `needs:` — never a *real, wired* job that runs and does nothing, per
`rules/ci.md`'s "a skipped job satisfies a required check" trap, but also no reason to wait on
enabling the merge queue itself, since the one required check (`CI Success`) already covers it.

**bootstrapping-a-product-repo template**: `references/scaffold/.github/workflows/ci.yml` updates
to the Tier 1 shape with a documented (commented, not wired) example of adding a Tier 2
`merge_group` job, so a repo scaffolded from it starts on the new standard instead of the old one.

## Rollout order

musclebuddy → redthread → adventureos → networthy → template. musclebuddy first because it's
where the workarounds already exist and the mapping is most involved; the others are smaller
deltas once the pattern is proven. Gated repos (adventureos, networthy) land as PRs for manual
merge; autonomous repos (musclebuddy, redthread) merge once green, per existing per-repo autonomy.

## Out of scope

- Model-selection strategy (separate design, tracked separately).
- Re-litigating which suites musclebuddy currently runs beyond the placement change above — job
  *content* stays as-is; only *trigger/tier* moves.
