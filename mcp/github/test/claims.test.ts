import { beforeEach, describe, expect, it, vi } from "vitest";

const execFileMock = vi.fn();
vi.mock("node:child_process", () => ({
  execFile: execFileMock,
}));

function makeResponse(opts: {
  status: number;
  body?: unknown;
  headers?: Record<string, string>;
}): Response {
  const { status, body, headers = {} } = opts;
  const text = body === undefined ? "" : JSON.stringify(body);
  return {
    status,
    ok: status >= 200 && status < 300,
    headers: new Headers(headers),
    text: async () => text,
    json: async () => JSON.parse(text),
  } as unknown as Response;
}

type ToolHandler = (args: Record<string, unknown>) => Promise<{
  content: { type: string; text: string }[];
  isError?: boolean;
}>;

async function getClaimHandler(name: string): Promise<ToolHandler> {
  const { registerClaimTools } = await import("../src/tools/claims.js");
  const handlers = new Map<string, ToolHandler>();
  const stubServer = {
    registerTool: (toolName: string, _def: unknown, handler: ToolHandler) => {
      handlers.set(toolName, handler);
    },
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  registerClaimTools(stubServer as any);
  const handler = handlers.get(name);
  if (!handler) throw new Error(`${name} was not registered`);
  return handler;
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  vi.resetModules();
  execFileMock.mockReset();
  execFileMock.mockImplementation(
    (_cmd: string, args: string[], ...rest: unknown[]) => {
      const cb = rest[rest.length - 1] as (err: unknown, out?: unknown) => void;
      if (args[0] === "auth" && args[1] === "token") {
        cb(null, { stdout: "tok\n", stderr: "" });
        return;
      }
      cb(new Error(`unexpected gh args: ${args.join(" ")}`));
    },
  );
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});

describe("claimBranchName", () => {
  it("kebab-slugs the title, drops punctuation, and truncates without a trailing dash", async () => {
    const { claimBranchName } = await import("../src/claim-lock.js");
    expect(claimBranchName(12, "Fix the thing!")).toBe("issue-12-fix-the-thing");
    expect(claimBranchName(12, "  Spaces  &  Symbols  ")).toBe("issue-12-spaces-symbols");
    const long = claimBranchName(7, "a".repeat(80));
    expect(long.length).toBeLessThanOrEqual("issue-7-".length + 40);
    expect(long.endsWith("-")).toBe(false);
    expect(claimBranchName(9, "!!!")).toBe("issue-9");
  });
});

describe("claim_release", () => {
  /**
   * Deleting a branch that heads an OPEN pull request closes that PR. `force`
   * says "these commits are disposable"; it has never meant "close the review
   * somebody has open on them" (#299 — a forced release took twelve commits
   * and an open PR with them, and the work survived only because a local
   * worktree still had it).
   */
  describe("an open pull request against the lock branch", () => {
    const releaseWith = async (pulls: unknown[], args: Record<string, unknown>) => {
      let deleted = false;
      fetchMock.mockImplementation(async (url: string, init: { method?: string }) => {
        if (url.endsWith("/user")) return makeResponse({ status: 200, body: { login: "GarrettMakesIt" } });
        if (init.method === "GET" && url.endsWith("/repos/octo/repo")) {
          return makeResponse({ status: 200, body: { default_branch: "main" } });
        }
        if (init.method === "GET" && url.includes("/compare/")) {
          return makeResponse({ status: 200, body: { ahead_by: 12, behind_by: 0, status: "ahead" } });
        }
        if (init.method === "GET" && url.includes("/pulls")) {
          return makeResponse({ status: 200, body: pulls });
        }
        if (init.method === "GET" && url.endsWith("/issues/12")) {
          return makeResponse({ status: 200, body: { number: 12, title: "Fix the thing", state: "open", labels: [] } });
        }
        if (init.method === "DELETE" && url.includes("/git/refs/heads/")) {
          deleted = true;
          return makeResponse({ status: 204 });
        }
        if (init.method === "DELETE") return makeResponse({ status: 204 });
        if (init.method === "PUT" && url.endsWith("/labels")) {
          return makeResponse({ status: 200, body: [] });
        }
        return makeResponse({ status: 500 });
      });
      const handler = await getClaimHandler("claim_release");
      const res = await handler({ repo: "octo/repo", number: 12, ...args });
      return { out: JSON.parse(res.content[0].text) as Record<string, unknown>, deleted };
    };

    const openPr = [{ number: 77, html_url: "https://gh/pr/77", state: "open", merged_at: null }];

    it("refuses even under force, and does not delete the ref", async () => {
      const { out, deleted } = await releaseWith(openPr, { force: true });
      expect(out.released).toBe(false);
      expect(out.reason).toBe("open-pull-request");
      expect(deleted).toBe(false);
      expect(String(out.message)).toMatch(/would close that PR/);
    });

    it("names the PR, so the correct order is actionable", async () => {
      const { out } = await releaseWith(openPr, {});
      expect(out.pull_request).toMatchObject({ number: 77 });
    });

    it("still releases when the only PR is already merged", async () => {
      // The pre-existing escape hatch: work that landed is safe to drop.
      const merged = [{ number: 70, html_url: "https://gh/pr/70", state: "closed", merged_at: "2026-09-01T00:00:00Z" }];
      const { out, deleted } = await releaseWith(merged, {});
      expect(out.released).toBe(true);
      expect(deleted).toBe(true);
    });

    it("still refuses unmerged commits with no PR at all, unless forced", async () => {
      const none = await releaseWith([], {});
      expect(none.out.reason).toBe("unmerged-commits");
      expect(none.deleted).toBe(false);
      // force remains the documented escape for that case — it is only the
      // open-PR case it no longer covers.
      const forced = await releaseWith([], { force: true });
      expect(forced.out.released).toBe(true);
      expect(forced.deleted).toBe(true);
    });
  });


  it("deletes the lock ref when the branch is not ahead of the default branch", async () => {
    let deleted = false;
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (url.endsWith("/user")) return makeResponse({ status: 200, body: { login: "GarrettMakesIt" } });
      if (init.method === "GET" && url.endsWith("/repos/octo/repo")) {
        return makeResponse({ status: 200, body: { default_branch: "main" } });
      }
      if (init.method === "GET" && url.endsWith("/issues/12")) {
        return makeResponse({ status: 200, body: { number: 12, title: "Fix the thing", labels: [] } });
      }
      if (init.method === "GET" && url.includes("/compare/")) {
        return makeResponse({ status: 200, body: { ahead_by: 0, behind_by: 3, status: "behind" } });
      }
      if (init.method === "DELETE" && url.endsWith("/git/refs/heads/issue-12-fix-the-thing")) {
        deleted = true;
        return makeResponse({ status: 204 });
      }
      if (init.method === "DELETE" && url.endsWith("/assignees")) {
        return makeResponse({ status: 200, body: {} });
      }
      if (init.method === "PUT" && url.endsWith("/labels")) {
        const sent = (JSON.parse(init.body ?? "{}") as { labels: string[] }).labels;
        return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getClaimHandler("claim_release");
    const res = await handler({ repo: "octo/repo", number: 12 });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as { released: boolean; branch: string };
    expect(out.released).toBe(true);
    expect(out.branch).toBe("issue-12-fix-the-thing");
    expect(deleted).toBe(true);
  });

  it("returns an OPEN issue to status:ready", async () => {
    let sentLabels: string[] | undefined;
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (url.endsWith("/user")) return makeResponse({ status: 200, body: { login: "GarrettMakesIt" } });
      if (init.method === "GET" && url.endsWith("/repos/octo/repo")) {
        return makeResponse({ status: 200, body: { default_branch: "main" } });
      }
      if (init.method === "GET" && url.endsWith("/issues/12")) {
        return makeResponse({
          status: 200,
          body: { number: 12, title: "Fix the thing", state: "open", labels: [{ name: "type:bug" }] },
        });
      }
      if (init.method === "GET" && url.includes("/compare/")) {
        return makeResponse({ status: 200, body: { ahead_by: 0, behind_by: 0, status: "identical" } });
      }
      if (init.method === "PUT" && url.endsWith("/labels")) {
        sentLabels = (JSON.parse(init.body ?? "{}") as { labels: string[] }).labels;
        return makeResponse({ status: 200, body: sentLabels.map((n) => ({ name: n })) });
      }
      if (init.method === "DELETE") return makeResponse({ status: 204 });
      return makeResponse({ status: 500 });
    });

    const handler = await getClaimHandler("claim_release");
    const res = await handler({ repo: "octo/repo", number: 12 });

    expect((JSON.parse(res.content[0].text) as { status: string | null }).status).toBe("ready");
    expect(sentLabels).toEqual(["type:bug", "status:ready"]);
  });

  it("CLEARS the status on a closed issue rather than showing finished work as startable", async () => {
    // A lock branch outlives its issue as readily as it outlives its work: a
    // merged PR closes the issue and leaves the ref behind. Done in this
    // taxonomy is a closed issue with NO status label.
    let sentLabels: string[] | undefined;
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (url.endsWith("/user")) return makeResponse({ status: 200, body: { login: "GarrettMakesIt" } });
      if (init.method === "GET" && url.endsWith("/repos/octo/repo")) {
        return makeResponse({ status: 200, body: { default_branch: "main" } });
      }
      if (init.method === "GET" && url.endsWith("/issues/12")) {
        return makeResponse({
          status: 200,
          body: {
            number: 12,
            title: "Fix the thing",
            state: "closed",
            labels: [{ name: "type:bug" }, { name: "status:in-progress" }],
          },
        });
      }
      if (init.method === "GET" && url.includes("/compare/")) {
        return makeResponse({ status: 200, body: { ahead_by: 0, behind_by: 0, status: "identical" } });
      }
      if (init.method === "PUT" && url.endsWith("/labels")) {
        sentLabels = (JSON.parse(init.body ?? "{}") as { labels: string[] }).labels;
        return makeResponse({ status: 200, body: [] });
      }
      if (init.method === "DELETE") return makeResponse({ status: 204 });
      return makeResponse({ status: 500 });
    });

    const handler = await getClaimHandler("claim_release");
    const res = await handler({ repo: "octo/repo", number: 12 });

    expect(res.isError).toBeFalsy();
    expect((JSON.parse(res.content[0].text) as { status: string | null }).status).toBeNull();
    // The stale `status:in-progress` goes; nothing replaces it.
    expect(sentLabels).toEqual(["type:bug"]);
  });

  it("refuses to delete a branch with unmerged commits unless force is set", async () => {
    let deleted = false;
    const mock = async (url: string, init: { method?: string }) => {
      if (init.method === "GET" && url.endsWith("/repos/octo/repo")) {
        return makeResponse({ status: 200, body: { default_branch: "main" } });
      }
      if (init.method === "GET" && url.endsWith("/issues/12")) {
        return makeResponse({ status: 200, body: { number: 12, title: "Fix the thing", labels: [] } });
      }
      if (init.method === "GET" && url.includes("/compare/")) {
        return makeResponse({ status: 200, body: { ahead_by: 2, behind_by: 0, status: "ahead" } });
      }
      if (init.method === "GET" && url.includes("/pulls")) {
        return makeResponse({ status: 200, body: [] });
      }
      if (url.endsWith("/user")) return makeResponse({ status: 200, body: { login: "GarrettMakesIt" } });
      if (init.method === "DELETE") {
        deleted = true;
        return makeResponse({ status: 204 });
      }
      if (init.method === "PUT" && url.endsWith("/labels")) {
        return makeResponse({ status: 200, body: [{ name: "status:ready" }] });
      }
      return makeResponse({ status: 500 });
    };
    fetchMock.mockImplementation(mock);

    const handler = await getClaimHandler("claim_release");
    const refused = await handler({ repo: "octo/repo", number: 12 });

    expect(refused.isError).toBe(true);
    const out = JSON.parse(refused.content[0].text) as { released: boolean; reason: string; ahead_by: number };
    expect(out.released).toBe(false);
    expect(out.reason).toBe("unmerged-commits");
    expect(out.ahead_by).toBe(2);
    expect(deleted).toBe(false);

    const forced = await handler({ repo: "octo/repo", number: 12, force: true });
    expect(forced.isError).toBeFalsy();
    expect(deleted).toBe(true);
  });

  it("releases an ahead branch without force when its commits landed in a merged PR", async () => {
    let deleted = false;
    fetchMock.mockImplementation(async (url: string, init: { method?: string }) => {
      if (init.method === "GET" && url.endsWith("/repos/octo/repo")) {
        return makeResponse({ status: 200, body: { default_branch: "main" } });
      }
      if (init.method === "GET" && url.endsWith("/issues/12")) {
        return makeResponse({ status: 200, body: { number: 12, title: "Fix the thing", labels: [] } });
      }
      if (init.method === "GET" && url.includes("/compare/")) {
        return makeResponse({ status: 200, body: { ahead_by: 2, behind_by: 0, status: "diverged" } });
      }
      if (init.method === "GET" && url.includes("/pulls")) {
        return makeResponse({
          status: 200,
          body: [{ number: 33, state: "closed", merged_at: "2026-07-01T00:00:00Z", html_url: "u", draft: false, title: "t", head: { ref: "issue-12-fix-the-thing" } }],
        });
      }
      if (url.endsWith("/user")) return makeResponse({ status: 200, body: { login: "GarrettMakesIt" } });
      if (init.method === "DELETE") {
        deleted = true;
        return makeResponse({ status: 204 });
      }
      if (init.method === "PUT" && url.endsWith("/labels")) {
        return makeResponse({ status: 200, body: [{ name: "status:ready" }] });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getClaimHandler("claim_release");
    const res = await handler({ repo: "octo/repo", number: 12 });
    expect(res.isError).toBeFalsy();
    expect(deleted).toBe(true);
  });

  it("reports not-held (without erroring) when the lock ref does not exist", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string }) => {
      if (init.method === "GET" && url.endsWith("/repos/octo/repo")) {
        return makeResponse({ status: 200, body: { default_branch: "main" } });
      }
      if (init.method === "GET" && url.endsWith("/issues/12")) {
        return makeResponse({ status: 200, body: { number: 12, title: "Fix the thing", labels: [] } });
      }
      if (init.method === "GET" && url.includes("/compare/")) {
        return makeResponse({ status: 404, body: { message: "Not Found" } });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getClaimHandler("claim_release");
    const res = await handler({ repo: "octo/repo", number: 12 });
    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as { released: boolean; reason: string };
    expect(out.released).toBe(false);
    expect(out.reason).toBe("not-held");
  });
});

describe("work_in_flight", () => {
  it("lists issue-* refs with last-commit detail and any open PR, newest first", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string }) => {
      if (init.method === "GET" && url.includes("/git/matching-refs/heads/issue-")) {
        return makeResponse({
          status: 200,
          body: [
            { ref: "refs/heads/issue-3-older", object: { sha: "sha3" } },
            { ref: "refs/heads/issue-9-newer", object: { sha: "sha9" } },
          ],
        });
      }
      if (init.method === "GET" && url.includes("/pulls")) {
        return makeResponse({
          status: 200,
          body: [
            {
              number: 40,
              html_url: "https://gh/pr/40",
              draft: false,
              title: "Newer work",
              head: { ref: "issue-9-newer" },
            },
          ],
        });
      }
      if (init.method === "GET" && url.endsWith("/commits/sha3")) {
        return makeResponse({
          status: 200,
          body: {
            sha: "sha3",
            commit: { author: { name: "Ada", date: "2026-07-01T00:00:00Z" }, message: "older\n\nbody" },
          },
        });
      }
      if (init.method === "GET" && url.endsWith("/commits/sha9")) {
        return makeResponse({
          status: 200,
          body: {
            sha: "sha9",
            commit: { author: { name: "Grace", date: "2026-07-20T00:00:00Z" }, message: "newer" },
          },
        });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getClaimHandler("work_in_flight");
    const res = await handler({ repo: "octo/repo" });

    expect(res.isError).toBeFalsy();
    const { claims: rows } = JSON.parse(res.content[0].text) as {
      claims: {
        branch: string;
        issue: number;
        last_commit_at: string | null;
        last_commit_author: string | null;
        pull_request: { number: number } | null;
      }[];
    };
    expect(rows).toHaveLength(2);
    expect(rows[0].branch).toBe("issue-9-newer");
    expect(rows[0].issue).toBe(9);
    expect(rows[0].last_commit_author).toBe("Grace");
    expect(rows[0].pull_request?.number).toBe(40);
    expect(rows[1].branch).toBe("issue-3-older");
    expect(rows[1].pull_request).toBeNull();
  });

  it("surfaces claimed_by/claimed_at from each branch's stamp comment", async () => {
    const stamp = { branch: "issue-9-newer", holder: "workhorse", claimed_at: "2026-07-19T00:00:00.000Z" };
    fetchMock.mockImplementation(async (url: string, init: { method?: string }) => {
      if (init.method === "GET" && url.includes("/git/matching-refs/heads/issue-")) {
        return makeResponse({
          status: 200,
          body: [{ ref: "refs/heads/issue-9-newer", object: { sha: "sha9" } }],
        });
      }
      if (init.method === "GET" && url.includes("/pulls")) {
        return makeResponse({ status: 200, body: [] });
      }
      if (init.method === "GET" && url.endsWith("/commits/sha9")) {
        return makeResponse({
          status: 200,
          body: { sha: "sha9", commit: { author: { name: "Grace", date: "2026-07-20T00:00:00Z" }, message: "newer" } },
        });
      }
      if (init.method === "GET" && url.includes("/issues/9/comments")) {
        return makeResponse({
          status: 200,
          body: [
            {
              body: `🔒 Claimed by \`workhorse\` at ${stamp.claimed_at} (branch \`issue-9-newer\`)\n<!-- claim-lock: ${JSON.stringify(stamp)} -->`,
            },
          ],
        });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getClaimHandler("work_in_flight");
    const res = await handler({ repo: "octo/repo" });

    expect(res.isError).toBeFalsy();
    const { claims: rows } = JSON.parse(res.content[0].text) as {
      claims: { claimed_by: string | null; claimed_at: string | null }[];
    };
    expect(rows[0].claimed_by).toBe("workhorse");
    expect(rows[0].claimed_at).toBe(stamp.claimed_at);
  });

  it("returns an empty list when the repo has no issue-* refs", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string }) => {
      if (init.method === "GET" && url.includes("/git/matching-refs/heads/issue-")) {
        return makeResponse({ status: 200, body: [] });
      }
      if (init.method === "GET" && url.includes("/pulls")) {
        return makeResponse({ status: 200, body: [] });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getClaimHandler("work_in_flight");
    const res = await handler({ repo: "octo/repo" });
    expect(res.isError).toBeFalsy();
    expect(JSON.parse(res.content[0].text)).toEqual({
      live_claims: 0,
      dead_claims: 0,
      claims: [],
    });
  });

  /**
   * A lock branch outlives its issue: closing the issue does not delete the
   * ref when that branch was not the PR head, which is the normal case. The
   * protocol tells every session "anything listed is being worked — pick
   * something else", so a leftover lock silently removes real work from the
   * queue on both machines (#314). Measured at 6 dead rows out of 8.
   */
  describe("locks whose issue has closed", () => {
    const twoRefs = async (url: string, init: { method?: string }) => {
      if (init.method === "GET" && url.includes("/git/matching-refs/heads/issue-")) {
        return makeResponse({
          status: 200,
          body: [
            { ref: "refs/heads/issue-3-done", object: { sha: "sha3" } },
            { ref: "refs/heads/issue-9-live", object: { sha: "sha9" } },
          ],
        });
      }
      if (init.method === "GET" && url.includes("/pulls")) {
        return makeResponse({ status: 200, body: [] });
      }
      if (init.method === "GET" && url.includes("/comments")) {
        return makeResponse({ status: 200, body: [] });
      }
      if (init.method === "GET" && url.endsWith("/issues/3")) {
        return makeResponse({ status: 200, body: { state: "closed" } });
      }
      if (init.method === "GET" && url.endsWith("/issues/9")) {
        return makeResponse({ status: 200, body: { state: "open" } });
      }
      if (init.method === "GET" && url.includes("/commits/")) {
        return makeResponse({
          status: 200,
          body: {
            commit: { author: { name: "Ada", date: "2026-07-01T00:00:00Z" }, message: "work" },
          },
        });
      }
      return makeResponse({ status: 500 });
    };

    it("marks them dead, counts them apart from the live ones, and says what to do", async () => {
      fetchMock.mockImplementation(twoRefs);
      const handler = await getClaimHandler("work_in_flight");
      const res = await handler({ repo: "octo/repo" });

      const body = JSON.parse(res.content[0].text) as {
        live_claims: number;
        dead_claims: number;
        note?: string;
        claims: { issue: number; issue_state: string | null; dead: boolean }[];
      };
      expect(body.live_claims).toBe(1);
      expect(body.dead_claims).toBe(1);
      // The count is the point: a reader who skims the list and treats its
      // length as work-in-progress is the failure mode this fixes.
      expect(body.note).toMatch(/claim_release/);
      expect(body.note).toMatch(/never by last_commit_at/i);
      expect(body.claims.find((c) => c.issue === 3)).toMatchObject({
        issue_state: "closed",
        dead: true,
      });
      expect(body.claims.find((c) => c.issue === 9)).toMatchObject({
        issue_state: "open",
        dead: false,
      });
    });

    it("omits them under include_closed: false, leaving only live claims", async () => {
      fetchMock.mockImplementation(twoRefs);
      const handler = await getClaimHandler("work_in_flight");
      const res = await handler({ repo: "octo/repo", include_closed: false });

      const body = JSON.parse(res.content[0].text) as {
        dead_claims: number;
        claims: { issue: number }[];
      };
      // Still counted, so the cleanup is not hidden by being filtered out.
      expect(body.dead_claims).toBe(1);
      expect(body.claims).toHaveLength(1);
      expect(body.claims[0].issue).toBe(9);
    });

    it("treats an unreadable issue as live rather than dead", async () => {
      // Fails safe: a lock is only ever released on positive evidence that its
      // issue is closed. A 404 or a rate limit must never read as "abandoned".
      fetchMock.mockImplementation(async (url: string, init: { method?: string }) => {
        if (init.method === "GET" && url.endsWith("/issues/3")) return makeResponse({ status: 500 });
        return twoRefs(url, init);
      });
      const handler = await getClaimHandler("work_in_flight");
      const res = await handler({ repo: "octo/repo" });

      const body = JSON.parse(res.content[0].text) as {
        dead_claims: number;
        claims: { issue: number; issue_state: string | null; dead: boolean }[];
      };
      expect(body.dead_claims).toBe(0);
      expect(body.claims.find((c) => c.issue === 3)).toMatchObject({
        issue_state: null,
        dead: false,
      });
    });
  });
});
