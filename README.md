# dotclaude

My personal Claude Code configuration — synced across machines via git.

## What's in here

| Path | Purpose |
|------|---------|
| `CLAUDE.md` | Global instructions injected into **every** session. Universal *behavioral* rules only. |
| `rules/` | Path-scoped stack conventions (`frontend`, `data-api`, `monorepo-hosting`, `ci`). Each loads only when Claude opens a matching file. |
| `skills/` | On-demand procedures: `finishing-work`, `managing-work-with-issues`, `operating-production`, `closing-tool-gaps`, `aligning-repo-config`, `running-an-audit`, `bootstrapping-a-product-repo`. Linked individually into `~/.claude/skills/`, so skills from other sources aren't clobbered. A skill with per-topic checklists keeps them in its own `references/`, loaded only when that topic is in scope. |
| `agents/` | Subagent definitions — the standing instructions and tool set for a dispatched role, so a fan-out doesn't re-specify them per call. `domain-auditor` is the read-only, evidence-required auditor `running-an-audit` fans out. |
| `hooks/` | Deterministic guardrails. `git-guard.sh` blocks dangerous shell commands; `worktree-guard.sh` blocks edits to a `.worktrees/` repo's main tree; `verify-reminder.sh` nudges verification, issue linkage, and per-finding accounting at PR-open, naming the deferred-work markers the branch adds; `worktree-bootstrap.sh` seeds a newly created worktree; `agent-creds-sync.sh` runs a repo's own `bin/agent-env-build.sh`/`bin/ops-pull.sh` at session start, if present, so agent shells and worktrees inherit current credentials; `link-doctor.sh` reports at session start when a committed skill or directory isn't linked into `~/.claude` yet; `subagent-evidence.sh` blocks a subagent report that claims completed work without showing command output; `tool-gap-reporter.sh` names the tool and the repo to file in when the same MCP tool fails twice in a session. Each ships a `*.test.sh` self-test; the script headers are the spec. |
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
| **Skill reference** (`skills/*/references/`) | Only when the skill reads it | Per-topic checklists too long to carry in the skill |
| **Agent** (`agents/`) | Only in the spawned agent's window | The standing role of a dispatched subagent |
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

For a whole machine — toolchain, repo fleet, dependencies, and this config — start
from `dotfiles`, which clones this repo and runs the script below as one of its
steps:

```bash
git clone git@github.com:GarrettMakesItLLC/dotfiles.git ~/workspace/dotfiles
bash ~/workspace/dotfiles/bootstrap/device.sh
```

For this config alone:

```bash
git clone git@github.com:GarrettMakesItLLC/dotclaude.git ~/dotclaude
bash ~/dotclaude/bootstrap.sh
```

The script is idempotent and narrates what it links; re-run it any time — a newly
committed skill or directory needs a run to get its symlink. Real files already
sitting at a link target are moved to `~/.claude.bak.<timestamp>/`, never
overwritten. `bash ~/dotclaude/bootstrap.sh --check` is a read-only link doctor.

Two things bootstrap can't do for you:

- **OAuth connectors and API keys** — per-machine, interactive. See `integrations.md`.
- **Issue labels** — per-repo, not per-machine. Run the `labels_ensure` MCP tool
  once in each project repo, then `labels_audit` to catch leftovers.

Issue and PR templates are no longer copied per repo: `GarrettMakesItLLC/.github`
supplies them org-wide to every repo without its own. `templates/` here stays the
authoring source — edit here, copy forward to that repo.

Standing up a whole new repo to the fleet standard is the
`bootstrapping-a-product-repo` skill.

## Updating

Commit here and pull elsewhere — `~/.claude/` is symlinks back to this repo, so
changes apply on the next session. Re-run `bootstrap.sh` only when a new skill or
directory is added and needs a link. `/dotclaude-sync` does the pull plus
`--check` in one step.

**Edit here, in the repo — never in `~/.claude/`.**

## Org-level repos

Repos above the per-project level are shared across every product repo in `GarrettMakesItLLC`, and
split into two kinds:

| Repo | What |
|------|------|
| `GarrettMakesItLLC/dotclaude` | This repo — Claude Code config, synced across machines. |
| `GarrettMakesItLLC/dotfiles` | Shell and git config across machines. Sibling to this repo; a machine bootstraps from `dotfiles`, which clones this repo as one of its steps (see "Setup on a new machine" above). |
| `GarrettMakesItLLC/.github` | Org-wide issue/PR templates, org profile, and community-health defaults (`CODEOWNERS`, `CONTRIBUTING.md`, `SECURITY.md`, `SUPPORT.md`, `FUNDING.yml`). Per-repo copies are redundant once a repo has none of its own — see "Setup on a new machine" above. |
| `GarrettMakesItLLC/ci` | Shared composite actions and reusable workflows for product-repo CI/CD, tagged `@v1`. See `rules/ci.md`. |
| `GarrettMakesItLLC/platform` | The shared `@gmi/*` package layer (tsconfig, eslint/prettier/commitlint config, design system, interop contracts) consumed by the product repos. |
| `GarrettMakesIt/GarrettMakesIt` | Personal org profile — a *different* GitHub org (`GarrettMakesIt`, not `GarrettMakesItLLC`). |

A convention or config change worth sharing across product repos belongs in one
of these, not copy-pasted per repo — same reasoning as `rules/` being hoisted
here once a rule repeats 3+ times (see "Per-repo overrides" below).

### Local checkout layout

`~/workspace/` holds every checkout except `dotclaude` and `dotfiles` — those bootstrap the machine
itself, so they stay at the special locations "Setup on a new machine" clones them to, not inside
`workspace/`. Everything else splits by whether it's a daily-work product or shared infrastructure:

```
~/workspace/
  MuscleBuddy/, RedThreadEvents/, NetWorthy/, AdventureOS/   # product repos — top level
  Tools/
    ci/, platform/, .github/, GarrettMakesIt/                # org-level repos from the table above
```

A new product repo clones to `~/workspace/<Name>` (the `bootstrapping-a-product-repo` skill). A new
org-level repo clones to `~/workspace/Tools/<name>`.

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
