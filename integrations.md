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
| `remember` (Digital-Process-Tools) | Duplicates Claude Code's built-in cross-session auto-memory (`~/.claude/projects/*/memory/`), and runs its own hook-driven session-capture/compression pipeline with full shell privileges and an optional git-push backup — no benefit over the built-in system to justify that surface. |
| `frontend-design` (Anthropic) | Overlapped by `impeccable`, which covers the same aesthetic-direction ground plus a deeper audit/critique/polish/harden command set, dedicated review agents, and an anti-pattern detector — the actual ask (bring existing product UI to production-grade, not just greenfield direction). One design skill, not two. |

`ui-ux-pro-max` breaks the "one design skill" rule deliberately: it's a searchable reference database (styles/palettes/font pairings/chart types per stack), not a critique workflow, so it composes with `impeccable` instead of overlapping it — `impeccable` judges and fixes, `ui-ux-pro-max` supplies the reference material it judges against.

### Third-party marketplaces

Three marketplaces outside `claude-plugins-official` are enabled, each because it fills a gap the official set doesn't: `impeccable` (design critique/polish), `ui-ux-pro-max` (design reference database), and `marketingskills`.

**`marketing-skills` (`coreyhaines31/marketingskills`, MIT)** — ~50 skills across CRO, copywriting, paid ads, ad creative, SEO and AI SEO, programmatic SEO, site architecture, schema, analytics, attribution, lifecycle and cold email, SMS, pricing, offers, paywalls, onboarding, signup, churn prevention, referrals, PR, launches, and customer research. Enabled because the whole marketing and growth axis had no coverage in this config at all: `running-an-audit` can now *find* an ads/conversion or GEO problem, and nothing here knew how to fix one.

It is the largest single addition to the skill listing, which is the cost — its descriptions load at session start like any plugin's. Accepted because the alternative is the same content re-derived per session from a model's priors, which is exactly the AI-slop failure `avoiding-ai-slop` exists to prevent. Where its skills and this config's rules disagree, this config wins: `avoiding-ai-slop` governs drafted prose, `content-drafting` governs the four product repos' content pipeline, and `legal-compliance.md`'s substantiation bar governs any comparative or performance claim before it is published.

**`email-marketing-bible` (`CosmoBlk/email-marketing-bible`, MIT)** — not a plugin (plain repo, no marketplace manifest), so `bootstrap.sh`'s `EXTERNAL_SKILLS` clones it into `~/.claude/skills/` and refreshes it on each run. A condensed operating manual: deliverability triage, flow recipes, compliance gates, and a pre-send safety checklist. It complements rather than duplicates `running-an-audit`'s `email-deliverability.md` — that file audits sending-domain architecture, DNS authentication, and routing; this one covers flow content, copy, benchmarks, and the send decision. Its benchmark figures are dated and vendor-sourced: verify before citing one, the same rule as `competitor-analysis.md`'s provenance discipline.

**Higgsfield (`higgsfield-ai/skills`) — evaluated, not enabled.** Image/video/brand-asset generation through Higgsfield's own MCP and a paid account. Out for three reasons, and the reasons are the rule for anything like it: it needs a paid third-party subscription and API credentials for a capability no product in the fleet currently ships; its brand-identity and website-generation skills overlap `impeccable` and `ui-ux-pro-max`, and one design pipeline is the standing rule; and generated ad creative is the *last* thing to add to a paid-acquisition stack, not the first — `growth-ads-conversion.md` says tracking is verified before spend scales, and none of that is in place yet. Revisit if and when paid acquisition is running with verified conversion tracking and creative volume is the actual bottleneck.

**GEO/AEO** is a realm, not a package. Nothing acquired for it: `running-an-audit`'s `answer-engine-visibility.md` carries the method, and `marketing-skills`' `ai-seo` covers the execution side.

`stop-slop` isn't a real plugin (no marketplace, no `.claude-plugin/plugin.json`) — it's a raw prose ruleset, vendored here as the `avoiding-ai-slop` skill instead of installed. `task-observer` (rebelytics) is likewise vendored as a skill rather than installed as a plugin, since it ships as a plain `SKILL.md` bundle too.

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
| Playwright | `playwright` (hand-registered, not the plugin) | None — drives the bundled Chromium |
| Chrome DevTools | `chrome-devtools` (hand-registered, not the plugin) | None — drives the bundled Chromium |

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

### Browser MCPs run on the bundled Chromium, not a system Chrome

Both browser plugins default to the Chrome `stable` channel — a system install
at `/opt/google/chrome/chrome`. That is root-only, and `npx playwright install
chrome` escalates to a `sudo` password prompt no agent shell can answer, so in
a sandbox (WSL2, containers) every browser tool failed at the first call with
`Chromium distribution 'chrome' is not found`. The channel is fixed in each
plugin's own `.mcp.json`, which lives in the marketplace package and is
overwritten on refresh, so there was nothing to override.

The Playwright-bundled Chromium needs no root, runs headless, and speaks CDP,
which satisfies both servers. So `playwright@claude-plugins-official` and
`chrome-devtools-mcp@claude-plugins-official` are **disabled** in
`settings.json`, and `bootstrap.sh` registers the same upstream packages
directly with the browser named:

```bash
claude mcp add --scope user playwright -- npx -y @playwright/mcp@latest --browser chromium
claude mcp add --scope user chrome-devtools -- \
  npx -y chrome-devtools-mcp@latest --executablePath ~/.cache/ms-playwright/chromium-<rev>/chrome-linux64/chrome
```

`--browser chromium` lets Playwright find its own build; `chrome-devtools-mcp`
has no equivalent channel for it and takes the path. The path carries a
revision that moves with the Playwright version, so bootstrap re-resolves and
re-registers on every run rather than skipping when already present.

If a machine does grow a real system Chrome, re-enabling the plugins is the
better answer — nothing here depends on the hand-registered names.

### Vercel plugin gap — no env-var read/write tool

`mcp__plugin_vercel_vercel__*` has no tool to list or set a project's
`Environment Variables` (compare Railway's `list-variables`/`set-variables`).
The plugin's source is the marketplace package, not this repo, so there is
nothing here to patch — tracked as
[dotclaude#97](https://github.com/GarrettMakesItLLC/dotclaude/issues/97).

Workaround, in order of preference:

1. **`vercel env` CLI**, if installed (`npm i -g vercel`, then `vercel link`
   once per project): `vercel env ls`, `vercel env add <NAME> <environment>`,
   `vercel env rm <NAME> <environment>`. The bundled `vercel` plugin ships an
   `/env` command and an `env-vars` skill that already wrap these — reach for
   those first.
2. **Vercel dashboard**, manual: Project → Settings → Environment Variables.
   Always available, no install step.

Neither needs a manually-minted `VERCEL_TOKEN`; both exist specifically
because the MCP can't do this yet.

Standing a project up from nothing needs the CLI form, since there is no
project to `/env` against yet: write `.vercel/project.json` first to scope the
CLI, then `npx vercel@58 env add <NAME> <target>` reading the value from stdin.
This sits directly on `bootstrapping-a-product-repo`'s path — a project needing
`VITE_*` or a build-time secret set before its first deploy cannot stay inside
the MCP (#240).

### No Docker daemon in the agent sandbox

`docker` is on PATH here and cannot reach a daemon: no `/var/run/docker.sock`,
and `sudo` wants a password, so no agent shell can start one. Docker Desktop's
WSL integration is the fix and is Garrett's toggle
([#152](https://github.com/GarrettMakesItLLC/dotclaude/issues/152),
[#153](https://github.com/GarrettMakesItLLC/dotclaude/issues/153)).

Until then, **a schema-only Prisma migration does not need a database**, which
is the case that most often looks blocked and is not:

```bash
prisma migrate diff \
  --from-schema-datamodel <old-schema> --to-schema-datamodel <new-schema> --script
```

That variant is fully offline. `--from-migrations` is not — it wants a
`--shadow-database-url`. Write the output to
`prisma/migrations/<timestamp>_<name>/migration.sql` by hand, append whatever
the repo's convention adds that `migrate diff` cannot know about (RLS
statements, in repos that use them), then `prisma generate`, `prisma validate`
and `tsc --noEmit` — all offline, and together they verify everything short of
applying it.

What genuinely needs a live database: applying the migration, and any RLS
check. Those wait for CI or for the toggle above.

### Railway MCP gap — `update-service` silently drops `source`

`mcp__plugin_railway_railway__update-service` accepts a `source` field, returns
success, and never applies it:

```
update-service(serviceId, source: {repo: "GarrettMakesItLLC/SideQuest", branch: "dev"},
               builder, buildCommand, startCommand, healthcheckPath)
→ {"updatedFields": ["buildCommand", "startCommand", "healthcheckPath"]}
```

`source` is absent from `updatedFields`, and `get-service-config` afterwards has
no `source` key. Passing `source` alone answers "No configuration fields
provided — nothing to update", so the field is dropped before the update is
assembled rather than rejected by the API.

**This is the failure mode worth remembering**: connecting a service to its
GitHub repo is what makes it deployable at all, so a silent drop leaves an
inert service that reports as configured — a half-provisioned environment that
looks finished.

**Workaround:** `railway-agent` with the same instruction applies it correctly;
its trace shows it calling `updateServiceTool` with exactly the config the
direct tool dropped. So the gap is the direct tool's argument handling, not the
Railway API. Verify with `get-service-config` either way (#240).

## Per-project context tools

Registered/installed once per machine by `bootstrap.sh`; which one to reach
for in a given app repo: `rules/context-tools.md`. Not wired into `dotclaude`
itself — too small and markdown-heavy for either to pay off.

| Tool | Surface | Tool prefix | Used for |
|------|---------|-------------|----------|
| **Serena** | MCP server (`claude mcp add --scope user serena -- serena start-mcp-server --context claude-code --project-from-cwd`) | `mcp__serena__*` | LSP-backed symbol navigation and refactors — `find_symbol`, `find_referencing_symbols`, `rename_symbol` |
| **Graphify** | Claude Code skill (`graphify install`), not an MCP | `/graphify` | Local tree-sitter knowledge graph — impact analysis, call graphs, shortest path between two symbols |

**Freshness contract.** Serena self-indexes live via the language server on
first use — no reindex step, no staleness to track. Graphify is
snapshot-based: a repo's `.husky/post-merge` and `.husky/post-checkout` hooks
run `graphify update` after every pull/checkout, and `.github/workflows/ci.yml`
re-runs `graphify update` + `graphify export callflow-html` on every push to
`main`, so the published call-flow view is never more than one push stale.
`graphify-out/` is gitignored (generated, regenerable) — none of this ever
requires a manual reindex. Every product repo runs `graphify install --project`
as part of its scaffold, not as a later manual step — see
`bootstrapping-a-product-repo`. A repo predating this convention, or bootstrapped
outside the standard flow, is the only case where the hooks/CI still no-op
until someone runs `graphify install --project` by hand.

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
