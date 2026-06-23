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
 * `issue_list` handler so it can be invoked directly.
 */
async function getIssueListHandler(): Promise<ToolHandler> {
  const { registerIssueTools } = await import("../src/tools/issues.js");
  const handlers = new Map<string, ToolHandler>();
  const stubServer = {
    registerTool: (name: string, _def: unknown, handler: ToolHandler) => {
      handlers.set(name, handler);
    },
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  registerIssueTools(stubServer as any);
  const handler = handlers.get("issue_list");
  if (!handler) throw new Error("issue_list was not registered");
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

    const handler = await getIssueListHandler();
    const res = await handler({ repo: "octo/repo", state: "open", limit: 4 });

    expect(res.isError).toBeFalsy();
    const issues = JSON.parse(res.content[0].text) as { number: number }[];
    const numbers = issues.map((i) => i.number);

    // PRs (2, 4, 6) excluded; real issues from both pages; capped at limit=4.
    expect(numbers).toEqual([1, 3, 5, 7]);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
