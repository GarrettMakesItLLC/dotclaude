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

- **`GH_TOKEN`/`GITHUB_TOKEN` set in your shell shadow your `gh auth login`
  scopes.** Every `gh` process this server spawns strips both env vars, so it
  always uses your keyring-stored login rather than a narrower-scoped env-var
  token. If neither env var is set this has no effect; if one is, and it's
  missing `project` scope, this is what makes `issue_set_effort`/
  `issue_set_priority` work without needing to touch the env var at all.

## Repo resolution

Every tool takes an optional `repo` parameter formatted `"owner/name"`. When
omitted, the server resolves a default once (cached) by running
`gh repo view --json nameWithOwner -q .nameWithOwner` in the current working
directory. If that fails and no `repo` was supplied, the tool returns a clear
error asking you to pass `repo` explicitly.

## Response shape

Every tool returns a projection (`src/slim.ts`), never the raw REST payload. A
tool result stays in the model's context for the rest of the session and is
re-read on every subsequent turn, so a raw issue (~6KB) or PR (~20KB) is a
recurring cost paid for fields nothing reads — nested actor objects, full label
objects for names already in hand, and a dozen `*_url` variants. `issue_list` at
its default limit of 30 goes from ~60k tokens to ~3k.

The contract:

- Actors collapse to logins, labels to names, milestones to titles.
- Absent and empty fields are omitted rather than emitted as `null`/`[]`.
- **List tools omit `body`; single-object views (`issue_view`, `pr_view`)
  include it.** Fetch the view when you need the body.
- **Writes acknowledge what changed** — a number, a URL, the mutated field —
  instead of echoing the whole object back.
- JSON is serialized compact; indentation buys nothing on a projected payload.

## Tools

Pull requests:

- `pr_list` — list PRs (`state`, `base`, `head`, `limit`).
- `pr_view` — view one PR, including `body`.
- `pr_create` — create a PR (`title`, `head`, `base`, `body?`, `draft?`).
- `pr_update` — update a PR (`title?`, `body?`, `base?`, `state?`).
- `pr_comment` — comment on a PR.
- `pr_request_review` — request `reviewers` and/or `team_reviewers`.
- `pr_checks` — resolve the PR head sha, then merge combined commit status +
  check-runs into one overall state with per-check detail.
- `pr_open_for_issue` — open a PR and move its issue to in-review in one
  call: ensures the body closes `issue_number` (appending `Closes #N` if not
  already present), creates the PR, then sets the issue's status to
  `in-review`.
- `pr_merge` — merge a PR (`method?` merge/squash/rebase, default `squash`,
  `commit_title?`, `commit_message?`), optionally deleting the head branch
  afterward (`delete_branch?`; refuses `main`/`master`).

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
- `issue_claim` — take the distributed lock for an issue, then self-assign `@me`
  and set `status:in-progress`. See [Claiming work](#claiming-work).
- `issue_set_status` — set the single `status:*` label (or clear it), preserving
  all other labels. Accepts any status in the taxonomy (`src/labels.ts`).
- `issue_set_type` — set bug/feature/task as the native GitHub issue type. A
  hard PATCH of the native type only — no label written.
- `issue_set_effort` / `issue_set_priority` — set the Effort (trivial/
  standard/complex) or Priority (urgent/high/medium/low) field on the shared
  GarrettMakesItLLC — Work project. The issue must already be a project item.
- `issue_set_milestone` / `milestone_ensure` — attach an issue to a milestone,
  finding or creating it by title.
- `issue_add_sub_issue` / `issue_list_sub_issues` — manage parent/child issue
  relationships.
- `issue_set_blocked_by` / `issue_list_blocked_by` — set or list GitHub's
  native issue-dependencies "blocked by" relationship for issues in the same
  repo. `issue_set_blocked_by` skips blockers already linked and reports them
  separately from newly-added ones.
- `issue_open` — create a fully-formed issue in one call: composes
  `status:*`/`source:*` labels, sets the native issue type (best-effort),
  finds-or-creates and attaches a milestone by title, sets Effort/Priority on
  the shared project (best-effort), and nests it under a `parent` as a
  sub-issue. Composes the granular tools above so agents don't have to
  hand-compose fields across several calls.

Claims:

- `issue_claim` — acquire the lock and start work (listed under Issues above).
- `claim_release` — delete an issue's lock branch, returning the issue to
  `status:ready` and unassigning `@me`. Refuses when the branch holds commits
  that landed nowhere, unless `force`.
- `work_in_flight` — every `issue-*` lock branch on the remote with its last
  commit (author + time) and any open PR.

Labels:

- `labels_ensure` — idempotently provision the canonical taxonomy (`status:*`,
  `source:*`, and the markers `epic` / `launch-blocker`) into a repo,
  and retitle GitHub's colliding stock labels (`bug`, `enhancement`,
  `documentation`) as deprecated where they already exist.
- `labels_audit` — read-only drift report: missing canonical labels, stock
  labels not yet retitled, removable GitHub defaults still present, labels the
  taxonomy doesn't recognize (per-repo `area:*`/`module:*` axes land here and
  are fine), and per-repo labels wearing a canonical label's exact color.
- `label_list` — every label with color, description, and how many issues carry
  it.
- `label_update` — rename, recolor, or redescribe. A rename carries the label
  across every issue that has it, so a legacy label folds into the taxonomy
  without losing history.
- `label_delete` — delete, reporting the issue count it was attached to.
  Refuses on a canonical label without `force`.

Repo:

- `repo_get` — repo metadata (name, full_name, default_branch, private,
  html_url, description).
- `branch_list` — list branches.
- `repo_file_read` — read a file from a repo without checking it out (decoded
  text + path/sha/size/line count, or a directory's entry names). Windows to
  500 lines by default; page with `offset`/`limit`.
- `ref_status` — merged status + check-runs summary for a branch or sha.

The list tools (`pr_list`, `issue_list`, `branch_list`) return up to `limit`
items (max 1000, default 30), following GitHub's `Link: rel="next"` pagination
across pages of 100. For `issue_list` the GitHub `/issues` endpoint mixes in
pull requests; those are filtered out and pages are followed until `limit` real
issues are collected, so PR-heavy repos still return a full result. Pagination
is bounded to 10 pages per call.

Effort and Priority live as custom fields on the shared `GarrettMakesItLLC — Work`
GitHub Project (Projects v2), not as labels — `issue_set_effort`,
`issue_set_priority`, `issue_claim`'s effort/model-mismatch check, and
`issue_open`'s `effort`/`priority` params all shell out to `gh project` under
the hood, so they require `gh` CLI auth with the `project` scope (`gh auth
refresh -s project` if it's missing). A token missing it fails in one of two
ways depending on which of gh's own checks trips first — an explicit "missing
required scopes" error, or the unrelated-looking "unknown owner type" — both
of which `src/project.ts` recognizes and rewraps with this same remediation,
so the `_warnings` a caller sees already carries the fix rather than gh's raw
text.

## Claiming work

Agents run against these repos from more than one machine, all authenticating as
the same GitHub user — so the assignee field cannot arbitrate who owns an issue,
and in-flight work sitting in a local worktree is invisible to the other machine.

The lock is a **remote branch ref**. `POST /git/refs` is atomic and server-side:
it returns `422` when the ref already exists, which makes it a true distributed
mutex, and the pushed branch simultaneously advertises the work.

`issue_claim` therefore, in order:

1. resolves the branch `issue-<N>-<title-slug>` (override with `branch`),
2. creates that ref at the default-branch head — a `422` here means **already
   claimed**, and the call fails with the holder's branch, last commit
   author/date, any open PR, and — when a stamp was posted — who holds it and
   when, so a live claim is distinguishable from an abandoned one,
3. posts a claim-stamp comment on the issue (holder identity + timestamp,
   `CLAIM_MACHINE_ID` env var or else `os.hostname()`) — best-effort, reported
   in `_warnings` on failure; the ref is what actually holds the lock,
4. self-assigns and sets `status:in-progress` — failures there are also
   reported in `_warnings` and never roll back the ref,
5. returns the branch to `git fetch && git checkout` rather than creating your own.

The stamp exists because the ref alone answers "is this claimed?" but not "by
whom" — every machine authenticates as the same GitHub user, so a conflict
can't otherwise tell your own earlier session from another machine. On a
conflict, the failure message says whether the stamp matches this machine
(safe to investigate resuming) or a different one (default to picking
different work; the mismatch alone is not evidence of abandonment).

Before picking up work, call `work_in_flight` to see what the other machine
already holds — each row includes `claimed_by`/`claimed_at` from the stamp,
alongside last-commit detail and any open PR. To drop a dead claim,
`claim_release` deletes the ref — refusing when the branch carries commits not
merged anywhere unless `force: true`.

The `claim-guard.sh` PreToolUse hook enforces the protocol at the first edit:
on a branch named `issue-<N>-*` whose issue is not assigned with
`status:in-progress`, the edit is blocked.

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
