import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  cacheKey,
  cachedGet,
  errorResult,
  ghPaginate,
  ghRequest,
  invalidate,
  jsonText,
  repoParam,
  resolveRepo,
} from "../github.js";
import { getChecksSummary } from "../checks.js";
import { setIssueStatus } from "../issue-status.js";
import { actorLogins, slimComment, slimPr, type RawPull } from "../slim.js";

interface PullRequest {
  number: number;
  title: string;
  state: string;
  draft: boolean;
  mergeable: boolean | null;
  mergeable_state: string;
  head: { ref: string; sha: string };
  base: { ref: string };
  html_url: string;
  body: string | null;
}

async function fetchPr(repo: string | undefined, number: number) {
  const { owner, name } = await resolveRepo(repo);
  return ghRequest<PullRequest>(`/repos/${owner}/${name}/pulls/${number}`);
}

export function registerPrTools(server: McpServer): void {
  server.registerTool(
    "pr_list",
    {
      description:
        "List pull requests in a repo (returns up to `limit` items, following pagination).",
      inputSchema: {
        repo: repoParam,
        state: z.enum(["open", "closed", "all"]).default("open"),
        base: z.string().optional().describe("Filter by base branch name."),
        head: z
          .string()
          .optional()
          .describe('Filter by head, formatted "user:ref-name" or "ref-name".'),
        limit: z.number().int().positive().optional().describe("Max items (<=1000, default 30)."),
      },
    },
    async ({ repo, state, base, head, limit }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghPaginate<RawPull>(`/repos/${owner}/${name}/pulls`, {
          query: { state, base, head },
          limit,
        });
        return jsonText(data.map((p) => slimPr(p)));
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "pr_view",
    {
      description: "View a single pull request with merge/branch details.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Pull request number."),
      },
    },
    async ({ repo, number }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const pr = await cachedGet(cacheKey("pr", `${owner}/${name}`, number), () =>
          fetchPr(repo, number),
        );
        return jsonText(slimPr(pr, { body: true }));
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "pr_create",
    {
      description: "Create a pull request.",
      inputSchema: {
        repo: repoParam,
        title: z.string().describe("PR title."),
        head: z.string().describe("Branch with your changes."),
        base: z.string().describe("Branch you want to merge into."),
        body: z.string().optional().describe("PR description (markdown)."),
        draft: z.boolean().optional().describe("Open as a draft PR."),
      },
    },
    async ({ repo, title, head, base, body, draft }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghRequest<RawPull>(`/repos/${owner}/${name}/pulls`, {
          method: "POST",
          body: { title, head, base, body, draft },
        });
        return jsonText(slimPr(data));
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "pr_update",
    {
      description: "Update a pull request (title, body, base branch, or open/closed state).",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Pull request number."),
        title: z.string().optional(),
        body: z.string().optional(),
        base: z.string().optional().describe("New base branch."),
        state: z.enum(["open", "closed"]).optional(),
      },
    },
    async ({ repo, number, title, body, base, state }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghRequest<RawPull>(`/repos/${owner}/${name}/pulls/${number}`, {
          method: "PATCH",
          body: { title, body, base, state },
        });
        invalidate(cacheKey("pr", `${owner}/${name}`, number));
        return jsonText(slimPr(data));
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "pr_comment",
    {
      description: "Add a comment to a pull request (uses the issues comments endpoint).",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Pull request number."),
        body: z.string().describe("Comment body (markdown)."),
      },
    },
    async ({ repo, number, body }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghRequest<{ id: number; html_url: string; created_at: string }>(
          `/repos/${owner}/${name}/issues/${number}/comments`,
          { method: "POST", body: { body } },
        );
        invalidate(cacheKey("pr", `${owner}/${name}`, number));
        return jsonText(slimComment(data));
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "pr_request_review",
    {
      description: "Request reviewers and/or team reviewers on a pull request.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Pull request number."),
        reviewers: z
          .array(z.string())
          .optional()
          .describe("Usernames to request review from."),
        team_reviewers: z
          .array(z.string())
          .optional()
          .describe("Team slugs to request review from."),
      },
    },
    async ({ repo, number, reviewers, team_reviewers }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghRequest<RawPull>(
          `/repos/${owner}/${name}/pulls/${number}/requested_reviewers`,
          { method: "POST", body: { reviewers, team_reviewers } },
        );
        invalidate(cacheKey("pr", `${owner}/${name}`, number));
        return jsonText({ number, requested_reviewers: actorLogins(data.requested_reviewers) });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "pr_open_for_issue",
    {
      description:
        "Open a PR and move its issue to in-review in one call: ensures the PR body closes " +
        "`issue_number` (appending `Closes #N` if not already present) so merging auto-closes it, " +
        "creates the PR, then sets the issue's status to `in-review`. The PR itself is always " +
        "created first; the status move is best-effort — on failure the created PR is still " +
        "returned, annotated with a `_warnings` array.",
      inputSchema: {
        repo: repoParam,
        issue_number: z.number().int().positive().describe("Issue number this PR resolves."),
        head: z.string().describe("Branch with your changes."),
        base: z.string().describe("Branch you want to merge into."),
        title: z.string().describe("PR title."),
        body: z.string().optional().describe("PR description (markdown)."),
        draft: z.boolean().optional().describe("Open as a draft PR."),
      },
    },
    async ({ repo, issue_number, head, base, title, body, draft }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const closesRef = `Closes #${issue_number}`;
        const base_ = body ?? "";
        const alreadyLinked = new RegExp(
          `(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\s+#${issue_number}(?![0-9])`,
          "i",
        ).test(base_);
        const finalBody = alreadyLinked
          ? base_
          : base_
            ? `${base_}\n\n${closesRef}`
            : closesRef;

        const pr = await ghRequest<RawPull>(`/repos/${owner}/${name}/pulls`, {
          method: "POST",
          body: { title, head, base, body: finalBody, draft },
        });

        // The PR is already created at this point — a status-move failure below must not
        // hide that creation behind an errorResult, or a retry would hit a 422 (branch in use).
        const warnings: string[] = [];
        try {
          await setIssueStatus(owner, name, issue_number, "in-review");
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          warnings.push(`issue #${issue_number} not moved to in-review: ${msg}`);
        }

        const slim = slimPr(pr);
        return jsonText(warnings.length ? { ...slim, _warnings: warnings } : slim);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "pr_merge",
    {
      description:
        "Merge a pull request. Optionally deletes the head branch afterward (skipped, with a " +
        "`_warnings` note, for `main`/`master` or if the delete fails — the merge itself is not " +
        "rolled back).",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Pull request number."),
        method: z
          .enum(["merge", "squash", "rebase"])
          .default("squash")
          .describe("Merge method."),
        commit_title: z.string().optional().describe("Title for the merge commit."),
        commit_message: z.string().optional().describe("Extra detail for the merge commit."),
        delete_branch: z
          .boolean()
          .default(false)
          .describe("Delete the head branch after a successful merge."),
      },
    },
    async ({ repo, number, method, commit_title, commit_message, delete_branch }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const result = await ghRequest<{ merged: boolean; sha?: string; message?: string }>(
          `/repos/${owner}/${name}/pulls/${number}/merge`,
          {
            method: "PUT",
            body: {
              merge_method: method,
              commit_title,
              commit_message,
            },
          },
        );
        invalidate(cacheKey("pr", `${owner}/${name}`, number));

        const warnings: string[] = [];
        if (delete_branch && result.merged) {
          const pr = await fetchPr(repo, number);
          const ref = pr.head.ref;
          if (ref === "main" || ref === "master") {
            warnings.push(`refused to delete protected branch "${ref}"`);
          } else {
            try {
              await ghRequest(`/repos/${owner}/${name}/git/refs/heads/${ref}`, {
                method: "DELETE",
              });
            } catch (err) {
              const msg = err instanceof Error ? err.message : String(err);
              warnings.push(`branch "${ref}" not deleted: ${msg}`);
            }
          }
        }

        return jsonText(warnings.length ? { ...result, _warnings: warnings } : result);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "pr_checks",
    {
      description:
        "Summarize CI for a PR: resolves the head sha, then merges the combined commit status and check-runs into one overall state with per-check name/status/conclusion.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Pull request number."),
      },
    },
    async ({ repo, number }) => {
      try {
        const ref = await resolveRepo(repo);
        const pr = await ghRequest<{ head: { sha: string } }>(
          `/repos/${ref.owner}/${ref.name}/pulls/${number}`,
        );
        const summary = await getChecksSummary(ref, pr.head.sha);
        return jsonText(summary);
      } catch (err) {
        return errorResult(err);
      }
    },
  );
}
