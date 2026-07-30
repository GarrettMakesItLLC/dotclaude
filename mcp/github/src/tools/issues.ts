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
  ISSUE_SOURCES,
  ISSUE_STATUSES,
  ISSUE_TYPES,
  typeLabel,
  nativeTypeName,
  statusLabel,
  sourceLabel,
  type IssueStatus,
} from "../labels.js";
import { setIssueStatus } from "../issue-status.js";
import { labelNames, slimComment, slimIssue, type RawIssue, type RawLabel } from "../slim.js";
import {
  acquireClaimLock,
  ClaimConflictError,
  resolveClaimBranch,
  structuredError,
} from "../claim-lock.js";

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
        return jsonText(issuesOnly.map((i) => slimIssue(i)));
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
        const data = await ghRequest<RawIssue>(`/repos/${owner}/${name}/issues/${number}`);
        return jsonText(slimIssue(data, { body: true }));
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
        const data = await ghRequest<RawIssue>(`/repos/${owner}/${name}/issues`, {
          method: "POST",
          body: { title, body, labels, assignees },
        });
        return jsonText(slimIssue(data));
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
        const data = await ghRequest<RawIssue>(`/repos/${owner}/${name}/issues/${number}`, {
          method: "PATCH",
          body: { title, body, state, state_reason },
        });
        return jsonText(slimIssue(data));
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
        const data = await ghRequest<{ id: number; html_url: string; created_at: string }>(
          `/repos/${owner}/${name}/issues/${number}/comments`,
          { method: "POST", body: { body } },
        );
        return jsonText(slimComment(data));
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
        const data = await ghRequest<RawLabel[]>(
          `/repos/${owner}/${name}/issues/${number}/labels`,
          { method: "PUT", body: { labels } },
        );
        return jsonText({ number, labels: labelNames(data) });
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
        const data = await ghRequest<RawIssue>(
          `/repos/${owner}/${name}/issues/${number}/assignees`,
          { method: "POST", body: { assignees: resolved } },
        );
        return jsonText(slimIssue(data));
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
        const data = await ghRequest<RawIssue>(
          `/repos/${owner}/${name}/issues/${number}/assignees`,
          { method: "DELETE", body: { assignees: resolved } },
        );
        return jsonText(slimIssue(data));
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
        type: z.enum(ISSUE_TYPES).describe("Issue type."),
      },
    },
    async ({ repo, number, type }) => {
      try {
        const { owner, name } = await resolveRepo(repo);

        // Native issue type — org-configured, may not exist on this owner. Best-effort.
        try {
          await ghRequest(`/repos/${owner}/${name}/issues/${number}`, {
            method: "PATCH",
            body: { type: nativeTypeName(type) },
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
        const next = [...kept, typeLabel(type)];
        const data = await ghRequest<RawLabel[]>(
          `/repos/${owner}/${name}/issues/${number}/labels`,
          { method: "PUT", body: { labels: next } },
        );
        return jsonText({ number, type, labels: labelNames(data) });
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
        return jsonText({ parent: number, sub_issue: sub_number, linked: true });
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
        const data = await ghPaginate<RawIssue>(`/repos/${owner}/${name}/issues/${number}/sub_issues`, {
          limit: 1000,
        });
        return jsonText(data.map((i) => slimIssue(i)));
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_claim",
    {
      description:
        "Claim an issue to begin work, taking a distributed lock first: creates the remote branch " +
        "`issue-<N>-<slug>` at the default-branch head via an atomic ref create, then self-assigns " +
        "the authenticated user and moves status to in-progress. If the branch already exists the " +
        "issue is ALREADY CLAIMED (typically by another machine) — the call fails with the holder's " +
        "branch, last commit and any open PR, and you must pick different work. Assignee alone " +
        "cannot arbitrate this: every machine authenticates as the same user. Check out the " +
        "returned branch instead of creating your own.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        branch: z
          .string()
          .optional()
          .describe("Override the derived lock branch name (default `issue-<N>-<title-slug>`)."),
      },
    },
    async ({ repo, number, branch }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const target = await resolveClaimBranch(owner, name, number, branch);
        const lock = await acquireClaimLock(owner, name, target, number);

        // The ref IS the lock. Once it exists the claim is held, so a failure in
        // either step below is reported as a warning and never rolls the ref back.
        const warnings: string[] = [];
        let assignee: string | null = null;
        try {
          assignee = await getViewerLogin();
          await ghRequest(`/repos/${owner}/${name}/issues/${number}/assignees`, {
            method: "POST",
            body: { assignees: [assignee] },
          });
        } catch (err) {
          assignee = null;
          const msg = err instanceof Error ? err.message : String(err);
          warnings.push(`self-assign failed (the branch lock is held regardless): ${msg}`);
        }

        let status: string | null = "in-progress";
        try {
          await setIssueStatus(owner, name, number, "in-progress");
        } catch (err) {
          status = null;
          const msg = err instanceof Error ? err.message : String(err);
          warnings.push(`status:in-progress not set (the branch lock is held regardless): ${msg}`);
        }

        const result = {
          claimed: true,
          issue: number,
          branch: target,
          base: lock.base,
          sha: lock.sha,
          assignee,
          status,
          checkout: `git fetch origin && git checkout ${target}`,
        };
        return jsonText(warnings.length ? { ...result, _warnings: warnings } : result);
      } catch (err) {
        if (err instanceof ClaimConflictError) {
          return structuredError({
            claimed: false,
            reason: "already-claimed",
            issue: number,
            ...err.holder,
            message: err.message,
          });
        }
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
          .enum(ISSUE_STATUSES)
          .optional()
          .describe("New status. Omit to clear the status:* label without setting a new one."),
      },
    },
    async ({ repo, number, status }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        return jsonText(await setIssueStatus(owner, name, number, status));
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
        const data = await ghRequest<RawIssue>(`/repos/${owner}/${name}/issues/${number}`, {
          method: "PATCH",
          body: { milestone },
        });
        return jsonText(slimIssue(data));
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
        "nests it under a parent as a sub-issue — instead of hand-composing across several tool calls. " +
        "Status defaults to `ready`, or `blocked` when a `source` is set (unverified feedback). " +
        "The issue itself is always created first; milestone/sub-issue enrichment is best-effort — " +
        "on partial failure the created issue is still returned, annotated with a `_warnings` array.",
      inputSchema: {
        repo: repoParam,
        title: z.string().describe("Issue title."),
        body: z.string().optional().describe("Issue body (markdown)."),
        type: z.enum(ISSUE_TYPES).optional().describe("Issue type."),
        status: z
          .enum(ISSUE_STATUSES)
          .optional()
          .describe(
            "Initial status. Defaults to `ready`, or `blocked` when `source` is set (unverified feedback). " +
              "Use `waiting` when the issue depends on another issue rather than on a person.",
          ),
        source: z
          .enum(ISSUE_SOURCES)
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
        const effectiveStatus: IssueStatus = status ?? (source ? "blocked" : "ready");

        const labels = [statusLabel(effectiveStatus)];
        if (type) labels.push(typeLabel(type));
        if (source) labels.push(sourceLabel(source));

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
        const warnings: string[] = [];

        if (type) {
          // Native issue type — org-configured, may not exist on this owner. Best-effort.
          try {
            await ghRequest(`/repos/${owner}/${name}/issues/${number}`, {
              method: "PATCH",
              body: { type: nativeTypeName(type) },
            });
          } catch {
            // Owner lacks native issue types; the type:* label already applied is the fallback.
          }
        }

        // The issue is already created at this point — enrichment failures below must not
        // hide that creation behind an errorResult, or a retry would create a duplicate.
        if (milestone) {
          try {
            const milestoneNumber = await ensureMilestone(owner, name, milestone);
            await ghRequest(`/repos/${owner}/${name}/issues/${number}`, {
              method: "PATCH",
              body: { milestone: milestoneNumber },
            });
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            warnings.push(`milestone "${milestone}" not attached: ${msg}`);
          }
        }

        if (parent) {
          try {
            // The sub_issues endpoint takes the child's database id, already captured above.
            await ghRequest(`/repos/${owner}/${name}/issues/${parent}/sub_issues`, {
              method: "POST",
              body: { sub_issue_id: id },
            });
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            warnings.push(`parent #${parent} not linked: ${msg}`);
          }
        }

        const final = await ghRequest<RawIssue>(
          `/repos/${owner}/${name}/issues/${number}`,
        );
        const slim = slimIssue(final);
        return jsonText(warnings.length ? { ...slim, _warnings: warnings } : slim);
      } catch (err) {
        return errorResult(err);
      }
    },
  );
}
