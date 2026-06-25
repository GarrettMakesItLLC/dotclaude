# MCP connectors (per-machine — re-add on a fresh setup)

These MCP servers are **not** configured by any file in this repo, and there's
nothing to commit for them: they're [claude.ai connectors](https://claude.ai/)
authenticated via OAuth, stored per-machine in `~/.claude.json` (gitignored,
holds live tokens). There is **no `mcpServers` block** to template — re-adding
them is an interactive OAuth step, not a file copy.

This file is the checklist so a fresh machine knows what to reconnect. Plugin
MCPs (Supabase, Stripe, Prisma, Playwright) are **not** here — they install
with their plugin; see `plugins.md`.

## How to reconnect

In a Claude Code session, run `/mcp` (or use the connectors UI on claude.ai),
pick the connector, and complete the OAuth flow. The tool name each exposes is
shown in the last column.

| Connector | What I use it for | Tool prefix |
|-----------|-------------------|-------------|
| **Notion** | Search pages, fetch specs/playbooks, query databases | `mcp__claude_ai_Notion__*` |
| **Vercel** | Deployments, build + runtime logs, projects | `mcp__claude_ai_Vercel__*` |
| **Gmail** | Read/draft emails, manage labels/threads | `mcp__claude_ai_Gmail__*` |
| **Google Calendar** | Read/create events, find meeting times | `mcp__claude_ai_Google_Calendar__*` |
| **Google Drive** | Fetch shared docs | `mcp__claude_ai_Google_Drive__*` |
| **PubMed** | Research-backed features (MuscleBuddy) | `mcp__claude_ai_PubMed__*` |
| **Spotify** | Karaoke/track metadata (RedThreadEvents) | `mcp__claude_ai_Spotify__*` |

> Note: Supabase also appears as a claude.ai connector in some setups, but the
> repo's source of truth for Supabase is the **`supabase` plugin** (`plugins.md`).

## Plugin MCP secrets (env vars — per-machine)

Some plugin MCPs authenticate with an API key from the environment rather than
OAuth. The key is a per-machine secret — set it in `~/.claude/settings.local.json`
(gitignored, **not** the symlinked `settings.json`) under `env`, or export it in
your shell. Never commit it.

| Env var | Plugin MCP | Where to get it |
|---------|-----------|-----------------|
| `RESEND_API_KEY` | `resend` | Resend dashboard → API Keys (<https://resend.com/api-keys>) |

```jsonc
// ~/.claude/settings.local.json
{ "env": { "RESEND_API_KEY": "re_…" } }
```

## Why not committed

`~/.claude.json` mixes these OAuth tokens with machine-local state (startup
counts, project history, caches). It's in `.gitignore` for that reason.
Committing a sanitized copy would drift instantly and risk leaking a token on
the next careless `git add -A`. A checklist that triggers the OAuth flow is the
safe, reproducible artifact.
