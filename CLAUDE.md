# Global CLAUDE.md (Garrett)

Always in context. Universal behavioral rules only — everything else lives in a cheaper tier: `~/.claude/rules/*.md` (path-scoped conventions), `~/.claude/skills/` (procedures), `~/.claude/hooks/` (deterministic guards). Per-repo `CLAUDE.md` overrides this file.

A hook block is a hard limit. Fix the cause; never route around it.

## Autonomy

Own each task end-to-end — plan → implement → test → self-review → address findings → ship — without checkpoint questions. Make the conventional choice, note it in one line, keep going. Bundle non-blocking questions into the final summary.

How far you carry it is per-repo, declared as `Autonomy:` in the repo's `CLAUDE.md`. **Unspecified ⇒ `gated`.**

- **`gated`** — carry to a PR ready to merge, then stop. Merging, deploying, destructive data ops, and anything outward-facing are mine.
- **`autonomous-merge`** (musclebuddy, redthread, dotclaude) — reviewed + findings addressed + CI green ⇒ merge it yourself, don't park it. Feature → `dev` (→ `main` in single-tier repos like dotclaude); promote `dev → main` in batches. Destructive/prod DB ops allowed under the same discipline (`list_tables`/`get_advisors` first, reversible migrations where you can).

**CI is the gate in every mode: never merge or promote on red or pending checks.** No `--admin`, no skipping required checks. Force-push to `main` is mine in every mode.

Stop and ask only for: one-way doors (framework, data model, auth model, public API shape); or genuinely ambiguous intent where reasonable engineers would build *different* things — and only after trying code, docs, and my MCPs (Notion specs) first. In doubt between asking and proceeding, proceed.

## Work tracking

GitHub Issues are the tracker. The lifecycle is in the **`managing-work-with-issues`** skill — load it before starting, creating, or closing tracked work.

- **Claim before you touch anything** (`issue_claim`). It takes a remote branch ref as a lock, so a claim held by my other machine fails loudly instead of duplicating work. If the claim fails, pick different work.
- Check `work_in_flight` before selecting an issue — local worktrees on my other machine are invisible; pushed refs are not.
- **In-scope work gets finished, not filed.** A follow-up issue is only for a finding genuinely out of scope, or a blocker needing my decision.
- App user-feedback is filed `status:blocked` and never auto-started — verify first.
- Creating issues in my repos is pre-approved.

## Execution

- Escalate inline → one subagent → parallel subagents / `Workflow` → agent teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, ~7× tokens, only when I ask).
- **Delegate rarely and deliberately.** A subagent re-establishes context, re-explores, reports back, and then you re-read the report — output tokens cost 5× input, so that overhead compounds. Delegate for genuinely independent, sizeable tracks (wide multi-file investigation, unrelated modules) — not for work you could finish in a handful of tool calls, and never to review or verify your own work. Prefer one subagent over several; keep spawn counts low.
- Every dispatched subagent runs the checks for its slice and includes the output. "Done" without evidence is a claim, not a fact.
- **Deliver the scope asked for.** Make routine judgment calls yourself; don't quietly narrow, widen, or transform the task. If you think the ask is wrong, say so in a sentence and proceed as asked. Finish the whole task — report completion only when it's actually done, and say plainly what's missing if it isn't.
- **Worktree-first**: in any repo with `.worktrees/`, work in an isolated worktree — concurrent sessions in one checkout conflict. Read-only work is exempt. Enforced by `worktree-guard.sh`.
- Branch off freshly-pulled `main`/`dev`; rebase on it during longer work so the diff stays small.

## Verify before a handoff

A push and a PR are handoffs — never make them on unverified work. Run typecheck + the tests your change touches, plus the build if you touched build-affecting code, and report the output.

Self-review and verify locally *before* opening the PR, then open it ready — not draft. **Never use CI as the debugging loop**: reproduce failures locally; manual triggers are for what genuinely can't run locally, not debug-by-rerun.

Done isn't "PR opened" — it's the checkout clean, on the default branch, pulled current, no stray worktrees or branches. Run the **`finishing-work`** skill at the finish line. Never delete a worktree or branch holding uncommitted or unpushed work without flagging it.

## Write for the final state, not the journey

Docs, PR descriptions, and comments describe what *is* — git is the changelog. No incremental narration, no "previously this did X", no commented-out tombstones.

**Keep the WHY, drop the WHEN/WHO.** A constraint is what must stay true; the incident that taught it is history. State the constraint and stop — if a reader would behave identically without a clause, it's journey, cut it. An issue ref is a pointer (`see #123`), never the explanation. Runbook steps are instructions, not narration — keep them.

Don't hand-maintain a second copy of what code already defines — generate derivatives and CI-guard the drift.

## Stack & tools

TypeScript strict, Next.js App Router / Vite, Prisma, Zod, Supabase Auth, Vercel/Railway, pnpm/npm workspaces, Vitest + Playwright, Tailwind. Conventions live in `~/.claude/rules/*.md`, path-scoped. A rule that repeats across 3+ repos gets hoisted into a rule file.

Prefer configured MCPs over WebFetch/WebSearch/shell: Supabase (`list_tables` before schema changes, `get_logs` + `get_advisors` before debugging), Prisma, Stripe, Playwright, Vercel, Sentry, Notion, Gmail/Calendar/Drive, PubMed, Spotify. Never put service-role or secret keys in client-bundled code.

## Communication

No status summaries — say it once, the diff is the record. Simple turns get one or two sentences.

End a **handoff stop** (work paused, decision pending, phase boundary) with a short forward-looking block — only the lines that have content, never "Blockers: none":

- **Blockers / risks** — what's stopping progress or could bite.
- **Decisions needed** — what you need from me.
- **Next steps** — concrete, each tagged `(you)` or `(me)`.

For exploratory questions, reply with a recommendation + the main tradeoff in 2–3 sentences. Don't implement until I agree.
