# Global CLAUDE.md (Garrett)

Loaded from `~/.claude/CLAUDE.md` into **every** session — it's in context on every turn, so it stays lean: universal *behavioral* rules only. Stack conventions, finish-line checklists, and deterministic guardrails live in lower-cost tiers (below). Per-repo `CLAUDE.md` overrides anything here.

**Where my config lives** (all synced from `~/dotclaude`; see that repo's README):

- **This file** — universal behavioral rules. Always loaded.
- **`~/.claude/rules/*.md`** — stack conventions (TypeScript, frontend, data/API, testing, monorepo/hosting), **path-scoped** so each loads only when I open matching files.
- **`~/.claude/skills/finishing-work`** — the finish-line procedure (definition of done, follow-ups, PR body, cleanup). Loads when wrapping up.
- **`~/.claude/skills/managing-work-with-issues`** — the GitHub-issue lifecycle (claim-on-begin, label taxonomy, follow-up discipline, feedback triage). Loads when starting/creating/finishing tracked work.
- **`~/.claude/hooks/`** — deterministic guardrails. `git-guard.sh` hard-**blocks** `--no-verify`, `.env` commits, force-push to `main`, and reckless `rm -rf`; `worktree-guard.sh` hard-**blocks** file edits to the main working tree of a `.worktrees/`-convention repo (use a worktree instead; `WORKTREE_GUARD_OFF=1` overrides); `verify-reminder.sh` (non-blocking) nudges you to verify before opening a PR. These fire even under `bypassPermissions`, so treat a block as a hard limit — fix the underlying cause, never route around it.

---

## Workflow rules — always apply

### Autonomy — drive every task to completion

When I hand you a feature or bug, **own it end-to-end without checkpoint questions.** The whole arc is one task, not six approvals:

**plan → implement → test → self-review → address review findings → ship**

- Don't stop between stages to ask "should I continue?" / "want me to move on?" / "linear or subagents?". The answer is always: yes, keep going, use subagents.
- **Make industry-standard assumptions and proceed.** Pick the conventional, best-practice option, note it in one line, and keep moving. A wrong assumption is cheap — visible in the diff, trivial to fix. A stalled task costs me more.
- **Default to your best guess. Use common sense.** The bar for stopping is "a competent engineer genuinely couldn't pick without more info," not "I'd feel safer confirming." If you can name the obvious right answer, take it. Asking when the answer was obvious is itself a mistake.
- Bundle any non-blocking questions or flagged choices into the **final summary**, not as mid-task interruptions.

#### How far you carry it — autonomy mode is per-repo

Where "ship" ends depends on the repo's **autonomy mode**, declared by a top line in its per-repo `CLAUDE.md`. **When unspecified, assume `gated`** — the safe default.

- **`gated` (default)** — carry the work to a **PR that's ready to merge**, then stop. **Merging to `main`, deploying, destructive data ops, force-push, and anything outward-facing/published are mine.** Take it right up to that line and stop there. This is the mode for any repo that hasn't opted in (e.g. **adventureOS**, until I say otherwise).
- **`autonomous-merge` (opt-in)** — repos whose `CLAUDE.md` declares `Autonomy: autonomous-merge` (currently **musclebuddy** and **redthread**). There you carry past the PR and merge it yourself:
  - **Merge feature → `dev`** once you've self-reviewed, addressed findings, and **CI is green**. In single-tier repos with no `dev` branch, this is feature → `main`.
  - **Promote `dev` → `main` in batches** when a coherent set of changes has landed and CI is green on `dev`. Batch related work; don't promote one commit at a time. Prefer promoting *through* `dev` rather than feature → `main` direct.
  - **Run any database operation** the task needs — including **destructive ops (DROP/DELETE/TRUNCATE) and prod migrations** — under the same review + CI discipline. `list_tables` / `get_advisors` first; write reversible migrations where you can; then proceed without stopping to ask.
  - **Still mine even here:** force-push to `main` (hook-blocked regardless), and any outward-facing action beyond the deploy a `main` merge triggers.

**CI is the gate in every mode: never merge or promote on red or pending checks.** If CI is failing, fix it or stop — never route around it (no `--admin` merge, no skipping required checks).

**When you MAY stop and ask** — narrows under `autonomous-merge`, but always applies to:
- **Big architecture forks / one-way doors**: framework, data model, auth model, public API shape — anything expensive to reverse.
- **Genuinely ambiguous intent** where reasonable engineers would build materially *different* things — and only after trying to resolve it from the code, docs, and my MCPs (Notion specs, etc.) first.
- **(`gated` repos only)** the irreversible final actions listed above: merge to `main`, deploy, destructive/prod data ops, force-push.

Everything else: decide and move. When in doubt between asking and proceeding on a reasonable default, **proceed.**

### Issues are the tracker; finish in-scope work

**Scope call first.** If something you notice is small and relevant to the task, just fix it inline — don't ask, don't defer. **In-scope work gets finished, not filed.** Leaving a task half-done and opening a follow-up for the rest is a failure, not tidiness.

GitHub Issues are the work-tracking substrate. The lifecycle — claim-on-begin (self-assign + `status:in-progress`), the `status:`/`type:`/`source:` taxonomy, close reasons, and feedback triage — lives in the **`managing-work-with-issues`** skill; load it when you start, create, or finish tracked work.

- **Claim before you work.** The moment you begin an issue, `issue_claim` it (self-assign + `status:in-progress`). Don't work an unclaimed issue.
- **A follow-up issue is only for** (a) a finding genuinely **out of scope**, or (b) a blocker needing a **human decision that totally halts** progress while you run autonomously. Not for in-scope work you could finish now.
- Every issue you create carries full fields (type, status, `file:line` in the body, relationships/milestone where known) and **no assignee** until claimed. Reference issues from the PR (`Closes #N`) and list them — with status — in the final summary.
- User-reported feedback (musclebuddy/redthread/adventureos) is filed `status:blocked` and **never auto-started** — it must be verified first.
- Creating issues in my own repos is **pre-approved** — bookkeeping in my tracker.

### Default to parallel + subagents

- Non-trivial features and bugs are **subagent-driven by default** (`superpowers:subagent-driven-development`). Reserve linear/inline execution for genuinely small, single-file, low-risk changes.
- Run independent work **in parallel** (`superpowers:dispatching-parallel-agents`): parallel exploration, parallel implementation of independent slices, parallel review dimensions. Always batch independent tool calls into one message.
- **Plan as a dependency graph, not a linear list.** Before working a multi-step plan (or a todo list), ask what *actually* blocks what — a step being *listed* first doesn't make it a *prerequisite*. Serialize only true dependencies; launch every unblocked branch immediately and concurrently — cheapest mechanism first (batch the independent tool calls in one message), escalating to parallel subagents only when a branch is heavy enough to warrant it (see the ladder below). Don't march top-to-bottom by default. E.g. `promote dev→main → verify deploys → reconcile issues → update docs`: only `promote → verify deploys` is a real chain; reconciling issues and updating docs depend on neither and should run alongside it from the start.
- **Escalation ladder** — match the tool to the scale: inline (small) → one subagent (token-heavy or needs context isolation) → parallel subagents / a `Workflow` (independent slices, fan-out review) → agent teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, ~7× tokens — reserve for exceptional parallel scale). Default to subagents/Workflow.
- Built-in "review checkpoints" in skills (`executing-plans`, `requesting-code-review`, `finishing-a-development-branch`) are **pre-approved** for routine work. Run the review, address findings, continue — surface results in the summary, not as a gate.
- `brainstorming` is for genuinely greenfield/ambiguous work. For a well-specified feature/bug, skip it.
- **Every dispatched subagent verifies before it reports "done."** Bake this into the dispatch prompt: the agent runs the checks relevant to its slice (typecheck + the affected tests) and includes the command output in its report. A subagent's "done" without evidence is a claim, not a fact — don't push or open a PR on top of it. This is structural, not ad hoc: put it in the prompt every time.

**Agent teams** (experimental, enabled via `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `settings.json`; needs Claude Code ≥ 2.1.32). These spawn *separate* Claude sessions that share a task list and message each other directly — heavier than subagents but they can challenge each other's findings. Don't reach for them by default. Use a team only when I explicitly ask, or for work where parallel *independent* exploration genuinely pays: multi-angle research/review, competing-hypothesis debugging, or features that split cleanly across frontend/backend/tests with one owner each. For everything else, subagents (report-back, cheaper) remain the default. Runtime state lives in `~/.claude/teams/` + `~/.claude/tasks/` (gitignored) — never pre-author or commit it.

### Worktree-first for code changes

Before any code changes in a repo with `.worktrees/` (gitignored), set up an isolated worktree (`superpowers:using-git-worktrees`) — multiple sessions in one checkout conflict.

```bash
git worktree add .worktrees/<short-name> -b feature/<short-name>
cd .worktrees/<short-name>
```

Skip for read-only work: questions, reviews, exploration, running tests without changes.

This is **enforced**, not just advised: `worktree-guard.sh` (a PreToolUse hook) hard-blocks `Edit`/`Write`/`MultiEdit`/`NotebookEdit` that target the **main working tree** of a `.worktrees/`-convention repo — so a stray agent can't leak uncommitted changes into everyone else's checkout. Edits inside a linked worktree pass. Deliberate main-tree edit? Set `WORKTREE_GUARD_OFF=1` (the config repo itself is auto-exempt).

### Stay current with the default branch

Branches drift behind `main` fast — stale bases cause avoidable conflicts and reviews against code that's already moved.

- **Starting a new batch of work**: sync first — `git checkout main && git pull` — and cut your worktree/branch off the freshly-pulled `main`, never a days-old local copy. In two-tier (`autonomous-merge`) repos, `dev` is the integration branch: branch off and merge back into `dev`, then promote `dev → main` in batches.
- **During longer work**: periodically pull the integration branch into your feature branch (`git fetch origin && git rebase origin/main`, or merge — substitute `dev` where that's the integration branch) so the diff stays small and current. Don't let it fall many commits behind.
- If a pull/rebase surfaces conflicts, resolve them as part of the work — don't defer them to merge time.

### Verify before you push or open a PR

A push and a PR are **handoffs** — never make them on unverified work. Before `git push` or opening a PR, run the checks relevant to *what you changed* and confirm they pass, then report the command output (`superpowers:verification-before-completion` — evidence before assertions):

- **Always**: typecheck + the tests affected by your change.
- **Only when relevant**: the build, if you touched build-affecting code (config, deps, codegen, bundler/route setup).
- This is *your* fast, change-scoped local check — **not** a "run the whole suite on every push" gate. Local git hooks are deliberately fast (pre-commit = gitleaks + lint-staged, pre-push = typecheck only); full build/unit/e2e live in CI by design. Scope verification to the diff so you stay fast without pushing blind.

### Finishing a task

A task isn't done at "PR opened" — it's done when the checkout is **clean, on the default branch, and pulled current**, ready for the next task. No stray worktrees, dead branches, or feature-branch HEAD left behind.

- At the finish line, run the **`finishing-work`** skill — it carries the definition-of-done checklist, the follow-up flow, the PR-body standard, and the cleanup steps (alongside `superpowers:finishing-a-development-branch`).
- **Never** delete a worktree or branch with uncommitted/unpushed work without flagging it first.

### Git hygiene

- **Conventional commits**: `feat:` `fix:` `chore:` `docs:` `refactor:` `test:` `perf:` `style:` `ci:` `build:` `revert:`. Most repos enforce with commitlint.
- **Never `--no-verify`** and **never commit `.env`** (only `.env.example`; use `vercel env pull`). Both are hook-blocked — if you hit the block, fix the real failure (rotate a leaked secret, fix lint/types), don't bypass.
- If a hook fails and you fix it, make a **NEW** commit — don't `--amend` (the original commit didn't happen).

### No ephemeral summary docs

Never create `INTEGRATION_SUMMARY.md`, `CHANGES.md`, `WHAT_I_DID.md`, or any file whose purpose is summarizing what just happened. The diff and commit message are the record. Permanent docs (architecture, runbooks) belong in the existing docs tree.

### Write for the final state, not the journey

Docs, PR descriptions, comments, and code describe **what is** — never the history of how it got there. Readers care about the end state; git is the changelog. This applies to *all* output: prose and code alike.

- **PR descriptions / docs**: write the final state once. Don't narrate incremental progress ("first I tried X, then switched to Y"), and don't keep editing the description as a running diary as you work — it reflects the merged result.
- **Code comments**: only ones that earn their place — explain *why* something non-obvious exists, a gotcha, an invariant. Never "what changed" / "removed the old version" / "previously this did X", and never leave commented-out code as a tombstone.
- **Delete dead code.** Deprecated, legacy, unused, or superseded code goes — don't keep it "just in case." It's bloat and a maintenance trap; git history holds anything you'd ever need back.

---

## Stack defaults

My default stack — TypeScript strict, Next.js App Router / Vite, Prisma, Zod, Supabase Auth, Vercel/Railway, pnpm/npm workspaces, Vitest/Jest + Playwright, Tailwind — is documented in **`~/.claude/rules/*.md`**, path-scoped so each set loads only when relevant. Per-repo `CLAUDE.md` overrides them. If a rule starts repeating across 3+ repos, hoist it into a rule file here.

## MCPs — prefer over generic tools

Use my configured MCPs instead of WebFetch / WebSearch / shell when relevant: **Supabase** (`list_tables` before schema changes; `get_logs` + `get_advisors` before debugging), **Prisma**, **Stripe**, **Playwright** (verify UI live), **Vercel** (deploys/logs), **Notion** (specs/playbooks), **Gmail / Calendar / Drive**, **PubMed** (MuscleBuddy), **Spotify** (RedThreadEvents). Tool schemas are deferred via tool-search — search for the tool when you need it. Never put service-role or secret keys in client-bundled code.

## Communication preferences

- **No status summaries.** Say it once and move on — the diff is the record.
- **Landing the turn, scaled to the stop.** Simple turns (Q&A, a recommendation, a one-line confirmation): one or two sentences, then stop. **Handoff stops** — work paused mid-task, a decision pending, or between phases of a multi-step task — end with a short *forward-looking* block (what happens next, not a recap of what was done), rendering *only* the lines that have content (never "Blockers: none"):
  - **Blockers / risks** — what's stopping progress or could bite.
  - **Decisions needed** — what you need from me to proceed.
  - **Next steps** — concrete actions, each tagged `(you)` or `(me)`.
- **Verify before claiming done** (`superpowers:verification-before-completion`): run typecheck / tests / the dev server before asserting something works.
- For exploratory questions ("what should we do about X"), reply with a recommendation + main tradeoff in 2–3 sentences. Don't implement until I agree.
