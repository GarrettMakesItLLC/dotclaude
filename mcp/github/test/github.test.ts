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

  /**
   * A missing OAuth scope comes back 403, not 401. Only 401 cleared the cache,
   * so granting the scope with `gh auth refresh` changed nothing until the
   * process restarted — and the error kept reciting the OLD scope list while
   * `gh auth status` showed the new one (#302).
   */
  it("retries once on 403 too, because a scope grant needs a fresh token", async () => {
    fetchMock
      .mockResolvedValueOnce(
        makeResponse({ status: 403, body: { message: "Resource not accessible by integration" } }),
      )
      .mockResolvedValueOnce(makeResponse({ status: 200, body: { ok: true } }));

    const result = await mod.ghRequest<{ ok: boolean }>("/some/path");

    expect(result).toEqual({ ok: true });
    const tokenCalls = execFileMock.mock.calls.filter(
      (c) => c[1][0] === "auth" && c[1][1] === "token",
    );
    expect(tokenCalls).toHaveLength(2);
  });

  it("surfaces a persistent 403 — a second one is a real permission answer", async () => {
    // The retry must not mask a genuine denial as an infinite refetch loop.
    fetchMock.mockResolvedValue(makeResponse({ status: 403, body: { message: "Forbidden" } }));

    await expect(mod.ghRequest("/some/path")).rejects.toThrow(/HTTP 403/);
    expect(fetchMock).toHaveBeenCalledTimes(2);
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

describe("cachedGet / invalidate", () => {
  it("fetches once, then returns the cached value on subsequent calls with the same key", async () => {
    const fetcher = vi.fn().mockResolvedValue({ n: 1 });
    const first = await mod.cachedGet("issue:octo/repo#1", fetcher);
    const second = await mod.cachedGet("issue:octo/repo#1", fetcher);
    expect(first).toEqual({ n: 1 });
    expect(second).toEqual({ n: 1 });
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("fetches independently for different keys", async () => {
    const fetcher = vi.fn().mockResolvedValueOnce({ n: 1 }).mockResolvedValueOnce({ n: 2 });
    const a = await mod.cachedGet("issue:octo/repo#1", fetcher);
    const b = await mod.cachedGet("issue:octo/repo#2", fetcher);
    expect(a).toEqual({ n: 1 });
    expect(b).toEqual({ n: 2 });
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it("invalidate clears the entry so the next cachedGet call refetches", async () => {
    const fetcher = vi.fn().mockResolvedValueOnce({ n: 1 }).mockResolvedValueOnce({ n: 2 });
    await mod.cachedGet("issue:octo/repo#1", fetcher);
    mod.invalidate("issue:octo/repo#1");
    const after = await mod.cachedGet("issue:octo/repo#1", fetcher);
    expect(after).toEqual({ n: 2 });
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it("invalidating a key that was never cached is a no-op", () => {
    expect(() => mod.invalidate("issue:octo/repo#999")).not.toThrow();
  });
});

describe("cacheKey", () => {
  it("builds a stable kind:repo#id string", () => {
    expect(mod.cacheKey("issue", "octo/repo", 42)).toBe("issue:octo/repo#42");
    expect(mod.cacheKey("pr", "octo/repo", "7")).toBe("pr:octo/repo#7");
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

  /**
   * Spawned `gh` has to use the SAME credential `ghRequest` chose, or the
   * Projects v2 calls that go through here fail on a scope the REST calls have.
   * It used to be handed the env with both token vars stripped, which made it
   * agree only by coincidence.
   */
  it("hands the spawned gh process the token this server selected", async () => {
    process.env.GH_TOKEN = "gho_ambient_narrow";
    try {
      vi.resetModules();
      let capturedEnv: NodeJS.ProcessEnv | undefined;
      execFileMock.mockImplementation((_c: string, args: string[], ...rest: unknown[]) => {
        const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
        if (args[0] === "auth" && args[1] === "token") {
          cb(null, { stdout: "gho_keyring_wide\n", stderr: "" });
          return;
        }
        if (rest.length > 1) capturedEnv = (rest[0] as { env?: NodeJS.ProcessEnv }).env;
        cb(null, { stdout: "ok\n", stderr: "" });
      });
      // Keyring covers repo+read:org+workflow+project; the ambient one does not.
      fetchMock.mockImplementation(async (_url: string, init: { headers: Record<string, string> }) =>
        makeResponse({
          status: 200,
          body: {},
          headers: {
            "x-oauth-scopes": init.headers.Authorization.includes("keyring")
              ? "repo, read:org, workflow, project"
              : "repo, read:org",
          },
        }),
      );
      const { execGh } = await import("../src/github.js");
      await execGh(["project", "item-list"]);
      expect(capturedEnv?.GH_TOKEN).toBe("gho_keyring_wide");
      expect(capturedEnv?.GITHUB_TOKEN).toBeUndefined();
    } finally {
      delete process.env.GH_TOKEN;
    }
  });
});

/**
 * Which credential wins used to be a policy — strip the env var, trust the
 * keyring — and the policy was right on some machines and exactly backwards on
 * others. On one box the keyring login carried `gist, read:org, repo, workflow`
 * while the stripped PAT also carried `project`, so the fallback was what lost
 * the scope and Effort/Priority silently stopped being settable (#263, #225).
 * Both are measured now; neither is the default.
 */
describe("token selection", () => {
  const scopesByToken = (map: Record<string, string | null>) =>
    async (_url: string, init: { headers: Record<string, string> }) => {
      const token = init.headers.Authorization.replace("Bearer ", "");
      const scopes = map[token];
      return makeResponse({
        status: 200,
        body: {},
        headers: scopes === null || scopes === undefined ? {} : { "x-oauth-scopes": scopes },
      });
    };

  const withKeyring = (keyring: string) =>
    setGhResponses((args) => {
      if (args[0] === "auth" && args[1] === "token") return `${keyring}\n`;
      if (args[0] === "repo" && args[1] === "view") return "octo/defaultrepo\n";
      throw new Error(`unexpected gh args: ${args.join(" ")}`);
    });

  const authHeaderOf = (call: unknown[]) =>
    (call[1] as { headers: Record<string, string> }).headers.Authorization;

  it("uses the ambient token when it covers more of the required scopes", async () => {
    process.env.GH_TOKEN = "tok_ambient";
    try {
      vi.resetModules();
      withKeyring("tok_keyring");
      fetchMock.mockImplementation(
        scopesByToken({ tok_keyring: "repo, read:org", tok_ambient: "repo, read:org, project" }),
      );
      const m = await import("../src/github.js");
      await m.ghRequest("/some/path");
      const last = fetchMock.mock.calls[fetchMock.mock.calls.length - 1];
      expect(authHeaderOf(last)).toBe("Bearer tok_ambient");
    } finally {
      delete process.env.GH_TOKEN;
    }
  });

  it("keeps the keyring token when it is the wider one", async () => {
    process.env.GH_TOKEN = "tok_ambient";
    try {
      vi.resetModules();
      withKeyring("tok_keyring");
      fetchMock.mockImplementation(
        scopesByToken({ tok_keyring: "repo, read:org, workflow, project", tok_ambient: "repo" }),
      );
      const m = await import("../src/github.js");
      await m.ghRequest("/some/path");
      const last = fetchMock.mock.calls[fetchMock.mock.calls.length - 1];
      expect(authHeaderOf(last)).toBe("Bearer tok_keyring");
    } finally {
      delete process.env.GH_TOKEN;
    }
  });

  it("accepts read:project as covering project", async () => {
    process.env.GH_TOKEN = "tok_ambient";
    try {
      vi.resetModules();
      withKeyring("tok_keyring");
      fetchMock.mockImplementation(
        scopesByToken({ tok_keyring: "repo", tok_ambient: "repo, read:project" }),
      );
      const m = await import("../src/github.js");
      await m.ghRequest("/some/path");
      const last = fetchMock.mock.calls[fetchMock.mock.calls.length - 1];
      expect(authHeaderOf(last)).toBe("Bearer tok_ambient");
    } finally {
      delete process.env.GH_TOKEN;
    }
  });

  it("falls back to the keyring when a token's scopes cannot be read", async () => {
    // A fine-grained PAT reports no x-oauth-scopes at all. Unknown is not the
    // same as empty, and must not be scored as zero.
    process.env.GH_TOKEN = "tok_ambient";
    try {
      vi.resetModules();
      withKeyring("tok_keyring");
      fetchMock.mockImplementation(
        scopesByToken({ tok_keyring: "repo", tok_ambient: null }),
      );
      const m = await import("../src/github.js");
      await m.ghRequest("/some/path");
      const last = fetchMock.mock.calls[fetchMock.mock.calls.length - 1];
      expect(authHeaderOf(last)).toBe("Bearer tok_keyring");
    } finally {
      delete process.env.GH_TOKEN;
    }
  });

  it("probes nothing when only one credential exists", async () => {
    vi.resetModules();
    withKeyring("tok_keyring");
    fetchMock.mockResolvedValue(makeResponse({ status: 200, body: { ok: true } }));
    const m = await import("../src/github.js");
    await m.ghRequest("/some/path");
    // One request: the caller's. No scope probe, because there is no choice.
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(authHeaderOf(fetchMock.mock.calls[0])).toBe("Bearer tok_keyring");
  });

  it("uses the ambient token when there is no keyring login at all", async () => {
    process.env.GH_TOKEN = "tok_ambient";
    try {
      vi.resetModules();
      setGhResponses((args) => {
        if (args[0] === "auth" && args[1] === "token") throw new Error("not logged in");
        return "octo/defaultrepo\n";
      });
      fetchMock.mockResolvedValue(makeResponse({ status: 200, body: { ok: true } }));
      const m = await import("../src/github.js");
      await m.ghRequest("/some/path");
      expect(authHeaderOf(fetchMock.mock.calls[0])).toBe("Bearer tok_ambient");
    } finally {
      delete process.env.GH_TOKEN;
    }
  });
});

describe("ghGraphQL", () => {
  it("POSTs the query/variables to /graphql and returns data", async () => {
    fetchMock.mockResolvedValueOnce(
      makeResponse({ status: 200, body: { data: { viewer: { login: "octo" } } } }),
    );
    const { ghGraphQL } = await import("../src/github.js");
    const data = await ghGraphQL<{ viewer: { login: string } }>("query { viewer { login } }", {
      foo: "bar",
    });
    expect(data).toEqual({ viewer: { login: "octo" } });
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit & { body: string }];
    expect(url).toBe("https://api.github.com/graphql");
    expect(JSON.parse(init.body)).toEqual({
      query: "query { viewer { login } }",
      variables: { foo: "bar" },
    });
  });

  it("throws on GraphQL-level errors even though the HTTP status is 200", async () => {
    fetchMock.mockResolvedValueOnce(
      makeResponse({ status: 200, body: { errors: [{ message: "Field not found" }] } }),
    );
    const { ghGraphQL } = await import("../src/github.js");
    await expect(ghGraphQL("query { bogus }")).rejects.toThrow(
      "GitHub GraphQL error: Field not found",
    );
  });

  it("retries once on 401 like ghRequest", async () => {
    fetchMock
      .mockResolvedValueOnce(makeResponse({ status: 401, body: { message: "Bad creds" } }))
      .mockResolvedValueOnce(makeResponse({ status: 200, body: { data: { ok: true } } }));
    const { ghGraphQL } = await import("../src/github.js");
    const data = await ghGraphQL("query { ok }");
    expect(data).toEqual({ ok: true });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

describe("jsonText", () => {
  it("returns a compact single-line JSON text block for a normal-sized payload", async () => {
    const { jsonText } = await import("../src/github.js");
    const res = jsonText({ number: 1, title: "x" });
    expect(res.content).toEqual([{ type: "text", text: '{"number":1,"title":"x"}' }]);
  });

  it("throws instead of returning a result over 100,000 characters (#181)", async () => {
    const { jsonText } = await import("../src/github.js");
    const huge = Array.from({ length: 5000 }, (_, i) => ({
      number: i,
      title: "x".repeat(30),
    }));
    expect(() => jsonText(huge)).toThrow(/Result too large to return/);
    expect(() => jsonText(huge)).toThrow(/`fields`/);
  });
});
