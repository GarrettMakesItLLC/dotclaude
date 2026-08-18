import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const execFileMock = vi.fn();
vi.mock("node:child_process", () => ({ execFile: execFileMock }));

function ghSuccess(stdout: string) {
  execFileMock.mockImplementation((_c: string, _a: string[], ...rest: unknown[]) => {
    const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
    cb(null, { stdout, stderr: "" });
  });
}

/** Build a minimal `Response`-like object good enough for `ghGraphQL`. */
function graphqlResponse(data: unknown): Response {
  const text = JSON.stringify({ data });
  return {
    status: 200,
    ok: true,
    headers: new Headers(),
    text: async () => text,
    json: async () => JSON.parse(text),
  } as unknown as Response;
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  vi.resetModules();
  execFileMock.mockReset();
  // `ghGraphQL` fetches a token via `gh auth token` before every request.
  execFileMock.mockImplementation((_c: string, args: string[], ...rest: unknown[]) => {
    const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
    if (args[0] === "auth" && args[1] === "token") {
      cb(null, { stdout: "ghs_secrettoken123\n", stderr: "" });
      return;
    }
    cb(new Error(`unexpected gh args: ${args.join(" ")}`));
  });
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("getProjectField", () => {
  it("finds a field by name, including its options", async () => {
    ghSuccess(
      JSON.stringify({
        fields: [
          { id: "F_status", name: "Status", options: [{ id: "O_todo", name: "Todo" }] },
          { id: "F_effort", name: "Effort", options: [{ id: "O_std", name: "Standard" }] },
        ],
      }),
    );
    const { getProjectField } = await import("../src/project.js");
    const field = await getProjectField("Effort");
    expect(field.id).toBe("F_effort");
    expect(field.options).toEqual([{ id: "O_std", name: "Standard" }]);
  });

  it("throws a clear error when the field doesn't exist", async () => {
    ghSuccess(JSON.stringify({ fields: [] }));
    const { getProjectField } = await import("../src/project.js");
    await expect(getProjectField("Nope")).rejects.toThrow('Project field "Nope" not found');
  });

  it("retries once on gh's intermittent \"unknown owner type\" error, then succeeds", async () => {
    execFileMock
      .mockImplementationOnce((_c: string, _a: string[], ...rest: unknown[]) => {
        const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
        cb(new Error("unknown owner type"), undefined);
      })
      .mockImplementation((_c: string, _a: string[], ...rest: unknown[]) => {
        const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
        cb(null, {
          stdout: JSON.stringify({ fields: [{ id: "F_effort", name: "Effort" }] }),
          stderr: "",
        });
      });
    const { getProjectField } = await import("../src/project.js");
    const field = await getProjectField("Effort");
    expect(field.id).toBe("F_effort");
    expect(execFileMock).toHaveBeenCalledTimes(2);
  });

  it("does not retry a real failure unrelated to the owner-type race", async () => {
    execFileMock.mockImplementation((_c: string, _a: string[], ...rest: unknown[]) => {
      const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
      cb(new Error("some other gh failure"), undefined);
    });
    const { getProjectField } = await import("../src/project.js");
    await expect(getProjectField("Effort")).rejects.toThrow("some other gh failure");
    expect(execFileMock).toHaveBeenCalledTimes(1);
  });

  it("wraps gh's explicit missing-scope error with the actionable fix, without retrying (#4051)", async () => {
    execFileMock.mockImplementation((_c: string, _a: string[], ...rest: unknown[]) => {
      const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
      cb(
        new Error(
          "error: your authentication token is missing required scopes [read:project]",
        ),
        undefined,
      );
    });
    const { getProjectField } = await import("../src/project.js");
    await expect(getProjectField("Effort")).rejects.toThrow("gh auth refresh -s project");
    expect(execFileMock).toHaveBeenCalledTimes(1);
  });

  it("wraps a second \"unknown owner type\" (post-retry) with the actionable fix (#4051)", async () => {
    execFileMock.mockImplementation((_c: string, _a: string[], ...rest: unknown[]) => {
      const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
      cb(new Error("unknown owner type"), undefined);
    });
    const { getProjectField } = await import("../src/project.js");
    await expect(getProjectField("Effort")).rejects.toThrow("gh auth refresh -s project");
    // One initial attempt + one retry — the retry still exists for the genuine race (#147).
    expect(execFileMock).toHaveBeenCalledTimes(2);
  });

  it("caches the field list across calls, but a miss triggers one refetch before giving up", async () => {
    execFileMock
      .mockImplementationOnce((_c: string, _a: string[], ...rest: unknown[]) => {
        const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
        cb(null, { stdout: JSON.stringify({ fields: [] }), stderr: "" });
      })
      .mockImplementation((_c: string, _a: string[], ...rest: unknown[]) => {
        const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
        cb(null, {
          stdout: JSON.stringify({ fields: [{ id: "F_effort", name: "Effort" }] }),
          stderr: "",
        });
      });
    const { getProjectField } = await import("../src/project.js");
    // First call: cache is empty, fetches (miss — the once-only empty list), then a
    // cache-miss refetch (the default impl, which has Effort) succeeds.
    const field = await getProjectField("Effort");
    expect(field.id).toBe("F_effort");
    expect(execFileMock).toHaveBeenCalledTimes(2);
    // Second call: field is in the (now-populated) cache — no further fetch needed.
    await getProjectField("Effort");
    expect(execFileMock).toHaveBeenCalledTimes(2);
  });
});

const PROJECT_ID = "PVT_kwDOEa9MV84BfYTK";

describe("findProjectItem", () => {
  it("resolves an issue's project item by a single targeted query, not the whole board", async () => {
    fetchMock.mockResolvedValueOnce(
      graphqlResponse({
        repository: {
          issue: {
            projectItems: {
              nodes: [
                {
                  id: "PVTI_1",
                  project: { id: PROJECT_ID },
                  fieldValues: {
                    nodes: [
                      {
                        __typename: "ProjectV2ItemFieldSingleSelectValue",
                        name: "Todo",
                        field: { name: "Status" },
                      },
                      {
                        __typename: "ProjectV2ItemFieldSingleSelectValue",
                        name: "Standard",
                        field: { name: "Effort" },
                      },
                    ],
                  },
                },
              ],
            },
          },
        },
      }),
    );
    const { findProjectItem } = await import("../src/project.js");
    const item = await findProjectItem("acme", "widgets", 5);
    expect(item).toEqual({ id: "PVTI_1", fields: { status: "Todo", effort: "Standard" } });
    // One GraphQL request for exactly this issue — not a project-wide list.
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit & { body: string }];
    const body = JSON.parse(init.body);
    expect(body.variables).toEqual({ owner: "acme", repo: "widgets", number: 5 });
  });

  it("ignores project items belonging to a different project", async () => {
    fetchMock.mockResolvedValueOnce(
      graphqlResponse({
        repository: {
          issue: {
            projectItems: {
              nodes: [{ id: "PVTI_other", project: { id: "PVT_someOtherProject" }, fieldValues: { nodes: [] } }],
            },
          },
        },
      }),
    );
    const { findProjectItem } = await import("../src/project.js");
    expect(await findProjectItem("acme", "widgets", 999)).toBeNull();
  });

  it("returns null when the issue isn't a project item at all", async () => {
    fetchMock.mockResolvedValueOnce(
      graphqlResponse({ repository: { issue: { projectItems: { nodes: [] } } } }),
    );
    const { findProjectItem } = await import("../src/project.js");
    expect(await findProjectItem("acme", "widgets", 999)).toBeNull();
  });

  it("caches per issue for the process lifetime — a second lookup of the same issue makes no request", async () => {
    fetchMock.mockResolvedValueOnce(
      graphqlResponse({
        repository: {
          issue: {
            projectItems: {
              nodes: [
                {
                  id: "PVTI_9",
                  project: { id: PROJECT_ID },
                  fieldValues: {
                    nodes: [
                      {
                        __typename: "ProjectV2ItemFieldSingleSelectValue",
                        name: "Todo",
                        field: { name: "Status" },
                      },
                    ],
                  },
                },
              ],
            },
          },
        },
      }),
    );
    const { findProjectItem } = await import("../src/project.js");
    const item = await findProjectItem("acme", "widgets", 5);
    expect(item?.id).toBe("PVTI_9");
    expect(fetchMock).toHaveBeenCalledTimes(1);
    await findProjectItem("acme", "widgets", 5);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("a write invalidates the cached lookup so the next read refetches", async () => {
    fetchMock.mockResolvedValue(
      graphqlResponse({
        repository: {
          issue: { projectItems: { nodes: [{ id: "PVTI_9", project: { id: PROJECT_ID }, fieldValues: { nodes: [] } }] } },
        },
      }),
    );
    const { findProjectItem, invalidateProjectItem } = await import("../src/project.js");
    await findProjectItem("acme", "widgets", 5);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    invalidateProjectItem("acme", "widgets", 5);
    await findProjectItem("acme", "widgets", 5);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

describe("setProjectSingleSelect", () => {
  it("shells out to gh project item-edit with the item/project/field/option ids", async () => {
    let calledArgs: string[] = [];
    execFileMock.mockImplementation((_c: string, args: string[], ...rest: unknown[]) => {
      const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
      calledArgs = args;
      cb(null, { stdout: "{}", stderr: "" });
    });
    const { setProjectSingleSelect } = await import("../src/project.js");
    await setProjectSingleSelect("PVTI_1", "F_effort", "O_std");
    expect(calledArgs).toEqual([
      "project", "item-edit",
      "--id", "PVTI_1",
      "--project-id", "PVT_kwDOEa9MV84BfYTK",
      "--field-id", "F_effort",
      "--single-select-option-id", "O_std",
    ]);
  });
});
