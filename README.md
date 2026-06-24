# dotclaude

My personal Claude Code configuration — synced across machines via git.

## What's in here

| Path | Purpose |
|------|---------|
| `CLAUDE.md` | Global instructions injected into **every** session. Lean by design — universal *behavioral* rules only. |
| `rules/` | Path-scoped stack conventions (TypeScript, frontend, data/API, testing, monorepo/hosting). Each loads only when Claude opens a matching file. Symlinked to `~/.claude/rules/`. |
| `skills/` | Personal/vendored skills (`finishing-work`, and the vendored `find-skills`). Load on demand when invoked or matched. Each linked into `~/.claude/skills/`. |
| `hooks/` | Deterministic guardrails run by Claude Code. `git-guard.sh` blocks dangerous shell commands (`--no-verify`, force-push to `main`, `.env` commits, reckless `rm -rf`); `git-guard.test.sh` is its self-test. Symlinked to `~/.claude/hooks/`. |
| `mcp/` | Source for custom MCP servers I built (e.g. `mcp/github` — a REST wrapper for GitHub PR/issue/repo ops). `bootstrap.sh` builds and registers each with `claude mcp add`. See `plugins.md`. |
| `settings.json` | User-scope settings: enabled plugins, the official marketplace, permission defaults, and the hooks wiring. |
| `keybindings.json` | Custom keyboard shortcuts (e.g., shift+enter for newline in chat). |
| `commands/` | Personal slash commands, symlinked to `~/.claude/commands/` (e.g. `/dotclaude-sync`, which pulls the repo and runs the link doctor). |
| `bootstrap.sh` | One-command installer for a fresh machine. Symlinks files + directories into `~/.claude/`; `--check` runs a link doctor. |
| `plugins.md` | Notes on which plugins are installed and what each is for. |
| `mcp-connectors.md` | Checklist of claude.ai OAuth connectors (Notion, Gmail, Vercel…) to reconnect on a fresh machine. |
| `.gitignore` | Keeps machine-local cruft out of the repo (history, sessions, caches, credentials). |

## The context-economy model

Every Claude Code primitive differs in **when its content enters the model's context window**. The config is organized so each rule lives at the cheapest tier that can still enforce it:

| Tier | Enters context | Use for |
|------|---------------|---------|
| **Hook** (`hooks/` + `settings.json`) | Never — runs as code at an event (0 tokens) | Deterministic guardrails that must hold every time |
| **Path-scoped rule** (`rules/`) | Only when a matching file is opened | Language/stack conventions |
| **Skill** (`skills/`) | Only when invoked or matched | Multi-step procedures & checklists |
| **`CLAUDE.md`** | Session start, **every turn** | Small set of universal behavioral rules |
| **Subagent / Workflow / agent team** | Spawned, isolated window(s) | Token-heavy or large parallel work |

Keeping `CLAUDE.md` lean (Anthropic targets <200 lines) matters because it's re-read on every turn. Reference material and finish-time checklists were moved out to `rules/` and `skills/` so they only cost context when relevant.

> **Hooks are the real guardrail here.** `settings.json` runs in `bypassPermissions` mode, where the allow/deny permission system is skipped — but hooks still fire. `git-guard.sh` hard-blocks `--no-verify` (and equivalent hook-bypasses like `commit -n` / `-c core.hooksPath=`), committing `.env`, force-push to `main`/`master`, and reckless `rm -rf` of root/home/parent paths, while leaving everyday commands (`rm -rf node_modules`, pushing feature branches) untouched. It's a *targeted* backstop for those rules, not a sandbox — it doesn't gate the rest of what `bypassPermissions` allows.

## Setup on a new machine

```bash
git clone git@github.com:GarrettMakesIt/dotclaude.git ~/dotclaude
bash ~/dotclaude/bootstrap.sh
```

The bootstrap script:
1. Symlinks `CLAUDE.md`, `settings.json`, `keybindings.json` into `~/.claude/`
2. Symlinks the `rules/`, `hooks/`, and `commands/` directories into `~/.claude/`
3. Symlinks each vendored skill (`finishing-work`, `find-skills`) into `~/.claude/skills/` individually, so plugin/user skills there aren't clobbered
4. Builds and registers vendored custom MCP servers (`mcp/github`) with `claude mcp add`
5. Reports which plugins will auto-install on first `claude` launch

Existing real files in `~/.claude/` are backed up to `~/.claude.bak.<timestamp>/` (never overwritten). The script is idempotent — safe to re-run.

Verify the links anytime (changes nothing):

```bash
bash ~/dotclaude/bootstrap.sh --check
```

## Updating

After editing files in this repo:

```bash
cd ~/dotclaude
git add -A && git commit -m "feat: tweak X" && git push   # conventional commits enforced
```

On other machines:

```bash
cd ~/dotclaude && git pull
# Symlinks already point at the repo — changes apply on next Claude session.
# Re-run bootstrap.sh only if directories/skills were added (to create new links).
```

Or just run `/dotclaude-sync` in any Claude Code session — it pulls the repo and runs the link doctor (`bootstrap.sh --check`) for you.

**Edit here, in the repo — never in `~/.claude/`.** Those paths are symlinks back to this repo. If `bootstrap.sh` is re-run after a real file is dropped at a symlink target, it moves the real file to `~/.claude.bak.<timestamp>/` and re-links from the repo.

## Plugin model

Plugins are *declared, not vendored.* `settings.json` lists them under `enabledPlugins`; Claude Code auto-installs from `anthropics/claude-plugins-official` on next launch. To add one: edit `settings.json`, update `plugins.md`, commit. To browse: `/plugin marketplace browse claude-plugins-official`.

## Per-repo overrides

Each project repo has its own `CLAUDE.md` and optionally `.claude/rules/<rule>.md`. Per-repo files always win over this global config. If a rule starts being repeated in 3+ project repos, hoist it into `rules/` here and remove it from the project files.

## What's intentionally NOT here

- **Per-project `.claude/` folders** — those live with each project (rules, commands, worktree state).
- **Local-only files** — sessions, history, paste cache, credentials. Listed in `.gitignore`.
- **Top-level MCP OAuth state** — Notion, Gmail, Vercel, etc. live in `~/.claude.json` per-machine.
- **Vendored plugin source** — plugins are declared in `settings.json` and installed from the marketplace. Update with `/plugin update`. (Custom MCP servers I wrote *are* vendored, under `mcp/` — they have no marketplace to install from.)
- **Vendored plugin skills** — domain skills come from plugins. The one standalone user skill, `find-skills`, *is* vendored here (`skills/find-skills/`) and symlinked into `~/.claude/skills/` by bootstrap — it's not in any plugin, so the repo is its source of truth.
