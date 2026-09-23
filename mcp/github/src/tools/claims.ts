import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  errorResult,
  getViewerLogin,
  ghPaginate,
  ghRequest,
  jsonText,
  listLimit,
  repoParam,
  resolveRepo,
} from "../github.js";
import { setIssueStatus } from "../issue-status.js";
import {
  CLAIM_BRANCH_PREFIX,
  ClaimAmbiguousError,
  claimHolder,
  defaultBranch,
  deleteClaimLock,
  issueNumberForBranch,
  latestClaimStamp,
  pullsForBranch,
  resolveClaimBranch,
  structuredError,
} from "../claim-lock.js";

interface CompareFile {
  filename: string;
  status: string;
  previous_filename?: string;
}

interface CompareResponse {
  ahead_by: number;
  behind_by: number;
  status: string;
  files?: CompareFile[];
}

interface ContentsResponse {
  content?: string;
  encoding?: string;
  type?: string;
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
/**
 * The SHA of the commit that closed this issue, when one did.
 *
 * `closed` events carry `commit_id` only when a commit message's closing
 * keyword did the closing — which means the commit is on the default branch.
 * Returns `undefined` for an open issue, a hand-closed one, or when the
 * timeline cannot be read (unreadable is never treated as evidence).
 */
async function closedByCommit(
  owner: string,
  name: string,
  issue: number,
): Promise<string | undefined> {
  try {
    const events = await ghPaginate<{ event: string; commit_id?: string | null }>(
      `/repos/${owner}/${name}/issues/${issue}/timeline`,
      { limit: 300 },
    );
    const closed = events.filter(
      (e: { event: string; commit_id?: string | null }) => e.event === "closed" && e.commit_id,
    );
    return closed.length > 0 ? (closed[closed.length - 1]!.commit_id ?? undefined) : undefined;
  } catch {
    return undefined;
  }
}

/**
 * A file's raw content at a given ref, or `undefined` when it does not exist
 * there (a 404) and `null` when it exists but this cannot read it as text —
 * a directory, a submodule, or a blob GitHub declines to inline (too large).
 * Both `undefined` and `null` are "no evidence", never "matches" or "landed".
 */
async function fileContentAt(
  owner: string,
  name: string,
  ref: string,
  path: string,
): Promise<string | null | undefined> {
  try {
    const res = await ghRequest<ContentsResponse>(
      `/repos/${owner}/${name}/contents/${path.split("/").map(encodeURIComponent).join("/")}`,
      { query: { ref } },
    );
    if (res.type && res.type !== "file") return null;
    if (res.encoding !== "base64" || res.content === undefined) return null;
    return Buffer.from(res.content, "base64").toString("utf8");
  } catch (err) {
    if (err instanceof Error && /HTTP 404/.test(err.message)) return undefined;
    return null;
  }
}

/**
 * Degraded-mode content check (#410 option 2): a lock branch's commits can be
 * genuinely landed under different SHAs — a wave squashes several batch PRs
 * into one integration branch and merges only that — so ancestry and
 * merged-PR membership both miss it. This checks the WORK instead of the
 * history: every file the lock branch touched since it diverged from the
 * default branch (the compare endpoint's `files`, which is already a
 * merge-base diff) is fetched at the lock branch's head and at the default
 * branch's current head. If every touched file's content agrees — or, for a
 * file the branch deleted, is likewise absent from the default branch — the
 * branch's tree is contained in the default branch and the commits landed,
 * whatever SHA they landed under.
 *
 * Conservative by construction: any file this can't read cleanly (network
 * error, binary, directory-vs-file mismatch), or an empty change list, is
 * "not proven landed" rather than "landed" — a false negative here just falls
 * through to requiring `force`, which is the safe direction to be wrong in.
 */
const COMPARE_FILES_CAP = 300;

async function contentAlreadyLanded(
  owner: string,
  name: string,
  base: string,
  target: string,
): Promise<boolean> {
  try {
    const comparison = await ghRequest<CompareResponse>(
      `/repos/${owner}/${name}/compare/${base}...${target}`,
    );
    const files = comparison.files ?? [];
    // The compare endpoint lists at most COMPARE_FILES_CAP files and truncates
    // silently, so a list that reaches the cap may be missing the one file
    // that did not land.
    if (files.length === 0 || files.length >= COMPARE_FILES_CAP) return false;
    for (const f of files) {
      if (f.status === "removed") {
        const onBase = await fileContentAt(owner, name, base, f.filename);
        if (onBase !== undefined) return false;
        continue;
      }
      const [onTarget, onBase] = await Promise.all([
        fileContentAt(owner, name, target, f.filename),
        fileContentAt(owner, name, base, f.filename),
      ]);
      if (onTarget === null || onTarget === undefined) return false;
      if (onBase === null || onBase === undefined) return false;
      if (onTarget !== onBase) return false;
    }
    return true;
  } catch {
    return false;
  }
}

  server.registerTool(
    "claim_release",
    {
      description:
        "Release an issue's claim by deleting its lock branch on the remote — for work abandoned " +
        "without a PR. Refuses when the branch carries commits that landed nowhere (not merged " +
        "into the default branch and not in a merged PR) unless `force` is set, so a live claim on " +
        "another machine cannot be dropped by accident. Also returns an OPEN issue to " +
        "`status:ready` — a closed one has its status cleared instead, because done is the absence " +
        "of a status — and unassigns the authenticated user (best-effort, reported via `_warnings`). " +
        "The lock is found by reading the `issue-<N>-*` refs that exist, not by re-deriving a slug " +
        "from the issue's current title, so a batch-named lock or one whose issue was retitled is " +
        "still reachable; pass `branch` when several refs exist for the issue.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number whose claim is released."),
        branch: z
          .string()
          .optional()
          .describe(
            "The lock branch to release. Defaults to whichever `issue-<N>-*` ref exists on the " +
              "remote; required only when several do.",
          ),
        force: z
          .boolean()
          .default(false)
          .describe("Delete the lock even when the branch holds unmerged commits."),
      },
    },
    async ({ repo, number, branch, force }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        let target: string;
        try {
          target = await resolveClaimBranch(owner, name, number, branch);
        } catch (err) {
          if (err instanceof ClaimAmbiguousError) {
            return structuredError({
              released: false,
              reason: "ambiguous-lock",
              issue: number,
              branches: err.branches,
              message: err.message,
            });
          }
          throw err;
        }
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

        const pulls = await pullsForBranch(owner, name, target);

        // Deleting a branch that heads an OPEN pull request closes that PR.
        // That is a different act from dropping an abandoned ref, and `force`
        // does not authorise it: force says "these commits are disposable",
        // never "close the review somebody has open on them" (#299, where a
        // forced release took twelve commits and an open PR with them, and the
        // work survived only because a local worktree still had it).
        //
        // Refused even under force, because there is a cheap correct order —
        // close the PR, then release — and no way to undo the alternative.
        const openPr = pulls.find((p) => !p.merged_at && p.state === "open");
        if (openPr) {
          return structuredError({
            released: false,
            reason: "open-pull-request",
            issue: number,
            branch: target,
            pull_request: { number: openPr.number, html_url: openPr.html_url },
            holder: await claimHolder(owner, name, target),
            message:
              `Refusing to release "${target}": PR #${openPr.number} is open against it, and ` +
              "deleting the ref would close that PR. `force` covers disposable commits, not an " +
              "open review. Close or merge the PR first, then release — or if the PR is the " +
              "thing you meant to discard, close it explicitly so that is on the record.",
          });
        }

        if (comparison.ahead_by > 0 && !force) {
          const merged = pulls.find((p) => p.merged_at);
          // A THIRD way commits can have landed, which the two tests above
          // both miss. In degraded mode (`operating-a-fleet`) a wave stacks
          // its batch PRs into one integration branch, merges that, and closes
          // the batch PRs UNMERGED. So every per-issue lock branch is ahead of
          // the trunk with commits that are in no merged PR — while the work
          // itself is in the trunk under a different squash SHA.
          //
          // The signal the wave leaves behind is the issue's own closing
          // event: GitHub records `commit_id` on the `closed` event when a
          // commit's `Closes #N` closed it, and that commit is on the default
          // branch by construction. So a CLOSED issue closed BY a commit is
          // evidence the work landed, whatever the branch's own SHAs say.
          //
          // Without this, a wave's locks can only be cleared with `force`, and
          // using force dozens of times in a row is how it stops meaning
          // anything on the day it would have saved real unpushed work (#382).
          const relanded = !merged ? await closedByCommit(owner, name, number) : undefined;
          // The commit-closed-the-issue signal above misses a batch PR whose
          // issue a DIFFERENT commit in the same wave closed (one PR closing
          // several issues, #310's shape), or a wave that closes issues by
          // hand rather than by keyword. Fall back to checking the work
          // itself before requiring force.
          const contentLanded =
            !merged && !relanded ? await contentAlreadyLanded(owner, name, base, target) : false;
          if (!merged && !relanded && !contentLanded) {
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
        let keptStatus: string | null = null;
        try {
          const issue = await ghRequest<{ state?: string; labels?: { name: string }[] }>(
            `/repos/${owner}/${name}/issues/${number}`,
          );
          if (issue.state === "closed") {
            reopenTo = undefined;
          } else {
            // Releasing a claim UNDOES THE CLAIM, and what the claim set was
            // `status:in-progress`. Anything else on the issue was put there
            // deliberately by somebody after that, so rewriting it to `ready`
            // is not a release — it is a downgrade.
            //
            // The case that made this bite: one PR closing several issues.
            // The agent claims each, works on one lock branch, releases the
            // others — and each released issue, already `in-review` with an
            // open PR against it, was shown as startable again (#310).
            const current = (issue.labels ?? [])
              .map((l) => l.name)
              .find((n) => n.startsWith("status:"));
            if (current && current !== "status:in-progress") {
              reopenTo = undefined;
              keptStatus = current;
            }
          }
        } catch {
          // Unreadable state ⇒ treat it as open, which is the prior behaviour
          // and the far more common case.
        }

        // `setIssueStatus(…, undefined)` CLEARS the label, which is right for a
        // closed issue and wrong for one we are deliberately leaving alone.
        if (keptStatus) {
          const releasedNote = `status left as \`${keptStatus}\` — the lock is released, but ` +
            "something moved this issue past `in-progress` and a release should not rewind that.";
          warnings.push(releasedNote);
        }

        let status: string | null = keptStatus ?? reopenTo ?? null;
        try {
          if (!keptStatus) await setIssueStatus(owner, name, number, reopenTo);
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
        "who claimed it and when (from its stamp comment, when one was posted), its last commit " +
        "(author + time), the state of its issue, and any open PR. Call this BEFORE picking up " +
        "work — a claim held by another machine lives in a local worktree you cannot see, but " +
        "its pushed lock branch is visible here.\n\n" +
        "`issue_state` is the signal for whether a claim is dead. A row marked `closed` is a " +
        "leftover lock (closing an issue does not delete its branch) and is safe to " +
        "`claim_release`; `dead_claims` counts them. An `open` row is live work — pick something " +
        "else — however quiet it looks.\n\n" +
        "**Never read `last_commit_at` as activity.** A holder\'s commits can sit unpushed in a " +
        "worktree this cannot see, so a months-quiet branch may be someone\'s live work and " +
        "releasing it destroys it. Set `include_closed: false` to survey only live claims.",
      inputSchema: {
        repo: repoParam,
        limit: z
          .number()
          .int()
          .positive()
          .optional()
          .describe("Max in-flight branches to detail (default 30)."),
        include_closed: z
          .boolean()
          .optional()
          .describe(
            "Include locks whose issue is already closed — leftovers, not work in progress. " +
              "Default true so they stay visible for cleanup; false surveys only live claims.",
          ),
      },
    },
    async ({ repo, limit, include_closed: includeClosed = true }) => {
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
            const issue = issueNumberForBranch(branch) ?? null;
            const [commit, stamp, issueState] = await Promise.all([
              ghRequest<CommitResponse>(`/repos/${owner}/${name}/commits/${sha}`).catch(
                // A ref whose commit is unreadable still counts as in-flight.
                () => null,
              ),
              issue ? latestClaimStamp(owner, name, issue, branch) : Promise.resolve(null),
              // The one sound signal for whether a claim is dead. Closing an
              // issue does not delete its lock branch, so the ref outlives the
              // work and the protocol's "anything listed is being worked" rule
              // then steers every session away from issues nobody holds.
              issue
                ? ghRequest<{ state?: string }>(`/repos/${owner}/${name}/issues/${issue}`)
                    .then((i) => i.state ?? null)
                    .catch(() => null)
                : Promise.resolve(null),
            ]);
            const pr = prByHead.get(branch);
            return {
              branch,
              issue,
              sha,
              claimed_by: stamp?.holder ?? null,
              claimed_at: stamp?.claimed_at ?? null,
              issue_state: issueState,
              /** A lock whose issue is closed. Safe to `claim_release`; not work in progress. */
              dead: issueState === "closed",
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

        const dead = rows.filter((r) => r.dead);
        const shown = includeClosed ? rows : rows.filter((r) => !r.dead);
        // A count rather than only per-row flags: the failure this fixes is a
        // reader skimming the list and treating its length as "work in
        // progress", which is what hid six dead locks among eight rows.
        return jsonText({
          live_claims: rows.length - dead.length,
          dead_claims: dead.length,
          ...(dead.length > 0
            ? {
                note:
                  `${dead.length} lock(s) below have a closed issue and are leftovers rather ` +
                  `than work in progress — release them with claim_release. Judge by issue_state, ` +
                  `never by last_commit_at: a holder's commits can sit unpushed where this cannot see them.`,
              }
            : {}),
          claims: shown,
        });
      } catch (err) {
        return errorResult(err);
      }
    },
  );
}
