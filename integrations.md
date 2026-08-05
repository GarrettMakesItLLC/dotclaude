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

### Deliberately not enabled

The official marketplace carries 200+ plugins; these are the near-misses, and
the reason each stays out is the rule for anything like it:

| Plugin | Why not |
|--------|---------|
| `github` | Its MCP routes writes through the deprecated GraphQL `projectCards` path that the vendored `github-rest` exists to avoid, and a second GitHub tool surface makes tool names ambiguous. One source per service. |
| `code-simplifier` | The bundled `/simplify` command already does this. |
| `claude-security` | The bundled `/security-review` already does this. |
| `claude-md-management` | Overlapped by the `aligning-repo-config` skill, which knows this tiering model. |
| `feature-dev` | Its workflow duplicates `superpowers` plus `finishing-work`, and competing process skills make the chosen path non-deterministic. |
| `claude-code-setup`, `hookify`, `mcp-server-dev` | One-shot authoring tools, not per-turn context. Install for the session that needs one (`/plugin install <name>@claude-plugins-official`), then remove it. |

## MCP servers a plugin brings

Present automatically once the plugin installs; most need one auth step per
machine. Plugins not listed ship skills only.

| MCP | Plugin | Auth |
|-----|--------|------|
| Supabase | `supabase` | OAuth — `mcp__plugin_supabase_supabase__authenticate` |
| Prisma | `prisma` | OAuth — `mcp__plugin_prisma_Prisma-Remote__authenticate` |
| Railway | `railway` | OAuth — `mcp__plugin_railway_railway__*` (read-only ops allowlisted in `settings.json`) |
| Vercel | `vercel` | OAuth — deployments, build/runtime logs, projects |
| Sentry | `sentry` | OAuth (Sentry account) |
| Playwright | `playwright` | None — drives a local browser |

### Railway `get-logs` on build logs — token-limit workaround

`get-logs` with `types: ["build"]` (or `["build", "deploy"]`) can exceed the
context token limit even at `limit: 100`–`200`, because each Metal/Railpack
build log entry duplicates a large base64 `data` attribute alongside the
already-decoded `message` field. The documented `filter` param (Loki-style)
does not reliably narrow build logs server-side — a `filter: "error"` call has
returned zero matches on a log later confirmed to contain matching lines when
read unfiltered. Don't retry with a smaller `limit` expecting it to fix this —
the fix is downstream of the tool's own overflow handling, below.

Workaround (skip straight to this instead of burning a token-limit error
first):

1. Call `get-logs` as usual. On overflow it writes the full JSON to a local
   file and reports the path (under
   `~/.claude/projects/*/tool-results/mcp-plugin_railway_railway-get-logs-*.txt`).
2. Filter that file instead of loading it into context — keep only entries
   where `severity == "error"` or `message` contains `error`/`fail`
   (case-insensitive):

   ```bash
   python3 -c "
   import json
   data = json.load(open('<path-from-step-1>'))
   for e in data:
       msg = e.get('message', '')
       if e.get('severity') == 'error' or 'error' in msg.lower() or 'fail' in msg.lower():
           print(msg)
   "
   ```

This is a gap in the `railway` plugin MCP, not this repo — its source isn't
vendored here to patch. Tracked at
[#95](https://github.com/GarrettMakesItLLC/dotclaude/issues/95); revisit once
a plugin update adds a compact/fields option or fixes server-side filtering.

## Custom MCPs vendored in this repo

Source lives in `mcp/`; `bootstrap.sh` installs deps, builds, and registers each
with `claude mcp add --scope user`.

| MCP | Source | Auth | Purpose |
|-----|--------|------|---------|
| `github-rest` | `mcp/github/` | Reuses `gh auth token` at runtime | GitHub PR, issue, and repo ops over the **REST** API — including the cross-machine issue-claim lock. REST-only, so it avoids the deprecated GraphQL `projectCards` field that breaks `gh`'s PR mutations, and needs no `jq`. Prefer it over `gh pr …` / `gh issue …` for every write. Tool list: `mcp/github/README.md`. |

Missing a capability, or a tool that keeps failing? The **`closing-tool-gaps`** skill covers unblocking
now and adding the tool so the gap closes for everyone.

## GitHub org-level rulesets — branch protection

The `gh` token (`gh auth token`, what `github-rest` reuses) carries `admin:org`,
so branch protection lives at the **organization** level, inherited by every
repo in `GarrettMakesItLLC` automatically — including one created later. Four
org rulesets:

- `Branch integrity (all repos)` — deletion + non-fast-forward, every repo.
- `Copilot review for default branch (all repos)` — every repo's default branch.
  Currently a no-op: Copilot has 0 assigned seats org-wide (`gh api
  orgs/GarrettMakesItLLC/copilot/billing`), so nothing actually runs the review
  until a seat is assigned.
- `StagePR (all repos)` / `ProdPR (all repos)` — squash-only + required `CI
  Success` check on `~DEFAULT_BRANCH`, merge-commit-only + required `CI Success`
  on `refs/heads/main`. **Excludes** the single-tier repos (`dotclaude`,
  `dotfiles`, `ci`, and `.github`, which carries no CI at all — templates and an
  org profile, nothing a workflow would verify) — for them `~DEFAULT_BRANCH` and
  `main` are the same branch, and StagePR's squash-only would fight ProdPR's
  merge-commit-only on it. Each keeps its own repo-level ruleset instead: squash
  + required `CI Success`, no merge queue.

**`merge_queue` cannot be an org-level rule** (the API 422s on it) — it stays a
thin repo-level ruleset per two-tier repo, `StagePR`/`ProdPR` in name only, now
holding nothing but the `merge_queue` rule. Everything else those used to carry
(deletion, non-fast-forward, the pull_request/merge-method rule, required
status checks) moved to the org-level rulesets above.

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
