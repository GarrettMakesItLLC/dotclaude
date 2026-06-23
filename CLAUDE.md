## About this repo (dotclaude)

This file lives in `~/dotclaude/CLAUDE.md` and is **symlinked** to `~/.claude/CLAUDE.md` by `bootstrap.sh`. Editing it here changes the global instructions loaded into every future Claude Code session on this machine. Same applies to `settings.json` and `keybindings.json` — they're symlinks, not copies.

**Layout:**
- `CLAUDE.md` — this file (global instructions, symlinked)
- `settings.json` — `enabledPlugins`, marketplace, permissions (symlinked)
- `keybindings.json` — chord/key overrides (symlinked)
- `bootstrap.sh` — idempotent installer; symlinks the three files above into `~/.claude/`, backs up any real files it finds to `~/.claude.bak.<timestamp>/`
- `plugins.md` — human-readable inventory of what each enabled plugin is for
- `README.md` — setup/update workflow for a fresh machine
- `.gitignore` — keeps machine-local state (sessions, history, credentials, caches) out of the repo

**Plugin model:** plugins are *declared*, not vendored. `settings.json` lists them under `enabledPlugins`; Claude Code auto-installs from `anthropics/claude-plugins-official` on next launch. To add one: edit `settings.json`, update `plugins.md`, commit. To browse what's available: `/plugin marketplace browse claude-plugins-official`.

**What's intentionally NOT here:** per-project `.claude/` folders, session/history/cache files, top-level MCP OAuth state (Notion, Gmail, Vercel etc. live in `~/.claude.json` per-machine), vendored plugin source. See `README.md` "What's intentionally NOT here" for rationale.

**Workflow for changes:**
1. Edit the file here in `~/dotclaude/`
2. `git add -A && git commit -m "feat: …" && git push` (conventional commits enforced)
3. Symlinks already point at the repo — changes apply on next Claude session
4. On other machines: `cd ~/dotclaude && git pull`

**Gotcha:** if `bootstrap.sh` is re-run after manual edits to `~/.claude/CLAUDE.md` (the symlink target), it will detect a non-symlink, move it to `~/.claude.bak.<timestamp>/`, and re-link from the repo. Real edits should always happen here in the repo, not in `~/.claude/`.

---

# Global CLAUDE.md (Garrett)

Loaded from `~/.claude/CLAUDE.md` for every Claude Code session. Per-repo `CLAUDE.md` files override anything here.

---

## Workflow rules — always apply

### Autonomy — drive every task to completion

When I hand you a feature or bug, **own it end-to-end without checkpoint questions.** The whole arc is one task, not six approvals:

**plan → implement → test → self-review → address review findings → PR-ready**

- Don't stop between stages to ask "should I continue?" / "want me to move on?" / "should I implement now?" / "linear or subagents?". The answer is always: yes, keep going, use subagents. Carry the work to a PR that's ready to merge.
- The only hard stop is the **irreversible final action**: opening the PR is yours to do, but **merging to `main`, deploying, destructive data ops, force-push, and anything outward-facing/published are mine.** Take it right up to that line and stop there.
- **Make industry-standard assumptions and proceed.** Pick the conventional, best-practice option, note it in one line, and keep moving. A wrong assumption is cheap — it's visible in the diff and trivial to fix. A stalled task costs me more.
- **Default to your best guess. Use common sense.** The bar for stopping is "a competent engineer genuinely couldn't pick without more info," not "I'd feel safer confirming." If you can name the obvious right answer, take it. Asking when the answer was obvious is itself a mistake — I'd rather correct a reasonable guess than be interviewed.
- Bundle any non-blocking questions or flagged choices into the **final summary**, not as mid-task interruptions.

**When you MAY stop and ask** — only when guessing wrong is genuinely costly:
- **Irreversible / hard-to-undo**: prod migrations, deletes, merges, deploys, force-push, anything published or outward-facing.
- **Big architecture forks / one-way doors**: choice of framework, data model, auth model, public API shape, or anything expensive to reverse later.
- **Genuinely ambiguous intent** where reasonable engineers would build materially *different* things — and only after you've tried to resolve it from the code, docs, and my MCPs (Notion specs, etc.) first.

Everything else: decide and move. When in doubt between asking and proceeding on a reasonable default, **proceed.**

### Fix what's relevant; track-and-tackle the rest

**Scope call first.** If something you notice is small and relevant to the task at hand, just fix it inline — don't ask. If it's **big, risky, or unrelated** to the current task, don't sprawl the diff to chase it: capture it instead.

When you defer something — out of scope, a leftover TODO, a "we should also…", a known limitation, a flagged risk — **open a GitHub issue for it** (`gh issue create`) instead of only mentioning it in the summary or dropping a bare `// TODO` in the code. Follow-up work must not evaporate into chat history.

- Title it clearly; give it a short body (what + why + a `file:line` pointer); apply a label if the repo uses them.
- **Don't just file it and walk away.** Once the issue is open, **dispatch a subagent to address it** — in its own worktree, in parallel with the main task — rather than leaving it for "later." Default to tackling follow-ups now. Only leave one un-started if it's genuinely blocked, needs my input, or truly belongs in a separate session — and say which in the summary.
- Reference each issue from the PR ("Follow-up: #123") and list every issue you opened — with its status (agent working it / blocked / parked) — in the final summary.
- Batch related follow-ups into one issue rather than spamming many tiny ones. If you're unsure something is worth tracking, it probably is — open it; closing a stray issue is cheaper than losing the thread.
- Creating issues in my own repos is **pre-approved** — it's the one outward-facing action you may take without asking, since it's just bookkeeping in my tracker. (Opening the PR itself still stops at the line in the Autonomy rule.)

### Default to parallel + subagents

- Non-trivial features and bugs are **subagent-driven by default** (`superpowers:subagent-driven-development`) — don't ask which mode. Reserve linear/inline execution for genuinely small, single-file, low-risk changes.
- Run independent work **in parallel** (`superpowers:dispatching-parallel-agents`): parallel exploration, parallel implementation of independent slices, parallel review dimensions. Always batch independent tool calls into one message.
- Built-in "review checkpoints" in skills (`executing-plans`, `requesting-code-review`, `finishing-a-development-branch`) are **pre-approved** for routine work. Run the review, address what it finds, and continue — surface results in the final summary, not as a gate.
- `brainstorming` is for genuinely greenfield or ambiguous work. For a well-specified feature/bug, skip it: proceed on best-practice assumptions instead of opening a Q&A.

### Worktree-first for code changes

Before making any code changes in a repo with `.worktrees/` (gitignored), set up an isolated worktree using the `superpowers:using-git-worktrees` skill. Multiple Claude sessions in the same checkout will conflict.

```bash
git worktree add .worktrees/<short-name> -b feature/<short-name>
cd .worktrees/<short-name>
```

Skip for read-only work: questions, reviews, exploration, running tests without changes.

### Leave the workspace clean and ready

A task isn't done when the PR is open — it's done when the checkout is back to a **clean, ready state** for the next task. Don't leave stray worktrees, dead branches, or a detached/feature-branch HEAD behind.

After finishing (`superpowers:finishing-a-development-branch`):
1. Remove the worktree you created, from the main checkout: `git worktree remove .worktrees/<short-name>`.
2. Delete the local feature branch once it's merged or its PR is open: `git branch -d feature/<short-name>` (`-D` only if I've explicitly abandoned it).
3. Return the main checkout to the default branch and bring it current: `git checkout main && git pull`.
4. Verify: `git status` is clean and `git worktree list` shows no leftovers.

Guardrails:
- **Never** delete a worktree or branch that has uncommitted or unpushed work without flagging it first. If a branch isn't merged and has no PR, stop and ask before deleting.
- Use `commit-commands:clean_gone` to sweep branches whose remotes are already deleted (`[gone]`) plus their worktrees.
- End the turn on the default branch with a clean tree, so the next task starts fresh — confirm this in the final summary.

### No ephemeral summary docs

Never create files like `INTEGRATION_SUMMARY.md`, `CHANGES.md`, `WHAT_I_DID.md`, or any document whose purpose is summarizing what just happened. The diff and the commit message are the record. Permanent docs (architecture, runbooks) belong in the existing docs tree.

### Don't bypass git hooks

Never use `--no-verify` on commit or push unless I explicitly ask. If a pre-commit hook fails:
- gitleaks flagged a real secret → rotate it, don't allowlist
- lint-staged failed → fix the lint/format issue
- typecheck failed → fix the types

If a hook fails and you fix the issue, create a NEW commit. Don't `--amend` after a hook failure (the original commit didn't happen).

### Conventional commits

`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `perf:`, `style:`, `ci:`, `build:`, `revert:`. Most repos enforce this with commitlint.

### Never commit `.env`

Only `.env.example` is tracked. Use `vercel env pull` to populate local `.env` files.

### Definition of done

Before calling work complete or opening a PR, this must actually pass — run the commands, don't assume:

- [ ] Typecheck and lint clean (`--max-warnings 0` where CI enforces it).
- [ ] Tests pass — existing plus new ones covering the change.
- [ ] App runs / change verified live where feasible (`superpowers:verification-before-completion`).
- [ ] No debug logging, commented-out code, dead code, or stray scratch files in the diff.
- [ ] No unrelated / scope-creep changes in the diff (those went to follow-up issues).
- [ ] Diff self-reviewed; no secrets committed; `.env` not staged.
- [ ] Workspace left clean and on the default branch (see "Leave the workspace clean and ready").

If any box can't be checked, **say so explicitly in the summary** — never present unfinished or unverified work as done.

### PR descriptions

A PR body I'd actually merge has:

- **What & why** — one or two sentences on the change and the motivation, not a file-by-file restatement of the diff.
- **Test evidence** — what you ran and that it passed (typecheck / tests / manual verification).
- **Linked follow-ups** — "Follow-up: #123" for every issue opened off this work; `Closes #N` for any it fully resolves.
- **Screenshots / notes** for UI changes or anything reviewer-visible.

Conventional-commit-style title. Keep it tight.

---

## Default stack assumptions

These are the defaults across my repos. Per-repo `CLAUDE.md` overrides if a project differs.

### TypeScript

- **Strict mode everywhere.** No `any` — use `unknown` and narrow.
- `import type { ... }` for type-only imports (`consistent-type-imports: error`).
- All promises must be awaited or explicitly voided (`no-floating-promises`, `no-misused-promises`).
- Unused vars allowed only with `_` prefix.
- ESLint runs with `--max-warnings 0` in CI.

### Frameworks & data

- **Next.js (App Router)** for new web apps; Vite + React for older / PWA repos.
- **Prisma** for all database access — no raw SQL.
- **Run `prisma generate`** after `npm ci` / `pnpm install` and after any schema change.
- **Zod at every API boundary.** Never trust raw `req.body` or untyped query params.
- **Supabase Auth** for auth where present. Two clients, never crossed: `supabaseServer()` (RSC/actions/handlers) vs `supabaseBrowser()` (`'use client'` only). Service-role key is server-only.

### Hosting

- **Vercel** for frontends (Next.js + Vite both deploy here).
- **Railway** for separate backend services (Fastify) when not deployable on Vercel.
- Postgres + Redis usually via Vercel Marketplace (Neon + Upstash) or Supabase.

### Monorepos

- pnpm workspaces (newer repos: AdventureOS) or npm workspaces (older: MuscleBuddy, RedThreadEvents).
- Common layout: `apps/web/`, optionally `apps/server/`, `packages/{engine,types,ui,database}/`.
- `packages/engine` (where present) is **pure deterministic logic** — no I/O, no DB, no Node built-ins. Fully unit-testable.
- Web app never imports from server package; comms via REST only.

### Testing

- Unit tests (Vitest or Jest) for pure logic.
- **Integration tests hit a real database** — never mock Prisma.
- E2E via Playwright.
- Coverage thresholds enforced on engine packages where defined.

### Frontend conventions

- Tailwind for styling.
- Dark mode (`dark:` variants) required on new components.
- WCAG 2.1 AA contrast.
- Lucide icons (when an icon set isn't otherwise specified).
- For Next.js i18n repos: never hardcode English strings in JSX — use `useTranslations`.

---

## MCPs available — prefer over generic alternatives

I have these MCP servers configured. Use them instead of WebFetch / WebSearch / shell scripting when relevant.

**From plugins (auto-installed via `enabledPlugins`):**

- **Supabase MCP** — schema introspection, migrations, advisors, logs, edge functions. Use `list_tables` before schema changes, `get_logs` + `get_advisors` before debugging.
- **Stripe MCP** — Stripe API surface, account ops, billing.
- **Prisma MCP** — Prisma schema/client interactions.
- **Playwright MCP** — full browser control (navigate, click, screenshot, network, console). Use to verify UI changes and run E2E flows live.
- **GitHub plugin** (not MCP, but plugin tooling) — beyond `gh` for repo/PR/issue ops.

**Top-level MCPs (configured in `~/.claude.json`, per-machine OAuth):**

- **Vercel MCP** — deployments, build logs, runtime logs, projects.
- **Notion MCP** — search pages, fetch docs, query databases. Many specs / playbooks live here.
- **Gmail MCP / Google Calendar MCP** — read/draft emails, manage calendar events.
- **Google Drive MCP** — fetch shared docs.
- **PubMed MCP** — for MuscleBuddy research-backed features.
- **Spotify MCP** — for RedThreadEvents karaoke metadata.

Never expose Supabase service-role keys, Stripe secret keys, or Vercel tokens in client-bundled code.

---

## Communication preferences

- **No status summaries.** Don't repeat what was done multiple times. Say it once and move on. The diff is the record.
- **Brief end-of-turn summaries only** — one or two sentences. What changed and what's next.
- **Verify before claiming done.** Run typecheck / tests / start the dev server before asserting something works. Use `superpowers:verification-before-completion`.
- For exploratory questions ("what should we do about X"), respond with a recommendation + main tradeoff in 2–3 sentences. Don't implement until I agree.

---

## Per-repo override pattern

Project repos define their own `CLAUDE.md`, plus `.claude/rules/<rule>.md` for repo-specific conventions (e.g., `worktree-first.md`). Repo files always win. This file is just the baseline so I don't have to repeat the same rules in every repo.
