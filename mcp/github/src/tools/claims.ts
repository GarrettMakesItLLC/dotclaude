import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  errorResult,
  getViewerLogin,
  ghRequest,
  jsonText,
  listLimit,
  repoParam,
  resolveRepo,
} from "../github.js";
import { setIssueStatus } from "../issue-status.js";
import {
  CLAIM_BRANCH_PREFIX,
  claimHolder,
  defaultBranch,
  deleteClaimLock,
  issueNumberForBranch,
  pullsForBranch,
  resolveClaimBranch,
  structuredError,
} from "../claim-lock.js";

interface CompareResponse {
  ahead_by: number;
  behind_by: number;
  status: string;
}

interface MatchingRef {
  ref: string;
  object: { sha: string };
}

interface OpenPull {
  number: number;
  html_url: string;
  draft?: boolean;
  title?: string;
  head: { ref: string };
}

interface CommitResponse {
  sha: string;
  commit?: {
    message?: string;
    author?: { name?: string; date?: string };
  };
}

export function registerClaimTools(server: McpServer): void {
  server.registerTool(
    "claim_release",
    {
      description:
        "Release an issue's claim by deleting its lock branch on the remote — for work abandoned " +
        "without a PR. Refuses when the branch carries commits that landed nowhere (not merged " +
        "into the default branch and not in a merged PR) unless `force` is set, so a live claim on " +
        "another machine cannot be dropped by accident. Also returns an OPEN issue to " +
        "`status:ready` — a closed one has its status cleared instead, because done is the absence " +
        "of a status — and unassigns the authenticated user (best-effort, reported via `_warnings`).",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number whose claim is released."),
        branch: z
          .string()
          .optional()
          .describe("Override the derived lock branch name (default `issue-<N>-<title-slug>`)."),
        force: z
          .boolean()
          .default(false)
          .describe("Delete the lock even when the branch holds unmerged commits."),
      },
    },
    async ({ repo, number, branch, force }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const target = await resolveClaimBranch(owner, name, number, branch);
        const base = await defaultBranch(owner, name);

        let comparison: CompareResponse;
        try {
          comparison = await ghRequest<CompareResponse>(
            `/repos/${owner}/${name}/compare/${base}...${target}`,
          );
        } catch {
          return jsonText({
            released: false,
            reason: "not-held",
            issue: number,
            branch: target,
            message: `No lock branch "${target}" on the remote — nothing to release.`,
          });
        }

        if (comparison.ahead_by > 0 && !force) {
          const pulls = await pullsForBranch(owner, name, target);
          const merged = pulls.find((p) => p.merged_at);
          if (!merged) {
            return structuredError({
              released: false,
              reason: "unmerged-commits",
              issue: number,
              branch: target,
              ahead_by: comparison.ahead_by,
              holder: await claimHolder(owner, name, target),
              message:
                `Refusing to release "${target}": it is ${comparison.ahead_by} commit(s) ahead of ` +
                `${base} and those commits are not in any merged PR. Deleting the ref would ` +
                "destroy work. Open a PR for it, or pass force:true if the commits are genuinely disposable.",
            });
          }
        }

        await deleteClaimLock(owner, name, target);

        const warnings: string[] = [];
        try {
          const me = await getViewerLogin();
          await ghRequest(`/repos/${owner}/${name}/issues/${number}/assignees`, {
            method: "DELETE",
            body: { assignees: [me] },
          });
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          warnings.push(`assignee not removed (the lock is released regardless): ${msg}`);
        }

        // A lock branch outlives its issue as readily as it outlives its work: a
        // merged PR closes the issue and leaves the ref behind. Returning THAT
        // to `ready` shows finished work as startable, and contradicts the model
        // the audit enforces — done is a closed issue with no status label at
        // all. So a closed issue has its status cleared rather than rewritten.
        let reopenTo: "ready" | undefined = "ready";
        try {
          const issue = await ghRequest<{ state?: string }>(
            `/repos/${owner}/${name}/issues/${number}`,
          );
          if (issue.state === "closed") reopenTo = undefined;
        } catch {
          // Unreadable state ⇒ treat it as open, which is the prior behaviour
          // and the far more common case.
        }

        let status: string | null = reopenTo ?? null;
        try {
          await setIssueStatus(owner, name, number, reopenTo);
        } catch (err) {
          status = null;
          const msg = err instanceof Error ? err.message : String(err);
          warnings.push(`status not updated (the lock is released regardless): ${msg}`);
        }

        const result = {
          released: true,
          issue: number,
          branch: target,
          ahead_by: comparison.ahead_by,
          forced: force,
          status,
        };
        return jsonText(warnings.length ? { ...result, _warnings: warnings } : result);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "work_in_flight",
    {
      description:
        "Survey every claim currently held on the remote: the `issue-*` lock branches, each with " +
        "its last commit (author + time) and any open PR. Call this BEFORE picking up work — a " +
        "claim held by another machine lives in a local worktree you cannot see, but its pushed " +
        "lock branch is visible here. A branch with a stale last commit and no PR is a candidate " +
        "for `claim_release`.",
      inputSchema: {
        repo: repoParam,
        limit: z
          .number()
          .int()
          .positive()
          .optional()
          .describe("Max in-flight branches to detail (default 30)."),
      },
    },
    async ({ repo, limit }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const [refs, pulls] = await Promise.all([
          ghRequest<MatchingRef[]>(
            `/repos/${owner}/${name}/git/matching-refs/heads/${CLAIM_BRANCH_PREFIX}`,
          ),
          ghRequest<OpenPull[]>(`/repos/${owner}/${name}/pulls`, {
            query: { state: "open", per_page: 100 },
          }),
        ]);

        const prByHead = new Map(pulls.map((p) => [p.head.ref, p]));
        const branches = refs
          .map((r) => ({ branch: r.ref.replace(/^refs\/heads\//, ""), sha: r.object.sha }))
          .slice(0, listLimit(limit));

        const rows = await Promise.all(
          branches.map(async ({ branch, sha }) => {
            let commit: CommitResponse | null = null;
            try {
              commit = await ghRequest<CommitResponse>(
                `/repos/${owner}/${name}/commits/${sha}`,
              );
            } catch {
              // A ref whose commit is unreadable still counts as in-flight.
            }
            const pr = prByHead.get(branch);
            return {
              branch,
              issue: issueNumberForBranch(branch) ?? null,
              sha,
              last_commit_at: commit?.commit?.author?.date ?? null,
              last_commit_author: commit?.commit?.author?.name ?? null,
              last_commit_message: commit?.commit?.message?.split("\n")[0] ?? null,
              pull_request: pr
                ? {
                    number: pr.number,
                    html_url: pr.html_url,
                    draft: pr.draft ?? false,
                    title: pr.title ?? "",
                  }
                : null,
            };
          }),
        );

        rows.sort((a, b) => (b.last_commit_at ?? "").localeCompare(a.last_commit_at ?? ""));
        return jsonText(rows);
      } catch (err) {
        return errorResult(err);
      }
    },
  );
}
