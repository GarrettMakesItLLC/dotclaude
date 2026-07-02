import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { errorResult, ghRequest, jsonText, resolveRepo } from "../github.js";
import { ISSUE_LABELS } from "../labels.js";

const repoParam = z
  .string()
  .optional()
  .describe('Target repository as "owner/name". Defaults to the repo of the current directory.');

export function registerLabelTools(server: McpServer): void {
  server.registerTool(
    "labels_ensure",
    {
      description:
        "Idempotently provision the standard issue label taxonomy (status:*, type:*, source:*) into a repo. Creates missing labels and updates color/description on existing ones.",
      inputSchema: { repo: repoParam },
    },
    async ({ repo }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        let created = 0;
        let updated = 0;
        for (const label of ISSUE_LABELS) {
          try {
            await ghRequest(`/repos/${owner}/${name}/labels`, {
              method: "POST",
              body: { name: label.name, color: label.color, description: label.description },
            });
            created += 1;
          } catch (err) {
            // 422 => label already exists; update its color/description instead.
            const msg = err instanceof Error ? err.message : String(err);
            if (!msg.includes("422")) throw err;
            await ghRequest(
              `/repos/${owner}/${name}/labels/${encodeURIComponent(label.name)}`,
              { method: "PATCH", body: { color: label.color, description: label.description } },
            );
            updated += 1;
          }
        }
        return jsonText({ repo: `${owner}/${name}`, created, updated });
      } catch (err) {
        return errorResult(err);
      }
    },
  );
}
