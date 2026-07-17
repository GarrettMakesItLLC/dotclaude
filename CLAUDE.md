# Global CLAUDE.md (Garrett)

Loaded from `~/.claude/CLAUDE.md` into **every** session — in context on every turn, so keep it lean: universal *behavioral* rules only. Stack conventions, finish-line checklists, and deterministic guardrails live in lower-cost tiers. Per-repo `CLAUDE.md` overrides anything here.

**Where my config lives** (synced from `~/dotclaude`; see its README):

- **This file** — universal behavioral rules. Always loaded.
- **`~/.claude/rules/*.md`** — stack conventions, **path-scoped** so each loads only when I open matching files.
- **`~/.claude/skills/finishing-work`** — finish-line procedure (definition of done, follow-ups, PR body, cleanup).
- **`~/.claude/skills/managing-work-with-issues`** — GitHub-issue lifecycle (claim-on-begin, taxonomy, follow-up discipline, feedback triage).
- **`~/.claude/hooks/`** — deterministic guardrails that fire even under `bypassPermissions`. `git-guard.sh` blocks `--no-verify`, `.env` commits, force-push to `main`, reckless `rm -rf`; `worktree-guard.sh` blocks edits to the main working tree of a `.worktrees/` repo (`WORKTREE_GUARD_OFF=1` overrides); `verify-reminder.sh` nudges to verify before a PR. Treat a block as a hard limit — fix the cause, never route around it.

---

## Workflow rules — always apply

### Autonomy — drive every task to completion

Own each feature/bug end-to-end without checkpoint questions. The whole arc is one task: **plan → implement → test → self-review → address findings → ship.**

- Don't stop between stages to ask "should I continue?" / "linear or subagents?" — the answer is always yes, keep going, use subagents.
- **Make industry-standard assumptions and proceed.** Pick the conventional best-practice option, note it in one line, move on. A wrong assumption is cheap (visible in the diff); a stalled task costs more. The bar for stopping is "a competent engineer genuinely couldn't pick without more info" — not "I'd feel safer confirming."
- Bundle non-blocking questions into the **final summary**, not mid-task interruptions.

**How far you carry it — autonomy mode is per-repo**, declared by a top line in the repo's `CLAUDE.md`. **When unspecified, assume `gated`.**

- **`gated` (default)** — carry to a **PR ready to merge**, then stop. Merging to `main`, deploying, destructive data ops, force-push, and anything outward-facing are mine (e.g. adventureOS, until I say otherwise).
- **`autonomous-merge` (opt-in)** — repos declaring `Autonomy: autonomous-merge` (musclebuddy, redthread, dotclaude). Carry past the PR: **once reviewed, findings addressed, and CI green ⇒ merge it yourself — don't park it.** Merge feature → `dev` (or → `main` in single-tier repos like dotclaude), and promote `dev → main` in batches of related work, not one commit at a time. Run any DB operation the task needs — including destructive/prod ones — under the same review + CI discipline (`list_tables`/`get_advisors` first; reversible migrations where you can). Still mine: force-push to `main`.

**CI is the gate in every mode: never merge or promote on red or pending checks** — fix it or stop, never route around it (no `--admin`, no skipping required checks).

**When you MAY stop and ask** (narrows under `autonomous-merge`, always applies):
- **Big architecture forks / one-way doors** — framework, data model, auth model, public API shape.
- **Genuinely ambiguous intent** where reasonable engineers would build materially *different* things — and only after trying to resolve it from code, docs, and my MCPs (Notion specs, etc.) first.
- **(`gated` only)** the irreversible final actions above.

Everything else: decide and move. In doubt between asking and proceeding on a reasonable default, **proceed.**

### Issues are the tracker; finish in-scope work

**Scope call first.** Small and relevant to the task → fix it inline, don't defer. **In-scope work gets finished, not filed** — half-doing a task and filing the rest is a failure, not tidiness.

The issue lifecycle lives in the **`managing-work-with-issues`** skill; load it when you start, create, or finish tracked work. Essentials:

- **Claim before you work** (`issue_claim` = self-assign + `status:in-progress`). Don't work an unclaimed issue.
- **A follow-up issue is only for** (a) a finding genuinely out of scope, or (b) a blocker needing a human decision that halts autonomous progress. Not for in-scope work you could finish now.
- Issues carry full fields (type, status, `file:line` in body, relationships/milestone where known) and no assignee until claimed. Reference from the PR (`Closes #N`) and list them — with status — in the final summary.
- User-reported feedback (musclebuddy/redthread/adventureos) is filed `status:blocked` and never auto-started — verify first.
- Creating issues in my own repos is pre-approved.

### Default to parallel + subagents

- Non-trivial features/bugs are **subagent-driven by default** (`superpowers:subagent-driven-development`). Reserve inline execution for small, single-file, low-risk changes.
- Run independent work **in parallel** (`superpowers:dispatching-parallel-agents`); always batch independent tool calls into one message.
- **Plan as a dependency graph, not a linear list.** A step being listed first doesn't make it a prerequisite — serialize only true dependencies, launch every unblocked branch concurrently, cheapest mechanism first.
- **Escalation ladder**: inline → one subagent (token-heavy / needs context isolation) → parallel subagents or a `Workflow` (independent slices, fan-out review) → agent teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, ~7× tokens — only when I ask or for exceptional parallel-*independent* scale: multi-angle research/review, competing-hypothesis debugging, or a clean frontend/backend/tests split). Default to subagents/Workflow.
- Built-in skill "review checkpoints" (`executing-plans`, `requesting-code-review`, `finishing-a-development-branch`) are pre-approved for routine work — run the review, address findings, continue; surface results in the summary, not as a gate.
- `brainstorming` is for greenfield/ambiguous work; skip it for a well-specified feature/bug.
- **Every dispatched subagent verifies before reporting "done"** — bake into the dispatch prompt: run the checks relevant to its slice (typecheck + affected tests) and include the output. A "done" without evidence is a claim, not a fact.

### Worktree-first for code changes

Before any code changes in a repo with `.worktrees/` (gitignored), set up an isolated worktree (`superpowers:using-git-worktrees`) — multiple sessions in one checkout conflict. Skip for read-only work (questions, reviews, exploration, running tests). Enforced by `worktree-guard.sh`, which blocks main-tree edits in a `.worktrees/` repo (the config repo is auto-exempt; `WORKTREE_GUARD_OFF=1` overrides).

### Stay current with the default branch

Stale bases cause avoidable conflicts and reviews against moved code.

- **Starting a batch**: sync first (`git checkout main && git pull`) and cut your branch off freshly-pulled `main` — or `dev`, the integration branch in two-tier repos: branch off and merge back into `dev`, then promote in batches.
- **During longer work**: periodically `git fetch origin && git rebase origin/main` (or `dev`) so the diff stays small. Resolve any conflicts as part of the work, not at merge time.

### Verify before you push or open a PR

A push and a PR are **handoffs** — never make them on unverified work. Run the checks relevant to what you changed and report the output (`superpowers:verification-before-completion` — evidence before assertions):

- **Always**: typecheck + tests affected by your change. **When relevant**: the build, if you touched build-affecting code (config, deps, codegen, bundler/route setup).
- This is *your* fast, change-scoped local check, not a whole-suite gate — local hooks are deliberately fast (pre-commit = gitleaks + lint-staged, pre-push = typecheck), full build/unit/e2e live in CI by design.
- **Self-review and verify locally *before* opening the PR; then open it ready — not draft.** So the first thing CI ever sees is already self-reviewed and green. CI minutes are a shared, metered resource — keep a repo's CI cheap and non-stacking (see `rules/ci.md`).
- **Never use CI as the debugging loop.** No `workflow_dispatch` / re-runs / repeat pushes to chase a failure (flaky tests, env-dependent bugs) — reproduce and fix locally first (write down the local recipe via `claude-md-management:revise-claude-md` if missing). Manual triggers are for what genuinely can't be reproduced locally (e.g. a hosted data-plane connection), not debug-by-rerun.

### Finishing a task

Done isn't "PR opened" — it's the checkout **clean, on the default branch, pulled current**, no stray worktrees or dead branches. Run the **`finishing-work`** skill at the finish line (definition-of-done, follow-up flow, PR-body standard, cleanup; alongside `superpowers:finishing-a-development-branch`). Never delete a worktree/branch with uncommitted or unpushed work without flagging it first.

### Git hygiene

- **Conventional commits**: `feat:` `fix:` `chore:` `docs:` `refactor:` `test:` `perf:` `style:` `ci:` `build:` `revert:` (most repos enforce with commitlint).
- **Never `--no-verify`**, **never commit `.env`** (only `.env.example`; use `vercel env pull`) — both hook-blocked; fix the real failure (rotate a leaked secret, fix lint/types), don't bypass.
- If a hook fails and you fix it, make a **NEW** commit — don't `--amend` (the original commit didn't happen).

### Write for the final state, not the journey

Docs, PR descriptions, comments, and code describe **what is** — never how it got there; git is the changelog.

- **PR descriptions / docs**: write the final state once — no incremental narration ("first I tried X"), no running-diary edits as you work.
- **Code comments**: only ones that earn their place (why something non-obvious exists, a gotcha, an invariant). Never "what changed" / "previously this did X"; no commented-out tombstones.
- **Keep the WHY, drop the WHEN/WHO.** The rule above and "explain why non-obvious things exist" pull against each other, and the tie is broken toward the war story every time — that's how a doc rots into an incident log. A constraint is what *is* true and must stay true; the incident that taught it is history. State the constraint, then stop. If a reader would behave identically without a clause, it's journey — cut it.
  - ✅ "The exercise pool self-heals on boot when the DB is populated-but-partial: a partial table silently shadows the KB, making those exercises unreachable and earning zero rank credit."
  - ❌ "…it shipped that way twice (#1426 at 48-vs-138, #1522 at 138-vs-314) before the self-heal landed."
  - An issue ref is fine as a *pointer* (`see #123`), never as the explanation. If the constraint only makes sense as a story, you haven't found the constraint yet.
  - Runbook steps ("run AFTER the new server is live") are instructions, not narration — keep them.
- **Delete dead code** — deprecated/legacy/unused/superseded goes; git history holds anything you'd need back.
- **One source of truth for machine-checkable facts** — don't hand-maintain a second copy of what code already defines (pricing/tier/config table, API surface); generate or tag-link derivatives and CI-guard the drift.
- Never create ephemeral summary docs (`INTEGRATION_SUMMARY.md`, `CHANGES.md`, `WHAT_I_DID.md`) — the diff and commit message are the record. Permanent docs (architecture, runbooks) belong in the existing docs tree.

---

## Stack defaults

Default stack — TypeScript strict, Next.js App Router / Vite, Prisma, Zod, Supabase Auth, Vercel/Railway, pnpm/npm workspaces, Vitest/Jest + Playwright, Tailwind — documented in **`~/.claude/rules/*.md`**, path-scoped. Per-repo `CLAUDE.md` overrides. If a rule repeats across 3+ repos, hoist it into a rule file.

## MCPs — prefer over generic tools

Use configured MCPs instead of WebFetch / WebSearch / shell when relevant: **Supabase** (`list_tables` before schema changes; `get_logs` + `get_advisors` before debugging), **Prisma**, **Stripe**, **Playwright** (verify UI live), **Vercel** (deploys/logs), **Notion** (specs/playbooks), **Gmail / Calendar / Drive**, **PubMed** (MuscleBuddy), **Spotify** (RedThreadEvents). Schemas are deferred via tool-search — search when you need one. Never put service-role or secret keys in client-bundled code.

## Communication preferences

- **No status summaries.** Say it once — the diff is the record.
- **Landing the turn, scaled to the stop.** Simple turns (Q&A, a recommendation, a one-line confirmation): one or two sentences, then stop. **Handoff stops** (work paused mid-task, a decision pending, between phases) end with a short *forward-looking* block — what happens next, not a recap — rendering only lines that have content (never "Blockers: none"):
  - **Blockers / risks** — what's stopping progress or could bite.
  - **Decisions needed** — what you need from me to proceed.
  - **Next steps** — concrete actions, each tagged `(you)` or `(me)`.
- For exploratory questions ("what should we do about X"), reply with a recommendation + main tradeoff in 2–3 sentences. Don't implement until I agree.
