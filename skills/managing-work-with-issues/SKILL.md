---
name: managing-work-with-issues
description: Use when starting, creating, or finishing any tracked unit of work in a GitHub repo — claiming an issue before you begin, filing a well-formed issue during investigation or as a follow-up, triaging app user-feedback, or moving an issue through its status lifecycle. Establishes GitHub Issues as the work-tracking substrate.
---

# Managing work with GitHub issues

Every unit of work is a GitHub issue with **exactly one `status:*` label**. Done = the issue is **closed** (there is no `status:done`).

## Quick reference — the lifecycle

1. **Claim before you touch it.** Self-assign + set `status:in-progress` the moment you start. Never work an unclaimed issue.
2. **Work it.** Finish in-scope work — don't file a follow-up for something you could complete now.
3. **Open the PR** → set `status:in-review`; put `Closes #N` in the PR body.
4. **Merge** auto-closes it as `completed`. Closing something you *won't* do → close with reason `not_planned` and clear its `status:*` label.

## Tooling — MCP first, `gh` fallback (don't get stuck here)

Prefer the REST-only **`github-rest` MCP** tools (`issue_claim`, `issue_set_status`, `issue_set_type`, `labels_ensure`, `milestone_ensure`, `issue_set_milestone`, `issue_add_sub_issue`, `issue_update`) — they encode the taxonomy correctly and avoid the `gh` GraphQL `projectCards` breakage.

**But if those MCP tools aren't loaded in your session, do NOT stall or churn** — fall back to `gh` with an explicit `--repo` flag (`gh issue edit N --repo <owner/repo> --add-label ... --add-assignee @me`, `gh issue create`, `gh issue close --reason`). Search for the MCP tools once (ToolSearch `select:issue_claim,...`); if they don't resolve, use `gh` and move on. The lifecycle is what matters, not which tool applies the label. If the MCP is *missing a capability* you need, see **extending-the-github-mcp**.

## The label taxonomy

- **status:** `backlog` → `ready` → `in-progress` → `in-review`; `blocked` from any state. Exactly one at a time.
- **type:** `bug` / `feature` / `task`.
- **source:** `musclebuddy` / `redthread` / `adventureos` — origin of user-reported feedback only.

If labels are missing in a repo, provision the full set once (`labels_ensure`, or `gh label create`). New repos also want the issue/PR templates in `templates/` (copy them into `.github/`).

## Creating an issue (finding, follow-up, triaged feedback)

- Full fields: clear title; body with **what + why + a `file:line` pointer**; set type; milestone + relationships where known.
- Status `ready` when fully scoped; `blocked` only when a real decision/info is genuinely outstanding. **No assignee at creation** — issues stay unassigned until claimed.
- Closing multiple issues from one PR: GitHub's auto-close needs the keyword before **each** number — `Closes #1, closes #2` (a bare `Closes #1, #2` closes only #1).

## User-reported feedback (musclebuddy / redthread / adventureos)

Files as an issue with the matching `type:*` + `source:*` labels and **`status:blocked`**, never `ready`. User reports MUST be verified by Garrett before implementation — agents never auto-start them. Garrett flips verified reports to `ready`.

## Follow-up discipline — the part agents get wrong

A follow-up issue is **only** for **(a)** a finding genuinely **out of scope** of the current task, or **(b)** a blocker needing a **human decision that totally halts** progress while you run autonomously. Leaving a task half-done and filing a follow-up for the rest is a failure — if you can finish it now, finish it.
