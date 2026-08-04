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

/**
 * Register the issue tools against a stub MCP server and return the captured
 * handler for the named tool so it can be invoked directly.
 */
async function getIssueHandler(name: string): Promise<ToolHandler> {
  const { handler } = await getIssueTool(name);
  return handler;
}

interface ToolDef {
  inputSchema: Record<string, { safeParse: (v: unknown) => { success: boolean } }>;
}

/** Register the issue tools and return both the declared schema and the handler. */
async function getIssueTool(name: string): Promise<{ def: ToolDef; handler: ToolHandler }> {
  const { registerIssueTools } = await import("../src/tools/issues.js");
  const tools = new Map<string, { def: ToolDef; handler: ToolHandler }>();
  const stubServer = {
    registerTool: (toolName: string, def: ToolDef, handler: ToolHandler) => {
      tools.set(toolName, { def, handler });
    },
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  registerIssueTools(stubServer as any);
  const tool = tools.get(name);
  if (!tool) throw new Error(`${name} was not registered`);
  return tool;
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  vi.resetModules();
  execFileMock.mockReset();
  execFileMock.mockImplementation(
    (_cmd: string, args: string[], cb: (err: unknown, out?: unknown) => void) => {
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

describe("issue_list — PR filtering across pages", () => {
  it("excludes pull_request items and returns up to limit real issues spanning pages", async () => {
    fetchMock
      .mockResolvedValueOnce(
        makeResponse({
          status: 200,
          headers: { Link: '<https://api.github.com/x?page=2>; rel="next"' },
          body: [
            { number: 1 },
            { number: 2, pull_request: { url: "..." } },
            { number: 3 },
            { number: 4, pull_request: { url: "..." } },
          ],
        }),
      )
      .mockResolvedValueOnce(
        makeResponse({
          status: 200,
          body: [{ number: 5 }, { number: 6, pull_request: { url: "..." } }, { number: 7 }],
        }),
      );

    const handler = await getIssueHandler("issue_list");
    const res = await handler({ repo: "octo/repo", state: "open", limit: 4 });

    expect(res.isError).toBeFalsy();
    const issues = JSON.parse(res.content[0].text) as { number: number }[];
    const numbers = issues.map((i) => i.number);

    // PRs (2, 4, 6) excluded; real issues from both pages; capped at limit=4.
    expect(numbers).toEqual([1, 3, 5, 7]);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

describe("issue_update state_reason", () => {
  it("forwards state_reason in the PATCH body when closing", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      expect(init.method).toBe("PATCH");
      expect(init.body).toContain('"state_reason":"not_planned"');
      return makeResponse({ status: 200, body: { number: 9, state: "closed", state_reason: "not_planned" } });
    });
    const handler = await getIssueHandler("issue_update");
    const res = await handler({ repo: "octo/repo", number: 9, state: "closed", state_reason: "not_planned" });
    expect(res.isError).toBeFalsy();
  });
});

describe("issue_add_assignees", () => {
  it("resolves @me via GET /user and POSTs the resolved login", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (url.endsWith("/user")) return makeResponse({ status: 200, body: { login: "GarrettMakesIt" } });
      if (init.method === "POST" && url.includes("/assignees")) {
        expect(init.body).toContain("GarrettMakesIt");
        return makeResponse({ status: 201, body: { number: 5, assignees: [{ login: "GarrettMakesIt" }] } });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getIssueHandler("issue_add_assignees");
    const res = await handler({ repo: "octo/repo", number: 5, assignees: ["@me"] });

    expect(res.isError).toBeFalsy();
    const issue = JSON.parse(res.content[0].text) as { assignees: string[] };
    expect(issue.assignees).toEqual(["GarrettMakesIt"]);
  });
});

describe("milestone_ensure", () => {
  it("returns an existing milestone by title without creating a duplicate", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string }) => {
      if (init.method === "GET" && url.includes("/milestones")) {
        return makeResponse({ status: 200, body: [{ number: 3, title: "v1" }, { number: 4, title: "v2" }] });
      }
      // A POST here would mean it wrongly tried to create — fail loudly.
      return makeResponse({ status: 500, body: { message: "should not create" } });
    });
    const handler = await getIssueHandler("milestone_ensure");
    const res = await handler({ repo: "octo/repo", title: "v2" });
    expect(res.isError).toBeFalsy();
    const ms = JSON.parse(res.content[0].text) as { number: number };
    expect(ms.number).toBe(4);
  });
});

describe("issue_add_sub_issue", () => {
  it("resolves the sub-issue number to its id, then POSTs sub_issue_id", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "GET" && url.endsWith("/issues/12")) {
        return makeResponse({ status: 200, body: { number: 12, id: 999001 } });
      }
      if (init.method === "POST" && url.endsWith("/issues/4/sub_issues")) {
        expect(init.body).toContain('"sub_issue_id":999001');
        return makeResponse({ status: 201, body: { number: 4, id: 500 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_add_sub_issue");
    const res = await handler({ repo: "octo/repo", number: 4, sub_number: 12 });
    expect(res.isError).toBeFalsy();
  });
});

describe("issue_set_status", () => {
  it("accepts every taxonomy status — including waiting — on the tools that take one", async () => {
    const { ISSUE_STATUSES } = await import("../src/labels.js");
    for (const tool of ["issue_set_status", "issue_open"]) {
      const { def } = await getIssueTool(tool);
      for (const status of ISSUE_STATUSES) {
        expect(def.inputSchema.status.safeParse(status).success, `${tool} ← ${status}`).toBe(true);
      }
      expect(def.inputSchema.status.safeParse("done").success).toBe(false);
    }
  });

  it("swaps the existing status:* label for status:waiting, preserving other labels", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "GET" && url.endsWith("/issues/3364")) {
        return makeResponse({
          status: 200,
          body: { labels: [{ name: "status:ready" }, { name: "type:task" }] },
        });
      }
      if (init.method === "PUT" && url.endsWith("/labels")) {
        const sent = JSON.parse(init.body as string).labels as string[];
        expect(sent).toEqual(["type:task", "status:waiting"]);
        return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_set_status");
    const res = await handler({ repo: "octo/repo", number: 3364, status: "waiting" });
    expect(res.isError).toBeFalsy();
    expect(JSON.parse(res.content[0].text).labels).toContain("status:waiting");
  });
});

describe("issue_set_type", () => {
  it("PATCHes native type then replaces type:* labels, preserving non-type labels", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "PATCH" && /\/issues\/7$/.test(url)) {
        expect(init.body).toContain('"type":"Bug"');
        return makeResponse({ status: 200, body: {} });
      }
      if (init.method === "GET" && url.endsWith("/issues/7")) {
        return makeResponse({ status: 200, body: { labels: [{ name: "type:feature" }, { name: "status:ready" }] } });
      }
      if (init.method === "PUT" && url.endsWith("/labels")) {
        const sent = JSON.parse((init.body as string)).labels as string[];
        expect(sent).toContain("type:bug");
        expect(sent).toContain("status:ready");
        expect(sent).not.toContain("type:feature");
        return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_set_type");
    const res = await handler({ repo: "octo/repo", number: 7, type: "bug" });
    expect(res.isError).toBeFalsy();
  });
});

describe("issue_set_complexity", () => {
  it("replaces complexity:* labels, preserving non-complexity labels", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "GET" && url.endsWith("/issues/7")) {
        return makeResponse({
          status: 200,
          body: { labels: [{ name: "complexity:trivial" }, { name: "status:ready" }] },
        });
      }
      if (init.method === "PUT" && url.endsWith("/labels")) {
        const sent = JSON.parse(init.body as string).labels as string[];
        expect(sent).toContain("complexity:complex");
        expect(sent).toContain("status:ready");
        expect(sent).not.toContain("complexity:trivial");
        return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_set_complexity");
    const res = await handler({ repo: "octo/repo", number: 7, complexity: "complex" });
    expect(res.isError).toBeFalsy();
  });
});

describe("issue_claim", () => {
  /**
   * Mock the full happy path. `refStatus` drives the outcome of the atomic
   * `POST /git/refs` that acquires the lock; `calls` records the request order
   * so the lock-before-assign sequence can be asserted.
   */
  function mockClaim(opts: {
    refStatus: number;
    calls: string[];
    assigneesStatus?: number;
    branchBody?: unknown;
    prsBody?: unknown;
    commentsBody?: unknown;
  }) {
    return async (url: string, init: { method?: string; body?: string }) => {
      const method = init.method ?? "GET";
      opts.calls.push(`${method} ${new URL(url).pathname}`);
      if (url.endsWith("/user")) return makeResponse({ status: 200, body: { login: "GarrettMakesIt" } });
      if (method === "GET" && /\/repos\/octo\/repo$/.test(new URL(url).pathname)) {
        return makeResponse({ status: 200, body: { default_branch: "main" } });
      }
      if (method === "GET" && url.endsWith("/git/ref/heads/main")) {
        return makeResponse({ status: 200, body: { object: { sha: "basesha" } } });
      }
      if (method === "POST" && url.endsWith("/git/refs")) {
        if (opts.refStatus !== 201) {
          return makeResponse({ status: opts.refStatus, body: { message: "Reference already exists" } });
        }
        return makeResponse({ status: 201, body: { ref: JSON.parse(init.body as string).ref } });
      }
      if (method === "GET" && url.includes("/branches/")) {
        return makeResponse({ status: 200, body: opts.branchBody ?? { commit: { sha: "x" } } });
      }
      if (method === "GET" && url.includes("/pulls")) {
        return makeResponse({ status: 200, body: opts.prsBody ?? [] });
      }
      if (method === "GET" && url.includes("/issues/8/comments")) {
        return makeResponse({ status: 200, body: opts.commentsBody ?? [] });
      }
      if (method === "POST" && url.endsWith("/assignees")) {
        return makeResponse({ status: opts.assigneesStatus ?? 201, body: {} });
      }
      if (method === "POST" && url.endsWith("/issues/8/comments")) {
        return makeResponse({ status: 201, body: { body: JSON.parse(init.body as string).body } });
      }
      if (method === "GET" && url.endsWith("/issues/8")) {
        return makeResponse({
          status: 200,
          body: { number: 8, title: "Fix the thing!", labels: [{ name: "status:ready" }, { name: "type:bug" }] },
        });
      }
      if (method === "PUT" && url.endsWith("/labels")) {
        const sent = JSON.parse(init.body as string).labels as string[];
        expect(sent).toEqual(expect.arrayContaining(["type:bug", "status:in-progress"]));
        expect(sent).not.toContain("status:ready");
        return makeResponse({ status: 200, body: { number: 8 } });
      }
      return makeResponse({ status: 500 });
    };
  }

  it("creates the lock ref BEFORE assigning, then assigns @me and sets status:in-progress", async () => {
    const calls: string[] = [];
    fetchMock.mockImplementation(mockClaim({ refStatus: 201, calls }));

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as {
      claimed: boolean;
      branch: string;
      base: string;
      status: string | null;
      assignee: string | null;
    };
    expect(out.claimed).toBe(true);
    expect(out.branch).toBe("issue-8-fix-the-thing");
    expect(out.base).toBe("main");
    expect(out.assignee).toBe("GarrettMakesIt");
    expect(out.status).toBe("in-progress");

    const refIndex = calls.findIndex((c) => c === "POST /repos/octo/repo/git/refs");
    const stampIndex = calls.findIndex((c) => c === "POST /repos/octo/repo/issues/8/comments");
    const assignIndex = calls.findIndex((c) => c.endsWith("/assignees"));
    expect(refIndex).toBeGreaterThanOrEqual(0);
    expect(stampIndex).toBeGreaterThan(refIndex);
    expect(assignIndex).toBeGreaterThan(refIndex);
  });

  it("stamps the claim with a holder identity and timestamp, so a later conflict can tell who holds it", async () => {
    const calls: string[] = [];
    let stampBody = "";
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if ((init.method ?? "GET") === "POST" && url.endsWith("/issues/8/comments")) {
        stampBody = JSON.parse(init.body as string).body as string;
      }
      return mockClaim({ refStatus: 201, calls })(url, init);
    });

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBeFalsy();
    expect(stampBody).toContain("🔒 Claimed by");
    const marker = /<!-- claim-lock: (\{.*?\}) -->/.exec(stampBody);
    expect(marker).not.toBeNull();
    const stamp = JSON.parse(marker![1]) as { branch: string; holder: string; claimed_at: string };
    expect(stamp.branch).toBe("issue-8-fix-the-thing");
    expect(typeof stamp.holder).toBe("string");
    expect(stamp.holder.length).toBeGreaterThan(0);
    expect(new Date(stamp.claimed_at).toString()).not.toBe("Invalid Date");
  });

  it("returns a structured already-claimed failure on a 422 from the ref POST, and never assigns", async () => {
    const calls: string[] = [];
    fetchMock.mockImplementation(
      mockClaim({
        refStatus: 422,
        calls,
        branchBody: {
          commit: {
            sha: "deadbeef",
            commit: { author: { name: "Ada", date: "2026-07-20T00:00:00Z" }, message: "wip\n\nbody" },
          },
        },
        prsBody: [{ number: 77, html_url: "https://gh/pr/77", state: "open", draft: false, title: "WIP" }],
      }),
    );

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBe(true);
    const out = JSON.parse(res.content[0].text) as {
      claimed: boolean;
      reason: string;
      issue: number;
      branch: string;
      last_commit: { sha: string; author: string | null; date: string | null } | null;
      pull_request: { number: number } | null;
    };
    expect(out.claimed).toBe(false);
    expect(out.reason).toBe("already-claimed");
    expect(out.issue).toBe(8);
    expect(out.branch).toBe("issue-8-fix-the-thing");
    expect(out.last_commit?.sha).toBe("deadbeef");
    expect(out.last_commit?.author).toBe("Ada");
    expect(out.last_commit?.date).toBe("2026-07-20T00:00:00Z");
    expect(out.pull_request?.number).toBe(77);
    expect(calls.some((c) => c.endsWith("/assignees"))).toBe(false);
  });

  it("surfaces the holder's identity and claim time from the stamp comment on a conflict", async () => {
    const calls: string[] = [];
    const stamp = { branch: "issue-8-fix-the-thing", holder: "other-machine", claimed_at: "2026-08-01T10:00:00.000Z" };
    fetchMock.mockImplementation(
      mockClaim({
        refStatus: 422,
        calls,
        commentsBody: [
          { body: `🔒 Claimed by \`other-machine\` at ${stamp.claimed_at} (branch \`${stamp.branch}\`)\n<!-- claim-lock: ${JSON.stringify(stamp)} -->` },
        ],
      }),
    );

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBe(true);
    const out = JSON.parse(res.content[0].text) as {
      claimed_by: string | null;
      claimed_at: string | null;
      message: string;
    };
    expect(out.claimed_by).toBe("other-machine");
    expect(out.claimed_at).toBe(stamp.claimed_at);
    expect(out.message).toContain("other-machine");
    expect(out.message).toContain("pick different work");
  });

  it("keeps the lock and reports a _warnings entry when the self-assign fails", async () => {
    const calls: string[] = [];
    fetchMock.mockImplementation(mockClaim({ refStatus: 201, calls, assigneesStatus: 500 }));

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as {
      claimed: boolean;
      assignee: string | null;
      _warnings: string[];
    };
    expect(out.claimed).toBe(true);
    expect(out.assignee).toBeNull();
    expect(out._warnings).toHaveLength(1);
    expect(out._warnings[0]).toContain("self-assign");
    // The ref is the lock — it must NOT be rolled back when assignment fails.
    expect(calls.some((c) => c.startsWith("DELETE"))).toBe(false);
  });

  it("uses an explicit branch override instead of deriving one from the title", async () => {
    const calls: string[] = [];
    fetchMock.mockImplementation(mockClaim({ refStatus: 201, calls }));

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8, branch: "issue-8-custom" });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as { branch: string };
    expect(out.branch).toBe("issue-8-custom");
  });
});

describe("issue_open", () => {
  it("composes type/source labels on create, defaults feedback (source set, no status) to status:blocked, and sends the native-type PATCH", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        const sent = JSON.parse(init.body as string) as { labels: string[] };
        expect(sent.labels).toEqual(
          expect.arrayContaining(["status:blocked", "type:bug", "source:redthread"]),
        );
        expect(sent.labels).not.toContain("status:ready");
        return makeResponse({ status: 201, body: { number: 42, id: 8001, labels: sent.labels } });
      }
      if (init.method === "PATCH" && url.endsWith("/issues/42")) {
        expect(init.body).toContain('"type":"Bug"');
        return makeResponse({ status: 200, body: {} });
      }
      if (init.method === "GET" && url.endsWith("/issues/42")) {
        return makeResponse({ status: 200, body: { number: 42, id: 8001 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({
      repo: "octo/repo",
      title: "Something broke",
      type: "bug",
      source: "redthread",
    });
    expect(res.isError).toBeFalsy();
    const issue = JSON.parse(res.content[0].text) as { number: number };
    expect(issue.number).toBe(42);
  });

  it("defaults to status:ready when neither status nor source is given", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        const sent = JSON.parse(init.body as string) as { labels: string[] };
        expect(sent.labels).toEqual(expect.arrayContaining(["status:ready"]));
        return makeResponse({ status: 201, body: { number: 45, id: 8004, labels: sent.labels } });
      }
      if (init.method === "GET" && url.endsWith("/issues/45")) {
        return makeResponse({ status: 200, body: { number: 45, id: 8004 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({ repo: "octo/repo", title: "Plain task" });
    expect(res.isError).toBeFalsy();
  });

  it("defaults an owner-reported defect to status:ready — his report is the verification", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        const sent = JSON.parse(init.body as string) as { labels: string[] };
        expect(sent.labels).toEqual(
          expect.arrayContaining(["status:ready", "type:bug", "source:owner"]),
        );
        expect(sent.labels).not.toContain("status:blocked");
        return makeResponse({ status: 201, body: { number: 46, id: 8005, labels: sent.labels } });
      }
      if (init.method === "PATCH" && url.endsWith("/issues/46")) {
        return makeResponse({ status: 200, body: {} });
      }
      if (init.method === "GET" && url.endsWith("/issues/46")) {
        return makeResponse({ status: 200, body: { number: 46, id: 8005 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({
      repo: "octo/repo",
      title: "Rest timer drifts",
      type: "bug",
      source: "owner",
    });
    expect(res.isError).toBeFalsy();
  });

  it("still defaults an owner-reported feature to status:blocked — it needs his intent first", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        const sent = JSON.parse(init.body as string) as { labels: string[] };
        expect(sent.labels).toEqual(
          expect.arrayContaining(["status:blocked", "type:feature", "source:owner"]),
        );
        expect(sent.labels).not.toContain("status:ready");
        return makeResponse({ status: 201, body: { number: 47, id: 8006, labels: sent.labels } });
      }
      if (init.method === "PATCH" && url.endsWith("/issues/47")) {
        return makeResponse({ status: 200, body: {} });
      }
      if (init.method === "GET" && url.endsWith("/issues/47")) {
        return makeResponse({ status: 200, body: { number: 47, id: 8006 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({
      repo: "octo/repo",
      title: "Add a plate calculator",
      type: "feature",
      source: "owner",
    });
    expect(res.isError).toBeFalsy();
  });

  it("defaults an in-app third-party report to status:blocked", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        const sent = JSON.parse(init.body as string) as { labels: string[] };
        expect(sent.labels).toEqual(
          expect.arrayContaining(["status:blocked", "type:bug", "source:user-feedback"]),
        );
        return makeResponse({ status: 201, body: { number: 48, id: 8007, labels: sent.labels } });
      }
      if (init.method === "PATCH" && url.endsWith("/issues/48")) {
        return makeResponse({ status: 200, body: {} });
      }
      if (init.method === "GET" && url.endsWith("/issues/48")) {
        return makeResponse({ status: 200, body: { number: 48, id: 8007 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({
      repo: "octo/repo",
      title: "Timer stops on lock screen",
      type: "bug",
      source: "user-feedback",
    });
    expect(res.isError).toBeFalsy();
  });

  it("attaches an existing milestone by title without creating a duplicate", async () => {
    let milestonePatched = false;
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        return makeResponse({ status: 201, body: { number: 43, id: 8002 } });
      }
      if (init.method === "GET" && url.includes("/milestones")) {
        return makeResponse({ status: 200, body: [{ number: 3, title: "v1" }, { number: 4, title: "v2" }] });
      }
      if (init.method === "POST" && url.includes("/milestones")) {
        return makeResponse({ status: 500, body: { message: "should not create" } });
      }
      if (init.method === "PATCH" && url.endsWith("/issues/43")) {
        expect(init.body).toContain('"milestone":4');
        milestonePatched = true;
        return makeResponse({ status: 200, body: {} });
      }
      if (init.method === "GET" && url.endsWith("/issues/43")) {
        return makeResponse({ status: 200, body: { number: 43, id: 8002 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({ repo: "octo/repo", title: "Ship v2", milestone: "v2" });
    expect(res.isError).toBeFalsy();
    expect(milestonePatched).toBe(true);
  });

  it("nests the new issue under a parent via sub_issues, using the new issue's id", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        return makeResponse({ status: 201, body: { number: 44, id: 8003 } });
      }
      if (init.method === "POST" && url.endsWith("/issues/4/sub_issues")) {
        expect(init.body).toContain('"sub_issue_id":8003');
        return makeResponse({ status: 201, body: {} });
      }
      if (init.method === "GET" && url.endsWith("/issues/44")) {
        return makeResponse({ status: 200, body: { number: 44, id: 8003 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({ repo: "octo/repo", title: "Sub task", parent: 4 });
    expect(res.isError).toBeFalsy();
  });

  it("returns the created issue with no _warnings on a fully successful run", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        return makeResponse({ status: 201, body: { number: 50, id: 8010 } });
      }
      if (init.method === "GET" && url.endsWith("/issues/50")) {
        return makeResponse({ status: 200, body: { number: 50, id: 8010 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({ repo: "octo/repo", title: "Plain task" });
    expect(res.isError).toBeFalsy();
    const issue = JSON.parse(res.content[0].text) as Record<string, unknown>;
    expect(issue.number).toBe(50);
    expect(issue._warnings).toBeUndefined();
  });

  it("still returns the created issue (not an error) when the sub-issue link fails, with a _warnings entry", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        return makeResponse({ status: 201, body: { number: 51, id: 8011 } });
      }
      if (init.method === "POST" && url.endsWith("/issues/4/sub_issues")) {
        return makeResponse({ status: 500, body: { message: "server error" } });
      }
      if (init.method === "GET" && url.endsWith("/issues/51")) {
        return makeResponse({ status: 200, body: { number: 51, id: 8011 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({ repo: "octo/repo", title: "Sub task", parent: 4 });
    expect(res.isError).toBeFalsy();
    const issue = JSON.parse(res.content[0].text) as { number: number; _warnings: string[] };
    expect(issue.number).toBe(51);
    expect(issue._warnings).toHaveLength(1);
    expect(issue._warnings[0]).toContain("parent #4");
  });

  it("still returns the created issue (not an error) when the milestone step fails, with a _warnings entry", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        return makeResponse({ status: 201, body: { number: 52, id: 8012 } });
      }
      if (init.method === "GET" && url.includes("/milestones")) {
        return makeResponse({ status: 500, body: { message: "server error" } });
      }
      if (init.method === "GET" && url.endsWith("/issues/52")) {
        return makeResponse({ status: 200, body: { number: 52, id: 8012 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({ repo: "octo/repo", title: "Ship v2", milestone: "v2" });
    expect(res.isError).toBeFalsy();
    const issue = JSON.parse(res.content[0].text) as { number: number; _warnings: string[] };
    expect(issue.number).toBe(52);
    expect(issue._warnings).toHaveLength(1);
    expect(issue._warnings[0]).toContain('milestone "v2"');
  });

  it("includes complexity:* in the label set when complexity is passed", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        const body = JSON.parse(init.body as string);
        expect(body.labels).toContain("complexity:complex");
        return makeResponse({ status: 201, body: { number: 42, id: 1001 } });
      }
      if (init.method === "GET" && url.endsWith("/issues/42")) {
        return makeResponse({ status: 200, body: { number: 42, labels: [{ name: "complexity:complex" }] } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({ repo: "octo/repo", title: "Something hard", complexity: "complex" });
    expect(res.isError).toBeFalsy();
  });
});

describe("issue_set_status", () => {
  it("swaps the status:* label, preserving type:*/source:* labels", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "GET" && url.endsWith("/issues/11")) {
        return makeResponse({
          status: 200,
          body: {
            labels: [
              { name: "status:in-progress" },
              { name: "type:bug" },
              { name: "source:redthread" },
            ],
          },
        });
      }
      if (init.method === "PUT" && url.endsWith("/labels")) {
        const sent = JSON.parse(init.body as string).labels as string[];
        expect(sent).toEqual(
          expect.arrayContaining(["status:in-review", "type:bug", "source:redthread"]),
        );
        expect(sent).not.toContain("status:in-progress");
        return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_set_status");
    const res = await handler({ repo: "octo/repo", number: 11, status: "in-review" });
    expect(res.isError).toBeFalsy();
  });

  it("clears the status:* label when called with no status", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "GET" && url.endsWith("/issues/11")) {
        return makeResponse({
          status: 200,
          body: { labels: [{ name: "status:in-progress" }, { name: "type:bug" }] },
        });
      }
      if (init.method === "PUT" && url.endsWith("/labels")) {
        const sent = JSON.parse(init.body as string).labels as string[];
        expect(sent).toContain("type:bug");
        expect(sent.some((n) => n.startsWith("status:"))).toBe(false);
        return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_set_status");
    const res = await handler({ repo: "octo/repo", number: 11 });
    expect(res.isError).toBeFalsy();
  });
});
