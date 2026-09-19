---
description: Pull latest dotclaude config and verify ~/.claude symlinks are healthy
allowed-tools: Bash(git -C ~/dotclaude pull --ff-only), Bash(bash ~/dotclaude/bootstrap.sh --check), Bash(git -C ~/dotclaude log --oneline -5), Bash(cd ~/dotclaude/mcp/github && npm run build)
---

Sync my global Claude Code config from the `dotclaude` repo and confirm it's
wired up correctly on this machine. Do this:

1. **Pull latest:** run `git -C ~/dotclaude pull --ff-only`. Report what changed
   (new commits, or "already up to date"). If the pull fails because of local
   edits or divergence, stop and show me the error — don't force anything.

2. **Verify links:** run `bash ~/dotclaude/bootstrap.sh --check`. This changes
   nothing; it confirms every entry bootstrap links — `CLAUDE.md`,
   `settings.json`, `keybindings.json`, the `rules/`, `hooks/`, and `commands/`
   dirs, and each skill — is still symlinked into `~/.claude/`. It also
   confirms `mcp/github/dist` isn't stale relative to its own `src/` — that
   dist is gitignored and LOCAL, so a source fix that just landed on `main`
   does not reach the running `github-rest` MCP server until something
   rebuilds it, and that has silently made agents "rediscover" already-fixed
   MCP bugs days later (dotclaude#357, #349).

3. **On drift:** if the check reports a link replaced by a real file or a
   missing link, tell me the exact fix command
   (`bash ~/dotclaude/bootstrap.sh`) and what it will back up — but do **not**
   run it without my go-ahead (it moves real files to `~/.claude.bak.*`).
   If the ONLY finding is a stale `mcp/github/dist`, that one is safe to fix
   immediately without asking — it only rebuilds a gitignored artifact, moves
   no files, and needs a fresh Claude Code session afterward anyway to pick
   up the rebuilt server: run `(cd ~/dotclaude/mcp/github && npm run build)`.

4. **Summarize in two lines:** what was pulled + whether links (and
   `mcp/github/dist`) are healthy. Note that config changes, and a rebuilt
   `github-rest` MCP server, apply on the next Claude Code session.
