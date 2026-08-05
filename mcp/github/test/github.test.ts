import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// The gh subprocess is mocked so no real CLI/network is touched. `execFile` is
// the named export the production code promisifies.
const execFileMock = vi.fn();
vi.mock("node:child_process", () => ({
  execFile: execFileMock,
}));

/**
 * Make the mocked `execFile` behave like the callback-style API that
 * `promisify` wraps: the last argument is `(err, { stdout, stderr })`.
 */
function setGhResponses(responder: (args: string[]) => string): void {
  execFileMock.mockImplementation(
    (_cmd: string, args: string[], ...rest: unknown[]) => {
      const cb = rest[rest.length - 1] as (err: unknown, out?: unknown) => void;
      try {
        const stdout = responder(args);
        cb(null, { stdout, stderr: "" });
      } catch (err) {
        cb(err);
      }
    },
  );
}

/** Build a minimal `Response`-like object good enough for the code under test. */
function makeResponse(opts: {
  status: number;
  body?: unknown;
  headers?: Record<string, string>;
}): Response {
  const { status, body, headers = {} } = opts;
  const text =
    body === undefined ? "" : typeof body === "string" ? body : JSON.stringify(body);
  return {
    status,
    ok: status >= 200 && status < 300,
    headers: new Headers(headers),
    text: async () => text,
    json: async () => JSON.parse(text),
  } as unknown as Response;
}

// Re-imported fresh in each test so the module-scoped token/repo caches reset.
let mod: typeof import("../src/github.js");
let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(async () => {
  vi.resetModules();
  execFileMock.mockReset();
  // Default: `gh auth token` yields a token; `gh repo view` yields a repo.
  setGhResponses((args) => {
    if (args[0] === "auth" && args[1] === "token") return "ghs_secrettoken123\n";
    if (args[0] === "repo" && args[1] === "view") return "octo/defaultrepo\n";
    throw new Error(`unexpected gh args: ${args.join(" ")}`);
  });

  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);

  mod = await import("../src/github.js");
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("ghRequest — token + 401 retry", () => {
  it("retries once on 401, refetching the token, then parses the 200", async () => {
    fetchMock
      .mockResolvedValueOnce(makeResponse({ status: 401, body: { message: "Bad creds" } }))
      .mockResolvedValueOnce(makeResponse({ status: 200, body: { ok: true } }));

    const result = await mod.ghRequest<{ ok: boolean }>("/some/path");

    expect(result).toEqual({ ok: true });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    // Token fetched once initially, then again after the cache was cleared.
    const tokenCalls = execFileMock.mock.calls.filter(
      (c) => c[1][0] === "auth" && c[1][1] === "token",
    );
    expect(tokenCalls).toHaveLength(2);
  });

  it("does not loop forever on a persistent 401 — retries exactly once then surfaces the error", async () => {
    fetchMock.mockResolvedValue(
      makeResponse({ status: 401, body: { message: "Bad credentials" } }),
    );

    await expect(mod.ghRequest("/some/path")).rejects.toThrow(/HTTP 401/);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

describe("ghRequest — error surfacing", () => {
  it("throws an Error including the status and GitHub message, never the token", async () => {
    fetchMock.mockResolvedValueOnce(
      makeResponse({
        status: 404,
        body: { message: "Not Found", errors: [{ field: "x", code: "missing" }] },
      }),
    );

    let caught: Error | undefined;
    try {
      await mod.ghRequest("/repos/o/r/missing");
    } catch (err) {
      caught = err as Error;
    }

    expect(caught).toBeInstanceOf(Error);
    expect(caught!.message).toContain("404");
    expect(caught!.message).toContain("Not Found");
    expect(caught!.message).toContain("missing");
    expect(caught!.message).not.toContain("ghs_secrettoken123");
  });

  it("rejects with a GhHttpError carrying the numeric status", async () => {
    fetchMock.mockResolvedValueOnce(
      makeResponse({
        status: 422,
        body: { message: "Validation Failed" },
      }),
    );

    let caught: unknown;
    try {
      await mod.ghRequest("/repos/o/r/labels");
    } catch (err) {
      caught = err;
    }

    expect(caught).toBeInstanceOf(mod.GhHttpError);
    expect((caught as InstanceType<typeof mod.GhHttpError>).status).toBe(422);
  });
});

describe("resolveRepo", () => {
  it("parses a valid owner/name", async () => {
    const ref = await mod.resolveRepo("octocat/Hello-World");
    expect(ref).toEqual({ owner: "octocat", name: "Hello-World" });
  });

  it("rejects malformed values", async () => {
    await expect(mod.resolveRepo("evil?org/repo")).rejects.toThrow(/Invalid repo/);
    await expect(mod.resolveRepo("a/b/c")).rejects.toThrow(/Invalid repo/);
    await expect(mod.resolveRepo("noslash")).rejects.toThrow(/Invalid repo/);
  });

  it("resolves via `gh repo view` when no repo arg is given", async () => {
    const ref = await mod.resolveRepo();
    expect(ref).toEqual({ owner: "octo", name: "defaultrepo" });
    expect(
      execFileMock.mock.calls.some((c) => c[1][0] === "repo" && c[1][1] === "view"),
    ).toBe(true);
  });

  it("throws a clear error when gh fails and no repo arg is given", async () => {
    setGhResponses((args) => {
      if (args[0] === "auth" && args[1] === "token") return "tok\n";
      throw new Error("gh repo view failed: not a git repo");
    });
    await expect(mod.resolveRepo()).rejects.toThrow(
      /Could not resolve a default repository/,
    );
  });
});

describe("ghPaginate", () => {
  function page(items: unknown[], next?: string): Response {
    return makeResponse({
      status: 200,
      body: items,
      headers: next ? { Link: `<${next}>; rel="next"` } : {},
    });
  }

  it("follows rel=next across pages and stops when there is no next link", async () => {
    fetchMock
      .mockResolvedValueOnce(
        page([{ n: 1 }, { n: 2 }], "https://api.github.com/x?page=2"),
      )
      .mockResolvedValueOnce(page([{ n: 3 }, { n: 4 }]));

    const result = await mod.ghPaginate<{ n: number }>("/x", { limit: 100 });

    expect(result.map((r) => r.n)).toEqual([1, 2, 3, 4]);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("stops at limit without fetching further pages", async () => {
    fetchMock.mockResolvedValueOnce(
      page([{ n: 1 }, { n: 2 }, { n: 3 }], "https://api.github.com/x?page=2"),
    );

    const result = await mod.ghPaginate<{ n: number }>("/x", { limit: 2 });

    expect(result.map((r) => r.n)).toEqual([1, 2]);
    // limit reached on page 1 — page 2 must not be fetched.
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("respects maxPages", async () => {
    // Every page advertises a next link; only maxPages of them should be read.
    fetchMock.mockImplementation(async () =>
      page([{ n: 0 }], "https://api.github.com/x?page=next"),
    );

    const result = await mod.ghPaginate<{ n: number }>("/x", {
      limit: 1000,
      maxPages: 3,
    });

    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(result).toHaveLength(3);
  });

  it("applies filter so only passing items count toward limit", async () => {
    fetchMock
      .mockResolvedValueOnce(
        page(
          [{ keep: true }, { keep: false }, { keep: true }],
          "https://api.github.com/x?page=2",
        ),
      )
      .mockResolvedValueOnce(page([{ keep: false }, { keep: true }]));

    const result = await mod.ghPaginate<{ keep: boolean }>("/x", {
      limit: 3,
      filter: (item) => item.keep,
    });

    expect(result).toEqual([{ keep: true }, { keep: true }, { keep: true }]);
  });
});

describe("execGh", () => {
  it("returns trimmed stdout on success", async () => {
    execFileMock.mockImplementation((_c: string, args: string[], ...rest: unknown[]) => {
      const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
      if (args[0] === "project" && args[1] === "field-list") {
        return cb(null, { stdout: '{"fields":[]}\n', stderr: "" });
      }
      cb(new Error(`unexpected gh args: ${args.join(" ")}`));
    });
    const { execGh } = await import("../src/github.js");
    const out = await execGh(["project", "field-list", "2", "--owner", "acme", "--format", "json"]);
    expect(out).toBe('{"fields":[]}');
  });

  it("wraps a failing gh invocation with the args in the message", async () => {
    execFileMock.mockImplementation((_c: string, _a: string[], ...rest: unknown[]) => {
      const cb = rest[rest.length - 1] as (e: unknown) => void;
      cb(new Error("exit status 1"));
    });
    const { execGh } = await import("../src/github.js");
    await expect(execGh(["project", "bogus"])).rejects.toThrow(
      "gh project bogus failed: exit status 1",
    );
  });

  it("passes a 32MB maxBuffer so large project item-list output doesn't overflow the default 1MB limit", async () => {
    let capturedOptions: { maxBuffer?: number } | undefined;
    execFileMock.mockImplementation((_c: string, _a: string[], ...rest: unknown[]) => {
      const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
      if (rest.length > 1) capturedOptions = rest[0] as { maxBuffer?: number };
      cb(null, { stdout: "ok\n", stderr: "" });
    });
    const { execGh } = await import("../src/github.js");
    await execGh(["project", "item-list"]);
    expect(capturedOptions?.maxBuffer).toBe(32 * 1024 * 1024);
  });
});
