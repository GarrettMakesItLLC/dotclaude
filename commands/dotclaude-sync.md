---
description: Bring this machine fully up to date with dotclaude + dotfiles and everything they now install
allowed-tools: Bash(bash ~/dotclaude/bin/dot-sync.sh:*)
---

Run `bash ~/dotclaude/bin/dot-sync.sh` and report its output. This is the one
sync path for both dot repos — the same engine the SessionStart hook uses for
the fast, silent, every-session pull, plus the slower checks that hook
deliberately skips:

1. Pulls `~/dotclaude` and `~/dotfiles` (fast-forward only — never forces
   anything, and says exactly what's blocking it if it can't).
2. Runs `bootstrap.sh --check` for dotclaude and dotfiles' own installer,
   reporting drift with the exact fix command. It does **not** apply a fix on
   its own.
3. Flags a stale or missing `github-rest` MCP build (the gitignored `dist/`
   that a plain `git pull` never rebuilds).
4. Reports whether the agent gateway / Claude account ledger tooling exists
   on this machine, without touching it — another agent owns those files.
5. Reports anything this machine is still missing: an un-run install, a
   credential file the roster expects, a dependency the sync itself needed.

If it reports drift or a stale MCP build, tell me the exact command it named
(`bash ~/dotclaude/bin/dot-sync.sh --fix` and/or `--build-mcp`) — don't run
it without my go-ahead, since `--fix` moves real files under `~/.claude` to a
timestamped backup dir.

Pass `--kb` only if I ask to also refresh the Obsidian vault (`bin/kb-sync.sh`) —
it's a multi-tree copy, seconds of cost, not something every sync should pay.

Summarize in a few lines: what was pulled, whether config is healthy, and
what (if anything) needs my go-ahead.
