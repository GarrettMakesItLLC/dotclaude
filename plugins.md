# Plugins

26 plugins enabled, all from `anthropics/claude-plugins-official`. Declared in `settings.json` under `enabledPlugins` — Claude Code auto-installs them on first launch.

## Stack-specific (use what you actually deploy)

| Plugin | Purpose | Where I use it |
|--------|---------|----------------|
| `vercel` | Deployments, env vars, AI SDK, Next.js, shadcn, routing middleware, functions, firewall, Workflow DevKit | Every frontend |
| `railway` | Railway infra ops — services, DBs, buckets, deployments, logs | RedThreadEvents + MuscleBuddy backends |
| `supabase` | Supabase Database/Auth/Edge Functions/Realtime/Storage/Vectors. **Includes MCP server** for schema introspection, migrations, advisors, logs | Every repo with auth/DB |
| `stripe` | Stripe API + Connect + Billing best practices, test cards, error explanation, upgrade guidance. **Includes MCP server** | MuscleBuddy + RedThreadEvents (Stripe Connect) |
| `prisma` | Prisma schema/client guidance. **Includes MCP server** | Every repo with a database |
| `playwright` | Browser automation for E2E tests + UI verification. **Includes MCP server** with full browser control | E2E tests + verifying UI in dev |
| `github` | GitHub operations beyond `gh` CLI | PRs, issues, repo management |
| `sentry` | Error monitoring — SDK setup, feature config (AI/LLM tracing, alerts), and `/seer` workflow for fixing production issues with Sentry context. **Includes MCP server** | Deployed apps (error triage + SDK wiring) |
| `resend` | Transactional email — Resend API, React Email, deliverability/compliance best practices, agent email inbox. **Includes MCP server** (needs `RESEND_API_KEY`) | Any app sending email |
| `redis-development` | Redis best-practices skills — data structures, query engine, vector search, caching, clustering, observability, security. Skills only, no MCP | Caching / vector search layers |

## Workflow & process

| Plugin | Purpose |
|--------|---------|
| `superpowers` | Workflow discipline — TDD, debugging, brainstorming, worktrees, code review, verification, plan execution, parallel agents. The most-used plugin. |
| `feature-dev` | Guided feature development — codebase analysis → architecture plan → implementation. For non-trivial features. |
| `code-review` | Independent code review pass on a branch / PR |
| `pr-review-toolkit` | Multi-agent comprehensive PR review |
| `commit-commands` | `commit`, `commit-push-pr`, `clean_gone` (purge stale local branches that are gone on remote) |

## Editor / language tooling

| Plugin | Purpose |
|--------|---------|
| `typescript-lsp` | TypeScript language server integration |
| `pyright-lsp` | Python (Pyright) language server integration |

## Claude Code meta-tools

| Plugin | Purpose |
|--------|---------|
| `claude-md-management` | Audit + improve CLAUDE.md files; revise from session learnings |
| `claude-code-setup` | Recommends Claude Code automations (hooks, agents, skills, plugins, MCPs) for a given codebase |
| `hookify` | Create hooks from conversation analysis or explicit instructions |
| `skill-creator` | Create new skills, edit existing, run evals to measure performance |
| `plugin-dev` | End-to-end plugin creation workflow |
| `mcp-server-dev` | Build MCP servers (remote HTTP, MCPB, local stdio) + bundle as MCPB packages |

## Business / GTM (launch-readiness for consuming products)

Not dev-stack tooling — these support launching and growing the products the repos serve. Each is a hosted (HTTP) MCP server.

| Plugin | Purpose |
|--------|---------|
| `legalzoom` | Business legal assistance — `/review-contract` (risk-scored contract analysis + redlines) and `/attorney-assist` (LegalZoom attorney with full conversation context). Not legal advice; AI output needs review by a qualified professional. |
| `zoominfo` | B2B go-to-market intelligence — prospect lists, account/contact enrichment, buyer-intent signals, decision-maker lookup, TAM/ICP sizing, meeting prep. |

> **Removed:** `atomic-agents` — investigated and dropped. It's tooling for the **Atomic Agents Python framework** (BrainBlend AI): scaffolding/auditing apps built on that specific framework. My stack is TS/Next.js/Vercel/Supabase, so it added skills + 2 subagents to every session for nothing. Re-add `"atomic-agents@claude-plugins-official": true` to `settings.json` if I ever pick up that framework.

## User-installed skills

Both user skills are **vendored in this repo** under `skills/` and symlinked into `~/.claude/skills/` by `bootstrap.sh`, so a fresh machine gets them automatically:

- `finishing-work` — my personal finish-line procedure (definition of done, follow-ups, PR body, cleanup).
- `find-skills` — skill discovery; not in any plugin, so the repo is its source of truth.

All domain skills (Supabase, etc.) come from plugins.

## MCP servers added by plugins

These run automatically once the plugin is installed and you've authenticated:

| MCP | Plugin | Auth |
|-----|--------|------|
| Supabase MCP | `supabase` | OAuth via `mcp__plugin_supabase_supabase__authenticate` |
| Stripe MCP | `stripe` | OAuth via `mcp__plugin_stripe_stripe__authenticate` |
| Prisma MCP | `prisma` | OAuth via `mcp__plugin_prisma_Prisma-Remote__authenticate` |
| Railway MCP | `railway` | OAuth via `mcp__plugin_railway_railway__*` (read-only ops allowlisted in `settings.json`) |
| Playwright MCP | `playwright` | None (local browser control) |
| Sentry MCP | `sentry` | OAuth (Sentry account) — used by `/seer` and the Sentry workflow skills |
| Resend MCP | `resend` | HTTP — Bearer `RESEND_API_KEY` (set per-machine in the environment, **never committed**) |
| LegalZoom MCP | `legalzoom` | HTTP — needs the LegalZoom connector enabled in Claude app settings (+ Business Attorney Plan for `/attorney-assist`) |
| ZoomInfo MCP | `zoominfo` | HTTP (`mcp.zoominfo.com`) — ZoomInfo account auth |

(`redis-development` ships skills only — no MCP server.)

Plus separately-configured top-level MCPs (Notion, Gmail, Calendar, Drive, PubMed, Spotify, Vercel) live in `~/.claude.json` and are NOT in this repo — they're per-machine OAuth state.

## Custom MCPs (vendored in this repo)

Unlike marketplace plugins (declared, not vendored), these are servers I built — their source lives in `mcp/`. `bootstrap.sh` installs deps, builds, and registers them with `claude mcp add` (user scope).

| MCP | Source | Auth | Purpose |
|-----|--------|------|---------|
| `github-rest` | `mcp/github/` | Reuses `gh auth token` at runtime | Local stdio server wrapping the GitHub **REST** API (PR + issue + repo ops). Built because the `gh` CLI / `github` plugin route PR ops through GraphQL, which fails on the deprecated `projectCards` field. REST-only — so no `projectCards` error and no `jq` dependency. **Prefer it over `gh pr ...` for PR/issue edits.** See `mcp/github/README.md`. |

## Discovering more

```
/plugin marketplace browse claude-plugins-official
```

Or browse the marketplace repo: <https://github.com/anthropics/claude-plugins-official>
