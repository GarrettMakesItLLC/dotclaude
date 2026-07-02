---
name: managing-work-with-issues
description: Use when starting, creating, or finishing any tracked unit of work in a GitHub repo — claiming an issue before you begin, filing a well-formed issue during investigation or as a follow-up, triaging app user-feedback, or moving an issue through its status lifecycle. Establishes GitHub Issues as the work-tracking substrate.
---

# Managing work with GitHub issues

GitHub Issues are the high-level tracker for all agent work. Every unit of work is
an issue with exactly one `status:*` label. Use the REST-only `github-rest` MCP
tools (never `gh` GraphQL paths) for every mutation below.

## The label taxonomy

- **status:** `backlog` → `ready` → `in-progress` → `in-review`; `blocked` from any state. Exactly one at a time. **Done = the issue is closed** (no `status:done`).
- **type:** `bug` / `feature` / `task` — set with `issue_set_type` (applies the native type + `type:*` label).
- **source:** `musclebuddy` / `redthread` / `adventureos` — origin of user-reported feedback.

If a label is missing in a repo, run `labels_ensure` once to provision the full set.

## Lifecycle — the rules

**Creating an issue** (investigation finding, follow-up, or triaged feedback):
- Always fill full fields: clear title; body with *what + why + a `file:line` pointer*; `issue_set_type`; milestone (`milestone_ensure` + `issue_set_milestone`) and relationships (`issue_add_sub_issue`) where known.
- Set status `ready` when fully scoped, `blocked` only when a genuine decision/info is outstanding. Gather enough at creation that issues rarely start blocked.
- **Do not assign anyone at creation.** Issues stay unassigned until claimed.

**Beginning work:** call `issue_claim` the moment you start — it self-assigns you and moves the issue to `status:in-progress`. Never work an issue without claiming it first.

**Opening the PR:** set `status:in-review` (swap it in via `issue_set_labels`, dropping `in-progress`) and reference the issue in the PR body (`Closes #N`).

**Finishing:** the merged `Closes #N` PR closes the issue as `completed` automatically. If you close an issue *without* implementing it (won't/didn't do), close it with `issue_update` `state: closed`, `state_reason: not_planned`, and remove the `status:*` label first.

## User-reported feedback (musclebuddy / redthread / adventureos)

Feedback from these apps becomes an issue with the matching `type:*` and
`source:*` labels — and **`status:blocked`**, never `ready`. User reports MUST be
verified by Garrett before implementation; agents do not auto-start them. Garrett
flips verified reports to `ready`.

## Follow-up discipline — this is the part agents get wrong

A follow-up issue is **only** for:
- **(a)** a finding genuinely **out of scope** of your current task, or
- **(b)** a blocker needing a **human decision that totally halts** forward progress while you run autonomously and Garrett is away.

**Finish in-scope work — do not defer it.** Leaving a task partially done and
filing a follow-up for the rest is a failure. If you can complete it now, complete
it. Follow-ups are for genuinely-separate or genuinely-blocked work, not a
to-do dump for things you could have finished.
