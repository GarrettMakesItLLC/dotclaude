import { beforeEach, describe, expect, it, vi } from "vitest";

const execFileMock = vi.fn();
vi.mock("node:child_process", () => ({ execFile: execFileMock }));

function ghSuccess(stdout: string) {
  execFileMock.mockImplementation((_c: string, _a: string[], ...rest: unknown[]) => {
    const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
    cb(null, { stdout, stderr: "" });
  });
}

beforeEach(() => {
  vi.resetModules();
  execFileMock.mockReset();
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

describe("findProjectItem", () => {
  it("matches an item by repository and issue number, splitting id from fields", async () => {
    ghSuccess(
      JSON.stringify({
        items: [
          { id: "PVTI_1", content: { number: 5, repository: "acme/widgets" }, status: "Todo", effort: "Standard" },
          { id: "PVTI_2", content: { number: 6, repository: "acme/widgets" }, status: "Done" },
        ],
      }),
    );
    const { findProjectItem } = await import("../src/project.js");
    const item = await findProjectItem("acme", "widgets", 5);
    expect(item).toEqual({ id: "PVTI_1", fields: { status: "Todo", effort: "Standard" } });
  });

  it("returns null when the issue isn't a project item", async () => {
    ghSuccess(JSON.stringify({ items: [] }));
    const { findProjectItem } = await import("../src/project.js");
    expect(await findProjectItem("acme", "widgets", 999)).toBeNull();
  });

  it("caches the item list across calls, but a miss triggers one refetch before giving up null", async () => {
    execFileMock
      .mockImplementationOnce((_c: string, _a: string[], ...rest: unknown[]) => {
        const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
        cb(null, { stdout: JSON.stringify({ items: [] }), stderr: "" });
      })
      .mockImplementation((_c: string, _a: string[], ...rest: unknown[]) => {
        const cb = rest[rest.length - 1] as (e: unknown, o?: unknown) => void;
        cb(null, {
          stdout: JSON.stringify({
            items: [{ id: "PVTI_9", content: { number: 5, repository: "acme/widgets" }, status: "Todo" }],
          }),
          stderr: "",
        });
      });
    const { findProjectItem } = await import("../src/project.js");
    // First call: cache is empty, fetches (miss — the once-only empty list), then a
    // cache-miss refetch (the default impl, which has the item) succeeds.
    const item = await findProjectItem("acme", "widgets", 5);
    expect(item?.id).toBe("PVTI_9");
    expect(execFileMock).toHaveBeenCalledTimes(2);
    // Second call: item is in the (now-populated) cache — no further fetch needed.
    await findProjectItem("acme", "widgets", 5);
    expect(execFileMock).toHaveBeenCalledTimes(2);
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
