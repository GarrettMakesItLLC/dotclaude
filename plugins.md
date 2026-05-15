# Plugins

Plugins are declared in `settings.json` under `enabledPlugins` and auto-install from `anthropics/claude-plugins-official` on first launch.

## Currently enabled

| Plugin | Purpose | Why I use it |
|--------|---------|--------------|
| `vercel` | Vercel CLI, deployments, env vars, AI SDK, Next.js, shadcn, routing middleware, functions | Every frontend deploys to Vercel. Bundles Next.js + shadcn + AI SDK guidance. |
| `railway` | Railway infra ops — services, DBs, buckets, deployments, logs | RedThreadEvents and MuscleBuddy backends run on Railway. |
| `frontend-design` | Distinctive, production-grade UI generation that avoids generic AI aesthetics | Marketing pages + new UI work across all repos. |
| `superpowers` | Workflow discipline — TDD, debugging, brainstorming, worktrees, code review, verification, plan execution, parallel agents | The single most-used plugin. Drives my workflow. |
| `feature-dev` | Guided feature development with codebase understanding | For non-trivial features that need a plan + architecture pass before code. |
| `code-review` | Code review on PRs / branches | Independent review pass before merging. |

## Worth considering

These are not currently installed. Add to `settings.json` if/when relevant.

| Plugin | When to add |
|--------|-------------|
| Postgres / database tooling plugins | If a Supabase or generic-Postgres plugin appears in the marketplace beyond the existing user skills. Currently the user skills cover this. |
| Stripe / billing | If `claude-plugins-official` ships one — MuscleBuddy + RedThreadEvents both use Stripe Connect. |
| Playwright / testing | If one ships dedicated to E2E flake debugging. |

## User skills (separate from plugins)

Installed manually into `~/.claude/skills/` via `bootstrap.sh`:

- `find-skills` — discover installable skills on demand
- `supabase` — Supabase Database/Auth/Edge Functions/Realtime/Storage guidance
- `supabase-postgres-best-practices` — Postgres performance + schema review

Skills are simpler than plugins (single directory, no marketplace) but lack the bundling and version pinning. Use a plugin when bundling agents + commands + skills together; use a standalone skill for one-off domain expertise.

## Discovering more

```bash
/plugin marketplace browse claude-plugins-official
```

Or browse the marketplace repo directly: <https://github.com/anthropics/claude-plugins-official>
