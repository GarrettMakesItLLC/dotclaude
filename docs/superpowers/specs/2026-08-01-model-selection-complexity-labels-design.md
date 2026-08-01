# Model-selection complexity labels

## Why

Opus 5 has been the daily driver for everything, including small bug fixes and mechanical work
that doesn't need it — wasted tokens and cost with no quality upside. The session default already
moved to Sonnet 5. What's missing is a systematic way to route the *exceptions* — genuinely complex
work up to Opus, genuinely trivial work down to Haiku (or off Claude Code entirely, to opencode's
free tier) — instead of relying on in-the-moment judgment every time.

Scope: upfront triage only, applied at two points — GitHub issue labels and subagent dispatch.
Mid-task self-escalation (a running model recognizing it's underpowered and handing off) is an
explicit non-goal here; a follow-up if this proves out.

## Tiers

Three tiers, one per real lever available, matching the existing `type:*`/`source:*`/`status:*`
label style:

- **`complexity:trivial`** — mechanical, single-file, no judgment calls: typo/copy fixes,
  dependency bumps, a test added matching an existing pattern. → Haiku for subagents; for a
  personal session, a candidate for opencode instead of spinning up Claude at all (opencode isn't
  something this system dispatches to automatically — no integration exists — this is a heuristic
  note for a human choosing where to spend a task, not an automated route).
- **`complexity:standard`** — the default. Bounded scope, known patterns, a handful of files, no
  architectural decisions. → Sonnet.
- **`complexity:complex`** — cross-cutting, ambiguous, one-way-door (data model, auth, public API
  shape), multi-repo, or high blast radius. → Opus.

## Where it's provisioned

The label taxonomy's single source of truth is `mcp/github/src/labels.ts` (this repo), which
defines `ISSUE_STATUSES`/`ISSUE_TYPES`/`ISSUE_SOURCES`/`ISSUE_MARKERS`, their colors/descriptions,
and provisions them fleet-wide via `labels_ensure`/reports drift via `labels_audit`. This adds a
fourth axis the same way:

- `ISSUE_COMPLEXITIES = ["trivial", "standard", "complex"] as const`, `type IssueComplexity`.
- `COMPLEXITY_STYLES: Record<IssueComplexity, LabelStyle>` — new colors distinct from the existing
  status/type/source/marker palettes.
- `complexityLabel(c: IssueComplexity): string` helper, mirroring `typeLabel`/`statusLabel`.
- Appended to `ISSUE_LABELS` so `labels_ensure` provisions it in every repo and `labels_audit`
  flags drift, same as every other axis.

`issue_create`'s schema gains an optional `complexity: z.enum(ISSUE_COMPLEXITIES)` parameter,
composed into the label set the same way `type`/`source` already are. A new `issue_set_complexity`
tool mirrors the existing `issue_set_type` (replaces any existing `complexity:*` label, preserves
everything else, no native-GitHub-field equivalent since GitHub has no complexity concept to
mirror).

This is a real code change to the vendored `mcp/github` MCP server (TDD: failing test → implement
→ green, matching its existing style — zod schema, no `any` in `src/`), not just a documentation
convention. Per `mcp/github`'s own build model, the new/changed tools are only callable after
`npm run build` in `mcp/github` **and** a Claude Code restart.

## Issue-label application

- **New issues**: whenever an issue is filed (per the `managing-work-with-issues` skill), assign
  `complexity:*` alongside `type:*`/`source:*` at creation time — no separate pass.
- **Backfill**: a one-time sweep labels every currently-open issue across the fleet (musclebuddy,
  redthread, adventureos, networthy, dotclaude, and any other repo carrying the shared taxonomy) so
  nothing open is missing a tier. One-time, not a recurring job.
- **Claiming an issue**: when an issue carrying a `complexity:*` label is claimed (`issue_claim`),
  the claiming agent's own running model is compared against what the label calls for.
  Over-provisioned (Opus claiming a `trivial` issue) is wasteful but not wrong — no action needed.
  Under-provisioned (Sonnet claiming a `complex` issue) is a real mismatch: flag it to the owner
  rather than silently proceeding.

## Subagent dispatch

New line in global `CLAUDE.md`'s Execution section: when spawning `Agent`/`Workflow` subagents,
set the `model` param by the subtask's own complexity (same three-tier heuristic above) instead of
defaulting to inherit-from-session every time. This is a behavior change for the orchestrating
session, not a new tool — the `model` param already exists on both `Agent` and `Workflow`'s
`agent()` calls.

## Out of scope

- Mid-task self-escalation (a running model recognizing it's underpowered and handing off
  mid-task). Explicit non-goal for this pass — revisit as a follow-up once upfront triage has run
  for a while.
- Automated dispatch to opencode. No integration exists; the `trivial` tier's opencode note is
  guidance for a human's own tool choice, not something this system executes.
- Personal session-launch heuristics as a formal artifact — already effectively resolved by the
  saved default moving to Sonnet 5; no separate mechanism needed here.
