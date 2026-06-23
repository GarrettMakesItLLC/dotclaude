import { beforeEach, describe, expect, it, vi } from "vitest";

// Mock the github module so checks.ts gets a controlled ghRequest. Only the
// symbols checks.ts imports need to exist.
const ghRequestMock = vi.fn();
vi.mock("../src/github.js", () => ({
  ghRequest: ghRequestMock,
}));

const repo = { owner: "octo", name: "repo" };

/**
 * Wire `ghRequest` so the `/status` (combined commit status) and `/check-runs`
 * endpoints return the given payloads.
 */
function setEndpoints(status: unknown, checkRuns: unknown): void {
  ghRequestMock.mockImplementation(async (path: string) => {
    if (path.endsWith("/status")) return status;
    if (path.endsWith("/check-runs")) return checkRuns;
    throw new Error(`unexpected path ${path}`);
  });
}

let getChecksSummary: typeof import("../src/checks.js").getChecksSummary;

beforeEach(async () => {
  vi.resetModules();
  ghRequestMock.mockReset();
  ({ getChecksSummary } = await import("../src/checks.js"));
});

describe("combined_state rollup", () => {
  it("uses status.state when legacy statuses are present (total_count > 0)", async () => {
    setEndpoints(
      {
        state: "success",
        total_count: 2,
        statuses: [
          { context: "ci", state: "success", description: null, target_url: "u" },
        ],
      },
      { total_count: 0, check_runs: [] },
    );

    const summary = await getChecksSummary(repo, "abc");
    expect(summary.combined_state).toBe("success");
  });

  it("falls back to check-runs rollup -> success when no legacy statuses and all runs succeed", async () => {
    setEndpoints(
      { state: "pending", total_count: 0, statuses: [] },
      {
        total_count: 2,
        check_runs: [
          { name: "build", status: "completed", conclusion: "success", details_url: null },
          { name: "lint", status: "completed", conclusion: "skipped", details_url: null },
        ],
      },
    );

    const summary = await getChecksSummary(repo, "abc");
    expect(summary.combined_state).toBe("success");
  });

  it("rolls up to failure when a check-run failed or timed out", async () => {
    setEndpoints(
      { state: "pending", total_count: 0, statuses: [] },
      {
        total_count: 2,
        check_runs: [
          { name: "build", status: "completed", conclusion: "success", details_url: null },
          { name: "e2e", status: "completed", conclusion: "timed_out", details_url: null },
        ],
      },
    );

    const summary = await getChecksSummary(repo, "abc");
    expect(summary.combined_state).toBe("failure");
  });

  it("rolls up to pending when a check-run is still in progress", async () => {
    setEndpoints(
      { state: "pending", total_count: 0, statuses: [] },
      {
        total_count: 1,
        check_runs: [
          { name: "build", status: "in_progress", conclusion: null, details_url: null },
        ],
      },
    );

    const summary = await getChecksSummary(repo, "abc");
    expect(summary.combined_state).toBe("pending");
  });

  it("rolls up to pending when there are zero statuses and zero check-runs", async () => {
    setEndpoints(
      { state: "pending", total_count: 0, statuses: [] },
      { total_count: 0, check_runs: [] },
    );

    const summary = await getChecksSummary(repo, "abc");
    expect(summary.combined_state).toBe("pending");
  });

  it("merges both status and check_run entries into checks[]", async () => {
    setEndpoints(
      {
        state: "success",
        total_count: 1,
        statuses: [
          { context: "legacy-ci", state: "success", description: null, target_url: "s" },
        ],
      },
      {
        total_count: 1,
        check_runs: [
          { name: "actions-ci", status: "completed", conclusion: "success", details_url: "c" },
        ],
      },
    );

    const summary = await getChecksSummary(repo, "abc");
    const types = summary.checks.map((c) => c.type);
    expect(types).toContain("status");
    expect(types).toContain("check_run");
    expect(summary.checks).toHaveLength(2);
  });
});
