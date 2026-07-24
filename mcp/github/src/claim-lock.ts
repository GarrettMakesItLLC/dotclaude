import { GhHttpError, ghRequest, jsonText } from "./github.js";

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
  const issue = await ghRequest<{ title?: string }>(
    `/repos/${owner}/${name}/issues/${number}`,
  );
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
 * Describe who holds an existing lock ref: its last commit and any PR opened
 * from it, so the caller can tell a live claim from an abandoned one. Every
 * lookup is best-effort — a conflict is already established by the time this
 * runs, and partial detail beats failing the report.
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

  const pulls = await pullsForBranch(owner, name, branch);
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
  };
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
      throw new ClaimConflictError(
        `Issue #${issueNumber} is already claimed: the lock branch "${branch}" exists on the remote. ` +
          "Another machine or session holds it — do NOT start this issue. " +
          "Pick different work, or resume the existing branch after confirming it is abandoned " +
          "(`work_in_flight` to survey, `claim_release` to drop a dead lock).",
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
