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
  execFileMock.mockImplementation((_c: string, args: string[], ...rest: unknown[]) => {
    const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
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
    const { ISSUE_LABELS } = await import("../src/labels.js");
    const summary = JSON.parse(res.content[0].text) as { created: number; updated: number };
    expect(summary.created + summary.updated).toBe(ISSUE_LABELS.length);
    expect(summary.updated).toBeGreaterThanOrEqual(1);
  });

  it("retitles a deprecated label that exists, and never creates one that does not", async () => {
    const patched: string[] = [];
    const posted: string[] = [];
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/labels")) {
        const name = JSON.parse(init.body ?? "{}").name as string;
        posted.push(name);
        return makeResponse({ status: 201, body: {} });
      }
      if (init.method === "PATCH") {
        patched.push(decodeURIComponent(url.split("/labels/")[1]));
        // `enhancement` is absent from this repo; the others exist.
        if (url.endsWith("/enhancement")) return makeResponse({ status: 404, body: {} });
        return makeResponse({ status: 200, body: {} });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getHandler("labels_ensure");
    const res = await handler({ repo: "octo/repo" });

    expect(res.isError).toBeFalsy();
    const summary = JSON.parse(res.content[0].text) as { deprecated: number };
    // Attempted for all three, applied to the two that exist.
    expect(patched).toContain("bug");
    expect(patched).toContain("documentation");
    // The fixture 404s only on `/enhancement`; every other DEPRECATED_LABELS entry
    // (8 of the 9 — bug, documentation, the three type:* and three complexity:*
    // retirees) PATCHes as if it already exists on this repo.
    expect(summary.deprecated).toBe(8);
    // A deprecated label is never brought into existence.
    expect(posted).not.toContain("bug");
    expect(posted).not.toContain("enhancement");
  });
});

describe("label_list", () => {
  it("returns each label with the count of issues carrying it", async () => {
    fetchMock.mockImplementation(async (url: string) => {
      if (url.includes("/labels")) {
        return makeResponse({
          status: 200,
          body: [
            { name: "type:bug", color: "d73a4a", description: "Something is broken" },
            { name: "stray", color: "ededed", description: null },
          ],
        });
      }
      if (url.includes("/search/issues")) {
        return makeResponse({ status: 200, body: { total_count: url.includes("stray") ? 0 : 7 } });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getHandler("label_list");
    const res = await handler({ repo: "octo/repo" });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as { labels: { name: string; issues: number }[] };
    expect(out.labels).toEqual([
      { name: "type:bug", color: "d73a4a", description: "Something is broken", issues: 7 },
      { name: "stray", color: "ededed", description: "", issues: 0 },
    ]);
  });
});

describe("label_update", () => {
  it("renames a label and leaves unspecified fields alone", async () => {
    let sent: Record<string, unknown> = {};
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "PATCH" && url.includes("/labels/old%20name")) {
        sent = JSON.parse(init.body ?? "{}");
        return makeResponse({ status: 200, body: { name: "new-name", color: "ededed" } });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getHandler("label_update");
    const res = await handler({ repo: "octo/repo", name: "old name", new_name: "new-name" });

    expect(res.isError).toBeFalsy();
    expect(sent).toEqual({ new_name: "new-name" });
  });

  it("errors rather than sending an empty patch when no change is given", async () => {
    const handler = await getHandler("label_update");
    const res = await handler({ repo: "octo/repo", name: "type:bug" });

    expect(res.isError).toBe(true);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("label_delete", () => {
  it("deletes the label and reports how many issues carried it", async () => {
    const deleted: string[] = [];
    fetchMock.mockImplementation(async (url: string, init: { method?: string }) => {
      if (url.includes("/search/issues")) return makeResponse({ status: 200, body: { total_count: 3 } });
      if (init.method === "DELETE") {
        deleted.push(decodeURIComponent(url.split("/labels/")[1]));
        return makeResponse({ status: 204 });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getHandler("label_delete");
    const res = await handler({ repo: "octo/repo", name: "good first issue" });

    expect(res.isError).toBeFalsy();
    expect(deleted).toEqual(["good first issue"]);
    const out = JSON.parse(res.content[0].text) as { deleted: string; issues_affected: number };
    expect(out).toMatchObject({ deleted: "good first issue", issues_affected: 3 });
  });

  it("refuses to delete a canonical taxonomy label without force", async () => {
    const handler = await getHandler("label_delete");
    const res = await handler({ repo: "octo/repo", name: "status:blocked" });

    expect(res.isError).toBe(true);
    expect(res.content[0].text).toContain("status:blocked");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("labels_audit", () => {
  it("reports what is missing, retired, removable and unrecognized", async () => {
    fetchMock.mockImplementation(async (url: string) => {
      if (url.includes("/labels")) {
        return makeResponse({
          status: 200,
          body: [
            { name: "status:ready", color: "0e8a16", description: "Fully scoped, ready to start" },
            { name: "bug", color: "d73a4a", description: "Something isn't working" },
            { name: "good first issue", color: "7057ff", description: "Good for newcomers" },
            { name: "area:web", color: "ededed", description: null },
          ],
        });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getHandler("labels_audit");
    const res = await handler({ repo: "octo/repo" });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as {
      missing: string[];
      deprecated_present: string[];
      removable_defaults: string[];
      unrecognized: string[];
      clean: boolean;
    };
    expect(out.missing).toContain("status:blocked");
    expect(out.missing).toContain("epic");
    expect(out.missing).not.toContain("status:ready");
    // Present but not yet retitled — its description still reads as live.
    expect(out.deprecated_present).toEqual(["bug"]);
    expect(out.removable_defaults).toEqual(["good first issue"]);
    // Per-repo axes are legitimate and must not be reported as drift to fix.
    expect(out.unrecognized).toEqual(["area:web"]);
    expect(out.clean).toBe(false);
  });

  it("reports a per-repo label wearing a canonical label's color, and keeps it out of clean", async () => {
    const { ISSUE_LABELS } = await import("../src/labels.js");
    const ready = ISSUE_LABELS.find((l) => l.name === "status:ready");
    if (!ready) throw new Error("status:ready missing from the taxonomy");

    fetchMock.mockImplementation(async (url: string) => {
      if (!url.includes("/labels")) return makeResponse({ status: 500 });
      return makeResponse({
        status: 200,
        body: [
          ...ISSUE_LABELS.map((l) => ({ name: l.name, color: l.color, description: l.description })),
          ...DEPRECATED_LABELS_FIXTURE,
          // Two local labels squatting one canonical color, and one that is fine.
          { name: "quick-win", color: ready.color, description: "local" },
          { name: "seo", color: ready.color.toUpperCase(), description: "local, cased differently" },
          { name: "area:web", color: "abcdef", description: "local, no clash" },
        ],
      });
    });

    const handler = await getHandler("labels_audit");
    const res = await handler({ repo: "octo/repo" });

    const out = JSON.parse(res.content[0].text) as {
      missing: string[];
      color_collisions: { label: string; color: string; also_used_by: string[] }[];
      clean: boolean;
    };
    expect(out.missing).toEqual([]);
    expect(out.color_collisions).toEqual([
      { label: "status:ready", color: ready.color, also_used_by: ["quick-win", "seo"] },
    ]);
    // A local color choice is the repo's call, so it does not make the audit dirty.
    expect(out.clean).toBe(true);
  });
});

/** The deprecated labels already retitled, so they don't skew a collision fixture. */
const DEPRECATED_LABELS_FIXTURE = [
  { name: "bug", color: "ededed", description: "DEPRECATED historical label — use type:bug on new work" },
  { name: "enhancement", color: "ededed", description: "DEPRECATED historical label — use type:feature on new work" },
  { name: "documentation", color: "ededed", description: "DEPRECATED historical label — use type:task on new work" },
  { name: "type:bug", color: "d73a4a", description: "DEPRECATED — use the native GitHub issue type instead of type:bug" },
  { name: "type:feature", color: "a2eeef", description: "DEPRECATED — use the native GitHub issue type instead of type:feature" },
  { name: "type:task", color: "bfd4f2", description: "DEPRECATED — use the native GitHub issue type instead of type:task" },
  { name: "complexity:trivial", color: "8d6e63", description: "DEPRECATED — use the Effort project field instead of complexity:trivial" },
  { name: "complexity:standard", color: "4db6ac", description: "DEPRECATED — use the Effort project field instead of complexity:standard" },
  { name: "complexity:complex", color: "e07a5f", description: "DEPRECATED — use the Effort project field instead of complexity:complex" },
];

describe("taxonomy", () => {
  it("provisions exactly one label per status, source and marker value — no type or complexity axis", async () => {
    const { ISSUE_LABELS, ISSUE_STATUSES, ISSUE_SOURCES, ISSUE_MARKERS } = await import("../src/labels.js");
    expect(ISSUE_LABELS.map((l) => l.name)).toEqual([
      ...ISSUE_STATUSES.map((s) => `status:${s}`),
      ...ISSUE_SOURCES.map((s) => `source:${s}`),
      ...ISSUE_MARKERS,
    ]);
  });

  it("retires type:* and complexity:* into DEPRECATED_LABELS", async () => {
    const { DEPRECATED_LABELS, ISSUE_TYPES, ISSUE_EFFORTS, typeLabel } = await import("../src/labels.js");
    const names = DEPRECATED_LABELS.map((l) => l.name);
    for (const t of ISSUE_TYPES) expect(names).toContain(typeLabel(t));
    for (const e of ISSUE_EFFORTS) expect(names).toContain(`complexity:${e}`);
  });

  it("includes an Effort axis with exactly three tiers and a Priority axis with four", async () => {
    const { ISSUE_EFFORTS, ISSUE_PRIORITIES } = await import("../src/labels.js");
    expect([...ISSUE_EFFORTS].sort()).toEqual(["complex", "standard", "trivial"]);
    expect([...ISSUE_PRIORITIES].sort()).toEqual(["high", "low", "medium", "urgent"]);
  });

  it("keeps the deprecated and removable sets disjoint from the canonical one", async () => {
    const { ISSUE_LABELS, DEPRECATED_LABELS, REMOVABLE_DEFAULT_LABELS } = await import(
      "../src/labels.js"
    );
    const canonical = new Set(ISSUE_LABELS.map((l) => l.name));
    for (const l of DEPRECATED_LABELS) expect(canonical.has(l.name)).toBe(false);
    for (const n of REMOVABLE_DEFAULT_LABELS) expect(canonical.has(n)).toBe(false);
  });

  it("treats owner, agent and code-review as trusted, and nothing else", async () => {
    const { TRUSTED_SOURCES, ISSUE_SOURCES } = await import("../src/labels.js");
    expect([...TRUSTED_SOURCES].sort()).toEqual(["agent", "code-review", "owner"]);
    for (const s of TRUSTED_SOURCES) expect(ISSUE_SOURCES).toContain(s);
  });

  it("gives every label a distinct name and color, so two axes never look alike", async () => {
    const { ISSUE_LABELS } = await import("../src/labels.js");
    expect(new Set(ISSUE_LABELS.map((l) => l.name)).size).toBe(ISSUE_LABELS.length);
    expect(new Set(ISSUE_LABELS.map((l) => l.color)).size).toBe(ISSUE_LABELS.length);
  });

  it("includes waiting in the status set, and STATUS_LABEL_NAMES covers all of it", async () => {
    const { ISSUE_STATUSES, STATUS_LABEL_NAMES } = await import("../src/labels.js");
    expect(ISSUE_STATUSES).toContain("waiting");
    expect(STATUS_LABEL_NAMES).toEqual(ISSUE_STATUSES.map((s) => `status:${s}`));
  });

});

describe("effortModelMismatch", () => {
  it("flags an under-provisioned caller", async () => {
    const { effortModelMismatch } = await import("../src/labels.js");
    const msg = effortModelMismatch("complex", "claude-sonnet-5");
    expect(msg).not.toBeNull();
    expect(msg).toContain("Effort of complex");
    expect(msg).toContain("opus-tier or stronger");
  });

  it("says nothing about an exactly-matched or over-provisioned caller", async () => {
    const { effortModelMismatch } = await import("../src/labels.js");
    expect(effortModelMismatch("standard", "claude-sonnet-5")).toBeNull();
    expect(effortModelMismatch("trivial", "claude-opus-5")).toBeNull();
  });

  it("stays silent when the caller's model id isn't recognized, rather than guessing", async () => {
    const { effortModelMismatch } = await import("../src/labels.js");
    expect(effortModelMismatch("complex", "gpt-4")).toBeNull();
    expect(effortModelMismatch("complex", "")).toBeNull();
  });
});
