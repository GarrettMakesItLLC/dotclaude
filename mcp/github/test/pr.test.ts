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
 * Register the PR tools against a stub MCP server and return the captured
 * handler for the named tool so it can be invoked directly.
 */
async function getPrHandler(name: string): Promise<ToolHandler> {
  const { registerPrTools } = await import("../src/tools/pr.js");
  const handlers = new Map<string, ToolHandler>();
  const stubServer = {
    registerTool: (toolName: string, _def: unknown, handler: ToolHandler) => {
      handlers.set(toolName, handler);
    },
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  registerPrTools(stubServer as any);
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

describe("pr_view caching", () => {
  it("caches a single PR for the process lifetime — a second view does not re-fetch", async () => {
    fetchMock.mockResolvedValueOnce(
      makeResponse({ status: 200, body: { number: 42, title: "Cached PR" } }),
    );
    const handler = await getPrHandler("pr_view");

    const first = await handler({ repo: "octo/repo", number: 42 });
    const second = await handler({ repo: "octo/repo", number: 42 });

    expect(first.isError).toBeFalsy();
    expect(second.isError).toBeFalsy();
    expect(JSON.parse(first.content[0].text)).toEqual(JSON.parse(second.content[0].text));
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("caches different PR numbers independently", async () => {
    fetchMock
      .mockResolvedValueOnce(makeResponse({ status: 200, body: { number: 42, title: "A" } }))
      .mockResolvedValueOnce(makeResponse({ status: 200, body: { number: 43, title: "B" } }));
    const handler = await getPrHandler("pr_view");

    await handler({ repo: "octo/repo", number: 42 });
    await handler({ repo: "octo/repo", number: 43 });
    await handler({ repo: "octo/repo", number: 42 });
    await handler({ repo: "octo/repo", number: 43 });

    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

/**
 * Runs pr_view → pr_view → <write tool> → pr_view for PR `number`, the PR
 * analogue of the issue helper in issues.test.ts: the second view must be
 * served from cache, and the post-write view must re-fetch.
 */
async function expectPrViewRefetchesAfterWrite(
  toolName: string,
  writeArgs: Record<string, unknown>,
  extraFetch: (
    url: string,
    init: { method?: string; body?: string },
  ) => Response | undefined | Promise<Response | undefined>,
) {
  const number = writeArgs.number as number;
  let version = 0;
  fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
    const method = init.method ?? "GET";
    if (method === "GET" && url.endsWith(`/pulls/${number}`)) {
      version += 1;
      return makeResponse({ status: 200, body: { number, title: `v${version}` } });
    }
    const custom = await extraFetch(url, init);
    if (custom) return custom;
    return makeResponse({ status: 500, body: { message: `unexpected ${method} ${url}` } });
  });

  const viewHandler = await getPrHandler("pr_view");
  const first = await viewHandler({ repo: "octo/repo", number });
  expect(first.isError).toBeFalsy();
  const firstTitle = (JSON.parse(first.content[0].text) as { title: string }).title;

  const second = await viewHandler({ repo: "octo/repo", number });
  expect((JSON.parse(second.content[0].text) as { title: string }).title).toBe(firstTitle);

  const writeHandler = await getPrHandler(toolName);
  const writeRes = await writeHandler(writeArgs);
  expect(writeRes.isError, `${toolName} failed: ${writeRes.content[0]?.text}`).toBeFalsy();

  const third = await viewHandler({ repo: "octo/repo", number });
  expect(third.isError).toBeFalsy();
  expect((JSON.parse(third.content[0].text) as { title: string }).title).not.toBe(firstTitle);
}

describe("write tools invalidate the cached PR view", () => {
  it("pr_update", async () => {
    await expectPrViewRefetchesAfterWrite(
      "pr_update",
      { repo: "octo/repo", number: 42, title: "New title" },
      async (url, init) => {
        if (init.method === "PATCH" && url.endsWith("/pulls/42")) {
          return makeResponse({ status: 200, body: { number: 42, title: "New title" } });
        }
        return undefined;
      },
    );
  });

  it("pr_comment", async () => {
    await expectPrViewRefetchesAfterWrite(
      "pr_comment",
      { repo: "octo/repo", number: 42, body: "a comment" },
      async (url, init) => {
        if (init.method === "POST" && url.endsWith("/issues/42/comments")) {
          return makeResponse({ status: 201, body: { id: 1, html_url: "https://x", created_at: "now" } });
        }
        return undefined;
      },
    );
  });

  it("pr_request_review", async () => {
    await expectPrViewRefetchesAfterWrite(
      "pr_request_review",
      { repo: "octo/repo", number: 42, reviewers: ["octocat"] },
      async (url, init) => {
        if (init.method === "POST" && url.endsWith("/pulls/42/requested_reviewers")) {
          return makeResponse({ status: 201, body: { requested_reviewers: [{ login: "octocat" }] } });
        }
        return undefined;
      },
    );
  });

  it("pr_merge", async () => {
    await expectPrViewRefetchesAfterWrite(
      "pr_merge",
      { repo: "octo/repo", number: 42, method: "squash" },
      async (url, init) => {
        if (init.method === "PUT" && url.endsWith("/pulls/42/merge")) {
          return makeResponse({ status: 200, body: { merged: true, sha: "abc123" } });
        }
        return undefined;
      },
    );
  });
});

describe("pr_open_for_issue", () => {
  it("appends Closes #N to the PR body and sets status:in-review after creating the PR", async () => {
    let putBody: string | undefined;
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/pulls")) {
        expect(init.body).toContain("Closes #9");
        return makeResponse({
          status: 201,
          body: { number: 100, title: "Add thing", html_url: "https://example.com/pr/100" },
        });
      }
      if (init.method === "GET" && url.endsWith("/issues/9")) {
        return makeResponse({
          status: 200,
          body: { labels: [{ name: "status:in-progress" }, { name: "type:feature" }] },
        });
      }
      if (init.method === "PUT" && url.endsWith("/issues/9/labels")) {
        putBody = init.body;
        const sent = JSON.parse(init.body as string).labels as string[];
        expect(sent).toEqual(expect.arrayContaining(["status:in-review", "type:feature"]));
        expect(sent).not.toContain("status:in-progress");
        return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getPrHandler("pr_open_for_issue");
    const res = await handler({
      repo: "octo/repo",
      issue_number: 9,
      head: "feature/x",
      base: "main",
      title: "Add thing",
      body: "Some description.",
    });

    expect(res.isError).toBeFalsy();
    const pr = JSON.parse(res.content[0].text) as { number: number; _warnings?: string[] };
    expect(pr.number).toBe(100);
    expect(putBody).toBeDefined();
    expect(pr._warnings).toBeUndefined();
  });

  it("still returns the created PR (not an error) when moving the issue to in-review fails, with a _warnings entry", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/pulls")) {
        return makeResponse({
          status: 201,
          body: { number: 103, title: "Add thing", html_url: "https://example.com/pr/103" },
        });
      }
      if (init.method === "GET" && url.endsWith("/issues/9")) {
        return makeResponse({ status: 500, body: { message: "server error" } });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getPrHandler("pr_open_for_issue");
    const res = await handler({
      repo: "octo/repo",
      issue_number: 9,
      head: "feature/x",
      base: "main",
      title: "Add thing",
      body: "Some description.",
    });

    expect(res.isError).toBeFalsy();
    const pr = JSON.parse(res.content[0].text) as { number: number; _warnings: string[] };
    expect(pr.number).toBe(103);
    expect(pr._warnings).toHaveLength(1);
    expect(pr._warnings[0]).toContain("in-review");
  });

  it("does not duplicate Closes #N when the body already contains it", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/pulls")) {
        const sent = JSON.parse(init.body as string) as { body: string };
        const occurrences = sent.body.split("Closes #9").length - 1;
        expect(occurrences).toBe(1);
        return makeResponse({ status: 201, body: { number: 101 } });
      }
      if (init.method === "GET" && url.endsWith("/issues/9")) {
        return makeResponse({ status: 200, body: { labels: [] } });
      }
      if (init.method === "PUT" && url.endsWith("/issues/9/labels")) {
        const sent = JSON.parse(init.body as string).labels as string[];
        return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getPrHandler("pr_open_for_issue");
    const res = await handler({
      repo: "octo/repo",
      issue_number: 9,
      head: "feature/x",
      base: "main",
      title: "Add thing",
      body: "Fixes the bug.\n\nCloses #9",
    });

    expect(res.isError).toBeFalsy();
  });

  it("appends Closes #1 even when the body already contains Closes #12 (no substring false-positive)", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/pulls")) {
        expect(init.body).toContain("Closes #1");
        const sent = JSON.parse(init.body as string) as { body: string };
        // Must be a real standalone append, not just a substring match against "Closes #12".
        expect(/Closes #1(?!\d)/.test(sent.body)).toBe(true);
        return makeResponse({ status: 201, body: { number: 102 } });
      }
      if (init.method === "GET" && url.endsWith("/issues/1")) {
        return makeResponse({ status: 200, body: { labels: [] } });
      }
      if (init.method === "PUT" && url.endsWith("/issues/1/labels")) {
        const sent = JSON.parse(init.body as string).labels as string[];
        return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getPrHandler("pr_open_for_issue");
    const res = await handler({
      repo: "octo/repo",
      issue_number: 1,
      head: "feature/y",
      base: "main",
      title: "Add other thing",
      body: "Related to #1.\n\nCloses #12",
    });

    expect(res.isError).toBeFalsy();
  });
});

describe("pr_merge", () => {
  it("merges with the default squash method", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "PUT" && url.endsWith("/pulls/42/merge")) {
        expect(init.body).toContain('"merge_method":"squash"');
        return makeResponse({ status: 200, body: { merged: true, sha: "abc123" } });
      }
      return makeResponse({ status: 500 });
    });

    // The stub harness invokes the handler directly, bypassing zod schema parsing, so the
    // schema's `.default("squash")` isn't applied here — pass it explicitly to simulate what
    // a real MCP client omitting `method` would resolve to.
    const handler = await getPrHandler("pr_merge");
    const res = await handler({ repo: "octo/repo", number: 42, method: "squash" });

    expect(res.isError).toBeFalsy();
    const body = JSON.parse(res.content[0].text) as { merged: boolean; sha: string };
    expect(body.merged).toBe(true);
    expect(body.sha).toBe("abc123");
  });

  it("deletes the head branch after a successful merge when delete_branch is true", async () => {
    let deletedPath: string | undefined;
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "PUT" && url.endsWith("/pulls/42/merge")) {
        return makeResponse({ status: 200, body: { merged: true, sha: "abc123" } });
      }
      if (init.method === "GET" && url.endsWith("/pulls/42")) {
        return makeResponse({
          status: 200,
          body: { head: { ref: "feature/x", sha: "abc123" }, base: { ref: "main" } },
        });
      }
      if (init.method === "DELETE" && url.includes("/git/refs/heads/")) {
        deletedPath = url;
        return makeResponse({ status: 204 });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getPrHandler("pr_merge");
    const res = await handler({ repo: "octo/repo", number: 42, delete_branch: true });

    expect(res.isError).toBeFalsy();
    expect(deletedPath).toContain("/git/refs/heads/feature/x");
    const body = JSON.parse(res.content[0].text) as { _warnings?: string[] };
    expect(body._warnings).toBeUndefined();
  });

  it("warns (without failing the call) when the merge succeeds but branch deletion fails", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "PUT" && url.endsWith("/pulls/42/merge")) {
        return makeResponse({ status: 200, body: { merged: true, sha: "abc123" } });
      }
      if (init.method === "GET" && url.endsWith("/pulls/42")) {
        return makeResponse({
          status: 200,
          body: { head: { ref: "feature/x", sha: "abc123" }, base: { ref: "main" } },
        });
      }
      if (init.method === "DELETE" && url.endsWith("/git/refs/heads/feature/x")) {
        return makeResponse({ status: 500, body: { message: "server error" } });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getPrHandler("pr_merge");
    const res = await handler({ repo: "octo/repo", number: 42, delete_branch: true });

    expect(res.isError).toBeFalsy();
    const body = JSON.parse(res.content[0].text) as {
      merged: boolean;
      sha: string;
      _warnings?: string[];
    };
    expect(body.merged).toBe(true);
    expect(body.sha).toBe("abc123");
    expect(body._warnings).toHaveLength(1);
    expect(body._warnings?.[0]).toContain("feature/x");
  });

  it("refuses to delete the branch when the head ref is main, and warns", async () => {
    let deleteCalled = false;
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "PUT" && url.endsWith("/pulls/42/merge")) {
        return makeResponse({ status: 200, body: { merged: true, sha: "abc123" } });
      }
      if (init.method === "GET" && url.endsWith("/pulls/42")) {
        return makeResponse({
          status: 200,
          body: { head: { ref: "main", sha: "abc123" }, base: { ref: "main" } },
        });
      }
      if (init.method === "DELETE" && url.includes("/git/refs/heads/")) {
        deleteCalled = true;
        return makeResponse({ status: 204 });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getPrHandler("pr_merge");
    const res = await handler({ repo: "octo/repo", number: 42, delete_branch: true });

    expect(res.isError).toBeFalsy();
    expect(deleteCalled).toBe(false);
    const body = JSON.parse(res.content[0].text) as { _warnings?: string[] };
    expect(body._warnings).toHaveLength(1);
    expect(body._warnings?.[0]).toContain("main");
  });
});
