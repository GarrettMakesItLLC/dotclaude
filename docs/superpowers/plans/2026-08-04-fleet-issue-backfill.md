# Fleet Issue Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan — one subagent per repo task, dispatched in parallel (they touch disjoint repos, no shared state). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Backfill Type, Effort, Priority, Status (project field), Milestone, epic groupings, and blocked-by relationships across every open issue in the 8 active repos, using the tooling from [[2026-08-04-project-fields-mcp-tooling]] and the fields/views from [[2026-08-04-project-schema-and-views]].

**Architecture:** One subagent per repo. Each works entirely within its own repo's open issues — no cross-repo coordination needed, so full parallelism. `dotfiles` and `ReptIdle` are excluded (0 open issues, confirmed during brainstorming).

**Tech Stack:** `mcp__github-rest__*` MCP tools only — no raw `gh`/`git`, this is data entry, not code.

**Depends on:** Both prerequisite plans must be fully merged, built, and the MCP server restarted before dispatching any repo subagent — `issue_set_effort`/`issue_set_priority`/`issue_set_blocked_by` don't exist until then, and the Effort/Priority project fields don't exist until the schema plan runs.

## Global Constraints

- **Milestones are opt-in, not force-filled.** Assign an existing milestone only when an issue clearly belongs to it. An issue with no real release target stays milestone-less — don't invent a milestone to fill the field.
- **Epics: 3+ open issues forming one real cluster** get a new epic issue (labeled `epic`, via `issue_open`) with those issues attached as sub-issues (`issue_add_sub_issue`). Leftover one-offs in a repo go under a single evergreen umbrella epic, e.g. `"<Repo> — Maintenance & Misc"`, titled and labeled the same way. Don't force a cluster that isn't real just to hit the count — a repo can end up with zero feature epics and just the umbrella.
- **Relationships**: only link `blocked_by` where the blocker is identifiable — an explicit `#123` reference in the body/comments, or unambiguous from context (e.g. a `status:waiting` issue whose body says "after X ships"). An issue whose blocker can't be identified keeps its `status:blocked`/`status:waiting` label and gets no relationship link; don't guess.
- **Status field**: every issue touched gets its Status *project field* (not the label — that's untouched) set to match its existing `status:*` label, using the mapping from the widened field: `backlog→Backlog, ready→Ready, blocked→Blocked, waiting→Waiting, in-progress→In Progress, in-review→In Review`. This is the field the schema-setup plan's Task 3 mutation may have left stale/unset on many items.
- **Never touch closed issues** — this backfill is scoped to open work only.
- **Report gaps, don't silently drop them.** Each repo task ends with a short summary: how many issues got each field, how many milestones assigned, epics created, relationships linked, and — critically — anything that couldn't be resolved (ambiguous blocker, no clear epic cluster, etc.) so it's visible rather than silently absorbed.

## Shared Procedure (every repo task follows this)

1. `mcp__github-rest__issue_list` the repo's open issues (paginate if over the tool's default limit).
2. For each issue missing Type: infer bug/feature/task from title+body, set via `issue_set_type`.
3. For each issue missing Effort: judge trivial/standard/complex by the same rubric `managing-work-with-issues` uses for new issues (mechanical/single-file → trivial; bounded/known-pattern → standard, the default; cross-cutting/ambiguous/one-way-door → complex). Set via `issue_set_effort`.
4. For each issue missing Priority: judge urgent/high/medium/low from title+body+labels (e.g. `launch-blocker` → urgent; a paper-cut → low). Set via `issue_set_priority`.
5. Set every issue's Status project field to match its `status:*` label (see Global Constraints) — this needs a project-field-write tool call per issue; if `issue_set_effort`/`issue_set_priority`'s pattern doesn't have a direct Status-field equivalent tool yet, use the same `findProjectItem`/`getProjectField("Status")`/`setProjectSingleSelect` primitives Plan A's `project.ts` exposes — if no MCP tool wraps that combination for the Status field specifically, file that gap via the `closing-tool-gaps` skill rather than skipping every issue's Status sync.
6. List the repo's milestones (`mcp__github-rest__issue_view` or equivalent milestone-listing call); for each issue that clearly maps to one, attach it (`issue_set_milestone`).
7. Cluster analysis: group the remaining unclustered issues by theme; for each cluster of 3+, `issue_open` a new epic (title, `epic` label, type `task`) and `issue_add_sub_issue` each member. Create one umbrella epic for the rest.
8. Relationship pass: for each `status:blocked`/`status:waiting` issue, search its body/comments for an explicit blocker reference; where found, `issue_set_blocked_by`.
9. Re-run `issue_list` for the repo and confirm zero open issues are missing Type/Effort/Priority — that's the hard completeness bar. Milestone/epic/relationship coverage is best-effort and reported, not asserted to 100%.
10. Report the summary described in Global Constraints.

---

### Task 1: NetWorthy (92 open issues)

- [ ] Run the Shared Procedure above against `GarrettMakesItLLC/NetWorthy`. 3 existing milestones to consider for attachment (list them first — don't guess at their scope, read each one's description).

### Task 2: MuscleBuddy (100 open issues)

- [ ] Run the Shared Procedure above against `GarrettMakesItLLC/MuscleBuddy`. 3 existing milestones to consider. This is the largest repo in scope — if the subagent's context runs long, it's fine to checkpoint by working in title-sorted batches and reporting incrementally rather than holding all 100 in one pass.

### Task 3: AdventureOS (61 open issues)

- [ ] Run the Shared Procedure above against `GarrettMakesItLLC/AdventureOS`. 2 existing milestones to consider.

### Task 4: RedThreadEvents (67 open issues)

- [ ] Run the Shared Procedure above against `GarrettMakesItLLC/RedThreadEvents`. 1 existing milestone to consider.

### Task 5: dotclaude (6 open issues)

- [ ] Run the Shared Procedure above against `GarrettMakesItLLC/dotclaude`. 0 existing milestones — expect most issues to stay milestone-less unless a real one gets created here. At 6 issues, an epic cluster is unlikely (needs 3+ related); the umbrella epic alone may cover everything, or nothing may need grouping at all — don't force it.

### Task 6: ci (4 open issues)

- [ ] Run the Shared Procedure above against `GarrettMakesItLLC/ci`. 0 existing milestones. At 4 issues, likely no epic needed at all — skip epic creation if there's no real cluster and the umbrella would just hold everything (a 1-issue "umbrella" isn't worth creating; only make it if there are genuinely 2+ leftover one-offs after any real clusters are pulled out).

### Task 7: .github (2 open issues)

- [ ] Run the Shared Procedure above against `GarrettMakesItLLC/.github`. 0 existing milestones. Skip epic creation entirely at this size — 2 issues, set Type/Effort/Priority/Status/milestone-if-real only.

### Task 8: platform (1 open issue)

- [ ] Run the Shared Procedure above against `GarrettMakesItLLC/platform`. 0 existing milestones. Skip epic and relationship passes — 1 issue, nothing to cluster or link. Just Type/Effort/Priority/Status.

---

### Task 9: Cross-repo verification

**Files:** none — verification only.

- [ ] **Step 1: Confirm completeness across the fleet**

Type/Effort/Priority are native fields and a project field, not labels, so there's no single `gh issue list` grep that proves they're set fleet-wide. The real check is per-issue and already required by each repo task's own Step 9 (Shared Procedure) — re-run `issue_list` for that repo and confirm zero open issues are missing Type/Effort/Priority. This step is the roll-up: once every repo task in this plan reports its Step 9 result, confirm here that all 8 reported zero gaps. If any repo reported a nonzero gap, that repo's task isn't done — go back to it rather than treating this roll-up as a separate remediation pass.

- [ ] **Step 2: Confirm the label taxonomy retirement**

```bash
for r in NetWorthy MuscleBuddy AdventureOS RedThreadEvents dotclaude ci .github platform; do
  n=$(gh issue list --repo GarrettMakesItLLC/$r --state open --limit 500 --json labels \
    --jq '[.[] | .labels[] | select(.name | startswith("type:") or startswith("complexity:"))] | length')
  echo "$r: $n open issues still carrying a retired type:*/complexity:* label"
done
```

Expected: `0` for every repo, once each repo task has re-synced its issues past the label removal from the MCP tooling plan (issues created *before* that plan lands may still carry the old labels on disk even though the tools stopped writing new ones — this loop catches that leftover and each repo task should clean it up as part of its Type-setting pass, via `issue_set_labels` to strip the stale label once the native type is confirmed set).
