# Project fields, epics, and relationships

## Why

The org project (`GarrettMakesItLLC — Work`, project #2, 862 items) is thin: no priority, no
effort tracking beyond a label, a Status field that doesn't match the real status taxonomy, no
epics-via-sub-issues, no blocked/blocked-by links. ~330 open issues across 8 active repos are
missing most of this. Meanwhile `complexity:*` and `type:*` labels duplicate ground GitHub now
covers natively (issue types) or that a Project custom field covers better (effort). This
supersedes [[2026-08-01-model-selection-complexity-labels-design]]'s complexity-as-label approach.

Scope: field taxonomy, milestone/epic/relationship conventions, project views, the `mcp/github`
tooling change this implies, and a one-time backfill across the fleet. Not in scope: touching
`status:*` labels or the claim-lock system (they work, this doesn't ask them to change), building
a Roadmap (date-based) view, or exhaustive dependency-mining beyond what's already inferable from
`status:blocked`/`status:waiting` and epic groupings.

## Field taxonomy

| Axis | Mechanism | Values |
|---|---|---|
| Type | Native GitHub issue type (org already has Bug/Feature/Task configured) | Bug / Feature / Task |
| Effort | New Project #2 single-select field, replaces `complexity:*` label | Trivial / Standard / Complex |
| Priority | New Project #2 single-select field (net-new) | Urgent / High / Medium / Low |
| Status | `status:*` label stays the source of truth (claim-lock/automation depend on it, untouched). Project #2's native Status field is widened from Todo/In Progress/Done to match the six label values 1:1: Backlog / Ready / Blocked / Waiting / In Progress / In Review |

`type:*` label is dropped — the native issue type is reliably present org-wide now, so the label's
"universal fallback" role is gone. `complexity:*` label is retired once the Effort field ships;
values and their Haiku/Sonnet/Opus mapping carry over unchanged, only the storage mechanism moves.

## Milestones

Time/release-boxed, used only where a real target exists — not force-filled onto every issue.
Backfill assigns existing milestones where an issue clearly belongs to one; issues with no real
target stay milestone-less. No new milestones invented purely to fill the field.

## Epics

Native GitHub sub-issues (Project #2 already has unused Parent issue / Sub-issues progress
fields). The existing `epic` label remains the marker on the parent issue — no new label needed.

Rule: a repo with 3+ open issues clearly forming one feature/initiative gets a new epic issue,
with those issues attached as its sub-issues. Leftover one-off issues per repo go under one
evergreen umbrella epic (e.g. "MuscleBuddy — Maintenance & Misc") rather than being forced into a
fake cluster or left ungrouped. The umbrella epic is never meant to reach 100% sub-issue
completion — it's closed and reopened as a bucket, not tracked toward done.

## Relationships

Native blocks/blocked-by links (the "Relationships" section already in the issue sidebar, unused
today). Backfilled from what's already inferable, not an exhaustive pairwise analysis:

- Epic ↔ sub-issue links come for free from the epic pass above.
- Issues carrying `status:blocked` or `status:waiting` get linked to whatever they're actually
  blocked on — read from the issue body/comments (explicit `#123` references) or a judgment call
  by the backfill agent when the blocker is clear from context. An issue whose blocker can't be
  identified keeps its `status:blocked`/`waiting` label but gets no relationship link — that's a
  gap to flag, not to guess at.

## Views (single project, no split)

Keep: Needs Triage, By Repository, In Progress (All Repos), Active Board (rebuilt on the widened
Status field).

Add:

- **Blocked** — `status:blocked` or `status:waiting` or has an open blocking relationship link.
  Surfaces stuck work at a glance.
- **By Priority** — grouped/sorted on the new Priority field.
- **Epics** — board grouped by parent issue; sub-issue progress bars substitute for a
  date-based Roadmap view, which is explicitly out of scope (no start/target-date backfill).

## `mcp/github` tooling changes

Real code changes in this repo's vendored MCP server, TDD per its existing style (zod schemas, no
`any` in `src/`), rebuilt (`npm run build` in `mcp/github`) and Claude Code restarted before the
new tools are callable:

- `issue_set_type`: drop the `type:*` label half; native issue type only.
- `issue_set_complexity` → `issue_set_effort`: writes the Project #2 Effort field via
  `updateProjectV2ItemFieldValue` (GraphQL) instead of a label. Requires resolving repo+issue
  number to the project item id first — an extra GraphQL hop the label version didn't need.
- `complexityModelMismatch` (used by `issue_claim`'s model-tier check): reads Effort off the
  project item instead of `labelNames`. Same resolve-to-project-item-id step.
- `labels.ts`: remove `ISSUE_COMPLEXITIES`/`IssueComplexity`/`complexityLabel`/`COMPLEXITY_STYLES`;
  move `complexity:*` into `DEPRECATED_LABELS` (retitled, not deleted — preserves history on
  already-closed issues, matching how `bug`/`enhancement`/`documentation` are handled). Remove
  `type:*` from `ISSUE_LABELS` the same way; native type has no label fallback going forward.
- `labels_ensure`/`labels_audit`: no taxonomy-shape change needed beyond the above — they already
  provision/audit off `ISSUE_LABELS`.
- Global `CLAUDE.md` Execution section: "complexity:* label" → "Effort field" in the
  model-by-subtask-complexity guidance.
- `managing-work-with-issues` skill: swap any complexity/type label references to the field
  equivalents.

An issue must be a Project #2 item for its Effort field to be readable/writable. Every repo in
scope already auto-adds new issues to the project (confirmed for the 8 active repos checked during
brainstorming); the backfill pass should spot-check this holds before relying on it repo-by-repo.

## Rollout

Two stages:

1. **Schema + tooling, once**: add Effort/Priority fields and widen Status on Project #2, ship the
   `mcp/github` changes above, add the three new views.
2. **Backfill, fanned out**: one subagent per repo (NetWorthy, MuscleBuddy, AdventureOS,
   RedThreadEvents, dotclaude, ci, .github, platform — dotfiles/ReptIdle have zero open issues,
   skip) working through that repo's open issues — set Type/Effort/Priority, assign milestone
   where a real one exists, identify epic clusters and umbrella-epic the rest, wire up
   blocked/blocked-by links where inferable. Detailed task breakdown is a plan-phase concern, not
   this spec's.

## Out of scope

- Changing `status:*` labels or the claim-lock system.
- A date-based Roadmap view — the Epics board view covers the "see the shape of the work" need
  without backfilling start/target dates on 330 issues.
- Exhaustive dependency-mining across all issue pairs — only what's inferable from
  blocked/waiting status and epic groupings gets linked; unclear cases are flagged, not guessed.
- Splitting into multiple projects — single project stays, reached via better views instead.
