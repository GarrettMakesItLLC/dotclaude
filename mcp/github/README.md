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
- `issue_update` — update an issue (`title?`, `body?`, `state?`).
- `issue_comment` — comment on an issue.
- `issue_set_labels` — replace all labels on an issue.

Repo:

- `repo_get` — repo metadata (name, full_name, default_branch, private,
  html_url, description).
- `branch_list` — list branches.
- `ref_status` — merged status + check-runs summary for a branch or sha.

List tools return up to `limit` items (max 100, default 30) from the first page only.

## Build

```bash
npm install
npm run build      # tsc -> dist/
npm run typecheck  # tsc --noEmit
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
