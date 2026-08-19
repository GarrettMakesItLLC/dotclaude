import { beforeEach, describe, expect, it, vi } from "vitest";

const execFileMock = vi.fn();
vi.mock("node:child_process", () => ({
  execFile: execFileMock,
}));

const findProjectItemMock = vi.fn();
const getProjectFieldMock = vi.fn();
const setProjectSingleSelectMock = vi.fn();
const invalidateProjectItemMock = vi.fn();
vi.mock("../src/project.js", () => ({
  findProjectItem: findProjectItemMock,
  getProjectField: getProjectFieldMock,
  setProjectSingleSelect: setProjectSingleSelectMock,
  invalidateProjectItem: invalidateProjectItemMock,
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
  const { handler } = await getIssueTool(name);
  return handler;
}

interface ToolDef {
  inputSchema: Record<string, { safeParse: (v: unknown) => { success: boolean } }>;
}

/** Register the issue tools and return both the declared schema and the handler. */
async function getIssueTool(name: string): Promise<{ def: ToolDef; handler: ToolHandler }> {
  const { registerIssueTools } = await import("../src/tools/issues.js");
  const tools = new Map<string, { def: ToolDef; handler: ToolHandler }>();
  const stubServer = {
    registerTool: (toolName: string, def: ToolDef, handler: ToolHandler) => {
      tools.set(toolName, { def, handler });
    },
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  registerIssueTools(stubServer as any);
  const tool = tools.get(name);
  if (!tool) throw new Error(`${name} was not registered`);
  return tool;
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
  findProjectItemMock.mockReset();
  getProjectFieldMock.mockReset();
  setProjectSingleSelectMock.mockReset();
  invalidateProjectItemMock.mockReset();
});

/**
 * Runs issue_view → issue_view → <write tool> → issue_view for issue `number`.
 * The mocked GET to `/issues/<number>` returns a version-tagged title that
 * increments on every real network call (including any the write tool makes
 * internally, e.g. `setIssueStatus`'s own read); the assertions only care
 * that the second view is served from cache (same title as the first) and
 * the post-write view is NOT (a different title — proof it re-fetched).
 * `extraFetch` handles every request the write tool itself makes.
 */
async function expectIssueViewRefetchesAfterWrite(
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
    if (method === "GET" && url.endsWith(`/issues/${number}`)) {
      version += 1;
      return makeResponse({
        status: 200,
        body: { number, title: `v${version}`, labels: [{ name: "type:task" }] },
      });
    }
    const custom = await extraFetch(url, init);
    if (custom) return custom;
    return makeResponse({ status: 500, body: { message: `unexpected ${method} ${url}` } });
  });

  const viewHandler = await getIssueHandler("issue_view");
  const first = await viewHandler({ repo: "octo/repo", number });
  expect(first.isError).toBeFalsy();
  const firstTitle = (JSON.parse(first.content[0].text) as { title: string }).title;

  const second = await viewHandler({ repo: "octo/repo", number });
  expect((JSON.parse(second.content[0].text) as { title: string }).title).toBe(firstTitle);

  const writeHandler = await getIssueHandler(toolName);
  const writeRes = await writeHandler(writeArgs);
  expect(writeRes.isError, `${toolName} failed: ${writeRes.content[0]?.text}`).toBeFalsy();

  const third = await viewHandler({ repo: "octo/repo", number });
  expect(third.isError).toBeFalsy();
  expect((JSON.parse(third.content[0].text) as { title: string }).title).not.toBe(firstTitle);
}

describe("issue_view caching", () => {
  it("caches a single issue for the process lifetime — a second view does not re-fetch", async () => {
    fetchMock.mockResolvedValueOnce(
      makeResponse({ status: 200, body: { number: 9, title: "Cached issue" } }),
    );
    const handler = await getIssueHandler("issue_view");

    const first = await handler({ repo: "octo/repo", number: 9 });
    const second = await handler({ repo: "octo/repo", number: 9 });

    expect(first.isError).toBeFalsy();
    expect(second.isError).toBeFalsy();
    expect(JSON.parse(first.content[0].text)).toEqual(JSON.parse(second.content[0].text));
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("caches different issue numbers independently", async () => {
    fetchMock
      .mockResolvedValueOnce(makeResponse({ status: 200, body: { number: 9, title: "Nine" } }))
      .mockResolvedValueOnce(makeResponse({ status: 200, body: { number: 10, title: "Ten" } }));
    const handler = await getIssueHandler("issue_view");

    await handler({ repo: "octo/repo", number: 9 });
    await handler({ repo: "octo/repo", number: 10 });
    await handler({ repo: "octo/repo", number: 9 });
    await handler({ repo: "octo/repo", number: 10 });

    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

describe("write tools invalidate the cached issue view", () => {
  it("issue_update", async () => {
    await expectIssueViewRefetchesAfterWrite(
      "issue_update",
      { repo: "octo/repo", number: 9, title: "New title" },
      async (url, init) => {
        if (init.method === "PATCH" && url.endsWith("/issues/9")) {
          return makeResponse({ status: 200, body: { number: 9, title: "New title" } });
        }
        return undefined;
      },
    );
  });

  it("issue_set_type", async () => {
    await expectIssueViewRefetchesAfterWrite(
      "issue_set_type",
      { repo: "octo/repo", number: 9, type: "bug" },
      async (url, init) => {
        if (init.method === "PATCH" && url.endsWith("/issues/9")) {
          return makeResponse({ status: 200, body: { number: 9, type: { name: "Bug" } } });
        }
        return undefined;
      },
    );
  });

  it("issue_set_milestone", async () => {
    await expectIssueViewRefetchesAfterWrite(
      "issue_set_milestone",
      { repo: "octo/repo", number: 9, milestone: 4 },
      async (url, init) => {
        if (init.method === "PATCH" && url.endsWith("/issues/9")) {
          return makeResponse({ status: 200, body: { number: 9 } });
        }
        return undefined;
      },
    );
  });

  it("issue_set_labels", async () => {
    await expectIssueViewRefetchesAfterWrite(
      "issue_set_labels",
      { repo: "octo/repo", number: 9, labels: ["type:bug"] },
      async (url, init) => {
        if (init.method === "PUT" && url.endsWith("/issues/9/labels")) {
          return makeResponse({ status: 200, body: [{ name: "type:bug" }] });
        }
        return undefined;
      },
    );
  });

  it("issue_add_assignees", async () => {
    await expectIssueViewRefetchesAfterWrite(
      "issue_add_assignees",
      { repo: "octo/repo", number: 9, assignees: ["octocat"] },
      async (url, init) => {
        if (init.method === "POST" && url.endsWith("/issues/9/assignees")) {
          return makeResponse({ status: 201, body: { number: 9, assignees: [{ login: "octocat" }] } });
        }
        return undefined;
      },
    );
  });

  it("issue_remove_assignees", async () => {
    await expectIssueViewRefetchesAfterWrite(
      "issue_remove_assignees",
      { repo: "octo/repo", number: 9, assignees: ["octocat"] },
      async (url, init) => {
        if (init.method === "DELETE" && url.endsWith("/issues/9/assignees")) {
          return makeResponse({ status: 200, body: { number: 9, assignees: [] } });
        }
        return undefined;
      },
    );
  });

  it("issue_comment", async () => {
    await expectIssueViewRefetchesAfterWrite(
      "issue_comment",
      { repo: "octo/repo", number: 9, body: "a comment" },
      async (url, init) => {
        if (init.method === "POST" && url.endsWith("/issues/9/comments")) {
          return makeResponse({ status: 201, body: { id: 1, html_url: "https://x", created_at: "now" } });
        }
        return undefined;
      },
    );
  });

  it("issue_add_sub_issue (invalidates the parent)", async () => {
    await expectIssueViewRefetchesAfterWrite(
      "issue_add_sub_issue",
      { repo: "octo/repo", number: 9, sub_number: 12 },
      async (url, init) => {
        if (init.method === "GET" && url.endsWith("/issues/12")) {
          return makeResponse({ status: 200, body: { number: 12, id: 999 } });
        }
        if (init.method === "POST" && url.endsWith("/issues/9/sub_issues")) {
          return makeResponse({ status: 201, body: {} });
        }
        return undefined;
      },
    );
  });

  it("issue_set_blocked_by", async () => {
    await expectIssueViewRefetchesAfterWrite(
      "issue_set_blocked_by",
      { repo: "octo/repo", number: 9, blocked_by: [3] },
      async (url, init) => {
        if (init.method === "GET" && url.endsWith("/issues/9/dependencies/blocked_by")) {
          return makeResponse({ status: 200, body: [] });
        }
        if (init.method === "GET" && url.endsWith("/issues/3")) {
          return makeResponse({ status: 200, body: { number: 3, id: 300 } });
        }
        if (init.method === "POST" && url.endsWith("/issues/9/dependencies/blocked_by")) {
          return makeResponse({ status: 200, body: {} });
        }
        return undefined;
      },
    );
  });

  it("issue_set_status", async () => {
    await expectIssueViewRefetchesAfterWrite(
      "issue_set_status",
      { repo: "octo/repo", number: 9, status: "in-review" },
      async (url, init) => {
        if (init.method === "PUT" && url.endsWith("/issues/9/labels")) {
          const sent = JSON.parse(init.body as string).labels as string[];
          return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
        }
        return undefined;
      },
    );
  });

  it("issue_set_effort", async () => {
    findProjectItemMock.mockResolvedValue({ id: "PVTI_1", fields: {} });
    getProjectFieldMock.mockResolvedValue({
      id: "F_effort",
      name: "Effort",
      options: [{ id: "O_std", name: "Standard" }],
    });
    await expectIssueViewRefetchesAfterWrite(
      "issue_set_effort",
      { repo: "octo/repo", number: 9, effort: "standard" },
      async () => undefined,
    );
  });

  it("issue_set_priority", async () => {
    findProjectItemMock.mockResolvedValue({ id: "PVTI_2", fields: {} });
    getProjectFieldMock.mockResolvedValue({
      id: "F_priority",
      name: "Priority",
      options: [{ id: "O_high", name: "High" }],
    });
    await expectIssueViewRefetchesAfterWrite(
      "issue_set_priority",
      { repo: "octo/repo", number: 9, priority: "high" },
      async () => undefined,
    );
  });

  it("issue_claim", async () => {
    let version = 0;
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      const method = init.method ?? "GET";
      if (method === "GET" && url.endsWith("/issues/8")) {
        version += 1;
        return makeResponse({
          status: 200,
          body: { number: 8, title: `Fix the thing! v${version}`, labels: [{ name: "status:ready" }, { name: "type:bug" }] },
        });
      }
      if (url.endsWith("/user")) return makeResponse({ status: 200, body: { login: "GarrettMakesIt" } });
      if (method === "GET" && /\/repos\/octo\/repo$/.test(new URL(url).pathname)) {
        return makeResponse({ status: 200, body: { default_branch: "main" } });
      }
      if (method === "GET" && url.endsWith("/git/ref/heads/main")) {
        return makeResponse({ status: 200, body: { object: { sha: "basesha" } } });
      }
      if (method === "POST" && url.endsWith("/git/refs")) {
        return makeResponse({ status: 201, body: { ref: JSON.parse(init.body as string).ref } });
      }
      if (method === "POST" && url.endsWith("/assignees")) {
        return makeResponse({ status: 201, body: {} });
      }
      if (method === "POST" && url.endsWith("/issues/8/comments")) {
        return makeResponse({ status: 201, body: { body: JSON.parse(init.body as string).body } });
      }
      if (method === "PUT" && url.endsWith("/labels")) {
        const sent = JSON.parse(init.body as string).labels as string[];
        return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
      }
      return makeResponse({ status: 500, body: { message: `unexpected ${method} ${url}` } });
    });

    const viewHandler = await getIssueHandler("issue_view");
    const first = await viewHandler({ repo: "octo/repo", number: 8 });
    const firstTitle = (JSON.parse(first.content[0].text) as { title: string }).title;
    const second = await viewHandler({ repo: "octo/repo", number: 8 });
    expect((JSON.parse(second.content[0].text) as { title: string }).title).toBe(firstTitle);

    const claimHandler = await getIssueHandler("issue_claim");
    const claimRes = await claimHandler({ repo: "octo/repo", number: 8 });
    expect(claimRes.isError).toBeFalsy();

    const third = await viewHandler({ repo: "octo/repo", number: 8 });
    expect((JSON.parse(third.content[0].text) as { title: string }).title).not.toBe(firstTitle);
  });
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
    const issue = JSON.parse(res.content[0].text) as { assignees: string[] };
    expect(issue.assignees).toEqual(["GarrettMakesIt"]);
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

  it("looks up the child in ITS OWN repo, and posts to the PARENT's repo, when they differ (#234)", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      // Child lookup must hit the CHILD's repo (other-org-repo), not the parent's (octo/repo).
      if (init.method === "GET" && url === "https://api.github.com/repos/octo/other-repo/issues/12") {
        return makeResponse({ status: 200, body: { number: 12, id: 999001 } });
      }
      // The link itself must POST to the PARENT's repo.
      if (init.method === "POST" && url === "https://api.github.com/repos/octo/repo/issues/4/sub_issues") {
        expect(init.body).toContain('"sub_issue_id":999001');
        return makeResponse({ status: 201, body: { number: 4, id: 500 } });
      }
      throw new Error(`unexpected fetch: ${init.method} ${url}`);
    });
    const handler = await getIssueHandler("issue_add_sub_issue");
    const res = await handler({
      repo: "octo/repo",
      number: 4,
      sub_number: 12,
      sub_repo: "octo/other-repo",
    });
    expect(res.isError).toBeFalsy();
  });
});

describe("issue_set_blocked_by", () => {
  it("resolves each blocker's database id and posts a dependency per issue, skipping duplicates", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "GET" && url.endsWith("/dependencies/blocked_by")) {
        return makeResponse({ status: 200, body: [{ number: 3, id: 300 }] });
      }
      if (init.method === "GET" && url.endsWith("/issues/3")) {
        return makeResponse({ status: 200, body: { number: 3, id: 300 } });
      }
      if (init.method === "GET" && url.endsWith("/issues/4")) {
        return makeResponse({ status: 200, body: { number: 4, id: 400 } });
      }
      if (init.method === "POST" && url.endsWith("/dependencies/blocked_by")) {
        expect(init.body).toBe('{"issue_id":400}');
        return makeResponse({ status: 200, body: {} });
      }
      throw new Error(`unexpected fetch: ${init.method} ${url}`);
    });
    const handler = await getIssueHandler("issue_set_blocked_by");
    const res = await handler({ repo: "octo/repo", number: 9, blocked_by: [3, 4] });
    expect(res.isError).toBeFalsy();
    expect(JSON.parse(res.content[0].text)).toEqual({ number: 9, blocked_by: [3, 4], added: [4], already_linked: [3] });
  });
});

describe("issue_list_blocked_by", () => {
  it("returns the issue numbers an issue is blocked by", async () => {
    fetchMock.mockResolvedValueOnce(
      makeResponse({ status: 200, body: [{ number: 3 }, { number: 4 }] }),
    );
    const handler = await getIssueHandler("issue_list_blocked_by");
    const res = await handler({ repo: "octo/repo", number: 9 });
    expect(res.isError).toBeFalsy();
    expect(JSON.parse(res.content[0].text)).toEqual({ number: 9, blocked_by: [3, 4] });
  });
});

describe("issue_set_status", () => {
  it("accepts every taxonomy status — including waiting — on the tools that take one", async () => {
    const { ISSUE_STATUSES } = await import("../src/labels.js");
    for (const tool of ["issue_set_status", "issue_open"]) {
      const { def } = await getIssueTool(tool);
      for (const status of ISSUE_STATUSES) {
        expect(def.inputSchema.status.safeParse(status).success, `${tool} ← ${status}`).toBe(true);
      }
      expect(def.inputSchema.status.safeParse("done").success).toBe(false);
    }
  });

  it("swaps the existing status:* label for status:waiting, preserving other labels", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "GET" && url.endsWith("/issues/3364")) {
        return makeResponse({
          status: 200,
          body: { labels: [{ name: "status:ready" }, { name: "type:task" }] },
        });
      }
      if (init.method === "PUT" && url.endsWith("/labels")) {
        const sent = JSON.parse(init.body as string).labels as string[];
        expect(sent).toEqual(["type:task", "status:waiting"]);
        return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_set_status");
    const res = await handler({ repo: "octo/repo", number: 3364, status: "waiting" });
    expect(res.isError).toBeFalsy();
    expect(JSON.parse(res.content[0].text).labels).toContain("status:waiting");
  });
});

describe("issue_set_type", () => {
  it("sets the native type and touches no labels", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "PATCH" && url.includes("/issues/9") && !url.includes("/labels")) {
        expect(init.body).toBe('{"type":"Bug"}');
        return makeResponse({ status: 200, body: { number: 9, type: { name: "Bug" } } });
      }
      throw new Error(`unexpected fetch: ${init.method} ${url}`);
    });
    const handler = await getIssueHandler("issue_set_type");
    const res = await handler({ repo: "octo/repo", number: 9, type: "bug" });
    expect(res.isError).toBeFalsy();
    expect(JSON.parse(res.content[0].text)).toEqual({ number: 9, type: "bug" });
  });
});

describe("issue_set_effort", () => {
  it("resolves the project item and field, then sets the option", async () => {
    findProjectItemMock.mockResolvedValue({ id: "PVTI_1", fields: {} });
    getProjectFieldMock.mockResolvedValue({
      id: "F_effort",
      name: "Effort",
      options: [{ id: "O_std", name: "Standard" }, { id: "O_triv", name: "Trivial" }],
    });
    const handler = await getIssueHandler("issue_set_effort");
    const res = await handler({ repo: "octo/repo", number: 9, effort: "standard" });
    expect(res.isError).toBeFalsy();
    expect(setProjectSingleSelectMock).toHaveBeenCalledWith("PVTI_1", "F_effort", "O_std");
    expect(JSON.parse(res.content[0].text)).toEqual({ number: 9, effort: "standard" });
  });

  it("errors clearly when the issue isn't a project item", async () => {
    findProjectItemMock.mockResolvedValue(null);
    const handler = await getIssueHandler("issue_set_effort");
    const res = await handler({ repo: "octo/repo", number: 9, effort: "standard" });
    expect(res.isError).toBe(true);
    expect(res.content[0].text).toContain("not on the GarrettMakesItLLC — Work project");
  });
});

describe("issue_set_priority", () => {
  it("resolves the project item and field, then sets the option", async () => {
    findProjectItemMock.mockResolvedValue({ id: "PVTI_2", fields: {} });
    getProjectFieldMock.mockResolvedValue({
      id: "F_priority",
      name: "Priority",
      options: [{ id: "O_high", name: "High" }, { id: "O_low", name: "Low" }],
    });
    const handler = await getIssueHandler("issue_set_priority");
    const res = await handler({ repo: "octo/repo", number: 11, priority: "high" });
    expect(res.isError).toBeFalsy();
    expect(setProjectSingleSelectMock).toHaveBeenCalledWith("PVTI_2", "F_priority", "O_high");
    expect(JSON.parse(res.content[0].text)).toEqual({ number: 11, priority: "high" });
  });

  it("errors clearly when the issue isn't a project item", async () => {
    findProjectItemMock.mockResolvedValue(null);
    const handler = await getIssueHandler("issue_set_priority");
    const res = await handler({ repo: "octo/repo", number: 11, priority: "high" });
    expect(res.isError).toBe(true);
    expect(res.content[0].text).toContain("not on the GarrettMakesItLLC — Work project");
  });
});

describe("issue_claim", () => {
  /**
   * Mock the full happy path. `refStatus` drives the outcome of the atomic
   * `POST /git/refs` that acquires the lock; `calls` records the request order
   * so the lock-before-assign sequence can be asserted.
   */
  function mockClaim(opts: {
    refStatus: number;
    calls: string[];
    assigneesStatus?: number;
    branchBody?: unknown;
    prsBody?: unknown;
    commentsBody?: unknown;
  }) {
    return async (url: string, init: { method?: string; body?: string }) => {
      const method = init.method ?? "GET";
      opts.calls.push(`${method} ${new URL(url).pathname}`);
      if (url.endsWith("/user")) return makeResponse({ status: 200, body: { login: "GarrettMakesIt" } });
      if (method === "GET" && /\/repos\/octo\/repo$/.test(new URL(url).pathname)) {
        return makeResponse({ status: 200, body: { default_branch: "main" } });
      }
      if (method === "GET" && url.endsWith("/git/ref/heads/main")) {
        return makeResponse({ status: 200, body: { object: { sha: "basesha" } } });
      }
      if (method === "POST" && url.endsWith("/git/refs")) {
        if (opts.refStatus !== 201) {
          return makeResponse({ status: opts.refStatus, body: { message: "Reference already exists" } });
        }
        return makeResponse({ status: 201, body: { ref: JSON.parse(init.body as string).ref } });
      }
      if (method === "GET" && url.includes("/branches/")) {
        return makeResponse({ status: 200, body: opts.branchBody ?? { commit: { sha: "x" } } });
      }
      if (method === "GET" && url.includes("/pulls")) {
        return makeResponse({ status: 200, body: opts.prsBody ?? [] });
      }
      if (method === "GET" && url.includes("/issues/8/comments")) {
        return makeResponse({ status: 200, body: opts.commentsBody ?? [] });
      }
      if (method === "POST" && url.endsWith("/assignees")) {
        return makeResponse({ status: opts.assigneesStatus ?? 201, body: {} });
      }
      if (method === "POST" && url.endsWith("/issues/8/comments")) {
        return makeResponse({ status: 201, body: { body: JSON.parse(init.body as string).body } });
      }
      if (method === "GET" && url.endsWith("/issues/8")) {
        return makeResponse({
          status: 200,
          body: {
            number: 8,
            title: "Fix the thing!",
            labels: [{ name: "status:ready" }, { name: "type:bug" }],
          },
        });
      }
      if (method === "PUT" && url.endsWith("/labels")) {
        const sent = JSON.parse(init.body as string).labels as string[];
        expect(sent).toEqual(expect.arrayContaining(["type:bug", "status:in-progress"]));
        expect(sent).not.toContain("status:ready");
        return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
      }
      return makeResponse({ status: 500 });
    };
  }

  it("creates the lock ref BEFORE assigning, then assigns @me and sets status:in-progress", async () => {
    const calls: string[] = [];
    fetchMock.mockImplementation(mockClaim({ refStatus: 201, calls }));

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as {
      claimed: boolean;
      branch: string;
      base: string;
      status: string | null;
      assignee: string | null;
    };
    expect(out.claimed).toBe(true);
    expect(out.branch).toBe("issue-8-fix-the-thing");
    expect(out.base).toBe("main");
    expect(out.assignee).toBe("GarrettMakesIt");
    expect(out.status).toBe("in-progress");

    const refIndex = calls.findIndex((c) => c === "POST /repos/octo/repo/git/refs");
    const stampIndex = calls.findIndex((c) => c === "POST /repos/octo/repo/issues/8/comments");
    const assignIndex = calls.findIndex((c) => c.endsWith("/assignees"));
    expect(refIndex).toBeGreaterThanOrEqual(0);
    expect(stampIndex).toBeGreaterThan(refIndex);
    expect(assignIndex).toBeGreaterThan(refIndex);
  });

  it("stamps the claim with a holder identity and timestamp, so a later conflict can tell who holds it", async () => {
    const calls: string[] = [];
    let stampBody = "";
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if ((init.method ?? "GET") === "POST" && url.endsWith("/issues/8/comments")) {
        stampBody = JSON.parse(init.body as string).body as string;
      }
      return mockClaim({ refStatus: 201, calls })(url, init);
    });

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBeFalsy();
    expect(stampBody).toContain("🔒 Claimed by");
    const marker = /<!-- claim-lock: (\{.*?\}) -->/.exec(stampBody);
    expect(marker).not.toBeNull();
    const stamp = JSON.parse(marker![1]) as { branch: string; holder: string; claimed_at: string };
    expect(stamp.branch).toBe("issue-8-fix-the-thing");
    expect(typeof stamp.holder).toBe("string");
    expect(stamp.holder.length).toBeGreaterThan(0);
    expect(new Date(stamp.claimed_at).toString()).not.toBe("Invalid Date");
  });

  it("returns a structured already-claimed failure on a 422 from the ref POST, and never assigns", async () => {
    const calls: string[] = [];
    fetchMock.mockImplementation(
      mockClaim({
        refStatus: 422,
        calls,
        branchBody: {
          commit: {
            sha: "deadbeef",
            commit: { author: { name: "Ada", date: "2026-07-20T00:00:00Z" }, message: "wip\n\nbody" },
          },
        },
        prsBody: [{ number: 77, html_url: "https://gh/pr/77", state: "open", draft: false, title: "WIP" }],
      }),
    );

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBe(true);
    const out = JSON.parse(res.content[0].text) as {
      claimed: boolean;
      reason: string;
      issue: number;
      branch: string;
      last_commit: { sha: string; author: string | null; date: string | null } | null;
      pull_request: { number: number } | null;
    };
    expect(out.claimed).toBe(false);
    expect(out.reason).toBe("already-claimed");
    expect(out.issue).toBe(8);
    expect(out.branch).toBe("issue-8-fix-the-thing");
    expect(out.last_commit?.sha).toBe("deadbeef");
    expect(out.last_commit?.author).toBe("Ada");
    expect(out.last_commit?.date).toBe("2026-07-20T00:00:00Z");
    expect(out.pull_request?.number).toBe(77);
    expect(calls.some((c) => c.endsWith("/assignees"))).toBe(false);
  });

  it("surfaces the holder's identity and claim time from the stamp comment on a conflict", async () => {
    const calls: string[] = [];
    const stamp = { branch: "issue-8-fix-the-thing", holder: "other-machine", claimed_at: "2026-08-01T10:00:00.000Z" };
    fetchMock.mockImplementation(
      mockClaim({
        refStatus: 422,
        calls,
        commentsBody: [
          { body: `🔒 Claimed by \`other-machine\` at ${stamp.claimed_at} (branch \`${stamp.branch}\`)\n<!-- claim-lock: ${JSON.stringify(stamp)} -->` },
        ],
      }),
    );

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBe(true);
    const out = JSON.parse(res.content[0].text) as {
      claimed_by: string | null;
      claimed_at: string | null;
      message: string;
    };
    expect(out.claimed_by).toBe("other-machine");
    expect(out.claimed_at).toBe(stamp.claimed_at);
    expect(out.message).toContain("other-machine");
    expect(out.message).toContain("pick different work");
  });

  it("keeps the lock and reports a _warnings entry when the self-assign fails", async () => {
    const calls: string[] = [];
    fetchMock.mockImplementation(mockClaim({ refStatus: 201, calls, assigneesStatus: 500 }));

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as {
      claimed: boolean;
      assignee: string | null;
      _warnings: string[];
    };
    expect(out.claimed).toBe(true);
    expect(out.assignee).toBeNull();
    expect(out._warnings).toHaveLength(1);
    expect(out._warnings[0]).toContain("self-assign");
    // The ref is the lock — it must NOT be rolled back when assignment fails.
    expect(calls.some((c) => c.startsWith("DELETE"))).toBe(false);
  });

  it("reports status:null with a _warnings entry when the labels PUT returns 2xx but silently drops status:in-progress", async () => {
    const calls: string[] = [];
    const base = mockClaim({ refStatus: 201, calls });
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      const method = init.method ?? "GET";
      if (method === "PUT" && url.endsWith("/labels")) {
        // GitHub returned 2xx, but the applied set omits status:in-progress —
        // a silent no-op the caller must not report as a successful claim.
        return makeResponse({ status: 200, body: [{ name: "type:bug" }] });
      }
      return base(url, init);
    });

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as {
      claimed: boolean;
      status: string | null;
      _warnings: string[];
    };
    expect(out.claimed).toBe(true);
    expect(out.status).toBeNull();
    expect(out._warnings).toHaveLength(1);
    expect(out._warnings[0]).toContain("status:in-progress");
  });

  it("uses an explicit branch override instead of deriving one from the title", async () => {
    const calls: string[] = [];
    fetchMock.mockImplementation(mockClaim({ refStatus: 201, calls }));

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8, branch: "issue-8-custom" });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as { branch: string };
    expect(out.branch).toBe("issue-8-custom");
  });

  it("flags model_mismatch when caller_model is under-provisioned for the issue's Effort field", async () => {
    const calls: string[] = [];
    findProjectItemMock.mockResolvedValue({ id: "PVTI_3", fields: { effort: "Complex" } });
    fetchMock.mockImplementation(mockClaim({ refStatus: 201, calls }));

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8, caller_model: "claude-sonnet-5" });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as { model_mismatch: string | null };
    expect(out.model_mismatch).toContain("Effort of complex");
  });

  it("reports no mismatch when caller_model meets the effort, or when either is absent", async () => {
    const calls: string[] = [];
    findProjectItemMock.mockResolvedValue({ id: "PVTI_3", fields: { effort: "Complex" } });
    fetchMock.mockImplementation(mockClaim({ refStatus: 201, calls }));
    const handler = await getIssueHandler("issue_claim");

    const matched = await handler({ repo: "octo/repo", number: 8, caller_model: "claude-opus-5" });
    expect((JSON.parse(matched.content[0].text) as { model_mismatch: string | null }).model_mismatch).toBeNull();

    const noModel = await handler({ repo: "octo/repo", number: 8 });
    expect((JSON.parse(noModel.content[0].text) as { model_mismatch: string | null }).model_mismatch).toBeNull();
  });

  it("refuses to claim a closed issue, without creating the lock ref or self-assigning", async () => {
    const calls: string[] = [];
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      const method = init.method ?? "GET";
      calls.push(`${method} ${new URL(url).pathname}`);
      if (method === "GET" && url.endsWith("/issues/8")) {
        return makeResponse({
          status: 200,
          body: {
            number: 8,
            title: "Fix the thing!",
            state: "closed",
            state_reason: "completed",
            closed_at: "2026-07-30T18:31:30Z",
            labels: [{ name: "type:bug" }],
          },
        });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBe(true);
    const out = JSON.parse(res.content[0].text) as {
      claimed: boolean;
      reason: string;
      issue: number;
      state: string;
      state_reason: string | null;
      closed_at: string | null;
    };
    expect(out.claimed).toBe(false);
    expect(out.reason).toBe("closed");
    expect(out.issue).toBe(8);
    expect(out.state).toBe("closed");
    expect(out.state_reason).toBe("completed");
    expect(out.closed_at).toBe("2026-07-30T18:31:30Z");
    expect(calls.some((c) => c.endsWith("/git/refs"))).toBe(false);
    expect(calls.some((c) => c.endsWith("/assignees"))).toBe(false);
  });

  it("refuses to claim an epic with open sub-issues, without creating the lock ref or self-assigning", async () => {
    const calls: string[] = [];
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      const method = init.method ?? "GET";
      calls.push(`${method} ${new URL(url).pathname}`);
      if (method === "GET" && url.endsWith("/issues/8")) {
        return makeResponse({
          status: 200,
          body: {
            number: 8,
            title: "S2 — content & discovery",
            labels: [{ name: "epic" }],
            sub_issues_summary: { total: 5, completed: 2 },
          },
        });
      }
      return makeResponse({ status: 500 });
    });

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBe(true);
    const out = JSON.parse(res.content[0].text) as {
      claimed: boolean;
      reason: string;
      issue: number;
      open_sub_issues: number;
      total_sub_issues: number;
      message: string;
    };
    expect(out.claimed).toBe(false);
    expect(out.reason).toBe("epic");
    expect(out.issue).toBe(8);
    expect(out.open_sub_issues).toBe(3);
    expect(out.total_sub_issues).toBe(5);
    expect(out.message).toContain("sub-issue");
    expect(calls.some((c) => c.endsWith("/git/refs"))).toBe(false);
    expect(calls.some((c) => c.endsWith("/assignees"))).toBe(false);
  });

  it("allows claiming an issue whose sub-issues are all completed", async () => {
    const calls: string[] = [];
    fetchMock.mockImplementation(
      mockClaim({
        refStatus: 201,
        calls,
        branchBody: { commit: { sha: "x" } },
      }),
    );
    // Override the /issues/8 GET the shared mockClaim helper returns, to add a
    // fully-completed sub_issues_summary.
    const base = mockClaim({ refStatus: 201, calls });
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      const method = init.method ?? "GET";
      if (method === "GET" && url.endsWith("/issues/8")) {
        return makeResponse({
          status: 200,
          body: {
            number: 8,
            title: "Fix the thing!",
            labels: [{ name: "status:ready" }],
            sub_issues_summary: { total: 3, completed: 3 },
          },
        });
      }
      return base(url, init);
    });

    const handler = await getIssueHandler("issue_claim");
    const res = await handler({ repo: "octo/repo", number: 8 });

    expect(res.isError).toBeFalsy();
    const out = JSON.parse(res.content[0].text) as { claimed: boolean };
    expect(out.claimed).toBe(true);
  });
});

describe("issue_open", () => {
  it("composes status/source labels on create, defaults feedback (source set, no status) to status:blocked, and sends the native-type PATCH", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        const sent = JSON.parse(init.body as string) as { labels: string[] };
        expect(sent.labels).toEqual(
          expect.arrayContaining(["status:blocked", "source:redthread"]),
        );
        expect(sent.labels).not.toContain("type:bug");
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

  it("defaults an owner-reported defect to status:ready — his report is the verification", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        const sent = JSON.parse(init.body as string) as { labels: string[] };
        expect(sent.labels).toEqual(
          expect.arrayContaining(["status:ready", "source:owner"]),
        );
        expect(sent.labels).not.toContain("type:bug");
        expect(sent.labels).not.toContain("status:blocked");
        return makeResponse({ status: 201, body: { number: 46, id: 8005, labels: sent.labels } });
      }
      if (init.method === "PATCH" && url.endsWith("/issues/46")) {
        return makeResponse({ status: 200, body: {} });
      }
      if (init.method === "GET" && url.endsWith("/issues/46")) {
        return makeResponse({ status: 200, body: { number: 46, id: 8005 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({
      repo: "octo/repo",
      title: "Rest timer drifts",
      type: "bug",
      source: "owner",
    });
    expect(res.isError).toBeFalsy();
  });

  it("still defaults an owner-reported feature to status:blocked — it needs his intent first", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        const sent = JSON.parse(init.body as string) as { labels: string[] };
        expect(sent.labels).toEqual(
          expect.arrayContaining(["status:blocked", "source:owner"]),
        );
        expect(sent.labels).not.toContain("type:feature");
        expect(sent.labels).not.toContain("status:ready");
        return makeResponse({ status: 201, body: { number: 47, id: 8006, labels: sent.labels } });
      }
      if (init.method === "PATCH" && url.endsWith("/issues/47")) {
        return makeResponse({ status: 200, body: {} });
      }
      if (init.method === "GET" && url.endsWith("/issues/47")) {
        return makeResponse({ status: 200, body: { number: 47, id: 8006 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({
      repo: "octo/repo",
      title: "Add a plate calculator",
      type: "feature",
      source: "owner",
    });
    expect(res.isError).toBeFalsy();
  });

  it("defaults an in-app third-party report to status:blocked", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        const sent = JSON.parse(init.body as string) as { labels: string[] };
        expect(sent.labels).toEqual(
          expect.arrayContaining(["status:blocked", "source:user-feedback"]),
        );
        expect(sent.labels).not.toContain("type:bug");
        return makeResponse({ status: 201, body: { number: 48, id: 8007, labels: sent.labels } });
      }
      if (init.method === "PATCH" && url.endsWith("/issues/48")) {
        return makeResponse({ status: 200, body: {} });
      }
      if (init.method === "GET" && url.endsWith("/issues/48")) {
        return makeResponse({ status: 200, body: { number: 48, id: 8007 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({
      repo: "octo/repo",
      title: "Timer stops on lock screen",
      type: "bug",
      source: "user-feedback",
    });
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

  it("posts the sub_issues link to the PARENT's repo, not the new issue's, when parent_repo differs (#234)", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      // The new issue is created in octo/child-repo.
      if (init.method === "POST" && url === "https://api.github.com/repos/octo/child-repo/issues") {
        return makeResponse({ status: 201, body: { number: 44, id: 8003 } });
      }
      // The link must POST to the PARENT's repo (octo/parent-repo), not octo/child-repo.
      if (
        init.method === "POST" &&
        url === "https://api.github.com/repos/octo/parent-repo/issues/486/sub_issues"
      ) {
        expect(init.body).toContain('"sub_issue_id":8003');
        return makeResponse({ status: 201, body: {} });
      }
      if (init.method === "GET" && url.endsWith("/issues/44")) {
        return makeResponse({ status: 200, body: { number: 44, id: 8003 } });
      }
      throw new Error(`unexpected fetch: ${init.method} ${url}`);
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({
      repo: "octo/child-repo",
      title: "Sub task",
      parent: 486,
      parent_repo: "octo/parent-repo",
    });
    expect(res.isError).toBeFalsy();
    const body = JSON.parse(res.content[0].text) as { _warnings?: string[] };
    expect(body._warnings).toBeUndefined();
  });

  it("returns the created issue with no _warnings on a fully successful run", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        return makeResponse({ status: 201, body: { number: 50, id: 8010 } });
      }
      if (init.method === "GET" && url.endsWith("/issues/50")) {
        return makeResponse({ status: 200, body: { number: 50, id: 8010 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({ repo: "octo/repo", title: "Plain task" });
    expect(res.isError).toBeFalsy();
    const issue = JSON.parse(res.content[0].text) as Record<string, unknown>;
    expect(issue.number).toBe(50);
    expect(issue._warnings).toBeUndefined();
  });

  it("still returns the created issue (not an error) when the sub-issue link fails, with a _warnings entry", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        return makeResponse({ status: 201, body: { number: 51, id: 8011 } });
      }
      if (init.method === "POST" && url.endsWith("/issues/4/sub_issues")) {
        return makeResponse({ status: 500, body: { message: "server error" } });
      }
      if (init.method === "GET" && url.endsWith("/issues/51")) {
        return makeResponse({ status: 200, body: { number: 51, id: 8011 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({ repo: "octo/repo", title: "Sub task", parent: 4 });
    expect(res.isError).toBeFalsy();
    const issue = JSON.parse(res.content[0].text) as { number: number; _warnings: string[] };
    expect(issue.number).toBe(51);
    expect(issue._warnings).toHaveLength(1);
    expect(issue._warnings[0]).toContain("parent #4");
  });

  it("still returns the created issue (not an error) when the milestone step fails, with a _warnings entry", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        return makeResponse({ status: 201, body: { number: 52, id: 8012 } });
      }
      if (init.method === "GET" && url.includes("/milestones")) {
        return makeResponse({ status: 500, body: { message: "server error" } });
      }
      if (init.method === "GET" && url.endsWith("/issues/52")) {
        return makeResponse({ status: 200, body: { number: 52, id: 8012 } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({ repo: "octo/repo", title: "Ship v2", milestone: "v2" });
    expect(res.isError).toBeFalsy();
    const issue = JSON.parse(res.content[0].text) as { number: number; _warnings: string[] };
    expect(issue.number).toBe(52);
    expect(issue._warnings).toHaveLength(1);
    expect(issue._warnings[0]).toContain('milestone "v2"');
  });

});

describe("issue_open effort/priority", () => {
  it("sets effort and priority best-effort after creation, and drops the type:* label", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        expect(init.body).not.toContain("type:");
        return makeResponse({ status: 201, body: { number: 20, id: 555 } });
      }
      if (init.method === "PATCH" && url.includes("/issues/20") && init.body === '{"type":"Feature"}') {
        return makeResponse({ status: 200, body: {} });
      }
      if (init.method === "GET" && url.endsWith("/issues/20")) {
        return makeResponse({ status: 200, body: { number: 20 } });
      }
      throw new Error(`unexpected fetch: ${init.method} ${url}`);
    });
    findProjectItemMock.mockResolvedValue({ id: "PVTI_4", fields: {} });
    getProjectFieldMock.mockImplementation(async (name: string) =>
      name === "Effort"
        ? { id: "F_effort", name: "Effort", options: [{ id: "O_std", name: "Standard" }] }
        : { id: "F_priority", name: "Priority", options: [{ id: "O_high", name: "High" }] },
    );
    const handler = await getIssueHandler("issue_open");
    const res = await handler({
      repo: "octo/repo", title: "t", type: "feature", effort: "standard", priority: "high",
    });
    expect(res.isError).toBeFalsy();
    expect(setProjectSingleSelectMock).toHaveBeenCalledWith("PVTI_4", "F_effort", "O_std");
    expect(setProjectSingleSelectMock).toHaveBeenCalledWith("PVTI_4", "F_priority", "O_high");
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
