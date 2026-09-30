---
name: aligning-repo-config
description: Use when a project repo's CLAUDE.md, .claude/ config, or .github/ templates need to be brought back in line with the global dotclaude config — after a dotclaude refit or rule change, when adopting a repo that has no config yet, or when repo instructions have drifted from what the code actually does.
allowed-tools: Bash(git -C ~/dotclaude:*), Bash(diff:*), Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(rg:*), Bash(ls:*), Read, Edit, Write, Glob, Grep
---

# Aligning repo config

The global config is the baseline. A repo file earns its tokens only by carrying what the global tier **cannot know** — this repo's stack, commands, layout, and traps. Everything else is duplication, and duplication is drift waiting to happen.

Tiering model and the cost of each tier: `~/dotclaude/README.md`.

## 1. Align against a current global, not a stale one

Run `/dotclaude-sync` first. Then read what actually changed:

```bash
git -C ~/dotclaude log --oneline -10
git -C ~/dotclaude diff <last-alignment-sha>..HEAD -- CLAUDE.md rules/ settings.json templates/
```

That diff is the worklist:

- A global rule **added** → the repo's copy of it is now redundant. Delete the repo copy.
- A global rule **deleted** → it was deleted for a reason (a config file enforces it, or the model does it by default). Delete the repo's copy too, don't rescue it.
- A `rules/` file **deleted** → the repo file must not resurrect its content.
- A `templates/` change → the repo's `.github/` copies are stale.

## 2. Inventory the repo's AI surface before editing

Everything an agent reads, not just the root file:

```bash
ls -a; ls -R .claude 2>/dev/null; ls .github .github/ISSUE_TEMPLATE 2>/dev/null
rg --files -g 'CLAUDE.md' -g 'AGENTS.md' -g '.mcp.json' -g 'copilot-instructions.md'
```

Nested `CLAUDE.md` files load when a file under them is opened — check them for the same duplication, and for contradicting the root.

## 3. Delete vendored copies of dotclaude

Anything the repo copied from dotclaude has forked since. Diff, don't eyeball:

```bash
for f in .claude/hooks/*.sh; do [ -f ~/dotclaude/hooks/"$(basename "$f")" ] && diff -q "$f" ~/dotclaude/hooks/"$(basename "$f")"; done
for f in bin/*.sh bin/lib/*.sh; do [ -f ~/dotclaude/"$f" ] && diff -q "$f" ~/dotclaude/"$f"; done
ls .claude/skills/ ~/dotclaude/skills/
```

- **A hook dotclaude now ships and wires globally** — delete the repo copy AND its `.claude/settings.json` entry, or it runs twice. Keep only a repo-specific payload the global hook calls.
- **A `bin/` script dotclaude ships** (`setup-worktree.sh`, `agent-env-build.sh`, `ops-pull.sh`, `lib/vercel.sh`, `with-check-lock.sh`, `staging-db-url.sh`, `doctor.sh`) — move the repo's values into `.claude/repo.json` (`~/dotclaude/docs/repo-manifest.md`), repoint callers (`package.json`, `.husky/`, docs) at `~/.claude/bin/…`, and delete the copy. A script CI runs has no dotclaude on the runner: keep a shim that `exec`s `~/.claude/bin/<script>` when it exists and falls back otherwise (for `with-check-lock.sh`, to running the command unwrapped).
- **A skill dotclaude ships** (`agent-credentials`, `graphify`, a config-alignment skill like this one) — fold any repo-only content into the right place (`.claude/credentials.md` for credentials, `.claude/rules/` for invariants) and delete the copy.

## 4. Tier every line

For each line in the repo file, ask *what is the cheapest thing that can enforce this?* Anything with a home elsewhere leaves the repo file:

| The line is… | Where it belongs |
|---|---|
| Universal behavior (how to work, ship, communicate) | Global `CLAUDE.md` — already there. Delete. |
| A stack convention holding in 3+ of my repos | Hoist to `~/dotclaude/rules/<area>.md`, delete here |
| A stack convention specific to this repo, path-scoped | `.claude/rules/<area>.md` |
| Already enforced by a config file (commitlint, eslint, tsconfig, CI) | Delete the prose — the config is the rule |
| A multi-step procedure or finish-line checklist | A skill, global or `.claude/skills/` |
| A checklist for one topic a skill covers, long enough to crowd it | That skill's `references/<topic>.md` |
| The standing instructions of a dispatched subagent role | An agent definition (`agents/`) |
| Deterministic and detectable at an event | A hook |

What's left — and what the repo file must actually contain:

- **`Autonomy:`** — global default is now `autonomous-merge` for every repo; only state it here if this repo opts down to `gated`.
- **Architecture in a diagram**, plus which package depends on which.
- **Commands that work**, including how to run a *single* test.
- **Stack reality and deliberate non-choices** — the assumptions a competent agent would otherwise make and get wrong ("no Redis", "Vitest not Jest", "no i18n").
- **Where things live** — specs, plans, architecture docs, registries you must edit to add a thing.
- **Repo-specific guardrails and traps** — custom lint rules, drift scripts, the thing that silently renders unstyled.

Two smells that mean a section is in the wrong tier: it would be equally true of any of my repos (→ global), or it restates something a file in the repo already declares (→ delete, and let the config speak).

## 5. Verify every claim — this is the step that gets skipped

A repo `CLAUDE.md` is **testable**, and a confidently wrong instruction costs more than a missing one. Do not edit prose you have not checked:

- **Run every command it lists.** A command that errors or no longer exists gets fixed or cut. Cheap proxies (`--help`, `pnpm run` listing, `-n` dry runs) are fine for slow ones; say which you actually ran.
- **Resolve every path it names** — docs, scripts, directories, route folders. Dead pointers are worse than none.
- **Check versions and stack claims** against `package.json` / lockfile / config, not memory.
- **Confirm named guardrails still exist** — grep the eslint config for the custom rule, the workflow for the CI step, `.husky/` for the hook.
- **Check the counts** — "ten studios", "the only consumer", "the only route handlers". Count them.
- **Verify invariants against the code they describe.** An invariant that no longer matches the code teaches the wrong rule; one that reads like a war story is usually load-bearing.
- **A list of files** (routes, modules) either carries a "trust `ls` when this drifts" note or is refreshed — never left bare and stale.
- **Env vars have one registry** (usually `.env.example`); never start a second catalog in prose.

Before renaming or deleting a rule file or a heading, grep for citations: code comments cite `.claude/rules/*.md` by path, and applied migration SQL can quote a CLAUDE.md phrase — that SQL is checksum-locked, so the phrase has to survive verbatim. `rg -n 'claude/rules|CLAUDE.md' --glob '!node_modules'`.

## 6. The rest of the surface

- **`.claude/settings.json`** — repo-specific permissions and hooks only. Never a copy of user settings; user scope already applies.
- **`.github/`** — `GarrettMakesItLLC/.github` already supplies org-wide default `ISSUE_TEMPLATE/` and `PULL_REQUEST_TEMPLATE.md` (sourced from `~/dotclaude/templates/`) to any repo that doesn't define its own. A repo-local copy is redundant unless it genuinely diverges — `diff -r` against `~/dotclaude/templates/`, and delete the repo copy rather than leaving two sources if it doesn't.
- **Labels** — `labels_ensure` once per repo, so the taxonomy the issue skill assumes exists.
- **MCP** — `.mcp.json` only for a server this repo alone needs.
- **Integrations** — cross-check `~/dotclaude/integrations.md`'s roster against what the repo actually uses (its `package.json`/CI for Supabase, Railway, Vercel, Sentry, etc.). A used integration undocumented there is a gap to file back against `integrations.md`, not something to re-document per repo.
- **`.claude/rules/*.md` frontmatter** — every rule has a `paths:` glob. Without one it loads every turn, which is the cost the tier exists to avoid.
- **Repo-owned AI surfaces** — a vendored third-party skills lockfile, a public-docs allowlist, `llms.txt`: every file they list still exists under the listed name.
- **Context-graph scaffold** — the `graphify-out/`/`.serena/` gitignore lines, `.husky/post-merge` + `.husky/post-checkout`, and the `ci.yml` Graphify step (`bootstrapping-a-product-repo`'s `references/scaffold/`) are cheap and inert until a repo opts in — check for them and add if missing, same as any other scaffold drift.

## 7. Ship it

Final-state voice (global CLAUDE.md): the file describes what *is*. No "moved to", no "previously", no note that the config was refit — the PR body carries that.

Then per repo autonomy: conventional `docs:` or `chore:` commit, PR body listing what moved tier and what was **verified vs. deleted as unverifiable**, `Closes #N`.

A pass that only added lines almost certainly missed a deletion: `wc -w CLAUDE.md` before and after, and `bash ~/dotclaude/bootstrap.sh --check` for the global tier's own health.

## Red flags

- Editing `~/.claude/…` directly — those are symlinks into `~/dotclaude`; edit the repo.
- Vendoring a dotclaude hook, script or skill "so it's pinned" — wire the global one and keep only the repo payload.

- The repo file restates a global rule ("use conventional commits", "TypeScript strict") — the enforcing config already says it.
- A command in the file that you did not run this session.
- A section that reads as a changelog of the config itself.
- Rescuing a rule the global refit deliberately deleted.
- Copying the global file's structure into the repo file instead of the repo's own facts.
- Aligning several repos in one pass without re-verifying each one's commands — claims don't transfer between repos.
