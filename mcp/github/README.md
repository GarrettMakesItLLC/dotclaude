# github-rest-mcp

A local **stdio** MCP server that wraps the GitHub **REST** API so Claude can drive
issues, pull requests, and repo/CI status directly — without shelling out to the
`gh` CLI for every action.

## Why

The `gh` CLI routes some commands through GitHub's **GraphQL** API. Those paths
hit the now-deprecated `projectCards` field and fail with:

```
GraphQL: Projects (classic) is being deprecated ... (repository.issue.projectCards)
```

Working around it meant fragile `gh api` + `jq` pipelines. This server avoids
both: it talks to the GitHub **REST** API exclusively (never GraphQL) and never
shells out to `gh api` or depends on `jq`. The only use of `gh` is to obtain an
auth token (`gh auth token`).

## Requirements

- **Node 24+** (uses global `fetch`).
- **GitHub CLI authenticated** — the server gets its token from `gh auth token`.
  If you are not logged in, run:

  ```bash
  gh auth login
  ```

  The token is cached in memory. On a `401` the server refetches the token once
  and retries the request once.

## Repo resolution

Every tool takes an optional `repo` parameter formatted `"owner/name"`. When
omitted, the server resolves a default once (cached) by running
`gh repo view --json nameWithOwner -q .nameWithOwner` in the current working
directory. If that fails and no `repo` was supplied, the tool returns a clear
error asking you to pass `repo` explicitly.

## Tools

Pull requests:

- `pr_list` — list PRs (`state`, `base`, `head`, `limit`).
- `pr_view` — view one PR (number, title, state, draft, mergeable,
  mergeable_state, head ref/sha, base ref, html_url, body).
- `pr_create` — create a PR (`title`, `head`, `base`, `body?`, `draft?`).
- `pr_update` — update a PR (`title?`, `body?`, `base?`, `state?`).
- `pr_comment` — comment on a PR.
- `pr_request_review` — request `reviewers` and/or `team_reviewers`.
- `pr_checks` — resolve the PR head sha, then merge combined commit status +
  check-runs into one overall state with per-check detail.

Issues:

- `issue_list` — list issues (PRs filtered out; `state`, `labels`, `limit`).
- `issue_view` — view one issue.
- `issue_create` — create an issue (`title`, `body?`, `labels?`, `assignees?`).
- `issue_update` — update an issue (`title?`, `body?`, `state?`, `state_reason?`
  — `completed` / `not_planned` / `reopened`).
- `issue_comment` — comment on an issue.
- `issue_set_labels` — replace all labels on an issue.
- `issue_add_assignees` / `issue_remove_assignees` — (un)assign users; accepts
  `@me`.
- `issue_claim` — self-assign `@me` and set `status:in-progress`, removing any
  other `status:*` label. Use when starting work on an issue.
- `issue_set_type` — set bug/feature/task as the native issue type
  (best-effort) plus a `type:*` label.
- `issue_set_milestone` / `milestone_ensure` — attach an issue to a milestone,
  finding or creating it by title.
- `issue_add_sub_issue` / `issue_list_sub_issues` — manage parent/child issue
  relationships.

Labels:

- `labels_ensure` — idempotently provision the standard `status:*` / `type:*`
  / `source:*` label taxonomy into a repo.

Repo:

- `repo_get` — repo metadata (name, full_name, default_branch, private,
  html_url, description).
- `branch_list` — list branches.
- `ref_status` — merged status + check-runs summary for a branch or sha.

The list tools (`pr_list`, `issue_list`, `branch_list`) return up to `limit`
items (max 1000, default 30), following GitHub's `Link: rel="next"` pagination
across pages of 100. For `issue_list` the GitHub `/issues` endpoint mixes in
pull requests; those are filtered out and pages are followed until `limit` real
issues are collected, so PR-heavy repos still return a full result. Pagination
is bounded to 10 pages per call.

## Build

```bash
npm install
npm run build      # tsc -> dist/
npm run typecheck  # tsc --noEmit
npm test           # vitest run (no network; gh + fetch are mocked)
```

## Register (local stdio)

Launch the built server with `node dist/index.js`. Example MCP client entry:

```json
{
  "mcpServers": {
    "github": {
      "command": "node",
      "args": ["/absolute/path/to/mcp/github/dist/index.js"]
    }
  }
}
```

The server inherits the working directory of the client, which is what default
repo resolution uses.
