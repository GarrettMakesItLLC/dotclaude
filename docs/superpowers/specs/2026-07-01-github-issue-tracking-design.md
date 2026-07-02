# GitHub Issues as the agent work-tracking substrate

**Repo:** `dotclaude` (config repo, `gated` autonomy — work ends at a merge-ready PR).
**Date:** 2026-07-01

## Problem

Garrett runs agents continuously across multiple machines, all authenticated as
the single GitHub user `GarrettMakesIt`, fielding a constant stream of bug
reports and feature requests. Today issue usage is ad hoc: the global CLAUDE.md
tells agents to `gh issue create` for follow-ups, but there is no lifecycle, no
required fields, no status model, and — critically — agents tend to file
follow-up issues for work that was in scope, leaving tasks half-finished.

This spec makes GitHub Issues the high-level work-tracking substrate with a
disciplined lifecycle that agents follow autonomously.

## Goals

1. Every unit of work is a GitHub issue with a clear, single status.
2. An issue is **claimed** (self-assigned + moved to in-progress) the moment an
   agent begins it — and only then.
3. Every issue an agent creates carries full fields (type, status, source,
   relationships/milestone where known) so nothing is lost.
4. Follow-up issues are rare and reserved for genuinely out-of-scope findings or
   hard human-decision blockers — never a dumping ground for in-scope work.
5. User-reported feedback is never implemented unverified.
6. All of the above uses REST only (no GraphQL — the existing MCP constraint).

## Design principles: the enforcement hierarchy

Each piece is placed at the Claude Code tier that gives the best adherence per
token of context:

| Tier | When loaded | What it holds here |
|---|---|---|
| **Global CLAUDE.md** | every turn (most expensive) | ~8 lean lines: issues *are* the tracker; claim before working; finish in-scope work; the narrow follow-up rule; pointer to the skill. **Triggers only.** |
| **rules/*.md** | path-scoped | **nothing** — issue management is cross-cutting, not tied to file paths. Deliberately not a rule file. |
| **Skill** `managing-work-with-issues` | on-demand, when starting/creating/finishing an issue | the full lifecycle state-machine, exact MCP tool per transition, the label taxonomy, feedback-source flow, follow-up discipline, PR-linkage. The bulk lives here. |
| **MCP** (`mcp/github`) | tool calls | new REST tools for the state-machine transitions + provisioning. |
| **Hook** `verify-reminder.sh` (extend) | PreToolUse on PR-open | **non-blocking** nudge: does the PR link an issue and is that issue in-review? The one deterministic checkpoint. |

Rationale: the *trigger* to use the system must always be in context
(CLAUDE.md), but the *procedure* is expensive and only sometimes relevant
(skill, loaded on demand). The hook catches the single discrete, detectable
event (PR open); everything else is judgment encoded in the skill.

## Label taxonomy

Provisioned into every repo by automation (`labels_ensure`, below). Exactly one
`status:` label at a time.

**status:** (mutually exclusive)
- `status:backlog` — captured, not yet scoped or prioritized
- `status:ready` — fully scoped, ready to start
- `status:blocked` — needs info/decision, or awaiting human verification
- `status:in-progress` — an agent has claimed it and is actively working
- `status:in-review` — PR open, awaiting review/merge

*Done is represented by closing the issue* — there is no `status:done`. The
`status:*` label is **removed on close** (status only describes open work).
Whether the work was done vs. abandoned is captured by the native GitHub **close
reason**: `completed` (implemented) vs `not_planned` (won't/didn't do). A merged
PR that says `Closes #N` closes the issue as `completed` automatically.

**type:** applied as a label **and** set as the native GitHub issue type
(best-effort native; the label is the universal fallback for owners without
native types enabled)
- `type:bug`, `type:feature`, `type:task`

**source:** feedback origin
- `source:musclebuddy`, `source:redthread`, `source:adventureos`

Colors/descriptions: `status:*` share one hue, `type:*` another, `source:*`
another; exact hex values fixed in `labels_ensure`.

## Lifecycle state-machine (skill core)

1. **Create** (follow-up / investigation / app feedback): always full fields —
   title; body with *what + why + `file:line`*; `type:` label + native type;
   milestone and relationships if known; `source:` label if from app feedback.
   Status = `ready` when fully scoped, else `blocked`. **No assignee at
   creation.** Prefer capturing all needed info at creation so issues rarely
   start `blocked` (only when a genuine decision is outstanding).
2. **Feedback-sourced issues start `status:blocked`** and are never
   auto-started. They wait for Garrett to verify the report and flip to
   `ready`. Agents must not implement unverified user reports.
3. **Claim / begin** (single atomic action, via `issue_claim`): self-assign
   `@me` + set `status:in-progress` + remove `ready`/`blocked`/`backlog`.
4. **PR opened**: set `status:in-review`; PR body references the issue
   (`Closes #N`).
5. **Done**: strip the `status:*` label and close the issue with a close
   reason — `completed` when implemented, `not_planned` when abandoned. `gated`
   repos end at in-review → Garrett merges → closed as `completed`;
   `autonomous-merge` repos, the agent merges → issue closes via `Closes #N`.

## Follow-up discipline (revises current CLAUDE.md)

A follow-up issue is created **only** for:
- **(a)** a finding genuinely **out of scope** of the current task, or
- **(b)** a blocker requiring a **human decision that totally halts** forward
  progress while the agent runs autonomously and Garrett is unavailable.

**In-scope work is finished, not deferred.** Filing a follow-up to avoid
completing something the agent could and should complete now is a failure mode
to eliminate. This replaces the "track-and-tackle liberally" framing in the
global CLAUDE.md "Fix what's relevant; track-and-tackle the rest" section, which
today over-encourages filing.

## PR templates (project repos)

- Author a canonical `.github/PULL_REQUEST_TEMPLATE.md` (issue-link section with
  `Closes #`, a short summary, a verification section) and keep the canonical
  copy in `dotclaude` for reference.
- **Stand up one PR per project repo** adding the template:
  `musclebuddy`, `redthread`, `adventureos`. Identical content, except
  `adventureos` may get a build/verification tweak if its setup differs. Each PR
  follows that repo's autonomy mode (musclebuddy/redthread = autonomous-merge;
  adventureos = gated → merge-ready PR only).
- The skill always fills `Closes #N` into `pr_create` bodies regardless of the
  template; the template is the GitHub-UI-facing reinforcement for the same
  linkage the hook nudges about.

## New MCP tools (REST-only, reuse `ghRequest`)

- `issue_add_assignees` / `issue_remove_assignees` —
  `POST`/`DELETE /issues/{n}/assignees`
- `issue_set_type` — native type via `PATCH /issues/{n}` `{type}` **and** apply
  the `type:` label (best-effort native, always label)
- `issue_set_milestone` + `milestone_ensure` — `PATCH issue` +
  `POST /milestones` (idempotent create-or-find)
- `issue_add_sub_issue` / `issue_list_sub_issues` —
  `/issues/{n}/sub_issues` (the REST relationships primitive)
- `labels_ensure` — idempotently sync the full taxonomy into a repo
- `issue_claim` — convenience: self-assign `@me` + swap status to
  `in-progress` + strip `ready`/`blocked`/`backlog` in one call, so the claim
  transition can't be done partially
- Extend `issue_update` to accept `state_reason` (`completed` /
  `not_planned` / `reopened`) so closes carry the done-vs-won't-do distinction

All new tools ship with vitest coverage following the existing mocked-network
test pattern (`gh` + `fetch` mocked, no live network).

## Decisions locked

- **Hook:** non-blocking nudge (matches `verify-reminder.sh` philosophy; never
  blocks PR creation).
- **Skill scope:** one global skill in `~/.claude/skills`; feedback-source
  labels documented inside it (no per-repo CLAUDE.md pointers).
- **Type representation:** both native issue type and `type:` label.
- **Assignee:** `@me` (= `GarrettMakesIt`); unassigned until claimed.

## Deliverables

1. Edit global `CLAUDE.md` — issue-tracking triggers + rewritten follow-up rule.
2. New skill `skills/managing-work-with-issues/SKILL.md`.
3. Extend `mcp/github` with the tools above + vitest coverage.
4. Author the canonical `PULL_REQUEST_TEMPLATE.md` and stand up one PR per
   project repo (`musclebuddy`, `redthread`, `adventureos`) adding it.
5. Extend `hooks/verify-reminder.sh` (+ its test) for issue-linkage nudge.
6. Wire `labels_ensure` into `bootstrap.sh`.
7. Update `README.md` and `mcp/github/README.md` for the new tools/skill.

## Out of scope

- Migrating existing open issues in project repos to the new taxonomy (a
  separate one-off task).
- Native issue-type org configuration (assumed already available; label is the
  fallback).
