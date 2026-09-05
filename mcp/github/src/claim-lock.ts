import { hostname } from "node:os";
import { GhHttpError, ghRequest, jsonText } from "./github.js";

/** A marker embedded in the claim-stamp comment, parsed back out to identify the holder. */
const CLAIM_STAMP_RE = /<!-- claim-lock: (\{.*?\}) -->/;

interface ClaimStamp {
  branch: string;
  holder: string;
  claimed_at: string;
  /**
   * The session holding the lock, when the runtime exposes one. Optional
   * because a stamp written before this existed has none, and those must keep
   * resolving rather than becoming unreadable.
   */
  session?: string;
}

/** This machine's identity for claim stamps. Overridable for environments where `hostname()` isn't meaningful (e.g. ephemeral containers). */
function machineIdentity(): string {
  return process.env.CLAIM_MACHINE_ID ?? hostname();
}

/**
 * The SESSION holding a claim, which is what a hostname could never be.
 *
 * Several sessions per machine is the normal case with agent teams, so a
 * hostname identifies a box and not a holder — and three separate failures
 * followed from that in one night (#308): a sibling session could not tell a
 * claim from its own and force-pushed over it, an outside session could not
 * address the holder to hand work back, and `author` is the same GitHub user
 * everywhere so there was no second signal to fall back on.
 *
 * Undefined when the runtime exposes nothing, which keeps this additive: the
 * ref is still the lock, the hostname is still recorded, and a stamp without a
 * session degrades to exactly the old behaviour.
 */
function sessionIdentity(): string | undefined {
  const id = process.env.CLAIM_SESSION_ID ?? process.env.CLAUDE_CODE_SESSION_ID;
  return id && id.length > 0 ? id : undefined;
}

/** Short form for a human-readable line; the full id stays in the JSON. */
function shortSession(id: string): string {
  return id.length > 12 ? id.slice(0, 12) : id;
}

/**
 * How a lock relates to the caller: the caller's own, a sibling session on this
 * machine, or elsewhere. `same-machine` is deliberately NOT "yours" — treating
 * it as yours is what let one session force-push over another's branch.
 */
export type ClaimRelation = "self" | "same-machine" | "elsewhere";

export function claimRelation(stamp: {
  holder: string | null;
  session?: string | null;
}): ClaimRelation {
  const mySession = sessionIdentity();
  if (mySession && stamp.session && stamp.session === mySession) return "self";
  if (stamp.holder && stamp.holder === machineIdentity()) return "same-machine";
  return "elsewhere";
}

/** Prefix every claim branch carries, so a lock ref is identifiable by name alone. */
export const CLAIM_BRANCH_PREFIX = "issue-";

/** Branch names matching this encode the issue number they lock. */
export const CLAIM_BRANCH_RE = /^issue-(\d+)(?:-|$)/;

const MAX_SLUG = 40;

/**
 * The lock branch name for an issue: `issue-<N>-<kebab-slug-of-title>`.
 * The slug is truncated so the ref stays short enough for comfortable use in
 * worktree paths and PR heads; a title with no usable characters yields the
 * bare `issue-<N>`.
 */
export function claimBranchName(number: number, title: string): string {
  const slug = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, MAX_SLUG)
    .replace(/-+$/g, "");
  return slug ? `${CLAIM_BRANCH_PREFIX}${number}-${slug}` : `${CLAIM_BRANCH_PREFIX}${number}`;
}

/** The issue number a claim branch locks, or undefined for a non-claim branch. */
export function issueNumberForBranch(branch: string): number | undefined {
  const match = CLAIM_BRANCH_RE.exec(branch);
  return match ? Number(match[1]) : undefined;
}

interface IssueSummary {
  title?: string;
  state?: string;
  state_reason?: string | null;
  closed_at?: string | null;
}

/** Thrown when claiming an issue that is already closed — finished work, not startable. */
export class ClaimClosedError extends Error {
  constructor(
    message: string,
    readonly issue: {
      state: string;
      state_reason: string | null;
      closed_at: string | null;
    },
  ) {
    super(message);
    this.name = "ClaimClosedError";
  }
}

/**
 * Refuse to start a claim on an issue that's already closed — finished work,
 * not startable. Only `issue_claim` calls this: `claim_release` legitimately
 * targets closed issues too (a merged PR closes the issue and leaves the lock
 * ref behind), so the check does not belong in `resolveClaimBranch` itself.
 */
export async function assertIssueClaimable(
  owner: string,
  name: string,
  number: number,
): Promise<void> {
  const issue = await ghRequest<IssueSummary>(`/repos/${owner}/${name}/issues/${number}`);
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
}

/**
 * The lock branch for an issue: `branch` when given, otherwise derived from the
 * issue's current title.
 */
export async function resolveClaimBranch(
  owner: string,
  name: string,
  number: number,
  branch?: string,
): Promise<string> {
  if (branch) return branch;
  const issue = await ghRequest<IssueSummary>(`/repos/${owner}/${name}/issues/${number}`);
  return claimBranchName(number, issue.title ?? "");
}

export interface CommitSummary {
  sha: string;
  author: string | null;
  date: string | null;
  message: string | null;
}

export interface PullSummary {
  number: number;
  state: string;
  draft: boolean;
  title: string;
  html_url: string;
}

export interface ClaimHolder {
  branch: string;
  last_commit: CommitSummary | null;
  pull_request: PullSummary | null;
  claimed_by: string | null;
  claimed_at: string | null;
  /** The holding session, when its stamp carried one (#308). */
  claimed_by_session?: string | null;
  /** Whether that is this very session, a sibling on this machine, or elsewhere. */
  relation?: ClaimRelation;
}

/**
 * Thrown when claiming an issue that still has open sub-issues — an epic
 * exists to be decomposed, not implemented directly. Claiming it anyway has
 * caused real collisions (#148): a second machine claims one of the epic's
 * sub-issues later, sees no conflict (the lock is keyed per issue number, and
 * that sub-issue was never claimed), and builds on top of work already done
 * under the epic's own claim.
 */
export class ClaimEpicError extends Error {
  constructor(
    message: string,
    readonly epic: {
      open_sub_issues: number;
      total_sub_issues: number;
    },
  ) {
    super(message);
    this.name = "ClaimEpicError";
  }
}

/** Thrown when the lock ref already exists — the issue is claimed elsewhere. */
export class ClaimConflictError extends Error {
  constructor(
    message: string,
    readonly holder: ClaimHolder,
  ) {
    super(message);
    this.name = "ClaimConflictError";
  }
}

interface BranchResponse {
  commit: {
    sha: string;
    commit?: {
      message?: string;
      author?: { name?: string; date?: string };
    };
  };
}

interface PullResponse {
  number: number;
  state: string;
  draft?: boolean;
  title?: string;
  html_url?: string;
  merged_at?: string | null;
  head?: { ref?: string };
}

interface CommentResponse {
  body?: string;
}

function firstLine(message: string | undefined): string | null {
  if (!message) return null;
  return message.split("\n")[0];
}

/** The repo's default branch name. */
export async function defaultBranch(owner: string, name: string): Promise<string> {
  const repo = await ghRequest<{ default_branch: string }>(`/repos/${owner}/${name}`);
  return repo.default_branch;
}

/** Resolve the repo's default branch and the sha its ref currently points at. */
export async function defaultBranchHead(
  owner: string,
  name: string,
): Promise<{ branch: string; sha: string }> {
  const branch = await defaultBranch(owner, name);
  const ref = await ghRequest<{ object: { sha: string } }>(
    `/repos/${owner}/${name}/git/ref/heads/${branch}`,
  );
  return { branch, sha: ref.object.sha };
}

/** Pull requests whose head is `branch`, newest first. Empty on any failure. */
export async function pullsForBranch(
  owner: string,
  name: string,
  branch: string,
): Promise<PullResponse[]> {
  try {
    return await ghRequest<PullResponse[]>(`/repos/${owner}/${name}/pulls`, {
      query: { state: "all", head: `${owner}:${branch}`, per_page: 10 },
    });
  } catch {
    return [];
  }
}

/**
 * Post a comment on the issue stamping this claim with who holds it and when.
 * The ref alone records that *someone* claimed the issue, not *who* — every
 * machine authenticates as the same GitHub user, so the ref can't arbitrate
 * "is this my own earlier session, or another machine, holding the lock?".
 * Best-effort: the branch ref is the actual lock and must not depend on this.
 */
export async function stampClaim(
  owner: string,
  name: string,
  issueNumber: number,
  branch: string,
): Promise<void> {
  const session = sessionIdentity();
  const stamp: ClaimStamp = {
    branch,
    holder: machineIdentity(),
    claimed_at: new Date().toISOString(),
    ...(session ? { session } : {}),
  };
  await ghRequest(`/repos/${owner}/${name}/issues/${issueNumber}/comments`, {
    method: "POST",
    body: {
      body:
        `🔒 Claimed by \`${stamp.holder}\`` +
        (session ? ` (session \`${shortSession(session)}\`)` : "") +
        ` at ${stamp.claimed_at} (branch \`${branch}\`)\n` +
        `<!-- claim-lock: ${JSON.stringify(stamp)} -->`,
    },
  });
}

/** The most recent claim stamp for `branch`, or null if none was posted (older claim, or the post itself failed). */
export async function latestClaimStamp(
  owner: string,
  name: string,
  issueNumber: number,
  branch: string,
): Promise<ClaimStamp | null> {
  try {
    const comments = await ghRequest<CommentResponse[]>(
      `/repos/${owner}/${name}/issues/${issueNumber}/comments`,
      { query: { per_page: 100 } },
    );
    let latest: ClaimStamp | null = null;
    for (const comment of comments) {
      const match = comment.body ? CLAIM_STAMP_RE.exec(comment.body) : null;
      if (!match) continue;
      const parsed = JSON.parse(match[1]) as ClaimStamp;
      if (parsed.branch !== branch) continue;
      if (!latest || parsed.claimed_at > latest.claimed_at) latest = parsed;
    }
    return latest;
  } catch {
    return null;
  }
}

/**
 * Describe who holds an existing lock ref: its claim stamp (holder + time),
 * last commit, and any PR opened from it, so the caller can tell a live claim
 * from an abandoned one. Every lookup is best-effort — a conflict is already
 * established by the time this runs, and partial detail beats failing the report.
 */
export async function claimHolder(
  owner: string,
  name: string,
  branch: string,
): Promise<ClaimHolder> {
  let last_commit: CommitSummary | null = null;
  try {
    const data = await ghRequest<BranchResponse>(
      `/repos/${owner}/${name}/branches/${branch}`,
    );
    last_commit = {
      sha: data.commit.sha,
      author: data.commit.commit?.author?.name ?? null,
      date: data.commit.commit?.author?.date ?? null,
      message: firstLine(data.commit.commit?.message),
    };
  } catch {
    // Ref exists but its branch view is unavailable; the branch name still identifies the holder.
  }

  const issueNumber = issueNumberForBranch(branch);
  const [pulls, stamp] = await Promise.all([
    pullsForBranch(owner, name, branch),
    issueNumber ? latestClaimStamp(owner, name, issueNumber, branch) : Promise.resolve(null),
  ]);
  const pull = pulls.find((p) => p.state === "open") ?? pulls[0];

  return {
    branch,
    last_commit,
    pull_request: pull
      ? {
          number: pull.number,
          state: pull.state,
          draft: pull.draft ?? false,
          title: pull.title ?? "",
          html_url: pull.html_url ?? "",
        }
      : null,
    claimed_by: stamp?.holder ?? null,
    claimed_at: stamp?.claimed_at ?? null,
    claimed_by_session: stamp?.session ?? null,
    relation: claimRelation({
      holder: stamp?.holder ?? null,
      session: stamp?.session ?? null,
    }),
  };
}

/**
 * When the issue was last reopened, or null.
 *
 * The one thing that distinguishes a lock left over from an issue's PREVIOUS
 * life from a live claim on its current one. Asked of the timeline rather than
 * inferred from the branch, because nothing about the branch can tell them
 * apart: both may carry zero commits, and both may be quiet.
 *
 * Null on any failure, which reads as "no reopen" and leaves the lock treated
 * as live. Failing that way round matters: the cost of a missed leftover is an
 * issue somebody has to unstick by hand, and the cost of a false leftover is a
 * live claim getting stolen.
 */
async function lastReopenedAt(
  owner: string,
  name: string,
  issueNumber: number,
): Promise<string | null> {
  try {
    const events = await ghRequest<{ event?: string; created_at?: string }[]>(
      `/repos/${owner}/${name}/issues/${issueNumber}/timeline`,
      { query: { per_page: 100 } },
    );
    let latest: string | null = null;
    for (const e of events) {
      if (e.event !== "reopened" || !e.created_at) continue;
      if (!latest || e.created_at > latest) latest = e.created_at;
    }
    return latest;
  } catch {
    return null;
  }
}

/**
 * Acquire the distributed lock for an issue by creating its branch ref at the
 * current default-branch head. `POST /git/refs` is atomic and server-side: a
 * 422 means the ref already exists, i.e. another machine holds the claim.
 * Assignee cannot serve as the lock — both machines authenticate as the same
 * user — and a ref simultaneously makes the in-flight work visible.
 */
export async function acquireClaimLock(
  owner: string,
  name: string,
  branch: string,
  issueNumber: number,
): Promise<{ base: string; sha: string }> {
  const head = await defaultBranchHead(owner, name);
  try {
    await ghRequest(`/repos/${owner}/${name}/git/refs`, {
      method: "POST",
      body: { ref: `refs/heads/${branch}`, sha: head.sha },
    });
  } catch (err) {
    if (err instanceof GhHttpError && err.status === 422) {
      const holder = await claimHolder(owner, name, branch);

      // A lock outlives its issue: GitHub deletes a branch when ITS OWN PR
      // merges, and one PR commonly closes several issues, so every lock but
      // the PR head survives (#300). `issue_claim` already refuses a CLOSED
      // issue before it reaches this point, so the case that actually reaches
      // here is a REOPENED one — its state is `open` again while a lock from
      // its previous life is still sitting on the remote, reporting a holder
      // who finished months ago. The protocol then correctly says "pick
      // different work", and the issue is unclaimable forever.
      //
      // A stamp older than the last reopen is the only sound way to tell that
      // from a live claim. Not the branch's age: a holder's commits can sit
      // unpushed where the remote cannot see them, so a quiet branch may be
      // somebody's live work.
      const reopenedAt = holder.claimed_at
        ? await lastReopenedAt(owner, name, issueNumber)
        : null;
      if (reopenedAt && holder.claimed_at && holder.claimed_at < reopenedAt) {
        throw new ClaimConflictError(
          `Issue #${issueNumber} was REOPENED at ${reopenedAt}, and the lock branch "${branch}" ` +
            `was stamped before that (${holder.claimed_at}) — it is a leftover from the issue's ` +
            "previous life, not a live claim, and nobody is working this. Drop it with " +
            "claim_release and claim again.",
          holder,
        );
      }

      const whoWhen = holder.claimed_by
        ? `Claimed by \`${holder.claimed_by}\`` +
          (holder.claimed_by_session
            ? ` (session \`${shortSession(holder.claimed_by_session)}\`)`
            : "") +
          ` at ${holder.claimed_at}. `
        : "No claim stamp found (an older claim, predating stamping, or the stamp post failed) — " +
          "treat as held by an unknown machine. ";

      // Three states, not two. "Same machine" was being read as "probably mine",
      // and acting on that is how one session force-pushed over another's branch
      // and dropped four reviewed files (#308). Only a matching SESSION is yours.
      if (holder.relation === "self") {
        throw new ClaimConflictError(
          `Issue #${issueNumber} is already claimed BY THIS SESSION: the lock branch "${branch}" ` +
            `is yours and already exists. ${whoWhen}Nothing to do — check out the branch and carry on.`,
          holder,
        );
      }
      const sameMachine = holder.relation === "same-machine";
      throw new ClaimConflictError(
        `Issue #${issueNumber} is already claimed: the lock branch "${branch}" exists on the remote. ${whoWhen}` +
          (sameMachine
            ? "That's this machine but ANOTHER session — a sibling agent, or an earlier one of " +
              "yours that died. It is not yours to resume on that basis alone: a sibling may be " +
              "working it right now with commits you cannot see. Message the session named above, " +
              "or check `work_in_flight`; `claim_release` only once you know it is abandoned."
            : "Default to: pick different work. Only resume this branch if you have independent " +
              "confirmation (outside this tool) that the holder above is not actively working it — " +
              "the mismatch alone is NOT evidence of abandonment, and neither is a quiet " +
              "`last_commit_at`: the holder's commits may be unpushed where nothing here can see " +
              "them."),
        holder,
      );
    }
    throw err;
  }
  return { base: head.branch, sha: head.sha };
}

/** Delete a lock ref. */
export async function deleteClaimLock(
  owner: string,
  name: string,
  branch: string,
): Promise<void> {
  await ghRequest(`/repos/${owner}/${name}/git/refs/heads/${branch}`, {
    method: "DELETE",
  });
}

/** Render a structured tool failure: JSON payload plus the MCP error flag. */
export function structuredError(value: unknown): {
  content: { type: "text"; text: string }[];
  isError: true;
} {
  return { ...jsonText(value), isError: true };
}
