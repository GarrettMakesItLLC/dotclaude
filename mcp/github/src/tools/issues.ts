import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  cacheKey,
  cachedGet,
  errorResult,
  getViewerLogin,
  ghPaginate,
  ghRequest,
  invalidate,
  jsonText,
  repoParam,
  resolveRepo,
} from "../github.js";
import {
  ISSUE_SOURCES,
  ISSUE_STATUSES,
  ISSUE_TYPES,
  ISSUE_EFFORTS,
  ISSUE_PRIORITIES,
  nativeTypeName,
  statusLabel,
  sourceLabel,
  effortModelMismatch,
  TRUSTED_SOURCES,
  type IssueEffort,
  type IssueSource,
  type IssueStatus,
  type IssueType,
} from "../labels.js";
import {
  addProjectItem,
  findProjectItem,
  getProjectField,
  invalidateProjectItem,
  setProjectSingleSelect,
} from "../project.js";
import { setIssueStatus } from "../issue-status.js";
import { labelNames, slimComment, slimIssue, type RawIssue, type RawLabel } from "../slim.js";
import {
  acquireClaimLock,
  claimBranchName,
  ClaimClosedError,
  ClaimConflictError,
  ClaimEpicError,
  stampClaim,
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
 * The status an issue starts in when the caller doesn't name one.
 *
 * A defect the owner reported himself is already verified — his account of
 * running software settles whether it happens — so it starts ready. So does one
 * an agent or a code review found, since both carry the evidence with them.
 * Anyone else's defect report is one unverified account, and a feature request
 * needs his intent before it is built: both wait on him.
 */
function defaultStatus(source?: IssueSource, type?: IssueType): IssueStatus {
  if (!source) return "ready";
  if (TRUSTED_SOURCES.includes(source)) return type === "feature" ? "blocked" : "ready";
  return "blocked";
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

/**
 * Resolve a repo issue to its shared-project item, find the named single-select
 * field, and set it to the option matching `optionValue`. The match is
 * case-insensitive on both sides — option names on the project are
 * capitalized (e.g. "Complex") while callers pass the lowercase enum value,
 * but a caller passing mixed case is matched too.
 * An issue that isn't on the board yet is ADDED rather than rejected. Effort
 * and Priority live on the project, so "not a project item" is a missing setup
 * step the caller cannot be expected to do out-of-band — and it made
 * `issue_open`'s `effort`/`priority` params inert on every newly-created
 * issue, since nothing adds the issue between creating it and setting the
 * fields (platform#745). `addProjectV2ItemById` is idempotent, so this is
 * safe on an issue already on the board.
 *
 * Throws if the field has no such option — callers that want best-effort
 * behavior (issue_open) catch around this; callers that want a hard failure
 * (issue_set_effort/issue_set_priority) let it propagate to their own
 * try/catch.
 */
async function applyProjectSingleSelect(
  owner: string,
  name: string,
  number: number,
  fieldName: string,
  optionValue: string,
): Promise<void> {
  const existing = await findProjectItem(owner, name, number);
  const item = existing ?? { id: await addProjectItem(owner, name, number) };
  const field = await getProjectField(fieldName);
  const option = field.options?.find(
    (o) => o.name.toLowerCase() === optionValue.toLowerCase(),
  );
  if (!option) {
    const available = field.options?.map((o) => o.name).join(", ") ?? "(no options)";
    throw new Error(
      `${fieldName} field has no "${optionValue}" option. Available options: ${available}.`,
    );
  }
  await setProjectSingleSelect(item.id, field.id, option.id);
  invalidate(cacheKey("issue", `${owner}/${name}`, number));
  invalidateProjectItem(owner, name, number);
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
        const data = await cachedGet(cacheKey("issue", `${owner}/${name}`, number), () =>
          ghRequest<RawIssue>(`/repos/${owner}/${name}/issues/${number}`),
        );
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
        invalidate(cacheKey("issue", `${owner}/${name}`, number));
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
        invalidate(cacheKey("issue", `${owner}/${name}`, number));
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
        invalidate(cacheKey("issue", `${owner}/${name}`, number));
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
        invalidate(cacheKey("issue", `${owner}/${name}`, number));
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
        invalidate(cacheKey("issue", `${owner}/${name}`, number));
        return jsonText(slimIssue(data));
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_set_type",
    {
      description: "Set an issue's native GitHub issue type (bug/feature/task). No label written — native type is the only source of truth.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        type: z.enum(ISSUE_TYPES).describe("Issue type."),
      },
    },
    async ({ repo, number, type }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        await ghRequest(`/repos/${owner}/${name}/issues/${number}`, {
          method: "PATCH",
          body: { type: nativeTypeName(type) },
        });
        invalidate(cacheKey("issue", `${owner}/${name}`, number));
        return jsonText({ number, type });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_set_effort",
    {
      description:
        "Set an issue's Effort field on the shared GarrettMakesItLLC — Work project " +
        "(trivial/standard/complex) — the model-tier signal for subagent dispatch. The issue must " +
        "already be a project item.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        effort: z.enum(ISSUE_EFFORTS).describe("Effort tier."),
      },
    },
    async ({ repo, number, effort }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        await applyProjectSingleSelect(owner, name, number, "Effort", effort);
        return jsonText({ number, effort });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_set_priority",
    {
      description:
        "Set an issue's Priority field on the shared GarrettMakesItLLC — Work project " +
        "(urgent/high/medium/low). The issue must already be a project item.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        priority: z.enum(ISSUE_PRIORITIES).describe("Priority tier."),
      },
    },
    async ({ repo, number, priority }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        await applyProjectSingleSelect(owner, name, number, "Priority", priority);
        return jsonText({ number, priority });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_add_sub_issue",
    {
      description:
        "Link an existing issue as a sub-issue (child) of another. Parent and child may be in " +
        "different repos (same org) — pass `sub_repo` for the child's repo if it differs from " +
        "the parent's `repo`.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Parent issue number."),
        sub_number: z.number().int().positive().describe("Child issue number to nest under the parent."),
        sub_repo: repoParam.describe(
          'The CHILD\'s repo as "owner/name", if different from `repo` (the parent\'s repo). ' +
            "Defaults to `repo` when omitted, matching the same-repo case.",
        ),
      },
    },
    async ({ repo, number, sub_number, sub_repo }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const { owner: subOwner, name: subName } = await resolveRepo(sub_repo ?? repo);
        // The sub_issues endpoint takes the child's database id, not its number — looked up in
        // the CHILD's own repo, which may differ from the parent's (#234).
        const child = await ghRequest<{ id: number }>(
          `/repos/${subOwner}/${subName}/issues/${sub_number}`,
        );
        const data = await ghRequest(
          `/repos/${owner}/${name}/issues/${number}/sub_issues`,
          { method: "POST", body: { sub_issue_id: child.id } },
        );
        invalidate(cacheKey("issue", `${owner}/${name}`, number));
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
    "issue_set_blocked_by",
    {
      description:
        "Mark an issue as blocked by one or more other issues, in the same repo, using GitHub's " +
        "native issue-dependencies relationship. Already-linked blockers are reported separately " +
        "and not re-posted.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("The blocked issue's number."),
        blocked_by: z
          .array(z.number().int().positive())
          .min(1)
          .describe("Issue numbers, in the same repo, that block this one."),
      },
    },
    async ({ repo, number, blocked_by }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const existing = await ghRequest<{ number: number }[]>(
          `/repos/${owner}/${name}/issues/${number}/dependencies/blocked_by`,
        );
        const existingNumbers = new Set(existing.map((i) => i.number));
        const already_linked = blocked_by.filter((n) => existingNumbers.has(n));
        const toAdd = blocked_by.filter((n) => !existingNumbers.has(n));

        // If a POST partway through this loop fails, the caller loses track of which
        // blockers already succeeded before the error — a retry has to re-derive that
        // from `already_linked`, which does work today. Low-severity; not fixed here.
        const added: number[] = [];
        for (const blockerNumber of toAdd) {
          const blocker = await ghRequest<{ id: number }>(
            `/repos/${owner}/${name}/issues/${blockerNumber}`,
          );
          await ghRequest(`/repos/${owner}/${name}/issues/${number}/dependencies/blocked_by`, {
            method: "POST",
            body: { issue_id: blocker.id },
          });
          added.push(blockerNumber);
        }

        if (added.length) invalidate(cacheKey("issue", `${owner}/${name}`, number));
        return jsonText({ number, blocked_by, added, already_linked });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "issue_list_blocked_by",
    {
      description: "List the issue numbers (same repo) that block a given issue.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
      },
    },
    async ({ repo, number }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const data = await ghRequest<{ number: number }[]>(
          `/repos/${owner}/${name}/issues/${number}/dependencies/blocked_by`,
        );
        return jsonText({ number, blocked_by: data.map((i) => i.number) });
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
        "`issue-<N>-<slug>` at the default-branch head via an atomic ref create, stamps a claim " +
        "comment on the issue (holder identity + timestamp), then self-assigns the authenticated " +
        "user and moves status to in-progress. Refuses on a CLOSED issue — finished work, not " +
        "available to claim. Refuses on an issue with open sub-issues — an epic is meant to be " +
        "decomposed, not implemented directly; claim a specific sub-issue instead. If the branch " +
        "already exists the issue is ALREADY CLAIMED — the call " +
        "fails with the holder's branch, last commit, any open PR, and — from the stamp — who holds " +
        "it and when, so you can tell your own earlier session from another machine. Default to " +
        "picking different work unless the stamp identifies THIS machine. Assignee alone cannot " +
        "arbitrate this: every machine authenticates as the same user. Check out the returned " +
        "branch instead of creating your own. Pass `caller_model` (your own model id, e.g. " +
        "\"claude-sonnet-5\") and, when the issue carries an Effort field value calling for a " +
        "stronger model than you're running, the claim still succeeds but reports a " +
        "`model_mismatch` field flagging it — over-provisioned needs no action, under-provisioned " +
        "is worth surfacing to the owner rather than silently proceeding.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        branch: z
          .string()
          .optional()
          .describe("Override the derived lock branch name (default `issue-<N>-<title-slug>`)."),
        caller_model: z
          .string()
          .optional()
          .describe(
            "The claiming agent's own model id (e.g. \"claude-sonnet-5\"), self-reported — this " +
              "tool has no other way to know it. Omit to skip the effort/model check entirely.",
          ),
      },
    },
    async ({ repo, number, branch, caller_model }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const issue = await ghRequest<RawIssue>(`/repos/${owner}/${name}/issues/${number}`);
        if (issue.state === "closed") {
          throw new ClaimClosedError(
            `Issue #${number} is closed (${issue.state_reason ?? "closed"}) — it is finished work, ` +
              "not available to claim.",
            {
              state: issue.state,
              state_reason: issue.state_reason ?? null,
              closed_at: issue.closed_at ?? null,
            },
          );
        }
        const subTotal = issue.sub_issues_summary?.total ?? 0;
        const subCompleted = issue.sub_issues_summary?.completed ?? 0;
        const openSubIssues = subTotal - subCompleted;
        if (openSubIssues > 0) {
          throw new ClaimEpicError(
            `Issue #${number} has ${openSubIssues} open sub-issue(s) — it's an epic, meant to be ` +
              "decomposed, not implemented directly. Claim a specific sub-issue instead " +
              "(issue_list_sub_issues to see them).",
            { open_sub_issues: openSubIssues, total_sub_issues: subTotal },
          );
        }
        const target = branch ?? claimBranchName(number, issue.title ?? "");
        const lock = await acquireClaimLock(owner, name, target, number);

        // The ref IS the lock. Once it exists the claim is held, so a failure in
        // any step below is reported as a warning and never rolls the ref back.
        const warnings: string[] = [];
        try {
          await stampClaim(owner, name, number, target);
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          warnings.push(`claim stamp not posted (the branch lock is held regardless): ${msg}`);
        }

        let modelMismatch: string | null = null;
        if (caller_model) {
          try {
            const item = await findProjectItem(owner, name, number);
            const rawEffort = item?.fields.effort;
            const effort =
              typeof rawEffort === "string" &&
              (ISSUE_EFFORTS as readonly string[]).includes(rawEffort.toLowerCase())
                ? (rawEffort.toLowerCase() as IssueEffort)
                : undefined;
            modelMismatch = effort ? effortModelMismatch(effort, caller_model) : null;
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            warnings.push(`effort/model-mismatch check skipped: ${msg}`);
          }
        }

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

        invalidate(cacheKey("issue", `${owner}/${name}`, number));

        const result = {
          claimed: true,
          issue: number,
          branch: target,
          base: lock.base,
          sha: lock.sha,
          assignee,
          status,
          checkout: `git fetch origin && git checkout ${target}`,
          model_mismatch: modelMismatch,
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
        if (err instanceof ClaimClosedError) {
          return structuredError({
            claimed: false,
            reason: "closed",
            issue: number,
            ...err.issue,
            message: err.message,
          });
        }
        if (err instanceof ClaimEpicError) {
          return structuredError({
            claimed: false,
            reason: "epic",
            issue: number,
            ...err.epic,
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
        invalidate(cacheKey("issue", `${owner}/${name}`, number));
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
        "Status defaults to `ready`, except third-party feedback and owner feature requests, which " +
        "start `blocked` awaiting the owner. " +
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
            "Initial status. Defaults to `ready`; to `blocked` for third-party feedback and for any " +
              "`source: owner` feature request. Use `waiting` when the issue depends on another " +
              "issue rather than on a person.",
          ),
        source: z
          .enum(ISSUE_SOURCES)
          .optional()
          .describe(
            "Where the report came from, if it is feedback. `owner` / `user-feedback` are how it " +
              "arrived — an app's in-app reporter, filed in that app's own repo. The per-app values " +
              "name which app, for reports cross-filed elsewhere. `owner` is trusted, so his defects " +
              "start `ready` instead of awaiting verification.",
          ),
        effort: z
          .enum(ISSUE_EFFORTS)
          .optional()
          .describe(
            "How much judgment the task takes: trivial (Haiku-class), standard (Sonnet-class, the " +
              "default), or complex (Opus-class). Set best-effort after creation — if the issue hasn't " +
              "landed on the shared project yet, this is reported in `_warnings` rather than failing " +
              "the whole call.",
          ),
        priority: z
          .enum(ISSUE_PRIORITIES)
          .optional()
          .describe("Urgent/high/medium/low. Same best-effort timing as effort."),
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
        parent_repo: repoParam.describe(
          'The PARENT\'s repo as "owner/name", if different from `repo` (the new issue\'s repo). ' +
            "Defaults to `repo` when omitted, matching the same-repo case.",
        ),
        assignees: z
          .array(z.string())
          .optional()
          .describe('Usernames to assign, or "@me". Default: unassigned.'),
      },
    },
    async ({
      repo,
      title,
      body,
      type,
      status,
      source,
      effort,
      priority,
      milestone,
      parent,
      parent_repo,
      assignees,
    }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const effectiveStatus: IssueStatus = status ?? defaultStatus(source, type);

        const labels = [statusLabel(effectiveStatus)];
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
          // Native issue type — org-configured, may not exist on this owner. Best-effort:
          // there is no label fallback, so a failure here means the issue has no type set.
          try {
            await ghRequest(`/repos/${owner}/${name}/issues/${number}`, {
              method: "PATCH",
              body: { type: nativeTypeName(type) },
            });
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            warnings.push(`native type "${nativeTypeName(type)}" not set: ${msg}`);
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
            // Resolved independently from the new issue's own repo (#234) — a parent in a
            // different repo (same org) must be posted to via ITS repo, not the child's.
            const { owner: parentOwner, name: parentName } = await resolveRepo(
              parent_repo ?? repo,
            );
            // The sub_issues endpoint takes the child's database id, already captured above.
            await ghRequest(`/repos/${parentOwner}/${parentName}/issues/${parent}/sub_issues`, {
              method: "POST",
              body: { sub_issue_id: id },
            });
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            warnings.push(`parent #${parent} not linked: ${msg}`);
          }
        }

        if (effort) {
          try {
            await applyProjectSingleSelect(owner, name, number, "Effort", effort);
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            warnings.push(`effort "${effort}" not set: ${msg}`);
          }
        }
        if (priority) {
          try {
            await applyProjectSingleSelect(owner, name, number, "Priority", priority);
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            warnings.push(`priority "${priority}" not set: ${msg}`);
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
