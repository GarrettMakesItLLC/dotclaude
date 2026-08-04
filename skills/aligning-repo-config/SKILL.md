---
name: aligning-repo-config
description: Use when a project repo's CLAUDE.md, .claude/ config, or .github/ templates need to be brought back in line with the global dotclaude config — after a dotclaude refit or rule change, when adopting a repo that has no config yet, or when repo instructions have drifted from what the code actually does.
allowed-tools: Bash(git -C ~/dotclaude:*), Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(rg:*), Bash(ls:*), Read, Edit, Write, Glob, Grep
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

## 3. Tier every line

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

- **`Autonomy:`** — `gated` or `autonomous-merge`. Unspecified silently means `gated`; state it.
- **Architecture in a diagram**, plus which package depends on which.
- **Commands that work**, including how to run a *single* test.
- **Stack reality and deliberate non-choices** — the assumptions a competent agent would otherwise make and get wrong ("no Redis", "Vitest not Jest", "no i18n").
- **Where things live** — specs, plans, architecture docs, registries you must edit to add a thing.
- **Repo-specific guardrails and traps** — custom lint rules, drift scripts, the thing that silently renders unstyled.

Two smells that mean a section is in the wrong tier: it would be equally true of any of my repos (→ global), or it restates something a file in the repo already declares (→ delete, and let the config speak).

## 4. Verify every claim — this is the step that gets skipped

A repo `CLAUDE.md` is **testable**, and a confidently wrong instruction costs more than a missing one. Do not edit prose you have not checked:

- **Run every command it lists.** A command that errors or no longer exists gets fixed or cut. Cheap proxies (`--help`, `pnpm run` listing, `-n` dry runs) are fine for slow ones; say which you actually ran.
- **Resolve every path it names** — docs, scripts, directories, route folders. Dead pointers are worse than none.
- **Check versions and stack claims** against `package.json` / lockfile / config, not memory.
- **Confirm named guardrails still exist** — grep the eslint config for the custom rule, the workflow for the CI step, `.husky/` for the hook.
- **Check the counts** — "ten studios", "the only consumer", "the only route handlers". Count them.

## 5. The rest of the surface

- **`.claude/settings.json`** — repo-specific permissions and hooks only. Never a copy of user settings; user scope already applies.
- **`.github/`** — `GarrettMakesItLLC/.github` already supplies org-wide default `ISSUE_TEMPLATE/` and `PULL_REQUEST_TEMPLATE.md` (sourced from `~/dotclaude/templates/`) to any repo that doesn't define its own. A repo-local copy is redundant unless it genuinely diverges — `diff -r` against `~/dotclaude/templates/`, and delete the repo copy rather than leaving two sources if it doesn't.
- **Labels** — `labels_ensure` once per repo, so the taxonomy the issue skill assumes exists.
- **MCP** — `.mcp.json` only for a server this repo alone needs.
- **Integrations** — cross-check `~/dotclaude/integrations.md`'s roster against what the repo actually uses (its `package.json`/CI for Supabase, Railway, Vercel, Sentry, etc.). A used integration undocumented there is a gap to file back against `integrations.md`, not something to re-document per repo.

## 6. Ship it

Final-state voice (global CLAUDE.md): the file describes what *is*. No "moved to", no "previously", no note that the config was refit — the PR body carries that.

Then per repo autonomy: conventional `docs:` or `chore:` commit, PR body listing what moved tier and what was **verified vs. deleted as unverifiable**, `Closes #N`.

## Red flags

- The repo file restates a global rule ("use conventional commits", "TypeScript strict") — the enforcing config already says it.
- A command in the file that you did not run this session.
- A section that reads as a changelog of the config itself.
- Rescuing a rule the global refit deliberately deleted.
- Copying the global file's structure into the repo file instead of the repo's own facts.
- Aligning several repos in one pass without re-verifying each one's commands — claims don't transfer between repos.
