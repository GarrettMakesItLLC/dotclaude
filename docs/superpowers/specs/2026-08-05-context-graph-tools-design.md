# Context-graph tools: Serena + Graphify for app repos

## Problem

Sessions working in real application codebases (musclebuddy, redthread, etc.) burn
tokens rediscovering structure — grepping for a symbol's definition, reading whole
files to find callers, reconstructing "what depends on this" by hand. Industry
tooling exists specifically to eliminate this: LSP-backed symbol navigation and
local AST knowledge graphs, both queried instead of grepped. `dotclaude` itself is
too small and too markdown-heavy for either to pay off (143 tracked files, mostly
docs/config, one small MCP server) — this is scoped to the app repos the fleet
config already scaffolds and aligns.

## Goal

Fleet-wide availability of two context tools, wired so they stay current without
manual reindexing, following the same "hooks + CI keep it fresh, nothing stale
gets silently trusted" philosophy as `dotrepo-sync.sh`.

- **Serena** (MIT, LSP-over-MCP) — symbol-level navigation and refactors:
  `find_symbol`, `find_referencing_symbols`, `rename_symbol`. Self-indexes per
  project on first use; the language server keeps it live. No extra freshness
  plumbing needed — this is why it's the default tool.
- **Graphify** (Apache 2.0, local tree-sitter AST → knowledge graph) — cross-cutting
  questions Serena doesn't answer: impact analysis, call graphs, shortest path
  between two symbols. Snapshot-based, so it needs the freshness mechanism below.

## Non-goals

- Wiring either tool into `dotclaude` itself — established as low-value given its
  size and composition.
- Committing raw graph/index data (Graphify's `graphify-out/*.json`, Serena's
  `.serena/cache/`) to any repo. Both projects' own conventions gitignore this —
  it's a regenerable local artifact, not source. `dotclaude` doesn't create
  precedent for committing generated indexes elsewhere in the fleet.
- Standing up new hosting infrastructure for a "docs site." Every app repo already
  has CI (`ci.yml` from the scaffold) and, where wanted, GitHub Pages — reuse it.
- Turning on Graphify's `--auto-update` flag. That triggers LLM-backed semantic
  re-extraction for docs/images (token cost, off by default upstream for exactly
  that reason). Code-file re-extraction via plain `--update` is tree-sitter-only —
  zero tokens — and is all a code-graph-freshness hook needs.
- Serena project files: no scaffold changes needed. `.serena/project.yml` and
  `.serena/memories/` are ordinary small committed files once a repo opts in
  (Serena creates them); only `.serena/cache/` and `.serena/*.local.yml` need a
  gitignore entry, same tier as `.claude/settings.local.json` already gets.

## Design

### 1. Install, user-scope (`bootstrap.sh`)

Alongside the existing `github-rest`/`upload-post` registration block:

- `uv tool install graphify` (skip if `uv` isn't present, same pattern as the
  `npx playwright install` step — warn, don't fail bootstrap).
- Serena registered as a user-scope MCP server (`claude mcp add --scope user
  serena -- <serena launch command>`), guarded the same way `github-rest` is
  (`claude mcp get serena` first, skip if already registered).

Both are per-machine installs, not per-repo state — same tier as the rest of
`bootstrap.sh`.

### 2. Per-repo scaffold (`bootstrapping-a-product-repo` skill)

Add to `references/scaffold/`:

- `gitignore`: append `graphify-out/`, `.serena/cache/`, `.serena/*.local.yml`.
- `.husky/post-merge` (new file): if the `graphify` CLI is present *and*
  `graphify-out/` already exists in the repo (i.e., someone has opted this repo
  into Graphify — bootstrapping doesn't force every repo to carry a graph), run
  `graphify --update --quiet`, swallow errors. Mirrors `.husky/pre-commit`'s
  "no-op if the tool isn't relevant" shape.
- `.husky/post-checkout`: same guarded call — covers branch switches, which
  `post-merge` alone misses.
- `.github/workflows/ci.yml`: one additional step, gated on push to the default
  branch, gated the same way (graph already opted-in) — `graphify --update` then
  `graphify export callflow-html`, publish the resulting standalone HTML (vis.js/
  Mermaid, self-contained — no separate hosting needed) as a workflow artifact,
  and to GitHub Pages if the repo already has Pages configured. This is the CI-side
  redundancy: a hook only fires on a machine that has the CLI installed and pulls
  locally; CI is what guarantees the published view is never more than one push
  stale, same double-coverage reasoning as `dotrepo-sync.sh` (hook) plus
  `link-doctor.sh` (verify) for the symlink case.

Opt-in, not forced: a repo gets the scaffold gitignore lines and no-op hook
guards regardless (cheap, inert), but only starts actually running `graphify` once
someone runs `graphify install` in it — same "no-op if irrelevant" pattern already
used for the husky hooks.

### 3. Decision rule (`rules/context-tools.md`, new)

One rule file, scoped by path convention to app-repo work (not `dotclaude`):

- Default to Serena for anything symbol-shaped: "where is X defined," "what calls
  Y," rename/refactor.
- Reach for Graphify when the question is relational/architectural: "what breaks if
  I change this," call-graph shape, cross-file impact — the kind of question that
  would otherwise mean grepping several rounds and holding the results in context
  by hand.
- Fall back to `rg`/`Read` when neither tool is installed in the repo yet, or for
  anything outside code structure (config values, string content).

### 4. Documentation (`integrations.md`)

New section, "Per-project context tools," alongside the existing MCP tables:
tool prefix, what it's for, and one line on the freshness contract (hook + CI,
gitignored data, no manual reindex expected) so a session never has to wonder
whether a graph result might be stale.

### 5. Backfill existing repos

`aligning-repo-config` skill gets a line noting this scaffold slice as something
to check for and add during a normal alignment pass — not a one-time migration
sweep across every repo today.

## Testing

- `bootstrap.sh`: manual run confirms both installs are idempotent (already-
  registered/installed → skip, matching the existing `github-rest` check).
- Scaffold hooks: a sibling test in the same style as `hooks/*.test.sh` isn't
  applicable here (these are husky hooks that ship *into* app repos, not
  `dotclaude`'s own session hooks) — verify by hand in one pilot app repo:
  commit with no graph present (hook no-ops), then `graphify install`, then a
  `git pull`/checkout confirms the graph updates.
- CI step: verify on the pilot repo's next PR that the workflow step runs,
  produces the HTML artifact, and is a true no-op (skipped, not failed) on repos
  that haven't opted in.

## Rollout

All four product repos get the scaffold slice. **musclebuddy** first (pilot —
verify the hook/CI behavior against something real before repeating it
elsewhere), then the remaining three via the normal `aligning-repo-config` pass.
