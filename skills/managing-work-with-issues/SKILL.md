---
name: managing-work-with-issues
description: Use when starting, creating, or finishing any tracked unit of work in a GitHub repo — claiming an issue before you begin, filing a well-formed issue during investigation or as a follow-up, triaging app user-feedback, or moving an issue through its status lifecycle. Carries the cross-machine claim protocol that prevents duplicate work.
allowed-tools: mcp__github-rest__issue_claim, mcp__github-rest__work_in_flight, mcp__github-rest__claim_release, mcp__github-rest__issue_open, mcp__github-rest__issue_list, mcp__github-rest__issue_view, mcp__github-rest__issue_update, mcp__github-rest__issue_set_status, mcp__github-rest__issue_set_type, mcp__github-rest__issue_set_labels, mcp__github-rest__issue_set_milestone, mcp__github-rest__issue_add_sub_issue, mcp__github-rest__issue_comment, mcp__github-rest__labels_ensure, mcp__github-rest__labels_audit, mcp__github-rest__label_list, mcp__github-rest__label_update, mcp__github-rest__label_delete, mcp__github-rest__milestone_ensure, Bash(git fetch:*), Bash(git checkout:*)
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

- **status:** `backlog` → `ready` → `in-progress` → `in-review`; `blocked` or `waiting` from any state. Exactly one at a time.
- **type:** `bug` / `feature` / `task`.
- **source:** where the report came from. `owner` / `user-feedback` arrived through an app's in-app reporter; `musclebuddy` / `redthread` / `adventureos` name the app instead, for reports cross-filed somewhere else; `agent` and `code-review` are internal provenance — an audit or sweep found it, or a review did. **`owner`, `agent` and `code-review` are trusted**: they carry their evidence, so their defects start `ready` rather than waiting to be verified.
- **markers:** orthogonal to all three above, and to each other. `epic` — an index of sub-issues, never worked directly. `launch-blocker` — must clear before public launch.

An app may carry axes of its own outside this taxonomy (`area:*`, `module:*`, musclebuddy's `beta-feedback` / `idea`). They aren't drift — `labels_audit` lists them as unrecognized for review, not for deletion.

**GitHub's stock labels are not part of the taxonomy.** `bug`, `enhancement` and `documentation` duplicate an axis at the identical color; `labels_ensure` retitles them as deprecated where they exist but never creates them, because they are still attached to closed issues and deleting a label erases it from that history. `good first issue`, `help wanted`, `invalid` and `question` have no place in a solo tracker — `labels_audit` reports them, `label_delete` removes them.

Provision a repo once with `labels_ensure`, then check it with `labels_audit`. `label_list` shows usage counts, and `label_update` renames a legacy label into the taxonomy without losing the issues that carry it. New repos also want the issue/PR templates from `templates/` copied into `.github/`.

### `blocked` vs `waiting` vs `backlog`

These three get conflated, and the cost is real: agents skip a `blocked` queue wholesale, so an over-applied `blocked` hides startable work.

- **`blocked` means it needs Garrett** — a decision only he can make, a credential only he can mint, an asset only he can author, or a dashboard only he can see. Nothing else. Every `blocked` issue carries a **`## ⛔ Owner action required`** section: a checklist of the literal steps, an estimate, and — where there is a defensible default — a recommendation he can just say yes to. "Blocked on the owner" without those steps is an unfinished issue.
- **`waiting` means it depends on another issue**, not a person. It carries a **`## ⏳ Waiting on #N`** section naming the dependency and stating plainly that nothing is needed from Garrett. An agent seeing `waiting` should check whether the dependency has landed and re-label to `ready` if so.
- **`backlog` means nothing is outstanding at all** — it is scoped and startable, just not prioritised.

Before applying `blocked`, try to resolve it. A missing env var you can fetch from Railway/Vercel, a fact you can grep for, a bug you can reproduce — those are work, not blockers. Only what genuinely requires Garrett's hands or judgement earns the label.

## Filing an issue

Clear title; body with **what + why + a `file:line` pointer**; type set; milestone and relationships where known. **No assignee at creation** — unassigned until claimed. `status:ready` when fully scoped, `blocked` only when Garrett is genuinely required.

A follow-up issue is **only** for a finding genuinely out of scope, or a blocker needing a human decision that halts autonomous progress. Filing a follow-up for work you could finish now is a failure, not tidiness.

## Epics and milestones — the two axes

Every issue that isn't a standalone one-off answers two questions, and they are different questions:

- **Parent epic — "what is this part of?"** A native sub-issue relationship (`issue_open` with `parent`, or `issue_add_sub_issue`). The epic is an **index, not work**: labelled `epic`, its body links its children and carries the scope statement, and nothing is ever implemented on it directly.
- **Milestone — "which push does this ship in?"** Found-or-created by exact title (`issue_open` with `milestone`, or `milestone_ensure`). Titles are themed and dated: `Feature Gaps — surface & wire (2026-06)`, `Pre-Launch Audit (2026-07-09)`.

An issue with a milestone and no parent is orphaned work; an issue with a parent and no milestone is unscheduled work. Both are how a backlog becomes unreadable.

Close an epic when its children are closed — an **exhausted epic** left open reads as live work, and the next session re-derives its contents. Never file a child under a closed parent.

Audit findings land on exactly this shape: the audit epic is the findings index, one child per finding, all on the dated milestone — see **running-an-audit**.

Where a repo carries an issue-audit script (MuscleBuddy's `npm run issues:audit`), **it is the arbiter, not this document** — it reads the live tracker and exits non-zero on any violation. Its rule names are the checklist: `missing-parent`, `missing-milestone`, `missing-status`, `missing-type`, `closed-parent`, `unlabelled-epic`, `stale-in-progress`, `blocked-without-owner-action`, `waiting-without-dependency`, `exhausted-epic`, `deprecated-label`. Run it before handing off in any repo that has it.

## Reported feedback (`source:*`)

Files with matching `type:*` + `source:*`. The status depends on **who reported it and whether an agent can verify it**:

- **Garrett's own defect reports → `status:ready`.** He is the primary reporter, and his account of running software settles the question of whether it happens. Reproduce it, then fix it. `source:owner` marks these.
- **A third party's defect report → `status:blocked`.** One person's account of what they saw, unverifiable from here, and building against it confidently builds the wrong thing. It waits for Garrett to reproduce.
- **Any idea or feature request → `status:blocked`, whoever filed it.** These need his intent before they are built, and he develops them *with* an agent rather than receiving a finished guess.

The in-app reporter applies this itself (`apps/server/src/lib/bug-report-github.ts`), so the label that arrives is already correct — do not re-derive it by hand. `issue_open` encodes the same defaults: pass `source` and `type` and the status follows.

## Tooling

Use the `github-rest` MCP tools — they encode the taxonomy and avoid `gh`'s deprecated GraphQL `projectCards` path. `gh api` (REST) is an acceptable fallback for *anything except a claim*: the claim protocol depends on the atomic ref-create, so if `issue_claim` is unavailable, don't hand-roll it — say so and stop. A missing capability → **extending-the-github-mcp**.
