---
name: extending-the-github-mcp
description: Use when you need a GitHub operation the github-rest MCP does not expose — you are about to reach for a raw `gh`/curl command because a tool is missing. Covers unblocking now and growing the MCP so the gap closes for every agent.
---

# Extending the github-rest MCP

The `github-rest` MCP (source: `mcp/github/` in this repo) is the sanctioned, REST-only way agents drive GitHub. When you hit a capability gap — an operation no tool exposes — do not just work around it silently. Close the loop.

## 1. Unblock now (fallback)
Use a raw `gh` command to finish your immediate task. REST-only paths — never `gh api graphql` (the MCP is REST-only precisely to avoid the deprecated GraphQL `projectCards` path). **State in your summary that you fell back and why** — a fallback is the signal that the MCP has a gap.

## 2. Capture the gap — always file an issue
File an issue in `GarrettMakesItLLC/dotclaude` describing the missing capability: the operation, why it was needed, and the REST endpoint that would back it. `type:task`. Use `issue_open` if the tool is available; otherwise `gh issue create`. This guarantees the gap is never lost, even if you do not fix it now.

## 3. Close the gap — grow the MCP
Most missing tools wrap a single REST endpoint — small and clear. For those, do not stop at filing; add the tool:
- Worktree off `main`; TDD in `mcp/github` (test → red → implement → green), following the existing tool style (zod schema, `ghRequest`, `jsonText`/`errorResult`, `.js` specifiers, no `any` in `src/`).
- Verify: `npm run typecheck && npm test && npm run build`.
- Get it reviewed (dispatch a reviewer subagent), open a PR with `Closes #<gap issue>`, and once **CI is green and review is clean, merge it** — growing the shared tooling is autonomous-merge work: agents own the full process including the merge. CI is the gate (never merge on red/pending); force-push to `main` stays off-limits.
- After merge the running MCP server serves the new tool only after a rebuild + reload: `npm run build` in `mcp/github`, then restart Claude Code.

## When to file and NOT build
If the change is large, ambiguous, needs a design decision, or touches auth/security, file the issue (`status:blocked` if it needs Garrett's input) and stop. The build-and-merge path is for the common case: one more thin REST wrapper.
