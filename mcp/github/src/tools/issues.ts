import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  errorResult,
  getViewerLogin,
  ghPaginate,
  ghRequest,
  jsonText,
  repoParam,
  resolveRepo,
} from "../github.js";
import {
  typeLabel,
  nativeTypeName,
  statusLabel,
  STATUS_LABEL_NAMES,
  type IssueType,
  type IssueStatus,
} from "../labels.js";

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

/**
 * Find a milestone by exact title, or create it. Returns the milestone number.
 * Shared by the `milestone_ensure` tool and `issue_open`.
 */
async function ensureMilestone(
  owner: string,
  name: string,
  title: string,
  description?: string,
  due_on?: string,
): Promise<number> {
  const existing = await ghPaginate<{ number: number; title: string }>(
    `/repos/${owner}/${name}/milestones`,
    { query: { state: "all" }, limit: 1000 },
  );
  const match = existing.find((m) => m.title === title);
  if (match) return match.number;
  const created = await ghRequest<{ number: number; title: string }>(
    `/repos/${owner}/${name}/milestones`,
    { method: "POST", body: { title, description, due_on } },
  );
  return created.number;
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
      description: "Update an issue (title, body, open/closed state, or the state_reason for a close).",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        title: z.string().optional(),
        body: z.string().optional(),
        state: z.enum(["open", "closed"]).optional(),
        state_reason: z
          .enum(["completed", "not_planned", "reopened"])
          .optional()
          .describe("Reason when changing state: completed vs not_planned (won't/didn't do), or reopened."),
      },
    },
    async ({ repo, number, title, body, state, state_reason }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghRequest(`/repos/${owner}/${name}/issues/${number}`, {
          method: "PATCH",
          body: { title, body, state, state_reason },
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

  server.registerTool(
    "issue_set_type",
    {
      description:
        "Set an issue's type (bug/feature/task): applies the native GitHub issue type (best-effort) and the matching type:* label, replacing any existing type:* label.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        type: z.enum(["bug", "feature", "task"]).describe("Issue type."),
      },
    },
    async ({ repo, number, type }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const t = type as IssueType;

        // Native issue type — org-configured, may not exist on this owner. Best-effort.
        try {
          await ghRequest(`/repos/${owner}/${name}/issues/${number}`, {
            method: "PATCH",
            body: { type: nativeTypeName(t) },
          });
        } catch {
          // Owner lacks native issue types; the label below is the universal fallback.
        }

        // Replace any existing type:* label, preserving all others.
        const issue = await ghRequest<{ labels: { name: string }[] }>(
          `/repos/${owner}/${name}/issues/${number}`,
        );
        const kept = issue.labels
          .map((l) => l.name)
          .filter((n) => !n.startsWith("type:"));
        const next = [...kept, typeLabel(t)];
        const data = await ghRequest(
          `/repos/${owner}/${name}/issues/${number}/labels`,
          { method: "PUT", body: { labels: next } },
        );
        return jsonText(data);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_add_sub_issue",
    {
      description:
        "Link an existing issue as a sub-issue (child) of another. Both are issue numbers in the same repo.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Parent issue number."),
        sub_number: z.number().int().positive().describe("Child issue number to nest under the parent."),
      },
    },
    async ({ repo, number, sub_number }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        // The sub_issues endpoint takes the child's database id, not its number.
        const child = await ghRequest<{ id: number }>(
          `/repos/${owner}/${name}/issues/${sub_number}`,
        );
        const data = await ghRequest(
          `/repos/${owner}/${name}/issues/${number}/sub_issues`,
          { method: "POST", body: { sub_issue_id: child.id } },
        );
        return jsonText(data);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_list_sub_issues",
    {
      description: "List the sub-issues (children) of an issue.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Parent issue number."),
      },
    },
    async ({ repo, number }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghPaginate(`/repos/${owner}/${name}/issues/${number}/sub_issues`, {
          limit: 1000,
        });
        return jsonText(data);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_claim",
    {
      description:
        "Claim an issue to begin work: self-assign the authenticated user and move status to in-progress (removing any other status:* label). Use this the moment you start an issue.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
      },
    },
    async ({ repo, number }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const me = await getViewerLogin();
        await ghRequest(`/repos/${owner}/${name}/issues/${number}/assignees`, {
          method: "POST",
          body: { assignees: [me] },
        });
        const issue = await ghRequest<{ labels: { name: string }[] }>(
          `/repos/${owner}/${name}/issues/${number}`,
        );
        const kept = issue.labels
          .map((l) => l.name)
          .filter((n) => !STATUS_LABEL_NAMES.includes(n));
        const next = [...kept, statusLabel("in-progress")];
        const data = await ghRequest(
          `/repos/${owner}/${name}/issues/${number}/labels`,
          { method: "PUT", body: { labels: next } },
        );
        return jsonText(data);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_set_status",
    {
      description:
        "Set the single status:* label on an issue, preserving all other labels (type:*, source:*, etc). " +
        "Omit `status` to clear it entirely (e.g. before closing an issue).",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        status: z
          .enum(["backlog", "ready", "blocked", "in-progress", "in-review"])
          .optional()
          .describe("New status. Omit to clear the status:* label without setting a new one."),
      },
    },
    async ({ repo, number, status }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const issue = await ghRequest<{ labels: { name: string }[] }>(
          `/repos/${owner}/${name}/issues/${number}`,
        );
        const kept = issue.labels
          .map((l) => l.name)
          .filter((n) => !STATUS_LABEL_NAMES.includes(n));
        const next = status ? [...kept, statusLabel(status as IssueStatus)] : kept;
        const data = await ghRequest(
          `/repos/${owner}/${name}/issues/${number}/labels`,
          { method: "PUT", body: { labels: next } },
        );
        return jsonText(data);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "milestone_ensure",
    {
      description:
        "Find a milestone by exact title, or create it. Returns the milestone number and title.",
      inputSchema: {
        repo: repoParam,
        title: z.string().describe("Milestone title (exact match)."),
        description: z.string().optional(),
        due_on: z.string().optional().describe("ISO 8601 due date."),
      },
    },
    async ({ repo, title, description, due_on }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const number = await ensureMilestone(owner, name, title, description, due_on);
        return jsonText({ number, title });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_set_milestone",
    {
      description: "Attach an issue to a milestone by milestone number (use milestone_ensure to get it).",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        milestone: z.number().int().positive().describe("Milestone number."),
      },
    },
    async ({ repo, number, milestone }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghRequest(`/repos/${owner}/${name}/issues/${number}`, {
          method: "PATCH",
          body: { milestone },
        });
        return jsonText(data);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_open",
    {
      description:
        "Create a fully-formed issue in one call: composes status/type/source labels, sets the " +
        "native issue type (best-effort), finds-or-creates and attaches a milestone by title, and " +
        "nests it under a parent as a sub-issue — instead of hand-composing across several tool calls.",
      inputSchema: {
        repo: repoParam,
        title: z.string().describe("Issue title."),
        body: z.string().optional().describe("Issue body (markdown)."),
        type: z.enum(["bug", "feature", "task"]).optional().describe("Issue type."),
        status: z
          .enum(["backlog", "ready", "blocked", "in-progress", "in-review"])
          .default("ready")
          .describe("Initial status."),
        source: z
          .enum(["musclebuddy", "redthread", "adventureos"])
          .optional()
          .describe("Feedback source, if this issue originated from user feedback."),
        milestone: z
          .string()
          .optional()
          .describe("Milestone title; found or created by exact title match, then attached."),
        parent: z
          .number()
          .int()
          .positive()
          .optional()
          .describe("Parent issue number; nests the new issue as its sub-issue."),
        assignees: z
          .array(z.string())
          .optional()
          .describe('Usernames to assign, or "@me". Default: unassigned.'),
      },
    },
    async ({ repo, title, body, type, status, source, milestone, parent, assignees }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const t = type as IssueType | undefined;
        const s = (status ?? "ready") as IssueStatus;

        const labels = [statusLabel(s)];
        if (t) labels.push(typeLabel(t));
        if (source) labels.push(`source:${source}`);

        const created = await ghRequest<{ number: number; id: number }>(
          `/repos/${owner}/${name}/issues`,
          {
            method: "POST",
            body: {
              title,
              body,
              labels,
              assignees: assignees ? await resolveAssignees(assignees) : undefined,
            },
          },
        );
        const { number, id } = created;

        if (t) {
          // Native issue type — org-configured, may not exist on this owner. Best-effort.
          try {
            await ghRequest(`/repos/${owner}/${name}/issues/${number}`, {
              method: "PATCH",
              body: { type: nativeTypeName(t) },
            });
          } catch {
            // Owner lacks native issue types; the type:* label already applied is the fallback.
          }
        }

        if (milestone) {
          const milestoneNumber = await ensureMilestone(owner, name, milestone);
          await ghRequest(`/repos/${owner}/${name}/issues/${number}`, {
            method: "PATCH",
            body: { milestone: milestoneNumber },
          });
        }

        if (parent) {
          // The sub_issues endpoint takes the child's database id, already captured above.
          await ghRequest(`/repos/${owner}/${name}/issues/${parent}/sub_issues`, {
            method: "POST",
            body: { sub_issue_id: id },
          });
        }

        const final = await ghRequest(`/repos/${owner}/${name}/issues/${number}`);
        return jsonText(final);
      } catch (err) {
        return errorResult(err);
      }
    },
  );
}
