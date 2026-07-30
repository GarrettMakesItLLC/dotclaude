---
name: closing-tool-gaps
description: Use when a tool fails repeatedly or cannot do what you need — a missing MCP capability, an MCP call that keeps erroring, a hook misfiring, a skill whose instructions no longer match reality — and you are about to work around it. Covers unblocking now, filing the gap where the fix lands, and closing it. Deepest case is building the missing tool into the vendored github-rest MCP.
allowed-tools: Bash(gh api:*), Bash(npm run:*), Bash(npm test:*), mcp__github-rest__issue_open, mcp__github-rest__issue_claim, mcp__github-rest__pr_create
---

# Closing tool gaps

**A tool that keeps failing, or cannot do what you need, is a defect in this ecosystem — not a fact about the world.** Unblock, file it where the fix would land, and close it when closing it is small. `tool-gap-reporter.sh` says so out loud when the same MCP tool fails twice in a session; this is the procedure it points at.

## 1. Is it a gap, or a wrong call?

Settle this first. A filed non-gap costs more than an unfiled one, because it sends the next session chasing a bug that isn't there.

**Not a gap:** a 404 for something that genuinely does not exist; a validation error naming an argument you got wrong; an auth error on an MCP that needs re-authenticating (`integrations.md`); a rate limit; a capability the tool never claimed. Fix the call, authenticate, move on.

**A gap:** the operation has no tool at all; the tool rejects input its own schema says it accepts; it returns the wrong shape or silently truncates; the same call fails twice with nothing wrong on your side; a hook blocks work it was not meant to block; a skill's instructions no longer match the code.

## 2. Unblock now

Use the lowest-level thing that works, and say in your summary that you fell back and why — the fallback *is* the gap signal.

For GitHub: `gh api` (REST). Never `gh api graphql`, and avoid `gh`'s convenience subcommands (`gh pr edit`, `gh pr merge`) — they can silently route through the deprecated GraphQL `projectCards` path the MCP exists to avoid. **Percent-encode the name in the final path segment**: `gh api repos/O/R/labels/source:owner` 404s for a label that exists while `source%3Aowner` returns it, so an unencoded write reports success at doing nothing.

For a plugin MCP: the vendor's CLI (`vercel`, `railway`, `supabase`, `gh`) or its documented REST API. Never hand-roll an issue claim — that protocol depends on an atomic ref-create, so if `issue_claim` is unavailable, say so and stop.

## 3. File it where the fix lands

| The gap is in | File in | Then |
|---|---|---|
| A vendored MCP (`mcp/github` → `github-rest`) | `GarrettMakesItLLC/dotclaude` | Build it — §4 |
| A hook, skill, rule, or `CLAUDE.md` itself | `GarrettMakesItLLC/dotclaude` | Fix it in the same PR when small |
| A plugin or connector MCP (Supabase, Vercel, Railway, Sentry, Prisma, Playwright, Notion, Gmail/Calendar/Drive, upload-post) | `GarrettMakesItLLC/dotclaude`, as a **tracking** issue | Record the workaround; the source is not ours to patch |
| Tooling owned by one app (its scripts, CI, generators) | that app's repo | Per that repo's autonomy mode |

Every gap issue carries the **exact call** and arguments, the **error text**, what you **expected**, the **workaround** you used, and — for a missing capability — the endpoint or flag that would back it. `type:task`, or `type:feature` when it is genuinely a new capability. A third-party gap also names the plugin version, so it can be closed when an update fixes it instead of lingering.

Filing is not conditional on fixing. File it even when you close it in the same session — the issue is what makes the PR reviewable and the history searchable.

## 4. Close it — the vendored-MCP case

Most missing tools wrap a single REST endpoint. For those, do not stop at filing:

- Worktree off `main`; TDD in `mcp/github` (test → red → implement → green), matching the existing tool style: zod schema, `ghRequest`/`ghPaginate`, `jsonText`/`errorResult`, `.js` specifiers, no `any` in `src/`.
- Verify: `npm run typecheck && npm test && npm run build`.
- PR with `Closes #<gap issue>`, shipped under the **target repo's** autonomy mode.
- The running server serves the new tool only after `npm run build` in `mcp/github` **and** a Claude Code restart — so a tool you just added is not callable in the session that added it. Keep using the fallback for the rest of that session.

## When to file and NOT build

Large, ambiguous, needs a design decision, touches auth, or lives in someone else's source — file it (`status:blocked` if it needs Garrett) and stop. The build-and-merge path is for the common case: one more thin wrapper.
