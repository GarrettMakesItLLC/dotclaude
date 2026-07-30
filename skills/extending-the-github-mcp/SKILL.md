---
name: extending-the-github-mcp
description: Use when you need a GitHub operation the github-rest MCP does not expose — you are about to reach for a raw `gh`/curl command because a tool is missing. Covers unblocking now and growing the MCP so the gap closes for every agent.
allowed-tools: Bash(gh api:*), Bash(npm run:*), Bash(npm test:*), mcp__github-rest__issue_open, mcp__github-rest__issue_claim, mcp__github-rest__pr_create
---

# Extending the github-rest MCP

Source: `mcp/github/` in `GarrettMakesItLLC/dotclaude`. A capability gap is a bug in the MCP, not a fact of life — close the loop.

## 1. Unblock now

Fall back to `gh api` (REST). Never `gh api graphql`, and avoid `gh`'s convenience subcommands (`gh pr edit`, `gh pr merge`) — they can silently route through the deprecated GraphQL `projectCards` path the MCP exists to avoid. **Say in your summary that you fell back and why** — the fallback is the gap signal.

**Percent-encode the name in the final path segment.** `gh api repos/O/R/labels/source:owner` returns 404 for a label that exists; `source%3Aowner` returns it. The 404 reads as "absent", so an unencoded write reports success at doing nothing. The MCP builds its own URL and is unaffected.

## 2. Capture the gap

File an issue in `GarrettMakesItLLC/dotclaude`: the operation, why it was needed, the REST endpoint that would back it. `type:task`. This happens even if you go on to fix it.

## 3. Close the gap

Most missing tools wrap a single REST endpoint. For those, don't stop at filing:

- Worktree off `main`; TDD in `mcp/github` (test → red → implement → green), matching the existing tool style: zod schema, `ghRequest`, `jsonText`/`errorResult`, `.js` specifiers, no `any` in `src/`.
- Verify: `npm run typecheck && npm test && npm run build`.
- Reviewer subagent, then a PR with `Closes #<gap issue>`. Ship it under the **target repo's** autonomy mode (CLAUDE.md).
- The running server serves the new tool only after `npm run build` in `mcp/github` **and** a Claude Code restart.

## When to file and NOT build

Large, ambiguous, needs a design decision, or touches auth — file it (`status:blocked` if it needs Garrett) and stop. The build-and-merge path is for the common case: one more thin REST wrapper.
