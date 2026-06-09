# dotclaude

My personal Claude Code configuration — synced across machines via git.

## What's in here

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Global instructions injected into every Claude Code session. Cross-cutting rules + default stack assumptions. |
| `settings.json` | User-scope settings. Declares enabled plugins, the official marketplace, and permission defaults. |
| `keybindings.json` | Custom keyboard shortcuts (e.g., shift+enter for newline in chat). |
| `hooks/` | PreToolUse hook scripts, symlinked to `~/.claude/hooks/`. `git-guard.sh` enforces the git rules (blocks `--no-verify`, force-push to `main`, `.env` commits) — the deterministic backstop under `bypassPermissions` mode. |
| `bootstrap.sh` | One-command installer for a fresh machine. Symlinks files into `~/.claude/`. |
| `plugins.md` | Notes on which plugins are installed and what each one is for. |
| `.gitignore` | Keeps machine-local cruft out of the repo (history, sessions, caches, credentials). |

## Setup on a new machine

```bash
git clone git@github.com:GarrettMakesIt/dotclaude.git ~/dotclaude
bash ~/dotclaude/bootstrap.sh
```

The bootstrap script:
1. Symlinks `CLAUDE.md`, `settings.json`, `keybindings.json` + the `hooks/` dir into `~/.claude/`
2. Reports which plugins will auto-install on first `claude` launch

Existing files in `~/.claude/` are backed up to `~/.claude.bak.<timestamp>/` (never overwritten).

Verify the links anytime (changes nothing):

```bash
bash ~/dotclaude/bootstrap.sh --check
```

## Updating

After editing files in this repo:

```bash
cd ~/dotclaude
git add -A && git commit -m "feat: tweak X" && git push
```

On other machines:

```bash
cd ~/dotclaude && git pull
# Symlinks already point at the repo — changes apply on next Claude session.
```

## Per-repo overrides

Each project repo has its own `CLAUDE.md` and optionally `.claude/rules/<rule>.md`. Per-repo files always win over what's in this global `CLAUDE.md`.

If a rule starts being repeated in 3+ project repos, hoist it here and remove it from the project files.

## What's intentionally NOT here

- **Per-project `.claude/` folders** — those live with each project (rules, commands, worktrees state).
- **Local-only files** — sessions, history, paste cache, credentials. Listed in `.gitignore`.
- **Vendored plugin source** — plugins are declared in `settings.json` and installed from the marketplace. Self-contained, versioned, and easy to update with `/plugin update`.
- **Vendored skills** — domain skills now come from plugins. The only standalone user skill is `find-skills`; manually drop it in `~/.claude/skills/find-skills/` if needed.
