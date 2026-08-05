# Multi-model review team (fleet-wide)

## Why

Existing PR review coverage is single-vendor: the `/code-review` skill fans out Haiku/Sonnet
agents, and CI enforces lint/typecheck/tests. That's real signal, but it's one model family
reviewing its own kind's output — no second opinion from a genuinely different model lineage.
GitHub Copilot code review (no seats currently held, $19-39/user/mo) and the Claude Code GitHub
Action (shares the same Pro/Max usage pool already tight from interactive development) were both
ruled out as the way to get that second opinion. Open-weight models via a pay-per-token provider
(OpenRouter) sidestep both constraints: no seat cost, no shared quota, and genuine model diversity
against Sonnet/Opus.

Applies fleet-wide: a reusable composite action in `GarrettMakesItLLC/ci` (matching how
`setup-node-workspace` and other shared actions already live there per `rules/ci.md`), consumed by
each product repo through a thin per-repo workflow file. Off by default per repo via a
`RUN_REVIEW_TEAM` capability-gate variable until `OPENROUTER_API_KEY` is provisioned as an
org-level secret.

## Harness: opencode on OpenRouter

Each review "lens" runs as a non-interactive `opencode` invocation, checked out at the PR head
sha, pointed at a specific OpenRouter-hosted model. `opencode` was chosen over a bespoke
diff-in/review-out script because it gives each lens a real agent loop (read files, grep, follow
references) rather than a single stuffed-context prompt, and because it doubles as the harness for
a separate, already-planned exploration of using opencode + cheap models for simple development
tasks — the investment in wiring it up serves both.

**Open risk to validate before building the full pipeline**: unlike Claude Code's forced-tool-call
structured output, `opencode`'s output needs a defined parsing contract (e.g., a required fenced
JSON block in the lens prompt). A lens whose output can't be reliably parsed produces zero
findings silently. Prototype this standalone, against a handful of real past PRs, before wiring up
the full CI pipeline.

## Trigger

`pull_request: [opened, ready_for_review]`, gated on live draft state (`gh pr view --json
isDraft`, same pattern the rest of CI already uses for draft lag) — fires once per PR, not on
every push. This deliberately keeps the review team out of the tight edit-iterate loop: it's a
gate-adjacent supplemental signal, not something that should scale with commit count.

Idempotent: skips if this action already commented on the current head sha, so a manual re-trigger
on the same sha doesn't double-post. Never a required/blocking check — it posts a comment, same
spirit as Copilot/CodeRabbit-style bots.

## Triage (risk-tiered team sizing)

A plain script, no model call, runs first: reads `git diff --stat` against the PR base plus a
repo-overridable config (`.github/review-team.yml`) listing sensitive path globs (`auth/**`,
`payments/**`, `migrations/**`, `infra/**`, etc.) and size thresholds. Outputs a risk tier —
`small` / `standard` / `high` — that determines which lenses run. This keeps sizing "intelligent"
(matches PR risk, not PR count) without spending a model call on the decision itself.

## Lens catalog

| Lens | Tier | Purpose |
|---|---|---|
| General correctness | small+ | logic errors, obvious bugs — cheapest/fastest model |
| Security | standard+ | injection, auth, secrets, unsafe deserialization |
| Performance | standard+ (or path-triggered on hot-path/DB files) | N+1s, unbounded loops, blocking calls |
| Adversarial bug-hunt | high only | tries to break the change; feeds the verify pass |

Model-to-lens assignment (e.g. Qwen3-Coder for general correctness, DeepSeek for security) lives in
`review-team.yml` as config, not hardcoded in the action — OpenRouter pricing and model
availability shift, and the assignment should be swappable without touching the action itself.

## Adversarial verification (high tier only)

Each finding from a high-tier PR's lenses is re-checked by a lens running under a **different**
model than the one that raised it. Findings not confirmed by the verify pass are dropped before
synthesis. This mirrors the confidence-scoring/filtering step already used in the existing
`/code-review` skill, but cross-model instead of same-vendor.

## Data flow

```
PR -> ready_for_review
   -> triage script reads diff stats + config -> risk tier
   -> tier selects lens set from catalog
   -> parallel: each lens = opencode run (repo checkout @ head sha, model X, lens prompt)
        -> each lens emits findings as structured text (file, line, description, confidence)
   -> [high tier only] each finding -> verify run on a different model -> keep only confirmed
   -> dedupe/merge (file+line proximity) -> single formatted comment -> gh pr comment
```

Comment format matches the existing `/code-review` skill's style (brief, cited file+line links
with full sha, generated-by footer), with each finding additionally tagged by which model raised
it, so the diversity is visible rather than implicit.

## Error handling & cost guardrails

- **Eligibility gate first**: skip closed/draft/bot PRs and same-sha re-runs, same check the
  existing `/code-review` skill already does before it starts.
- **Per-lens spend cap**: a max-token budget per `opencode` run, enforced by opencode's own limits
  where available, else a wrapper timeout/kill. A lens that fails, errors, or is truncated drops
  its findings silently from that run and gets one line noted in the final comment ("security lens
  did not complete") — one flaky model call doesn't fail the whole job.
- **Secrets**: `OPENROUTER_API_KEY` is an org-level GitHub secret, not per-repo — the
  `RUN_REVIEW_TEAM` capability gate is the only per-repo toggle needed.

## Testing & rollout

1. Prototype the `opencode` + OpenRouter + structured-output contract standalone (outside the
   Action), against a handful of real past PRs, to validate parsing reliability and get real
   per-tier cost numbers before wiring up CI.
2. Roll out on dotclaude itself first (`RUN_REVIEW_TEAM=true` here only) — low-stakes, fast
   iteration — before extending to product repos.
3. No automated test suite for the lens prompts themselves (inherently fuzzy); success criteria is
   empirical — track false-positive rate and per-tier cost over the first ~20 real PRs before
   trusting it as more than supplemental, ignorable signal.

## Non-goals

- Not a required/blocking CI check.
- Not a replacement for the existing Claude-based `/code-review` skill or interactive self-review
  — additive diversity, not a swap.
- Not wired into pre-push/local iteration — deliberately PR-gate-only per the trigger discussion
  above, to avoid scaling cost with commit count during active development.
