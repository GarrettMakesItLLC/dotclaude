import { ghRequest, type RepoRef } from "./github.js";

interface CombinedStatus {
  state: string;
  total_count: number;
  statuses: {
    context: string;
    state: string;
    description: string | null;
    target_url: string | null;
  }[];
}

interface CheckRunsResponse {
  total_count: number;
  check_runs: {
    name: string;
    status: string;
    conclusion: string | null;
    details_url: string | null;
  }[];
}

export interface ChecksSummary {
  ref: string;
  combined_state: string;
  checks: {
    name: string;
    type: "status" | "check_run";
    status: string;
    conclusion: string | null;
    url: string | null;
  }[];
}

/**
 * Roll a set of check-runs up to a single state. The combined-status endpoint
 * ignores check-runs entirely, so for Actions-only repos (no legacy statuses)
 * this is the only signal available.
 */
function aggregateCheckRunState(
  runs: CheckRunsResponse["check_runs"],
): string {
  if (runs.length === 0) return "pending";
  if (runs.some((r) => r.conclusion === "failure" || r.conclusion === "timed_out"))
    return "failure";
  if (runs.some((r) => r.status !== "completed")) return "pending";
  if (runs.every((r) => r.conclusion === "success" || r.conclusion === "skipped"))
    return "success";
  return "pending";
}

/**
 * Merge the legacy combined commit status and the Checks API check-runs for a
 * given ref/sha into one summary. Both endpoints are REST.
 */
export async function getChecksSummary(
  repo: RepoRef,
  ref: string,
): Promise<ChecksSummary> {
  const base = `/repos/${repo.owner}/${repo.name}/commits/${encodeURIComponent(ref)}`;
  const [status, checkRuns] = await Promise.all([
    ghRequest<CombinedStatus>(`${base}/status`),
    ghRequest<CheckRunsResponse>(`${base}/check-runs`),
  ]);

  const checks: ChecksSummary["checks"] = [
    ...status.statuses.map((s) => ({
      name: s.context,
      type: "status" as const,
      status: s.state,
      conclusion: s.state,
      url: s.target_url,
    })),
    ...checkRuns.check_runs.map((c) => ({
      name: c.name,
      type: "check_run" as const,
      status: c.status,
      conclusion: c.conclusion,
      url: c.details_url,
    })),
  ];

  // The combined-status endpoint reports "pending" when a commit has no legacy
  // statuses, even if all Actions check-runs passed. Fall back to the check-run
  // rollup in that case.
  const combined_state =
    status.total_count > 0
      ? status.state
      : aggregateCheckRunState(checkRuns.check_runs);

  return {
    ref,
    combined_state,
    checks,
  };
}
