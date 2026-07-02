import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  errorResult,
  getViewerLogin,
  ghPaginate,
  ghRequest,
  jsonText,
  resolveRepo,
} from "../github.js";

const repoParam = z
  .string()
  .optional()
  .describe('Target repository as "owner/name". Defaults to the repo of the current directory.');

interface IssueLike {
  number: number;
  // Present only on items that are actually pull requests.
  pull_request?: unknown;
}

async function resolveAssignees(assignees: string[]): Promise<string[]> {
  const out: string[] = [];
  for (const a of assignees) out.push(a === "@me" ? await getViewerLogin() : a);
  return out;
}

export function registerIssueTools(server: McpServer): void {
  server.registerTool(
    "issue_list",
    {
      description:
        "List issues in a repo (up to `limit` issues, default 30, following pagination). Pull requests are filtered out.",
      inputSchema: {
        repo: repoParam,
        state: z.enum(["open", "closed", "all"]).default("open"),
        labels: z
          .array(z.string())
          .optional()
          .describe("Filter to issues having all of these labels."),
        limit: z.number().int().positive().optional().describe("Max issues (<=1000, default 30)."),
      },
    },
    async ({ repo, state, labels, limit }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        // The /issues endpoint mixes in PRs, so filter them out and page until
        // we have `limit` real issues — otherwise PR-heavy repos return too few.
        const issuesOnly = await ghPaginate<IssueLike>(
          `/repos/${owner}/${name}/issues`,
          {
            query: {
              state,
              labels: labels && labels.length ? labels.join(",") : undefined,
            },
            limit,
            filter: (item) => !("pull_request" in item) || !item.pull_request,
          },
        );
        return jsonText(issuesOnly);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_view",
    {
      description: "View a single issue.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
      },
    },
    async ({ repo, number }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghRequest(`/repos/${owner}/${name}/issues/${number}`);
        return jsonText(data);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_create",
    {
      description: "Create an issue.",
      inputSchema: {
        repo: repoParam,
        title: z.string().describe("Issue title."),
        body: z.string().optional().describe("Issue body (markdown)."),
        labels: z.array(z.string()).optional().describe("Labels to apply."),
        assignees: z.array(z.string()).optional().describe("Usernames to assign."),
      },
    },
    async ({ repo, title, body, labels, assignees }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghRequest(`/repos/${owner}/${name}/issues`, {
          method: "POST",
          body: { title, body, labels, assignees },
        });
        return jsonText(data);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_update",
    {
      description: "Update an issue (title, body, or open/closed state).",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        title: z.string().optional(),
        body: z.string().optional(),
        state: z.enum(["open", "closed"]).optional(),
      },
    },
    async ({ repo, number, title, body, state }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghRequest(`/repos/${owner}/${name}/issues/${number}`, {
          method: "PATCH",
          body: { title, body, state },
        });
        return jsonText(data);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_comment",
    {
      description: "Add a comment to an issue.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
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
    "issue_set_labels",
    {
      description: "Replace all labels on an issue with the given set.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        labels: z.array(z.string()).describe("The complete set of labels (replaces existing)."),
      },
    },
    async ({ repo, number, labels }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghRequest(
          `/repos/${owner}/${name}/issues/${number}/labels`,
          { method: "PUT", body: { labels } },
        );
        return jsonText(data);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_add_assignees",
    {
      description: 'Assign users to an issue. Accepts the sentinel "@me" for the authenticated user.',
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        assignees: z.array(z.string()).describe('Usernames, or "@me".'),
      },
    },
    async ({ repo, number, assignees }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const resolved = await resolveAssignees(assignees);
        const data = await ghRequest(
          `/repos/${owner}/${name}/issues/${number}/assignees`,
          { method: "POST", body: { assignees: resolved } },
        );
        return jsonText(data);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_remove_assignees",
    {
      description: 'Unassign users from an issue. Accepts the sentinel "@me".',
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        assignees: z.array(z.string()).describe('Usernames, or "@me".'),
      },
    },
    async ({ repo, number, assignees }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const resolved = await resolveAssignees(assignees);
        const data = await ghRequest(
          `/repos/${owner}/${name}/issues/${number}/assignees`,
          { method: "DELETE", body: { assignees: resolved } },
        );
        return jsonText(data);
      } catch (err) {
        return errorResult(err);
      }
    },
  );
}
