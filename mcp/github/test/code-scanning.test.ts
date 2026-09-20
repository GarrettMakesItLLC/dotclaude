import { beforeEach, describe, expect, it, vi } from "vitest";

const execFileMock = vi.fn();
vi.mock("node:child_process", () => ({ execFile: execFileMock }));

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

async function getHandler(name: string): Promise<ToolHandler> {
  const { registerCodeScanningTools } = await import("../src/tools/code-scanning.js");
  const handlers = new Map<string, ToolHandler>();
  const stub = { registerTool: (n: string, _d: unknown, h: ToolHandler) => handlers.set(n, h) };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  registerCodeScanningTools(stub as any);
  const h = handlers.get(name);
  if (!h) throw new Error(`${name} not registered`);
  return h;
}

let fetchMock: ReturnType<typeof vi.fn>;
beforeEach(() => {
  vi.resetModules();
  execFileMock.mockReset();
  execFileMock.mockImplementation((_c: string, args: string[], ...rest: unknown[]) => {
    const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
    if (args[0] === "auth" && args[1] === "token") return cb(null, { stdout: "tok\n", stderr: "" });
    cb(new Error(`unexpected gh args: ${args.join(" ")}`));
  });
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});

const alert = (number: number, rule: string, path: string, line = 10) => ({
  number,
  state: "open",
  html_url: `https://gh/alert/${number}`,
  rule: { id: rule, severity: "warning" },
  most_recent_instance: { location: { path, start_line: line } },
});

describe("code_scanning_alerts", () => {
  it("shapes alerts to what triage needs and counts them per rule", async () => {
    // `by_rule` exists so a family of look-alikes is VISIBLE before anyone is
    // tempted to dismiss it wholesale — the failure MuscleBuddy#7676 is
    // written against.
    fetchMock.mockImplementation(async (url: string) => {
      if (url.includes("/code-scanning/alerts")) {
        return makeResponse({
          status: 200,
          body: [
            alert(1, "js/xss", "apps/web/src/a.ts"),
            alert(2, "js/xss", "apps/web/src/b.ts"),
            alert(3, "js/sql-injection", "apps/server/src/c.ts"),
          ],
        });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getHandler("code_scanning_alerts");
    const res = await handler({ repo: "octo/repo", state: "open", limit: 100 });
    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as {
      count: number;
      by_rule: Record<string, number>;
      alerts: { rule: string; path: string; line: number }[];
    };
    expect(out.count).toBe(3);
    expect(out.by_rule["js/xss"]).toBe(2);
    expect(out.alerts[0]).toMatchObject({ rule: "js/xss", path: "apps/web/src/a.ts", line: 10 });
  });

  it("filters by path prefix, which the API itself cannot do", async () => {
    fetchMock.mockImplementation(async (url: string) => {
      if (url.includes("/code-scanning/alerts")) {
        return makeResponse({
          status: 200,
          body: [
            alert(1, "js/xss", "apps/web/src/a.ts"),
            alert(3, "js/sql-injection", "apps/server/src/c.ts"),
          ],
        });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getHandler("code_scanning_alerts");
    const res = await handler({ repo: "octo/repo", state: "open", limit: 100, path_prefix: "apps/server" });
    const out = JSON.parse(res.content[0].text) as { count: number; alerts: { number: number }[] };
    expect(out.count).toBe(1);
    expect(out.alerts[0]!.number).toBe(3);
  });
});

describe("code_scanning_dismiss", () => {
  it("refuses a comment over 280 characters BEFORE calling the API", async () => {
    // GitHub 422s the whole call and names neither the field nor the limit.
    // Six of eight dismissals in MuscleBuddy#7676 failed this way.
    let called = false;
    fetchMock.mockImplementation(async () => {
      called = true;
      return makeResponse({ status: 200, body: {} });
    });
    const handler = await getHandler("code_scanning_dismiss");
    const res = await handler({
      repo: "octo/repo",
      number: 7,
      reason: "won't fix",
      comment: "x".repeat(281),
    });
    expect(res.isError).toBeTruthy();
    expect(res.content[0].text).toContain("281");
    expect(res.content[0].text).toContain("280");
    expect(called, "must not reach the API at all").toBe(false);
  });

  it("accepts a comment at exactly the limit, so the check is not off by one", async () => {
    // The other direction — a boundary guard that refuses the legal case is
    // its own defect.
    fetchMock.mockImplementation(async (url: string, init: { method?: string }) => {
      if (init.method === "PATCH" && url.includes("/code-scanning/alerts/7")) {
        return makeResponse({
          status: 200,
          body: { ...alert(7, "js/xss", "a.ts"), state: "dismissed", dismissed_reason: "won't fix" },
        });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getHandler("code_scanning_dismiss");
    const res = await handler({
      repo: "octo/repo",
      number: 7,
      reason: "won't fix",
      comment: "x".repeat(280),
    });
    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as { dismissed: boolean; state: string };
    expect(out.dismissed).toBe(true);
    expect(out.state).toBe("dismissed");
  });

  it("sends the reason and comment GitHub expects", async () => {
    let body: Record<string, unknown> | undefined;
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "PATCH" && url.includes("/code-scanning/alerts/9")) {
        body = JSON.parse(init.body ?? "{}") as Record<string, unknown>;
        return makeResponse({ status: 200, body: alert(9, "js/xss", "a.ts") });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getHandler("code_scanning_dismiss");
    await handler({ repo: "octo/repo", number: 9, reason: "used in tests", comment: "see #1234" });
    expect(body).toMatchObject({
      state: "dismissed",
      dismissed_reason: "used in tests",
      dismissed_comment: "see #1234",
    });
  });
});
