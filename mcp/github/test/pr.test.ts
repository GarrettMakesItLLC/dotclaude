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
    const pr = JSON.parse(res.content[0].text) as { number: number };
    expect(pr.number).toBe(100);
    expect(putBody).toBeDefined();
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
        return makeResponse({ status: 200, body: [] });
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
        return makeResponse({ status: 200, body: [] });
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
