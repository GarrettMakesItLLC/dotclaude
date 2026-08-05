import { beforeEach, describe, expect, it, vi } from "vitest";

const execFileMock = vi.fn();
vi.mock("node:child_process", () => ({ execFile: execFileMock }));

function makeResponse(opts: { status: number; body?: unknown }): Response {
  const { status, body } = opts;
  const text = body === undefined ? "" : JSON.stringify(body);
  return {
    status,
    ok: status >= 200 && status < 300,
    headers: new Headers({}),
    text: async () => text,
    json: async () => JSON.parse(text),
  } as unknown as Response;
}

type ToolHandler = (args: Record<string, unknown>) => Promise<{
  content: { type: string; text: string }[];
  isError?: boolean;
}>;

async function getRepoHandler(name: string): Promise<ToolHandler> {
  const { registerRepoTools } = await import("../src/tools/repo.js");
  const handlers = new Map<string, ToolHandler>();
  const stub = { registerTool: (n: string, _d: unknown, h: ToolHandler) => handlers.set(n, h) };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  registerRepoTools(stub as any);
  const h = handlers.get(name);
  if (!h) throw new Error(`${name} not registered`);
  return h;
}

/** A contents-API file response for the given text. */
function fileBody(text: string, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    type: "file",
    path: "src/app.ts",
    sha: "abc123",
    size: text.length,
    encoding: "base64",
    content: Buffer.from(text, "utf8").toString("base64"),
    ...extra,
  };
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

describe("repo_get caching", () => {
  it("caches a repo's metadata for the process lifetime — a second call does not re-fetch", async () => {
    fetchMock.mockResolvedValueOnce(
      makeResponse({
        status: 200,
        body: { name: "repo", full_name: "octo/repo", default_branch: "main", private: false },
      }),
    );
    const handler = await getRepoHandler("repo_get");

    const first = await handler({ repo: "octo/repo" });
    const second = await handler({ repo: "octo/repo" });

    expect(first.isError).toBeFalsy();
    expect(second.isError).toBeFalsy();
    expect(JSON.parse(first.content[0].text)).toEqual(JSON.parse(second.content[0].text));
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("caches different repos independently", async () => {
    fetchMock
      .mockResolvedValueOnce(
        makeResponse({ status: 200, body: { name: "repo", full_name: "octo/repo" } }),
      )
      .mockResolvedValueOnce(
        makeResponse({ status: 200, body: { name: "other", full_name: "octo/other" } }),
      );
    const handler = await getRepoHandler("repo_get");

    await handler({ repo: "octo/repo" });
    await handler({ repo: "octo/other" });
    await handler({ repo: "octo/repo" });
    await handler({ repo: "octo/other" });

    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

describe("repo_file_read", () => {
  it("decodes the base64 content and returns the text with its metadata", async () => {
    fetchMock.mockImplementation(async (url: string) => {
      expect(url).toContain("/repos/octo/repo/contents/src/app.ts");
      return makeResponse({ status: 200, body: fileBody("line one\nline two\n") });
    });

    const handler = await getRepoHandler("repo_file_read");
    const res = await handler({ repo: "octo/repo", path: "src/app.ts" });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as {
      path: string;
      sha: string;
      lines: number;
      text: string;
      truncated: boolean;
    };
    expect(out.path).toBe("src/app.ts");
    expect(out.sha).toBe("abc123");
    expect(out.text).toBe("line one\nline two\n");
    expect(out.lines).toBe(2);
    expect(out.truncated).toBe(false);
  });

  it("passes ref through as a query param", async () => {
    fetchMock.mockImplementation(async (url: string) => {
      expect(url).toContain("ref=dev");
      return makeResponse({ status: 200, body: fileBody("x\n") });
    });
    const handler = await getRepoHandler("repo_file_read");
    const res = await handler({ repo: "octo/repo", path: "src/app.ts", ref: "dev" });
    expect(res.isError).toBeFalsy();
  });

  it("encodes path segments so a `#` in a filename doesn't become a URL fragment", async () => {
    fetchMock.mockImplementation(async (url: string) => {
      expect(url).toContain("/contents/docs/notes%20%231.md");
      return makeResponse({ status: 200, body: fileBody("x\n") });
    });
    const handler = await getRepoHandler("repo_file_read");
    const res = await handler({ repo: "octo/repo", path: "/docs/notes #1.md" });
    expect(res.isError).toBeFalsy();
  });

  it("windows the file by offset/limit and reports it as truncated", async () => {
    const text = ["a", "b", "c", "d", "e"].join("\n");
    fetchMock.mockResolvedValue(makeResponse({ status: 200, body: fileBody(text) }));

    const handler = await getRepoHandler("repo_file_read");
    const res = await handler({ repo: "octo/repo", path: "src/app.ts", offset: 2, limit: 2 });

    const out = JSON.parse(res.content[0].text) as {
      text: string;
      lines: number;
      offset: number;
      truncated: boolean;
    };
    expect(out.text).toBe("b\nc");
    expect(out.lines).toBe(5);
    expect(out.offset).toBe(2);
    expect(out.truncated).toBe(true);
  });

  it("caps an unwindowed read so a huge file cannot dump into context", async () => {
    const text = Array.from({ length: 1200 }, (_, i) => `line ${i + 1}`).join("\n");
    fetchMock.mockResolvedValue(makeResponse({ status: 200, body: fileBody(text) }));

    const handler = await getRepoHandler("repo_file_read");
    const res = await handler({ repo: "octo/repo", path: "src/app.ts" });

    const out = JSON.parse(res.content[0].text) as { text: string; truncated: boolean };
    expect(out.text.split("\n")).toHaveLength(500);
    expect(out.text.split("\n")[0]).toBe("line 1");
    expect(out.truncated).toBe(true);
  });

  it("lists entry names when the path is a directory", async () => {
    fetchMock.mockResolvedValue(
      makeResponse({
        status: 200,
        body: [
          { type: "file", name: "app.ts", path: "src/app.ts", size: 10 },
          { type: "dir", name: "lib", path: "src/lib", size: 0 },
        ],
      }),
    );

    const handler = await getRepoHandler("repo_file_read");
    const res = await handler({ repo: "octo/repo", path: "src" });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as {
      type: string;
      entries: { name: string; type: string }[];
    };
    expect(out.type).toBe("dir");
    expect(out.entries).toEqual([
      { name: "app.ts", type: "file" },
      { name: "lib", type: "dir" },
    ]);
  });

  it("errors with the size, not an empty string, when GitHub declines to inline the content", async () => {
    // Files over ~1MB come back with `encoding: "none"` and an empty `content`.
    fetchMock.mockResolvedValue(
      makeResponse({
        status: 200,
        body: { type: "file", path: "big.bin", sha: "d00d", size: 2_000_000, encoding: "none", content: "" },
      }),
    );

    const handler = await getRepoHandler("repo_file_read");
    const res = await handler({ repo: "octo/repo", path: "big.bin" });

    expect(res.isError).toBe(true);
    expect(res.content[0].text).toContain("2000000");
  });

  it("refuses binary content instead of returning mojibake", async () => {
    fetchMock.mockResolvedValue(
      makeResponse({
        status: 200,
        body: {
          type: "file",
          path: "logo.png",
          sha: "beef",
          size: 4,
          encoding: "base64",
          content: Buffer.from([0x89, 0x50, 0x00, 0x01]).toString("base64"),
        },
      }),
    );

    const handler = await getRepoHandler("repo_file_read");
    const res = await handler({ repo: "octo/repo", path: "logo.png" });

    expect(res.isError).toBe(true);
    expect(res.content[0].text).toMatch(/binary/i);
  });
});
