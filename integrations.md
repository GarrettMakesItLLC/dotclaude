# Integrations — plugins, MCP servers, connectors

Everything that reaches outside a Claude Code session, and what a fresh machine
has to do to make each one work.

## Plugins

`settings.json` → `enabledPlugins` is the list. It is not restated here — read it
directly:

```bash
jq -r '.enabledPlugins | keys[]' ~/.claude/settings.json
```

They install from `anthropics/claude-plugins-official` on the next `claude`
launch. To add one: edit `settings.json`, commit. To browse:
`/plugin marketplace browse claude-plugins-official`.

**Keep the set small.** A plugin's skill descriptions, agent descriptions, and
MCP tool schemas load at session start, before anything is invoked — an enabled
plugin costs context on every turn whether or not it is used. Enable a plugin
only for a stack I actually deploy, and prefer one that ships skills over one
that ships agents. Where two plugins overlap, keep the cheaper one.

`github` is enabled for repo browsing, but **PR and issue writes go through the
vendored `github-rest` MCP below**, not `gh` or the plugin — see the table.

## MCP servers a plugin brings

Present automatically once the plugin installs; most need one auth step per
machine. Plugins not listed ship skills only.

| MCP | Plugin | Auth |
|-----|--------|------|
| Supabase | `supabase` | OAuth — `mcp__plugin_supabase_supabase__authenticate` |
| Stripe | `stripe` | OAuth — `mcp__plugin_stripe_stripe__authenticate` |
| Prisma | `prisma` | OAuth — `mcp__plugin_prisma_Prisma-Remote__authenticate` |
| Railway | `railway` | OAuth — `mcp__plugin_railway_railway__*` (read-only ops allowlisted in `settings.json`) |
| Vercel | `vercel` | OAuth — deployments, build/runtime logs, projects |
| Sentry | `sentry` | OAuth (Sentry account) |
| Playwright | `playwright` | None — drives a local browser |

## Custom MCPs vendored in this repo

Source lives in `mcp/`; `bootstrap.sh` installs deps, builds, and registers each
with `claude mcp add --scope user`.

| MCP | Source | Auth | Purpose |
|-----|--------|------|---------|
| `github-rest` | `mcp/github/` | Reuses `gh auth token` at runtime | GitHub PR, issue, and repo ops over the **REST** API — including the cross-machine issue-claim lock. REST-only, so it avoids the deprecated GraphQL `projectCards` field that breaks `gh`'s PR mutations, and needs no `jq`. Prefer it over `gh pr …` / `gh issue …` for every write. Tool list: `mcp/github/README.md`. |

Missing a capability? The **`extending-the-github-mcp`** skill covers unblocking
now and adding the tool so the gap closes for everyone.

## claude.ai OAuth connectors — reconnect on a fresh machine

Nothing in this repo configures these. They are OAuth connectors whose tokens
live per-machine in `~/.claude.json` (gitignored — it also holds session history
and caches, so a sanitized copy would drift instantly and risk leaking a token).
There is no `mcpServers` block to template; reconnecting is an interactive step.

Run `/mcp` in a session (or the connectors UI on claude.ai), pick the connector,
complete OAuth.

| Connector | Used for | Tool prefix |
|-----------|----------|-------------|
| **Notion** | Specs, playbooks, database queries | `mcp__claude_ai_Notion__*` |
| **Gmail** | Read/draft mail, labels, threads | `mcp__claude_ai_Gmail__*` |
| **Google Calendar** | Events, finding meeting times | `mcp__claude_ai_Google_Calendar__*` |
| **Google Drive** | Fetch shared docs | `mcp__claude_ai_Google_Drive__*` |
| **PubMed** | Research-backed features (MuscleBuddy) | `mcp__claude_ai_PubMed__*` |
| **Spotify** | Track metadata (RedThreadEvents) | `mcp__claude_ai_Spotify__*` |

Supabase and Vercel also exist as claude.ai connectors. Use the **plugin** MCPs
for both — one source per service, so tool names stay predictable.

## API-key HTTP MCPs — registered by `bootstrap.sh`

Remote HTTP servers that authenticate with a static key instead of OAuth. The
URL is fixed, so these *are* reproducible from this repo; only the key is
per-machine.

| Server | Used for | Tool prefix |
|--------|----------|-------------|
| **upload-post** | Publish/schedule/analyze social posts (TikTok, IG, YouTube, LinkedIn, X, …) | `mcp__upload-post__*` |

Re-register by hand if needed:

```bash
claude mcp add --scope user --transport http upload-post \
  https://mcp.upload-post.com/mcp \
  --header 'Authorization: ApiKey ${UPLOAD_POST_API_KEY}'
```

## Per-machine secrets

Set in `~/.claude/settings.local.json` (gitignored) under `env`, or export in
your shell. Never in the symlinked `settings.json`.

| Env var | Used by | Where to get it |
|---------|---------|-----------------|
| `UPLOAD_POST_API_KEY` | `upload-post` MCP | Upload-Post dashboard → API key / JWT (<https://app.upload-post.com/>) |

```jsonc
// ~/.claude/settings.local.json
{ "env": { "UPLOAD_POST_API_KEY": "eyJ…" } }
```
