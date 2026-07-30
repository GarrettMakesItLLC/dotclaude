import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  errorResult,
  GhHttpError,
  ghPaginate,
  ghRequest,
  jsonText,
  repoParam,
  resolveRepo,
} from "../github.js";
import {
  DEPRECATED_LABELS,
  ISSUE_LABELS,
  REMOVABLE_DEFAULT_LABELS,
  isKnownLabel,
} from "../labels.js";

interface RawLabelListItem {
  name: string;
  color: string;
  description: string | null;
}

const labelPath = (owner: string, name: string, label: string): string =>
  `/repos/${owner}/${name}/labels/${encodeURIComponent(label)}`;

/** Every label on the repo, following pagination — a repo can carry dozens. */
async function listLabels(owner: string, name: string): Promise<RawLabelListItem[]> {
  return ghPaginate<RawLabelListItem>(`/repos/${owner}/${name}/labels`, { limit: 300 });
}

/**
 * How many issues and PRs carry a label. Search is the only endpoint that
 * answers this in one call, and a delete without it is a blind one. Returns -1
 * when the count could not be resolved — never fails the caller's operation.
 */
async function labelUsage(owner: string, name: string, label: string): Promise<number> {
  try {
    const res = await ghRequest<{ total_count: number }>("/search/issues", {
      query: { q: `repo:${owner}/${name} label:"${label}"` },
    });
    return res?.total_count ?? 0;
  } catch {
    return -1;
  }
}

export function registerLabelTools(server: McpServer): void {
  server.registerTool(
    "labels_ensure",
    {
      description:
        "Idempotently provision the standard issue label taxonomy (status:*, type:*, source:*, and the " +
        "markers epic / launch-blocker) into a repo: creates missing labels and updates color/description " +
        "on existing ones. Also retitles GitHub's stock labels that duplicate a taxonomy axis (bug, " +
        "enhancement, documentation) as deprecated — only where they already exist, never creating them.",
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
            if (!(err instanceof GhHttpError && err.status === 422)) throw err;
            await ghRequest(labelPath(owner, name, label.name), {
              method: "PATCH",
              body: { color: label.color, description: label.description },
            });
            updated += 1;
          }
        }

        let deprecated = 0;
        for (const label of DEPRECATED_LABELS) {
          try {
            await ghRequest(labelPath(owner, name, label.name), {
              method: "PATCH",
              body: { color: label.color, description: label.description },
            });
            deprecated += 1;
          } catch (err) {
            // 404 => this repo never had it, which is already the end state.
            if (!(err instanceof GhHttpError && err.status === 404)) throw err;
          }
        }

        return jsonText({ repo: `${owner}/${name}`, created, updated, deprecated });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "label_list",
    {
      description:
        "List every label on a repo with its color, description, and the number of issues/PRs carrying it " +
        "(-1 when that count could not be resolved).",
      inputSchema: {
        repo: repoParam,
        with_counts: z
          .boolean()
          .default(true)
          .describe("Resolve the issue count per label — one search request each. False to skip."),
      },
    },
    async ({ repo, with_counts }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const raw = await listLabels(owner, name);
        const labels: { name: string; color: string; description: string; issues: number }[] = [];
        for (const l of raw) {
          labels.push({
            name: l.name,
            color: l.color,
            description: l.description ?? "",
            issues: with_counts === false ? -1 : await labelUsage(owner, name, l.name),
          });
        }
        return jsonText({ repo: `${owner}/${name}`, labels });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "label_update",
    {
      description:
        "Rename a label and/or change its color or description. A rename carries the label across every " +
        "issue that has it, which is how a legacy label folds into the taxonomy without losing history.",
      inputSchema: {
        repo: repoParam,
        name: z.string().describe("Current label name."),
        new_name: z.string().optional().describe("New name. Omit to keep the current one."),
        color: z.string().optional().describe("6-hex color, no leading '#'."),
        description: z.string().optional().describe("New description."),
      },
    },
    async ({ repo, name: label, new_name, color, description }) => {
      try {
        const body: Record<string, string> = {};
        if (new_name !== undefined) body.new_name = new_name;
        if (color !== undefined) body.color = color;
        if (description !== undefined) body.description = description;
        if (Object.keys(body).length === 0) {
          throw new Error(
            `label_update on "${label}" was given nothing to change — pass new_name, color, or description.`,
          );
        }
        const { owner, name } = await resolveRepo(repo);
        const res = await ghRequest<RawLabelListItem>(labelPath(owner, name, label), {
          method: "PATCH",
          body,
        });
        return jsonText({
          repo: `${owner}/${name}`,
          label: res?.name ?? new_name ?? label,
          changed: body,
        });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "label_delete",
    {
      description:
        "Delete a label, reporting how many issues carried it. Deletion removes the label from those " +
        "issues permanently, so a label that records history should be renamed or retitled instead. " +
        "Refuses on a canonical taxonomy label unless `force` is set.",
      inputSchema: {
        repo: repoParam,
        name: z.string().describe("Label to delete."),
        force: z
          .boolean()
          .default(false)
          .describe("Allow deleting a label that is part of the canonical taxonomy."),
      },
    },
    async ({ repo, name: label, force }) => {
      try {
        if (!force && ISSUE_LABELS.some((l) => l.name === label)) {
          throw new Error(
            `"${label}" is part of the canonical taxonomy — every repo is provisioned with it, so ` +
              "labels_ensure would recreate it on the next run. Pass force to delete it anyway.",
          );
        }
        const { owner, name } = await resolveRepo(repo);
        const issues = await labelUsage(owner, name, label);
        await ghRequest(labelPath(owner, name, label), { method: "DELETE" });
        return jsonText({ repo: `${owner}/${name}`, deleted: label, issues_affected: issues });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "labels_audit",
    {
      description:
        "Read-only drift report for a repo's labels against the canonical taxonomy: what is missing, " +
        "which stock labels are present but not yet retitled as deprecated, which removable GitHub " +
        "defaults remain, and which labels the taxonomy does not recognize. Unrecognized is not " +
        "automatically wrong — per-repo axes like area:* / module:* are legitimate and listed for review.",
      inputSchema: { repo: repoParam },
    },
    async ({ repo }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const raw = await listLabels(owner, name);
        const present = new Map(raw.map((l) => [l.name, l.description ?? ""]));

        const missing = ISSUE_LABELS.filter((l) => !present.has(l.name)).map((l) => l.name);
        const deprecatedPresent = DEPRECATED_LABELS.filter(
          (l) => present.has(l.name) && present.get(l.name) !== l.description,
        ).map((l) => l.name);
        const removable = REMOVABLE_DEFAULT_LABELS.filter((n) => present.has(n));
        const unrecognized = raw.map((l) => l.name).filter((n) => !isKnownLabel(n));

        return jsonText({
          repo: `${owner}/${name}`,
          missing,
          deprecated_present: deprecatedPresent,
          removable_defaults: removable,
          unrecognized,
          clean: missing.length === 0 && deprecatedPresent.length === 0 && removable.length === 0,
        });
      } catch (err) {
        return errorResult(err);
      }
    },
  );
}
