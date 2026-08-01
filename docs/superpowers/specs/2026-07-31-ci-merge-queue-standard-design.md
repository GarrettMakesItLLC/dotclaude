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

## Two-tier check model

**Tier 1 — PR lane (`pull_request` trigger).** Fast jobs only: path-filtered lint, typecheck,
unit tests, PR-title lint, any job that reliably finishes in a few minutes. Required check:
`CI Success` (unchanged name/shape from today).

**Tier 2 — merge-queue lane (`merge_group` trigger).** Everything Tier 1 already proved, **plus**
the slow suites: e2e, a11y, and any other integration-depth job currently living on a nightly/
post-merge/manual trigger because it was previously too expensive to run per-PR. Required check:
`Queue CI Success` — a second aggregate, same `needs:`-all-real-jobs / fail-on-skip shape as
`CI Success`, scoped to `merge_group`.

A PR entering the queue has already passed Tier 1 (that's what let it queue). The queue is where
the change gets to run against what's actually about to be `dev`/`main` — GitHub batches queued
PRs and runs Tier 2 against the merged result, which is strictly better signal than PR-branch-only
e2e. A queue failure kicks that PR out of the queue and the rest proceed; the author fixes and
requeues.

**Nothing runs twice.** A suite lives in exactly one tier. Nightly/weekly/desktop lanes that
duplicate what the queue now covers get removed (see per-repo mapping below); lanes that check
something the queue genuinely can't (real-device smoke, dependency-drift, staleness) stay as-is —
this is a placement change, not "add more CI everywhere."

## Repo config changes

Each repo's branch ruleset for `dev` (and `main` where PRs target it directly):

- Enable merge queue (`merge_method`, queue depth default — GitHub's defaults are fine to start).
- Required checks: `CI Success` (PR) and `Queue CI Success` (merge_group). Both by exact context
  name, matching the existing "required check = exact job name" convention in `rules/ci.md`.
- `merge_group` is a *ref update* trigger, not a PR event — jobs triggered by it don't see
  `github.event.pull_request`; anything in a moved job that reads PR context needs adjusting.

## Shared `ci` repo changes

`GarrettMakesItLLC/ci` (`actions/ci-success`) currently guards with
`if: github.event_name == 'pull_request'`. It needs to also serve the queue lane. Two options,
pick during implementation:

- **(a)** Parameterize `ci-success` with an `event-name` input, so a repo declares two jobs
  (`ci-success` gated on `pull_request`, `queue-ci-success` gated on `merge_group`) both calling
  the same composite.
- **(b)** Loosen the composite's own `if:` to accept either event and let the caller's job-level
  `if:` do the gating (matches the existing division of responsibility — the action reports on
  `needs`, the caller controls when it runs).

(b) is less code to touch across every consumer; default to it unless implementation surfaces a
reason not to. This is a `v1`-compatible change (additive), not a `v2` cut.

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
  `merge_group`-triggered job in `ci.yml`, using `Queue CI Success` as the new gate. Its nightly
  desktop-lane caller is a *different* concern (self-hosted, broader/APK-inclusive) and stays.
- `desktop-lane.yml` / `weekly-lane.yml` / `nightly-staleness.yml`: self-hosted runner, effectively
  free minutes, checking things the hosted queue lane won't (APK boot smoke, deep/weekly-cadence
  signal). These stay — they were never the workaround for hosted-minute scarcity, `e2e-suite`'s
  gating position was. Re-verify overlap during implementation and drop anything the queue now
  makes redundant.
- `dev-push-report` (push-to-dev job) stays per `rules/ci.md`'s existing "push to dev triggers
  staging deploy, not re-validation" rule — unaffected by this change.

**redthread, adventureos**: split existing single `ci.yml` into the two tiers; whatever's
currently e2e/a11y-equivalent (if anything) moves to `merge_group`. Enable merge queue in branch
rulesets. No template-level surprises expected — implementation confirms per repo.

**networthy**: new app, `ci.yml` is 80 lines, likely no e2e/a11y yet. Build the **full two-tier
skeleton now** (Tier 1 job(s), `merge_group`-triggered Tier 2 job stub, both required checks wired
into the ruleset) so it doesn't need a second pass later — but don't wire a Tier 2 job that has
nothing to run. If there's no e2e suite yet, the Tier 2 job either doesn't exist yet (added when
the first e2e test lands) or exists with a clear TODO-free placeholder that's excluded from
`Queue CI Success`'s `needs:` until real jobs exist — never a job that runs and does nothing, per
`rules/ci.md`'s "a skipped job satisfies a required check" trap. Concretely: don't create
`Queue CI Success` as a required check until there's at least one real Tier 2 job to need.

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
