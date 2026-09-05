import { cacheKey, ghRequest, invalidate } from "./github.js";
import { isStatusLabel, statusLabel, type IssueStatus } from "./labels.js";
import { hasTickedOwnerAction, labelNames, type RawLabel } from "./slim.js";

/**
 * Set the single `status:*` label on an issue, preserving all other labels.
 * Omit `status` to clear the `status:*` label without setting a new one.
 * Shared by `issue_set_status`, `issue_claim`, and `pr_open_for_issue` so the
 * GET→filter→PUT sequence lives in exactly one place.
 *
 * Verifies the requested status label is actually present in the PUT
 * response before returning — a 2xx from `/labels` is not proof the write
 * took effect, and a caller (`issue_claim` in particular) that trusts a
 * silent-but-ineffective write reports `status:in-progress` while the issue
 * stays on its previous label. Throwing here routes that case through the
 * same error handling as any other failed write, instead of a false success.
 *
 * Returns the resulting label names — the endpoint's full label objects are the
 * raw payload `issue_set_status` would otherwise surface.
 */
export async function setIssueStatus(
  owner: string,
  name: string,
  number: number,
  status?: IssueStatus,
): Promise<{ number: number; labels: string[]; _warnings?: string[] }> {
  const issue = await ghRequest<{ labels: { name: string }[]; body?: string | null }>(
    `/repos/${owner}/${name}/issues/${number}`,
  );
  const kept = issue.labels
    .map((l) => l.name)
    .filter((n) => !isStatusLabel(n));
  const next = status ? [...kept, statusLabel(status)] : kept;
  const applied = await ghRequest<RawLabel[]>(
    `/repos/${owner}/${name}/issues/${number}/labels`,
    { method: "PUT", body: { labels: next } },
  );
  const appliedNames = labelNames(applied);
  if (status && !appliedNames.includes(statusLabel(status))) {
    throw new Error(
      `GitHub returned 2xx for the labels PUT on issue #${number}, but the response omits ` +
        `${statusLabel(status)} — applied labels: [${appliedNames.join(", ")}]. The status write ` +
        "did not take effect.",
    );
  }
  invalidate(cacheKey("issue", `${owner}/${name}`, number));

  // Re-blocking an issue whose owner-action checklist has a ticked box buries
  // an answer, and a bulk triage sweep is where that happens — one did exactly
  // this an hour after the owner had cleared the block, and the answer then sat
  // unread (#315). Warned rather than refused: the sweep may be right, and a
  // hard failure mid-sweep is its own mess. The point is that it cannot be
  // silent.
  const warnings =
    status === "blocked" && hasTickedOwnerAction(issue.body)
      ? [
          `#${number} has a ticked owner-action box, which means somebody answered it. ` +
            "Re-applying status:blocked buries that answer — read the checklist and the newest " +
            "comments before letting this stand.",
        ]
      : [];

  return { number, labels: appliedNames, ...(warnings.length ? { _warnings: warnings } : {}) };
}
