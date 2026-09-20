# Knowledge base (Obsidian vault)

A browsable, backlinked, graphed view over Markdown that already exists
across the fleet: the per-project auto-memory notes under
`~/.claude/projects/*/memory` and each repo's `CLAUDE.md` / `.claude/rules/`
(plus MuscleBuddy's `docs/`, the one repo with a normative docs tree worth
including whole). It answers "what do I know about X across every machine
and project", which no single repo or memory dir can on its own.

**This is a generated, read-only view.** The repos and the memory dirs stay
the source of truth. Never edit inside the vault — a refresh will overwrite
it. Edit the memory file or the repo doc, then re-run the refresh command.

## Refresh

```
bin/kb-sync.sh
```

Idempotent — safe to run any time, on a cron, or from a session hook (see
below). Add `--dry-run` to see what would change without writing anything.

## Open it in Obsidian (Windows, WSL2 backend)

The vault lives inside WSL at `~/vault` (i.e. `/home/garrett/vault`), which
Windows reaches over the `\\wsl.localhost\` share. **The exact path depends
on your WSL distro name** — check it with `echo $WSL_DISTRO_NAME` inside
WSL, or `wsl -l -v` from PowerShell. On this machine that's `Ubuntu-22.04`,
so the path is:

```
\\wsl.localhost\Ubuntu-22.04\home\garrett\vault
```

1. Install Obsidian for Windows from <https://obsidian.md/download> (not the
   Linux/WSL build — it runs on the Windows side and reaches into WSL over
   the network share).
2. Run `bin/kb-sync.sh` at least once so the vault exists.
3. In Obsidian, **Open folder as vault** and paste the path above into the
   Windows file picker's address bar (File Explorer accepts it too, for
   browsing without Obsidian).
4. First open seeds a small starter config (`templates/obsidian/`, see
   below) — appearance, and which core panels are on. No community plugins
   are installed automatically; add any you want by hand from Obsidian's
   settings.

**Why no symlinks:** the script copies (rsync) every source tree into the
vault rather than symlinking it, because Windows Obsidian does not reliably
follow symlinks created from the WSL side. Copies also mean editing inside
the vault is caught immediately — a real file changed there is just a stray
edit waiting to be overwritten, not a link that quietly writes back to the
source.

## What's included, and why

| Vault path | Source | Notes |
|---|---|---|
| `memory/<project>/` | `~/.claude/projects/<project-slug>/memory/*.md` | One fact per file, YAML frontmatter + `[[wiki-links]]` already in Obsidian's own syntax — no conversion needed. `skill-observations/` is excluded (working state for the task-observer skill, not a durable fact). |
| `repos/<repo>/CLAUDE.md` | that repo's `CLAUDE.md` | Only repos that have one. |
| `repos/<repo>/rules/` | that repo's `.claude/rules/*.md` | Only repos that have any. |
| `repos/MuscleBuddy/docs/` | MuscleBuddy's `docs/` tree | SPEC, ARCHITECTURE, API, RUNBOOK, and the rest — hand-maintained reference docs (some contain small CI-guarded generated blocks marked with `<!-- x:start/end -->` comments, which is a different thing from a wholly generated file and stays included). |

**Deliberately excluded:**

- `docs/superpowers/` inside MuscleBuddy — a ~5.5MB, 175-file dated archive
  of historical design specs and implementation plans. It's a changelog of
  past planning sessions, not source-of-truth reference material, and its
  size would dwarf everything else in the vault for little browsing value.
- Any workspace directory named `*-worktrees` or `scratchpad`, and any repo
  with neither a `CLAUDE.md` nor `.claude/rules/` — nothing to vault.
- Repos' own generated/build output, `node_modules`, etc. — never touched;
  the script only ever reads `CLAUDE.md`, `.claude/rules/*.md`, and (for
  MuscleBuddy) `docs/**`.

Adding a new repo needs no script change: any repo under `$WORKSPACE_ROOT`
(default `~/workspace`) with a `CLAUDE.md` or `.claude/rules/` is picked up
automatically on the next refresh.

## Adding a new source tree

`bin/kb-sync.sh` is a short, linear script — each source tree is a `sync_tree`
or `copy_file` call plus an entry in the generated index/map. To add one:

1. Pick or add an env var for its root (follow `WORKSPACE_ROOT`'s pattern).
2. Add a `sync_tree <src> <dest-under-$VAULT_DIR> <label> [rsync filters]`
   call — `--include`/`--exclude` pairs control which files copy (see the
   MuscleBuddy `docs/` block for an example that excludes a subtree).
3. Add the new destination to the relevant `gen_index` call and to
   `Map of Content.md` so it's actually reachable from the vault root.
4. Re-run `bin/kb-sync.test.sh` — it fixture-tests inclusion/exclusion
   rules the same way, so a new fixture there is the cheapest way to pin the
   new tree's behavior.

## Keeping it fresh

Two options, same script either way:

**Cron** (set-and-forget, zero session cost):

```
*/30 * * * * /home/garrett/dotclaude/bin/kb-sync.sh >> /home/garrett/.cache/kb-sync.log 2>&1
```

**A dotclaude session hook** (refreshes on every Claude Code session start,
so the vault is never more than one session behind): add a `SessionStart`
hook in `settings.json` that runs `bin/kb-sync.sh`, the same pattern
`hooks/dotrepo-sync.sh` uses. The honest tradeoff: this costs a small amount
of wall time on *every* session start (an `rsync` pass over every source
tree, even when nothing changed), where cron's cost is invisible because
it's not on any interactive path. Cron is the better default unless the
vault needs to be current within the same session that just wrote a memory
note or doc.
