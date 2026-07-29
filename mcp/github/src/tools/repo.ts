import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  errorResult,
  ghPaginate,
  ghRequest,
  jsonText,
  repoParam,
  resolveRepo,
} from "../github.js";
import { getChecksSummary } from "../checks.js";
import { slimBranch, type RawBranch } from "../slim.js";

interface Repository {
  name: string;
  full_name: string;
  default_branch: string;
  private: boolean;
  html_url: string;
  description: string | null;
}

export function registerRepoTools(server: McpServer): void {
  server.registerTool(
    "repo_get",
    {
      description: "Get core metadata about a repository.",
      inputSchema: { repo: repoParam },
    },
    async ({ repo }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghRequest<Repository>(`/repos/${owner}/${name}`);
        return jsonText({
          name: data.name,
          full_name: data.full_name,
          default_branch: data.default_branch,
          private: data.private,
          html_url: data.html_url,
          description: data.description,
        });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "branch_list",
    {
      description:
        "List branches in a repo (returns up to `limit` items, following pagination).",
      inputSchema: {
        repo: repoParam,
        limit: z.number().int().positive().optional().describe("Max items (<=1000, default 30)."),
      },
    },
    async ({ repo, limit }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghPaginate<RawBranch>(`/repos/${owner}/${name}/branches`, {
          limit,
        });
        return jsonText(data.map(slimBranch));
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "ref_status",
    {
      description:
        "Summarize CI for a branch or sha: merges the combined commit status and check-runs into one overall state with per-check name/status/conclusion.",
      inputSchema: {
        repo: repoParam,
        ref: z.string().describe("Branch name or commit sha."),
      },
    },
    async ({ repo, ref }) => {
      try {
        const target = await resolveRepo(repo);
        const summary = await getChecksSummary(target, ref);
        return jsonText(summary);
      } catch (err) {
        return errorResult(err);
      }
    },
  );
}
