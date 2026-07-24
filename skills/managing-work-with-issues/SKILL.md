---
name: managing-work-with-issues
description: Use when starting, creating, or finishing any tracked unit of work in a GitHub repo — claiming an issue before you begin, filing a well-formed issue during investigation or as a follow-up, triaging app user-feedback, or moving an issue through its status lifecycle. Carries the cross-machine claim protocol that prevents duplicate work.
allowed-tools: mcp__github-rest__issue_claim, mcp__github-rest__work_in_flight, mcp__github-rest__claim_release, mcp__github-rest__issue_open, mcp__github-rest__issue_list, mcp__github-rest__issue_view, mcp__github-rest__issue_update, mcp__github-rest__issue_set_status, mcp__github-rest__issue_set_type, mcp__github-rest__issue_set_labels, mcp__github-rest__issue_set_milestone, mcp__github-rest__issue_add_sub_issue, mcp__github-rest__issue_comment, mcp__github-rest__labels_ensure, mcp__github-rest__milestone_ensure, Bash(git fetch:*), Bash(git checkout:*)
---

# Managing work with GitHub issues

Every unit of work is a GitHub issue with **exactly one `status:*` label**. Done = the issue is **closed** (there is no `status:done`).

## The claim protocol — why this skill exists

Garrett runs agents on **two machines against the same repos**. Both authenticate as him, so an assignee proves nothing about *which* machine holds the work, and in-flight work lives in local worktrees the other machine cannot see. The remote is the only shared surface, so the lock lives there.

**1. Survey before you select.** `work_in_flight` lists open `issue-*` refs on the remote with last-commit time and whether a PR exists. Anything listed is being worked — by the other machine, or by an earlier session of yours. Pick something else.

**2. Claim by creating the lock ref.** `issue_claim` creates `issue-<N>-<slug>` on the remote via the refs API. That create is atomic and server-side: if the ref exists, the claim **fails** because someone already holds it. Only after the ref lands does it self-assign and set `status:in-progress`.

**3. A failed claim means pick different work.** Never proceed past a failed claim — not "the other session probably died", not "I'll just work locally and sort it out later". Failure is the mechanism working.

**4. Use the branch the claim returns.** `issue_claim` returns the branch name; `git fetch && git checkout <branch>`. Do not invent your own name — the ref you check out and the ref that holds the lock must be the same one.

**5. Release only when abandoning without a PR.** `claim_release` deletes the lock ref. It refuses to drop a branch holding unmerged commits unless the commits landed in a merged PR or you pass `force` — so an abandoned-but-not-empty branch needs a deliberate decision, not a reflex.

`claim-guard.sh` (PreToolUse) blocks the first Edit/Write on an `issue-<N>-*` branch whose issue isn't claimed. Claiming late now fails fast instead of racing silently.

## Lifecycle

Claim → work it → open the PR (`status:in-review`, `Closes #N` in the body) → merge auto-closes as `completed`. Something you *won't* do closes with reason `not_planned` and its `status:*` label cleared.

GitHub's auto-close needs the keyword before **each** number: `Closes #1, closes #2` (a bare `Closes #1, #2` closes only #1).

## Taxonomy

- **status:** `backlog` → `ready` → `in-progress` → `in-review`; `blocked` from any state. Exactly one at a time.
- **type:** `bug` / `feature` / `task`.
- **source:** `musclebuddy` / `redthread` / `adventureos` — origin of user-reported feedback only.

Missing labels in a repo: provision the set once with `labels_ensure`. New repos also want the issue/PR templates from `templates/` copied into `.github/`.

## Filing an issue

Clear title; body with **what + why + a `file:line` pointer**; type set; milestone and relationships where known. **No assignee at creation** — unassigned until claimed. `status:ready` when fully scoped, `blocked` only when a decision or fact is genuinely outstanding.

A follow-up issue is **only** for a finding genuinely out of scope, or a blocker needing a human decision that halts autonomous progress. Filing a follow-up for work you could finish now is a failure, not tidiness.

## User-reported feedback (musclebuddy / redthread / adventureos)

Files with matching `type:*` + `source:*` and **`status:blocked`**, never `ready`. Garrett verifies reports before implementation and flips them to `ready` himself — agents never auto-start one.

## Tooling

Use the `github-rest` MCP tools — they encode the taxonomy and avoid `gh`'s deprecated GraphQL `projectCards` path. `gh api` (REST) is an acceptable fallback for *anything except a claim*: the claim protocol depends on the atomic ref-create, so if `issue_claim` is unavailable, don't hand-roll it — say so and stop. A missing capability → **extending-the-github-mcp**.
