# Test & CI gate integrity

The question: **which green checks are actually capable of going red?** This is Law 2 of the audit method as its own realm: enumerate every guard, and for each establish either how it fails or that nobody knows.

Every other realm relies on this one when it writes "verified safe, gated by X". Where another realm's finding is "the guard for Y is vacuous", it belongs here; the underlying Y belongs to its realm.

## Checklist

- **The required-check set.** Read branch protection / rulesets (`gh api repos/{owner}/{repo}/rules/branches/<branch>` and `.../branches/<branch>/protection`). List what is required. Every workflow job NOT in that set is advisory: report which advisory jobs are the only thing checking something that matters.
- **`continue-on-error`, `if: always()`, `|| true`, `set +e`, `exit 0` in steps.** Each one is a place a failure becomes a pass. Cite each and say what it masks.
- **Job-level `if:` conditions and path filters.** A job that runs only on `paths:` X never runs when Y changes; a `workflow_dispatch`-only job is not a gate. Cross-check each guard's trigger against the files it protects.
- **Skipped, todo, `.only`, `.skip`, and conditional tests.** `grep -rn "\.skip\|\.todo\|xit(\|xdescribe(\|it\.only\|describe\.only"`. Each `.skip` with no linked issue is a finding; a `.only` that reached the default branch is a blocker.
- **Vacuous tests.** Tests whose assertion count can be zero (a loop over an empty corpus, `expect.assertions` absent), tests that assert on their own fixture rather than on production code, snapshot tests whose snapshot is empty or trivial, tests of a mock. For each corpus-scanning guard: how is the expected size derived, and could the change under test lower it?
- **Guards that scan the wrong glob.** A lint override, a test glob, a coverage `include`, a ratchet's file list — check each against the files that exist now. Files added since the glob was written that it doesn't match are the finding.
- **Flake handling.** `retries:` in Playwright/Vitest config, `--retry` flags, `rerun-failed` actions. Retries hide real races; report any test that needed a retry in the last 20 CI runs (`gh run list` + logs).
- **Coverage thresholds.** Are they enforced (`thresholds` with `autoUpdate: false`, or a ratchet)? Have they moved down in git history (`git log -p -- vitest.config.ts | grep -n threshold`)?
- **Hooks and local guards.** `.husky`, `.claude/hooks`, `bin/*guard*`. For each: what does it block, does CI re-check it (a local-only guard is bypassable with `--no-verify`), and does it exit non-zero on the case it names? Run one against known-bad input.
- **Scheduled lanes.** Nightly/weekly jobs: last 10 runs' conclusions. A lane that has been red for a week with an auto-filed issue nobody closed, or a lane whose failure files nothing, is a finding. A lane whose every run is green AND whose duration is suspiciously short (seconds) deserves a log read.
- **Self-verification of the audit's own gates.** Any `scripts/*audit*`, `*:verify`, `compliance:*` script: run it, then break its input and run it again. Report which ones do not go red.
- **Environment truthfulness in CI.** Tests that pass because an env var is unset and the code path short-circuits; a test DB that is a mock of a mock; E2E fixtures that skip-green when unprovisioned (should FAIL).

## Gates that fit this realm

Branch protection enumerated by a test that fails when a named job leaves the required set; a `scripts/ci/no-continue-on-error.test.ts`; a `.only`/`.skip` grep in the lint step; a "guard fires" test for each corpus-scanning guard that feeds it a known-bad input; a scheduled lane whose failure files an issue and whose issue-filing is itself tested.
