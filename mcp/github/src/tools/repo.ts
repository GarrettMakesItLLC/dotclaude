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

/** Default line window for an unwindowed read — a whole file would flood context. */
const DEFAULT_LINE_LIMIT = 500;

interface ContentsEntry {
  type: string;
  name?: string;
  path: string;
  sha?: string;
  size?: number;
  encoding?: string;
  content?: string;
}

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
    "repo_file_read",
    {
      description:
        "Read a file from a repo without checking it out. Returns the decoded text plus path/sha/size " +
        "and the file's total line count. A directory path returns its entry names instead. " +
        `Reads a window of ${DEFAULT_LINE_LIMIT} lines by default — page through a longer file with ` +
        "`offset`/`limit` rather than pulling it whole.",
      inputSchema: {
        repo: repoParam,
        path: z.string().describe("Path within the repo, e.g. `src/lib/auth.ts`."),
        ref: z.string().optional().describe("Branch, tag or sha. Default: the default branch."),
        offset: z
          .number()
          .int()
          .positive()
          .optional()
          .describe("1-indexed first line to return. Default: 1."),
        limit: z
          .number()
          .int()
          .positive()
          .optional()
          .describe(`Max lines to return. Default: ${DEFAULT_LINE_LIMIT}.`),
      },
    },
    async ({ repo, path, ref, offset, limit }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        // Encode per segment: a `#` or `?` in a filename would otherwise be read
        // as a fragment/query and silently 404.
        const encoded = path.replace(/^\/+/, "").split("/").map(encodeURIComponent).join("/");
        const data = await ghRequest<ContentsEntry | ContentsEntry[]>(
          `/repos/${owner}/${name}/contents/${encoded}`,
          { query: { ref } },
        );

        if (Array.isArray(data)) {
          return jsonText({
            path,
            type: "dir",
            entries: data.map((e) => ({ name: e.name ?? e.path, type: e.type })),
          });
        }

        // Over ~1MB the contents API stops inlining the blob: `encoding: "none"`
        // and an empty `content`. Say so rather than returning an empty file.
        if (data.encoding !== "base64") {
          throw new Error(
            `${path} is ${data.size ?? "?"} bytes — too large for the contents API to inline ` +
              `(encoding: ${data.encoding ?? "none"}). Read it from a checkout instead.`,
          );
        }

        const buf = Buffer.from(data.content ?? "", "base64");
        if (buf.includes(0)) {
          throw new Error(`${path} is binary (${data.size ?? buf.length} bytes), not text.`);
        }

        const all = buf.toString("utf8").split("\n");
        // A trailing newline terminates the last line rather than starting an
        // empty one, so it must not count as a line of its own.
        const endsWithNewline = all.length > 1 && all[all.length - 1] === "";
        if (endsWithNewline) all.pop();

        const start = (offset ?? 1) - 1;
        const end = start + (limit ?? DEFAULT_LINE_LIMIT);
        const window = all.slice(start, end);
        const reachesEnd = end >= all.length;
        return jsonText({
          path: data.path,
          sha: data.sha,
          size: data.size,
          lines: all.length,
          offset: start + 1,
          truncated: start > 0 || !reachesEnd,
          text: window.join("\n") + (endsWithNewline && reachesEnd ? "\n" : ""),
        });
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
