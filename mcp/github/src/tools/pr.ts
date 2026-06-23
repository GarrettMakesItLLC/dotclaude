import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  errorResult,
  ghRequest,
  jsonText,
  perPage,
  resolveRepo,
} from "../github.js";
import { getChecksSummary } from "../checks.js";

const repoParam = z
  .string()
  .optional()
  .describe('Target repository as "owner/name". Defaults to the repo of the current directory.');

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
        "List pull requests in a repo (returns up to `limit` items, first page only).",
      inputSchema: {
        repo: repoParam,
        state: z.enum(["open", "closed", "all"]).default("open"),
        base: z.string().optional().describe("Filter by base branch name."),
        head: z
          .string()
          .optional()
          .describe('Filter by head, formatted "user:ref-name" or "ref-name".'),
        limit: z.number().int().positive().optional().describe("Max items (<=100, default 30)."),
      },
    },
    async ({ repo, state, base, head, limit }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghRequest(`/repos/${owner}/${name}/pulls`, {
          query: { state, base, head, per_page: perPage(limit) },
        });
        return jsonText(data);
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
        const pr = await fetchPr(repo, number);
        return jsonText({
          number: pr.number,
          title: pr.title,
          state: pr.state,
          draft: pr.draft,
          mergeable: pr.mergeable,
          mergeable_state: pr.mergeable_state,
          head: { ref: pr.head.ref, sha: pr.head.sha },
          base: { ref: pr.base.ref },
          html_url: pr.html_url,
          body: pr.body,
        });
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
        const data = await ghRequest(`/repos/${owner}/${name}/pulls`, {
          method: "POST",
          body: { title, head, base, body, draft },
        });
        return jsonText(data);
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
        const data = await ghRequest(`/repos/${owner}/${name}/pulls/${number}`, {
          method: "PATCH",
          body: { title, body, base, state },
        });
        return jsonText(data);
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
        const data = await ghRequest(
          `/repos/${owner}/${name}/issues/${number}/comments`,
          { method: "POST", body: { body } },
        );
        return jsonText(data);
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
        const data = await ghRequest(
          `/repos/${owner}/${name}/pulls/${number}/requested_reviewers`,
          { method: "POST", body: { reviewers, team_reviewers } },
        );
        return jsonText(data);
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
