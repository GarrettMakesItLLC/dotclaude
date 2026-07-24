# dotclaude

My personal Claude Code configuration — synced across machines via git.

## What's in here

| Path | Purpose |
|------|---------|
| `CLAUDE.md` | Global instructions injected into **every** session. Universal *behavioral* rules only. |
| `rules/` | Path-scoped stack conventions (`frontend`, `data-api`, `monorepo-hosting`, `ci`). Each loads only when Claude opens a matching file. |
| `skills/` | On-demand procedures: `finishing-work`, `managing-work-with-issues`, `operating-production`, `extending-the-github-mcp`, `aligning-repo-config`. Linked individually into `~/.claude/skills/`, so skills from other sources aren't clobbered. |
| `hooks/` | Deterministic guardrails. `git-guard.sh` blocks dangerous shell commands; `worktree-guard.sh` blocks edits to a `.worktrees/` repo's main tree; `verify-reminder.sh` nudges verification + issue linkage at PR-open; `worktree-bootstrap.sh` seeds a newly created worktree. Each ships a `*.test.sh` self-test; the script headers are the spec. |
| `mcp/` | Source for the custom MCP servers I wrote. `mcp/github` (`github-rest`) covers PR, issue, and repo ops over REST, including the issue-claim lock. `bootstrap.sh` builds and registers it; tool list in `mcp/github/README.md`. |
| `settings.json` | User-scope settings: enabled plugins, marketplace, permission defaults, hooks wiring. |
| `keybindings.json` | Custom keyboard shortcuts. |
| `commands/` | Personal slash commands (e.g. `/dotclaude-sync`). |
| `bootstrap.sh` | Installer + link doctor (`--check`) for a fresh machine. |
| `integrations.md` | Plugins, plugin/custom MCP servers, claude.ai OAuth connectors, and per-machine secrets. |
| `templates/` | Canonical `.github/` sources — `PULL_REQUEST_TEMPLATE.md` and `ISSUE_TEMPLATE/`. Copied into each project repo so GitHub's own UI enforces the issue taxonomy and PR shape. Never active in this repo. |
| `.gitignore` | Keeps machine-local cruft out of the repo (history, sessions, caches, credentials). |

## The context-economy model

Every Claude Code primitive differs in **when its content enters the context
window**. Each rule lives at the cheapest tier that can still enforce it:

| Tier | Enters context | Use for |
|------|---------------|---------|
| **Hook** (`hooks/` + `settings.json`) | Never — runs as code at an event (0 tokens) | Deterministic guardrails that must hold every time |
| **Path-scoped rule** (`rules/`) | Only when a matching file is opened | Language/stack conventions |
| **Skill** (`skills/`) | Only when invoked or matched | Multi-step procedures & checklists |
| **`CLAUDE.md`** | Session start, **every turn** | Small set of universal behavioral rules |
| **Subagent / Workflow / agent team** | Spawned, isolated window(s) | Token-heavy or large parallel work |

`CLAUDE.md` is re-read on every turn, so it holds only rules that are universal
*and* behavioral. Anything conditional — stack conventions, finish-line
checklists, reference material — belongs in a lower tier, and a rule that only
ever needs to fire on a detectable event belongs in a hook.

The same economy governs plugins: an enabled plugin's skill, agent, and MCP tool
descriptions load at session start whether or not it is used. See
`integrations.md`.

> **Hooks are the real guardrail here.** `settings.json` runs in
> `bypassPermissions` mode, where the allow/deny permission system is skipped —
> but hooks still fire. They are a targeted backstop for the handful of rules
> that must never be negotiable, not a sandbox.

## Setup on a new machine

```bash
git clone git@github.com:GarrettMakesItLLC/dotclaude.git ~/dotclaude
bash ~/dotclaude/bootstrap.sh
```

The script is idempotent and narrates what it links; re-run it any time. Real
files already sitting at a link target are moved to `~/.claude.bak.<timestamp>/`,
never overwritten. `bash ~/dotclaude/bootstrap.sh --check` is a read-only link
doctor.

Two things bootstrap can't do for you:

- **OAuth connectors and API keys** — per-machine, interactive. See `integrations.md`.
- **Issue labels** — per-repo, not per-machine. Run the `labels_ensure` MCP tool
  once in each project repo, and copy `templates/` into its `.github/`.

## Updating

Commit here and pull elsewhere — `~/.claude/` is symlinks back to this repo, so
changes apply on the next session. Re-run `bootstrap.sh` only when a new skill or
directory is added and needs a link. `/dotclaude-sync` does the pull plus
`--check` in one step.

**Edit here, in the repo — never in `~/.claude/`.**

## Per-repo overrides

Each project repo has its own `CLAUDE.md` and optionally `.claude/rules/<rule>.md`,
which always win over this global config. A rule repeated in 3+ project repos gets
hoisted into `rules/` here and removed from the project files.

## What's intentionally NOT here

- **Per-project `.claude/` folders** — those live with each project.
- **Local-only files** — sessions, history, paste cache, credentials. See `.gitignore`.
- **MCP credentials** — OAuth tokens and API keys are per-machine; the repo carries
  the reproducible parts only (`integrations.md`).
- **Vendored plugin source** — plugins are declared in `settings.json` and installed
  from the marketplace; update with `/plugin update`. The MCP servers I wrote have no
  marketplace to install from, so those *are* vendored under `mcp/`.
- **Domain skills** — those come from plugins. `skills/` holds only the procedures
  that are mine and belong to no plugin.
