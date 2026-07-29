import { ghRequest } from "./github.js";
import { STATUS_LABEL_NAMES, statusLabel, type IssueStatus } from "./labels.js";
import { labelNames, type RawLabel } from "./slim.js";

/**
 * Set the single `status:*` label on an issue, preserving all other labels.
 * Omit `status` to clear the `status:*` label without setting a new one.
 * Shared by `issue_set_status`, `issue_claim`, and `pr_open_for_issue` so the
 * GET→filter→PUT sequence lives in exactly one place.
 *
 * Returns the resulting label names — the endpoint's full label objects are the
 * raw payload `issue_set_status` would otherwise surface.
 */
export async function setIssueStatus(
  owner: string,
  name: string,
  number: number,
  status?: IssueStatus,
): Promise<{ number: number; labels: string[] }> {
  const issue = await ghRequest<{ labels: { name: string }[] }>(
    `/repos/${owner}/${name}/issues/${number}`,
  );
  const kept = issue.labels
    .map((l) => l.name)
    .filter((n) => !STATUS_LABEL_NAMES.includes(n));
  const next = status ? [...kept, statusLabel(status)] : kept;
  const applied = await ghRequest<RawLabel[]>(
    `/repos/${owner}/${name}/issues/${number}/labels`,
    { method: "PUT", body: { labels: next } },
  );
  return { number, labels: labelNames(applied) };
}
