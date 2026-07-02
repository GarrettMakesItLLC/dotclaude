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
  const { registerIssueTools } = await import("../src/tools/issues.js");
  const handlers = new Map<string, ToolHandler>();
  const stubServer = {
    registerTool: (toolName: string, _def: unknown, handler: ToolHandler) => {
      handlers.set(toolName, handler);
    },
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  registerIssueTools(stubServer as any);
  const handler = handlers.get(name);
  if (!handler) throw new Error(`${name} was not registered`);
  return handler;
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
    const issue = JSON.parse(res.content[0].text) as { assignees: { login: string }[] };
    expect(issue.assignees[0].login).toBe("GarrettMakesIt");
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

describe("issue_claim", () => {
  it("assigns @me and swaps any status:* label for status:in-progress", async () => {
    let assigned = false;
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (url.endsWith("/user")) return makeResponse({ status: 200, body: { login: "GarrettMakesIt" } });
      if (init.method === "POST" && url.endsWith("/assignees")) {
        assigned = true;
        return makeResponse({ status: 201, body: {} });
      }
      if (init.method === "GET" && url.endsWith("/issues/8")) {
        return makeResponse({ status: 200, body: { labels: [{ name: "status:ready" }, { name: "type:bug" }] } });
      }
      if (init.method === "PUT" && url.endsWith("/labels")) {
        const sent = JSON.parse(init.body as string).labels as string[];
        expect(sent).toEqual(expect.arrayContaining(["type:bug", "status:in-progress"]));
        expect(sent).not.toContain("status:ready");
        return makeResponse({ status: 200, body: { number: 8 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });
    expect(res.isError).toBeFalsy();
    expect(assigned).toBe(true);
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
