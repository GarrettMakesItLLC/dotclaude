import { beforeEach, describe, expect, it, vi } from "vitest";

const execFileMock = vi.fn();
vi.mock("node:child_process", () => ({ execFile: execFileMock }));

function makeResponse(opts: { status: number; body?: unknown; headers?: Record<string, string> }): Response {
  const { status, body, headers = {} } = opts;
  const text = body === undefined ? "" : JSON.stringify(body);
  return {
    status, ok: status >= 200 && status < 300,
    headers: new Headers(headers),
    text: async () => text, json: async () => JSON.parse(text),
  } as unknown as Response;
}

type ToolHandler = (args: Record<string, unknown>) => Promise<{
  content: { type: string; text: string }[]; isError?: boolean;
}>;

async function getHandler(name: string): Promise<ToolHandler> {
  const { registerLabelTools } = await import("../src/tools/labels.js");
  const handlers = new Map<string, ToolHandler>();
  const stub = { registerTool: (n: string, _d: unknown, h: ToolHandler) => handlers.set(n, h) };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  registerLabelTools(stub as any);
  const h = handlers.get(name);
  if (!h) throw new Error(`${name} not registered`);
  return h;
}

let fetchMock: ReturnType<typeof vi.fn>;
beforeEach(() => {
  vi.resetModules();
  execFileMock.mockReset();
  execFileMock.mockImplementation((_c: string, args: string[], cb: (e: unknown, o?: unknown) => void) => {
    if (args[0] === "auth" && args[1] === "token") return cb(null, { stdout: "tok\n", stderr: "" });
    cb(new Error(`unexpected gh args: ${args.join(" ")}`));
  });
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});

describe("labels_ensure", () => {
  it("creates missing labels and updates ones that already exist", async () => {
    // First label: create succeeds (201). Second: create 422 (exists) -> PATCH 200.
    // All remaining: create 201. Assert create-or-update chosen per response.
    fetchMock.mockImplementation(async (url: string, init: { method?: string }) => {
      if (init.method === "POST" && url.endsWith("/labels")) {
        // exists for status:ready only
        if (url.includes("labels") && (init as { body?: string }).body?.includes('"status:ready"')) {
          return makeResponse({ status: 422, body: { message: "already_exists" } });
        }
        return makeResponse({ status: 201, body: {} });
      }
      if (init.method === "PATCH") return makeResponse({ status: 200, body: {} });
      return makeResponse({ status: 500 });
    });

    const handler = await getHandler("labels_ensure");
    const res = await handler({ repo: "octo/repo" });

    expect(res.isError).toBeFalsy();
    const summary = JSON.parse(res.content[0].text) as { created: number; updated: number };
    expect(summary.created + summary.updated).toBe(12);
    expect(summary.updated).toBeGreaterThanOrEqual(1);
  });
});

describe("taxonomy", () => {
  it("provisions exactly one label per status, type and source value", async () => {
    const { ISSUE_LABELS, ISSUE_STATUSES, ISSUE_TYPES, ISSUE_SOURCES } = await import(
      "../src/labels.js"
    );
    expect(ISSUE_LABELS.map((l) => l.name)).toEqual([
      ...ISSUE_STATUSES.map((s) => `status:${s}`),
      ...ISSUE_TYPES.map((t) => `type:${t}`),
      ...ISSUE_SOURCES.map((s) => `source:${s}`),
    ]);
  });

  it("includes waiting in the status set, and STATUS_LABEL_NAMES covers all of it", async () => {
    const { ISSUE_STATUSES, STATUS_LABEL_NAMES } = await import("../src/labels.js");
    expect(ISSUE_STATUSES).toContain("waiting");
    expect(STATUS_LABEL_NAMES).toEqual(ISSUE_STATUSES.map((s) => `status:${s}`));
  });
});
