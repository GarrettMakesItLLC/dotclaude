# Global CLAUDE.md (Garrett)

Loaded from `~/.claude/CLAUDE.md` into **every** session — it's in context on every turn, so it stays lean: universal *behavioral* rules only. Stack conventions, finish-line checklists, and deterministic guardrails live in lower-cost tiers (below). Per-repo `CLAUDE.md` overrides anything here.

**Where my config lives** (all synced from `~/dotclaude`; see that repo's README):

- **This file** — universal behavioral rules. Always loaded.
- **`~/.claude/rules/*.md`** — stack conventions (TypeScript, frontend, data/API, testing, monorepo/hosting), **path-scoped** so each loads only when I open matching files.
- **`~/.claude/skills/finishing-work`** — the finish-line procedure (definition of done, follow-ups, PR body, cleanup). Loads when wrapping up.
- **`~/.claude/hooks/`** — deterministic guardrails. `git-guard.sh` hard-**blocks** `--no-verify`, `.env` commits, force-push to `main`, and reckless `rm -rf`. These fire even under `bypassPermissions`, so treat a block as a hard limit — fix the underlying cause, never route around it.

---

## Workflow rules — always apply

### Autonomy — drive every task to completion

When I hand you a feature or bug, **own it end-to-end without checkpoint questions.** The whole arc is one task, not six approvals:

**plan → implement → test → self-review → address review findings → PR-ready**

- Don't stop between stages to ask "should I continue?" / "want me to move on?" / "linear or subagents?". The answer is always: yes, keep going, use subagents. Carry the work to a PR that's ready to merge.
- The only hard stop is the **irreversible final action**: opening the PR is yours to do, but **merging to `main`, deploying, destructive data ops, force-push, and anything outward-facing/published are mine.** Take it right up to that line and stop there.
- **Make industry-standard assumptions and proceed.** Pick the conventional, best-practice option, note it in one line, and keep moving. A wrong assumption is cheap — visible in the diff, trivial to fix. A stalled task costs me more.
- **Default to your best guess. Use common sense.** The bar for stopping is "a competent engineer genuinely couldn't pick without more info," not "I'd feel safer confirming." If you can name the obvious right answer, take it. Asking when the answer was obvious is itself a mistake.
- Bundle any non-blocking questions or flagged choices into the **final summary**, not as mid-task interruptions.

**When you MAY stop and ask** — only when guessing wrong is genuinely costly:
- **Irreversible / hard-to-undo**: prod migrations, deletes, merges, deploys, force-push, anything published or outward-facing.
- **Big architecture forks / one-way doors**: framework, data model, auth model, public API shape — anything expensive to reverse.
- **Genuinely ambiguous intent** where reasonable engineers would build materially *different* things — and only after trying to resolve it from the code, docs, and my MCPs (Notion specs, etc.) first.

Everything else: decide and move. When in doubt between asking and proceeding on a reasonable default, **proceed.**

### Fix what's relevant; track-and-tackle the rest

**Scope call first.** If something you notice is small and relevant to the task, just fix it inline — don't ask. If it's **big, risky, or unrelated**, don't sprawl the diff: capture it instead.

When you defer something — out of scope, a leftover TODO, a "we should also…", a known limitation, a flagged risk — **open a GitHub issue** (`gh issue create`) instead of only mentioning it in the summary or dropping a bare `// TODO`. Follow-up work must not evaporate into chat history.

- Title it clearly; short body (what + why + a `file:line` pointer); label it if the repo uses labels.
- **Don't just file it and walk away** — dispatch a subagent (its own worktree, in parallel) to address it, unless it's genuinely blocked, needs my input, or belongs in a separate session.
- Reference each issue from the PR (`Follow-up: #123`) and list them — with status — in the final summary.
- Batch related follow-ups into one issue rather than many tiny ones.
- Creating issues in my own repos is **pre-approved** — the one outward-facing action you may take without asking, since it's just bookkeeping in my tracker.

### Default to parallel + subagents

- Non-trivial features and bugs are **subagent-driven by default** (`superpowers:subagent-driven-development`). Reserve linear/inline execution for genuinely small, single-file, low-risk changes.
- Run independent work **in parallel** (`superpowers:dispatching-parallel-agents`): parallel exploration, parallel implementation of independent slices, parallel review dimensions. Always batch independent tool calls into one message.
- **Escalation ladder** — match the tool to the scale: inline (small) → one subagent (token-heavy or needs context isolation) → parallel subagents / a `Workflow` (independent slices, fan-out review) → agent teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, ~7× tokens — reserve for exceptional parallel scale). Default to subagents/Workflow.
- Built-in "review checkpoints" in skills (`executing-plans`, `requesting-code-review`, `finishing-a-development-branch`) are **pre-approved** for routine work. Run the review, address findings, continue — surface results in the summary, not as a gate.
- `brainstorming` is for genuinely greenfield/ambiguous work. For a well-specified feature/bug, skip it.

**Agent teams** (experimental, enabled via `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `settings.json`; needs Claude Code ≥ 2.1.32). These spawn *separate* Claude sessions that share a task list and message each other directly — heavier than subagents but they can challenge each other's findings. Don't reach for them by default. Use a team only when I explicitly ask, or for work where parallel *independent* exploration genuinely pays: multi-angle research/review, competing-hypothesis debugging, or features that split cleanly across frontend/backend/tests with one owner each. For everything else, subagents (report-back, cheaper) remain the default. Runtime state lives in `~/.claude/teams/` + `~/.claude/tasks/` (gitignored) — never pre-author or commit it.

### Worktree-first for code changes

Before any code changes in a repo with `.worktrees/` (gitignored), set up an isolated worktree (`superpowers:using-git-worktrees`) — multiple sessions in one checkout conflict.

```bash
git worktree add .worktrees/<short-name> -b feature/<short-name>
cd .worktrees/<short-name>
```

Skip for read-only work: questions, reviews, exploration, running tests without changes.

### Stay current with the default branch

Branches drift behind `main` fast — stale bases cause avoidable conflicts and reviews against code that's already moved.

- **Starting a new batch of work**: sync first — `git checkout main && git pull` — and cut your worktree/branch off the freshly-pulled `main`, never a days-old local copy.
- **During longer work**: periodically pull the default branch into your feature branch (`git fetch origin && git rebase origin/main`, or merge) so the diff stays small and current. Don't let it fall many commits behind.
- If a pull/rebase surfaces conflicts, resolve them as part of the work — don't defer them to merge time.

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
- **Brief end-of-turn summaries** — one or two sentences: what changed, what's next.
- **Verify before claiming done** (`superpowers:verification-before-completion`): run typecheck / tests / the dev server before asserting something works.
- For exploratory questions ("what should we do about X"), reply with a recommendation + main tradeoff in 2–3 sentences. Don't implement until I agree.
