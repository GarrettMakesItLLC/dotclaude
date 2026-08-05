# Project Fields MCP Tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the `complexity:*`/`type:*` labels in favor of GitHub's native issue type and two new Project custom fields (Effort, Priority), and add blocked/blocked-by relationship tools — all in the vendored `mcp/github` MCP server.

**Architecture:** `mcp/github` is REST-only by design (`ghRequest`'s own doc comment: "REST only — never GraphQL"). Projects v2 custom fields have no REST API, so field reads/writes shell out to the `gh project` CLI subcommand (the same pattern `resolveRepo`/`fetchToken` already use for `gh repo view`/`gh auth token`) rather than adding a hand-rolled GraphQL client. Blocked/blocked-by uses a real REST endpoint (`/issues/{n}/dependencies/blocked_by`, confirmed live against this org) — no `gh` shell-out needed there, `ghRequest` handles it directly.

**Tech Stack:** TypeScript (strict, no `any` in `src/`), zod schemas, vitest, `@modelcontextprotocol/sdk`.

## Global Constraints

- Every tool follows the existing `server.registerTool(name, { description, inputSchema }, handler)` shape; handlers always wrap in try/catch returning `errorResult(err)` on failure.
- `src/` has no `any`; tests may use `as any` only where they already do (stubbing `McpServer`).
- Rebuild (`npm run build` in `mcp/github`) and restart Claude Code before any new/changed tool is callable — note this at the end, don't repeat per task.
- The shared work project is `GarrettMakesItLLC — Work`, org project #2, node id `PVT_kwDOEa9MV84BfYTK` (confirmed via `gh project view 2 --owner GarrettMakesItLLC --format json`). Hardcode these three as constants — this tool targets one specific project, not an arbitrary one.
- Every `gh project item-list`/`gh project field-list` call already returns JSON; no `jq` piping.
- **Ordering note:** `labels.ts`'s `complexity:*`/`type:*` removal and every `issues.ts` call site that imports those names form one compilation unit — `issues.ts` fails to even load once `labels.ts` stops exporting `ISSUE_COMPLEXITIES`/`complexityLabel`/`complexityModelMismatch`/`IssueComplexity`. Task 3 below does both together for that reason; don't split it further.

---

### Task 1: `execGh` shell helper in `github.ts`

**Files:**
- Modify: `mcp/github/src/github.ts`
- Test: `mcp/github/test/github.test.ts`

**Interfaces:**
- Produces: `export async function execGh(args: string[]): Promise<string>` — runs `gh <args>` via the module's existing `execFileAsync`, returns trimmed stdout, throws `Error("gh <args.join(' ')> failed: <message>")` on non-zero exit or spawn failure.

- [ ] **Step 1: Write the failing test**

Add to `mcp/github/test/github.test.ts` (mirror the existing `execFileMock` setup already in that file):

```ts
describe("execGh", () => {
  it("returns trimmed stdout on success", async () => {
    execFileMock.mockImplementation((_c: string, args: string[], cb: (e: unknown, o?: unknown) => void) => {
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
    execFileMock.mockImplementation((_c: string, _a: string[], cb: (e: unknown) => void) => {
      cb(new Error("exit status 1"));
    });
    const { execGh } = await import("../src/github.js");
    await expect(execGh(["project", "bogus"])).rejects.toThrow(
      "gh project bogus failed: exit status 1",
    );
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp/github && npx vitest run test/github.test.ts -t execGh`
Expected: FAIL — `execGh` is not exported from `../src/github.js`.

- [ ] **Step 3: Implement `execGh`**

In `mcp/github/src/github.ts`, directly below the existing `fetchToken` function (it already has `execFileAsync` in scope from the top of the file):

```ts
/**
 * Run a `gh` subcommand and return its trimmed stdout. Used only for the
 * handful of operations REST has no equivalent for (Projects v2 fields) —
 * everything else goes through `ghRequest`, never this.
 */
export async function execGh(args: string[]): Promise<string> {
  try {
    const { stdout } = await execFileAsync("gh", args);
    return stdout.trim();
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    throw new Error(`gh ${args.join(" ")} failed: ${message}`);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp/github && npx vitest run test/github.test.ts -t execGh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mcp/github/src/github.ts mcp/github/test/github.test.ts
git commit -m "feat(mcp/github): add execGh shell-out helper for gh project subcommands"
```

---

### Task 2: `src/project.ts` — resolve project items and fields

**Files:**
- Create: `mcp/github/src/project.ts`
- Test: `mcp/github/test/project.test.ts`

**Interfaces:**
- Consumes: `execGh(args: string[]): Promise<string>` from Task 1.
- Produces:
  - `export interface ProjectField { id: string; name: string; options?: { id: string; name: string }[] }`
  - `export interface ProjectItemInfo { id: string; fields: Record<string, unknown> }`
  - `export async function getProjectField(name: string): Promise<ProjectField>` — throws if the named field doesn't exist on the project.
  - `export async function findProjectItem(owner: string, repo: string, issueNumber: number): Promise<ProjectItemInfo | null>`
  - `export async function setProjectSingleSelect(itemId: string, fieldId: string, optionId: string): Promise<void>`

**Verify the live JSON shape first** (not a test — a one-time sanity check informing the parsing code below): run
`gh project item-list 2 --owner GarrettMakesItLLC --format json --limit 3` and confirm each item has `content.number`, `content.repository` (as `"owner/repo"`, no URL), and a `status` key holding the *plain option name* (e.g. `"Todo"`), not an id. This confirms single-select fields serialize as their option name under the field's lowercased name — the same convention `findProjectItem` below relies on for reading `effort`/`priority` once those fields exist (created in the companion project-schema-setup plan, which should land before this is exercised against real data — the code and its tests don't depend on the fields existing yet).

- [ ] **Step 1: Write the failing tests**

Create `mcp/github/test/project.test.ts`:

```ts
import { beforeEach, describe, expect, it, vi } from "vitest";

const execFileMock = vi.fn();
vi.mock("node:child_process", () => ({ execFile: execFileMock }));

function ghSuccess(stdout: string) {
  execFileMock.mockImplementation((_c: string, _a: string[], cb: (e: unknown, o?: unknown) => void) =>
    cb(null, { stdout, stderr: "" }),
  );
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
});

describe("setProjectSingleSelect", () => {
  it("shells out to gh project item-edit with the item/project/field/option ids", async () => {
    let calledArgs: string[] = [];
    execFileMock.mockImplementation((_c: string, args: string[], cb: (e: unknown, o?: unknown) => void) => {
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mcp/github && npx vitest run test/project.test.ts`
Expected: FAIL — `../src/project.js` does not exist.

- [ ] **Step 3: Implement `src/project.ts`**

```ts
import { execGh } from "./github.js";

const PROJECT_OWNER = "GarrettMakesItLLC";
const PROJECT_NUMBER = 2;
const PROJECT_ID = "PVT_kwDOEa9MV84BfYTK";

export interface ProjectFieldOption {
  id: string;
  name: string;
}

export interface ProjectField {
  id: string;
  name: string;
  options?: ProjectFieldOption[];
}

export interface ProjectItemInfo {
  id: string;
  /** Every field's current value, keyed by the field's lowercased name (e.g. `effort`, `status`). */
  fields: Record<string, unknown>;
}

interface RawProjectItem {
  id: string;
  content?: { number?: number; repository?: string };
  [fieldKey: string]: unknown;
}

let cachedFields: ProjectField[] | null = null;

async function listProjectFields(): Promise<ProjectField[]> {
  if (cachedFields) return cachedFields;
  const out = await execGh([
    "project", "field-list", String(PROJECT_NUMBER),
    "--owner", PROJECT_OWNER, "--format", "json",
  ]);
  const parsed = JSON.parse(out) as { fields: ProjectField[] };
  cachedFields = parsed.fields;
  return cachedFields;
}

/** A named custom field on the shared work project. Throws if no field has that exact name. */
export async function getProjectField(name: string): Promise<ProjectField> {
  const fields = await listProjectFields();
  const field = fields.find((f) => f.name === name);
  if (!field) {
    throw new Error(
      `Project field "${name}" not found on GarrettMakesItLLC — Work (#${PROJECT_NUMBER}).`,
    );
  }
  return field;
}

/** The shared work project's item for a repo issue, or null if it isn't a project item. */
export async function findProjectItem(
  owner: string,
  repo: string,
  issueNumber: number,
): Promise<ProjectItemInfo | null> {
  const out = await execGh([
    "project", "item-list", String(PROJECT_NUMBER),
    "--owner", PROJECT_OWNER, "--format", "json", "--limit", "1000",
  ]);
  const parsed = JSON.parse(out) as { items: RawProjectItem[] };
  const match = parsed.items.find(
    (item) =>
      item.content?.number === issueNumber && item.content?.repository === `${owner}/${repo}`,
  );
  if (!match) return null;
  const { id, content: _content, ...fields } = match;
  return { id, fields };
}

/** Set a single-select field's value on a project item, by option id. */
export async function setProjectSingleSelect(
  itemId: string,
  fieldId: string,
  optionId: string,
): Promise<void> {
  await execGh([
    "project", "item-edit",
    "--id", itemId,
    "--project-id", PROJECT_ID,
    "--field-id", fieldId,
    "--single-select-option-id", optionId,
  ]);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mcp/github && npx vitest run test/project.test.ts`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add mcp/github/src/project.ts mcp/github/test/project.test.ts
git commit -m "feat(mcp/github): add project.ts for reading/writing shared-project fields"
```

---

### Task 3: `labels.ts` + every `issues.ts` type/complexity call site, together

This is one task, not five, because they share a single import block in `issues.ts` — `labels.ts` dropping `ISSUE_COMPLEXITIES`/`complexityLabel`/`complexityModelMismatch`/`IssueComplexity` breaks `issues.ts`'s module load immediately, before any individual tool's body is touched. Splitting this across task boundaries would leave every intermediate task's own test run unable to even import the file. Do all of it, then run the full suite once.

**Files:**
- Modify: `mcp/github/src/labels.ts`
- Modify: `mcp/github/src/tools/issues.ts` (import block; `issue_set_type`, `issue_set_complexity`→`issue_set_effort`, `issue_claim`, `issue_open`; new `issue_set_priority`)
- Test: `mcp/github/test/labels.test.ts`, `mcp/github/test/issues.test.ts`

**Interfaces:**
- Consumes: `findProjectItem`, `getProjectField`, `setProjectSingleSelect` from `project.ts` (Task 2).
- Produces:
  - `labels.ts`: `ISSUE_EFFORTS = ["trivial","standard","complex"] as const`, `IssueEffort`; `ISSUE_PRIORITIES = ["urgent","high","medium","low"] as const`, `IssuePriority`; `effortModelMismatch(effort: IssueEffort, callerModel: string): string | null` (replaces `complexityModelMismatch`); `ISSUE_LABELS` drops the `type:*`/`complexity:*` axes; `DEPRECATED_LABELS` gains six entries. `typeLabel`/`nativeTypeName`/`ISSUE_TYPES`/`IssueType` unchanged.
  - `issues.ts`: a shared internal `applyProjectSingleSelect(owner, name, number, fieldName, optionValue)` helper (not exported — module-private) does the resolve-item/resolve-field/resolve-option/set sequence once; `issue_set_effort` (replaces `issue_set_complexity`), `issue_set_priority` (new), and `issue_open`'s best-effort effort/priority blocks all call it instead of duplicating that sequence. `issue_set_type` no longer touches labels; `issue_claim`'s model-mismatch check reads Effort off the project item; `issue_open` drops the `type:*`/`complexity:*` label pushes and gains optional `effort`/`priority` params.

#### Step 1: Write every failing test first

**1a. `labels.test.ts`** — replace the `DEPRECATED_LABELS_FIXTURE`, the `"provisions exactly one label..."` test, the `"includes a complexity:* axis..."` test, and the `describe("complexityModelMismatch", ...)` block:

```ts
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
```

```ts
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
```

Remove the old `"includes a complexity:* axis..."` test and the old `describe("complexityModelMismatch", ...)` block entirely (superseded by the two above).

**1b. `issues.test.ts`** — add the project-tools mock near the top of the file, alongside the existing `execFileMock`/`fetchMock` setup:

```ts
const findProjectItemMock = vi.fn();
const getProjectFieldMock = vi.fn();
const setProjectSingleSelectMock = vi.fn();
vi.mock("../src/project.js", () => ({
  findProjectItem: findProjectItemMock,
  getProjectField: getProjectFieldMock,
  setProjectSingleSelect: setProjectSingleSelectMock,
}));
```

Add to the file's `beforeEach`: `findProjectItemMock.mockReset(); getProjectFieldMock.mockReset(); setProjectSingleSelectMock.mockReset();`

**1c.** `issue_set_type`:

```ts
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
```

**1d.** `issue_set_effort`:

```ts
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
```

**1e.** `issue_set_priority`:

```ts
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
```

**1f.** `issue_claim` — find the existing test(s) covering `caller_model`/`model_mismatch` (search `issues.test.ts` for `caller_model`) and adapt them in place: replace whatever stubs a `complexity:complex` label on the fetched issue with `findProjectItemMock.mockResolvedValue({ id: "PVTI_3", fields: { effort: "complex" } })`, keeping every other part of those tests (the `ghRequest` mocking for the claim flow itself — branch creation, assignee, status) unchanged. Add the assertion:

```ts
expect(JSON.parse(res.content[0].text).model_mismatch).toContain("Effort of complex");
```

**1g.** `issue_open` effort/priority:

```ts
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
```

- [ ] **Step 2: Run both test files to confirm they fail**

Run: `cd mcp/github && npx vitest run test/labels.test.ts test/issues.test.ts`
Expected: FAIL — new names don't exist yet, old behavior still in place.

- [ ] **Step 3: Implement the `labels.ts` changes**

Replace the `ISSUE_COMPLEXITIES`/`IssueComplexity` block (lines ~21-26) with:

```ts
/**
 * How much judgment a task takes, and which model it calls for. Orthogonal to
 * type/status/source — a bug fix and a feature can each be trivial or complex.
 * Lives on the shared Project's Effort field, not a label (see project.ts).
 */
export const ISSUE_EFFORTS = ["trivial", "standard", "complex"] as const;
export type IssueEffort = (typeof ISSUE_EFFORTS)[number];

/** Lives on the shared Project's Priority field, not a label. */
export const ISSUE_PRIORITIES = ["urgent", "high", "medium", "low"] as const;
export type IssuePriority = (typeof ISSUE_PRIORITIES)[number];
```

Remove `complexityLabel` entirely. Remove `COMPLEXITY_STYLES`; add, in its place, a small map used only for the deprecated-label entries below (same three colors):

```ts
const RETIRED_EFFORT_COLORS: Record<IssueEffort, string> = {
  trivial: "8d6e63",
  standard: "4db6ac",
  complex: "e07a5f",
};
```

Rename `COMPLEXITY_MIN_TIER` to `EFFORT_MIN_TIER: Record<IssueEffort, ModelTier>` (same values), and rename+reword `complexityModelMismatch`:

```ts
export function effortModelMismatch(
  effort: IssueEffort,
  callerModel: string,
): string | null {
  const caller = modelTier(callerModel);
  if (!caller) return null;
  const required = EFFORT_MIN_TIER[effort];
  if (MODEL_TIERS.indexOf(caller) >= MODEL_TIERS.indexOf(required)) return null;
  return (
    `caller is running "${callerModel}" (${caller}-tier) but this issue carries an ` +
    `Effort of ${effort}, which calls for ${required}-tier or stronger.`
  );
}
```

Update `ISSUE_LABELS` to drop both axes:

```ts
export const ISSUE_LABELS: LabelSpec[] = [
  ...ISSUE_STATUSES.map((s) => ({ name: statusLabel(s), ...STATUS_STYLES[s] })),
  ...ISSUE_SOURCES.map((s) => ({ name: sourceLabel(s), ...SOURCE_STYLES[s] })),
  ...ISSUE_MARKERS.map((m) => ({ name: m, ...MARKER_STYLES[m] })),
];
```

Extend `DEPRECATED_LABELS` (keep the existing three, append six more — `TYPE_STYLES` stays defined and is now used only here):

```ts
export const DEPRECATED_LABELS: LabelSpec[] = [
  { name: "bug", color: "ededed", description: "DEPRECATED historical label — use type:bug on new work" },
  { name: "enhancement", color: "ededed", description: "DEPRECATED historical label — use type:feature on new work" },
  { name: "documentation", color: "ededed", description: "DEPRECATED historical label — use type:task on new work" },
  ...ISSUE_TYPES.map((t) => ({
    name: typeLabel(t),
    color: TYPE_STYLES[t].color,
    description: `DEPRECATED — use the native GitHub issue type instead of ${typeLabel(t)}`,
  })),
  ...ISSUE_EFFORTS.map((e) => ({
    name: `complexity:${e}`,
    color: RETIRED_EFFORT_COLORS[e],
    description: `DEPRECATED — use the Effort project field instead of complexity:${e}`,
  })),
];
```

`typeLabel`/`nativeTypeName`/`ISSUE_TYPES`/`IssueType` are all unchanged.

- [ ] **Step 4: Implement the `issues.ts` changes**

Update the `labels.js` import block at the top of `issues.ts` (currently lines 12-28):

```ts
import {
  ISSUE_SOURCES,
  ISSUE_STATUSES,
  ISSUE_TYPES,
  ISSUE_EFFORTS,
  ISSUE_PRIORITIES,
  typeLabel,
  nativeTypeName,
  statusLabel,
  sourceLabel,
  effortModelMismatch,
  TRUSTED_SOURCES,
  type IssueEffort,
  type IssueSource,
  type IssueStatus,
  type IssueType,
} from "../labels.js";
```

Add: `import { findProjectItem, getProjectField, setProjectSingleSelect } from "../project.js";`

**`issue_set_type`** (currently lines 304-346) — replace the handler body and description:

```ts
description: "Set an issue's native GitHub issue type (bug/feature/task). No label written — native type is the only source of truth.",
```

```ts
async ({ repo, number, type }) => {
  try {
    const { owner, name } = await resolveRepo(repo);
    await ghRequest(`/repos/${owner}/${name}/issues/${number}`, {
      method: "PATCH",
      body: { type: nativeTypeName(type) },
    });
    return jsonText({ number, type });
  } catch (err) {
    return errorResult(err);
  }
},
```

**`issue_set_complexity` → `issue_set_effort`** (currently lines 348-380) — first add a module-private helper above `registerIssueTools` (or as a top-level function in the file, alongside `defaultStatus`/`resolveAssignees`) that both new tools and `issue_open` share:

```ts
/**
 * Resolve a repo issue to its shared-project item, find the named single-select
 * field, and set it to the option matching `optionValue` (case-insensitive).
 * Throws if the issue isn't a project item, or the field has no such option —
 * callers that want best-effort behavior (issue_open) catch around this;
 * callers that want a hard failure (issue_set_effort/issue_set_priority) let
 * it propagate to their own try/catch.
 */
async function applyProjectSingleSelect(
  owner: string,
  name: string,
  number: number,
  fieldName: string,
  optionValue: string,
): Promise<void> {
  const item = await findProjectItem(owner, name, number);
  if (!item) {
    throw new Error(
      `Issue #${number} in ${owner}/${name} is not on the GarrettMakesItLLC — Work project — add it first.`,
    );
  }
  const field = await getProjectField(fieldName);
  const option = field.options?.find((o) => o.name.toLowerCase() === optionValue);
  if (!option) {
    throw new Error(`${fieldName} field has no "${optionValue}" option.`);
  }
  await setProjectSingleSelect(item.id, field.id, option.id);
}
```

Then replace the `issue_set_complexity` block with both new tools, each a thin wrapper around the helper:

```ts
server.registerTool(
  "issue_set_effort",
  {
    description:
      "Set an issue's Effort field on the shared GarrettMakesItLLC — Work project " +
      "(trivial/standard/complex) — the model-tier signal for subagent dispatch. The issue must " +
      "already be a project item.",
    inputSchema: {
      repo: repoParam,
      number: z.number().int().positive().describe("Issue number."),
      effort: z.enum(ISSUE_EFFORTS).describe("Effort tier."),
    },
  },
  async ({ repo, number, effort }) => {
    try {
      const { owner, name } = await resolveRepo(repo);
      await applyProjectSingleSelect(owner, name, number, "Effort", effort);
      return jsonText({ number, effort });
    } catch (err) {
      return errorResult(err);
    }
  },
);

server.registerTool(
  "issue_set_priority",
  {
    description:
      "Set an issue's Priority field on the shared GarrettMakesItLLC — Work project " +
      "(urgent/high/medium/low). The issue must already be a project item.",
    inputSchema: {
      repo: repoParam,
      number: z.number().int().positive().describe("Issue number."),
      priority: z.enum(ISSUE_PRIORITIES).describe("Priority tier."),
    },
  },
  async ({ repo, number, priority }) => {
    try {
      const { owner, name } = await resolveRepo(repo);
      await applyProjectSingleSelect(owner, name, number, "Priority", priority);
      return jsonText({ number, priority });
    } catch (err) {
      return errorResult(err);
    }
  },
);
```

**`issue_claim`** — replace lines 495-499:

```ts
const item = await findProjectItem(owner, name, number);
const effort = item?.fields.effort as IssueEffort | undefined;
const modelMismatch =
  effort && caller_model ? effortModelMismatch(effort, caller_model) : null;
```

Update the tool's `description` (lines 447-449) to say "Effort field" instead of "`complexity:*` label".

**`issue_open`** — in the `inputSchema`, remove the old `complexity` field (lines 664-670) and add:

```ts
effort: z
  .enum(ISSUE_EFFORTS)
  .optional()
  .describe(
    "How much judgment the task takes: trivial (Haiku-class), standard (Sonnet-class, the " +
      "default), or complex (Opus-class). Set best-effort after creation — if the issue hasn't " +
      "landed on the shared project yet, this is reported in `_warnings` rather than failing " +
      "the whole call.",
  ),
priority: z
  .enum(ISSUE_PRIORITIES)
  .optional()
  .describe("Urgent/high/medium/low. Same best-effort timing as effort."),
```

In the handler signature, replace `complexity` with `effort, priority`. In the labels composition (lines ~692-695), drop the `type`/`complexity` pushes entirely:

```ts
const labels = [statusLabel(effectiveStatus)];
if (source) labels.push(sourceLabel(source));
```

(`type` is still applied via the native-type PATCH a few lines below, unchanged — only its label push is removed.)

After the existing `parent` best-effort block, before the final `ghRequest` re-fetch, add — reusing the same `applyProjectSingleSelect` helper `issue_set_effort`/`issue_set_priority` use, just caught locally instead of propagated, since creation enrichment is best-effort:

```ts
if (effort) {
  try {
    await applyProjectSingleSelect(owner, name, number, "Effort", effort);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    warnings.push(`effort "${effort}" not set: ${msg}`);
  }
}
if (priority) {
  try {
    await applyProjectSingleSelect(owner, name, number, "Priority", priority);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    warnings.push(`priority "${priority}" not set: ${msg}`);
  }
}
```

- [ ] **Step 5: Run both test files to verify they pass**

Run: `cd mcp/github && npx vitest run test/labels.test.ts test/issues.test.ts`
Expected: PASS

- [ ] **Step 6: Typecheck**

Run: `cd mcp/github && npm run typecheck`
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add mcp/github/src/labels.ts mcp/github/src/tools/issues.ts mcp/github/test/labels.test.ts mcp/github/test/issues.test.ts
git commit -m "feat(mcp/github): retire type:*/complexity:* labels for native type + Effort/Priority fields"
```

---

### Task 4: `issue_set_blocked_by` / `issue_list_blocked_by`

Independent of Task 3 — no interaction with type/complexity/effort/priority.

**Files:**
- Modify: `mcp/github/src/tools/issues.ts` (add after `issue_list_sub_issues`)
- Test: `mcp/github/test/issues.test.ts`

**Confirmed live**: `GET /repos/{owner}/{repo}/issues/{number}/dependencies/blocked_by` and `.../blocking` both return 200 with an array (checked against `GarrettMakesItLLC/dotclaude`); `POST .../dependencies/blocked_by` takes `{ "issue_id": <integer database id> }` (confirmed via its validation error, which also names the docs page `rest/issues/issue-dependencies`) and 422s if the id isn't an integer.

- [ ] **Step 1: Write the failing tests**

```ts
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mcp/github && npx vitest run test/issues.test.ts -t "blocked_by"`
Expected: FAIL — neither tool is registered yet.

- [ ] **Step 3: Implement both tools**

Insert after the existing `issue_list_sub_issues` block:

```ts
server.registerTool(
  "issue_set_blocked_by",
  {
    description:
      "Mark an issue as blocked by one or more other issues, in the same repo, using GitHub's " +
      "native issue-dependencies relationship. Already-linked blockers are reported separately " +
      "and not re-posted.",
    inputSchema: {
      repo: repoParam,
      number: z.number().int().positive().describe("The blocked issue's number."),
      blocked_by: z
        .array(z.number().int().positive())
        .min(1)
        .describe("Issue numbers, in the same repo, that block this one."),
    },
  },
  async ({ repo, number, blocked_by }) => {
    try {
      const { owner, name } = await resolveRepo(repo);
      const existing = await ghRequest<{ number: number }[]>(
        `/repos/${owner}/${name}/issues/${number}/dependencies/blocked_by`,
      );
      const existingNumbers = new Set(existing.map((i) => i.number));
      const already_linked = blocked_by.filter((n) => existingNumbers.has(n));
      const toAdd = blocked_by.filter((n) => !existingNumbers.has(n));

      const added: number[] = [];
      for (const blockerNumber of toAdd) {
        const blocker = await ghRequest<{ id: number }>(
          `/repos/${owner}/${name}/issues/${blockerNumber}`,
        );
        await ghRequest(`/repos/${owner}/${name}/issues/${number}/dependencies/blocked_by`, {
          method: "POST",
          body: { issue_id: blocker.id },
        });
        added.push(blockerNumber);
      }

      return jsonText({ number, blocked_by, added, already_linked });
    } catch (err) {
      return errorResult(err);
    }
  },
);

server.registerTool(
  "issue_list_blocked_by",
  {
    description: "List the issue numbers (same repo) that block a given issue.",
    inputSchema: {
      repo: repoParam,
      number: z.number().int().positive().describe("Issue number."),
    },
  },
  async ({ repo, number }) => {
    try {
      const { owner, name } = await resolveRepo(repo);
      const data = await ghRequest<{ number: number }[]>(
        `/repos/${owner}/${name}/issues/${number}/dependencies/blocked_by`,
      );
      return jsonText({ number, blocked_by: data.map((i) => i.number) });
    } catch (err) {
      return errorResult(err);
    }
  },
);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mcp/github && npx vitest run test/issues.test.ts -t "blocked_by"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add mcp/github/src/tools/issues.ts mcp/github/test/issues.test.ts
git commit -m "feat(mcp/github): add issue_set_blocked_by and issue_list_blocked_by tools"
```

---

### Task 5: `labels_ensure`/`labels_audit` regression check

**Files:**
- Read-only check: `mcp/github/src/tools/labels.ts`, `mcp/github/test/labels.test.ts`

Both tools already derive their behavior entirely from `ISSUE_LABELS`/`DEPRECATED_LABELS`/`REMOVABLE_DEFAULT_LABELS` (confirmed by inspection while writing Task 3 — no `type:`/`complexity:` special-casing found outside `labels.ts` itself). No code change expected; this task exists to prove it rather than assume it.

- [ ] **Step 1: Search for any special-casing this plan might have missed**

Run: `cd mcp/github && grep -rn "type:\|complexity:" src/tools/labels.ts`
Expected: no matches (or only matches inside string literals unrelated to the taxonomy) — confirming Task 3's `labels.ts` changes are sufficient on their own.

- [ ] **Step 2: Run the full labels test file**

Run: `cd mcp/github && npx vitest run test/labels.test.ts`
Expected: PASS.

- [ ] **Step 3: No commit** — this task makes no code changes. If Step 1 surfaces something, stop and fold the fix into Task 3 instead of committing here.

---

### Task 6: Doc updates — `CLAUDE.md` and `managing-work-with-issues`

**Files:**
- Modify: `CLAUDE.md:46`
- Modify: `skills/managing-work-with-issues/SKILL.md:4,36-37,59`

- [ ] **Step 1: Update `CLAUDE.md:46`**

Change:
> When a subtask maps to an issue carrying a `complexity:*` label, that label is the answer — otherwise judge it the same way.

To:
> When a subtask maps to an issue carrying an Effort value on the shared project, that's the answer — otherwise judge it the same way.

- [ ] **Step 2: Update `skills/managing-work-with-issues/SKILL.md`**

Line 4 (`allowed-tools`): replace `mcp__github-rest__issue_set_complexity` with `mcp__github-rest__issue_set_effort, mcp__github-rest__issue_set_priority, mcp__github-rest__issue_set_blocked_by, mcp__github-rest__issue_list_blocked_by`.

Lines 36-37, replace:
```
- **type:** `bug` / `feature` / `task`.
- **complexity:** how much judgment a task takes, and which model it calls for. `trivial` — mechanical, single-file, no judgment calls, a Haiku-class task. `standard` — bounded scope, known patterns, the default, Sonnet-class task. `complex` — cross-cutting, ambiguous, or one-way-door, an Opus-class task.
```

With:
```
- **type:** native GitHub issue type — `Bug` / `Feature` / `Task` (`issue_set_type`, or `issue_open`'s `type` param). No label; the native field is the only source of truth.
- **effort:** the shared project's Effort field — how much judgment a task takes, and which model it calls for. `trivial` — mechanical, single-file, no judgment calls, a Haiku-class task. `standard` — bounded scope, known patterns, the default, Sonnet-class task. `complex` — cross-cutting, ambiguous, or one-way-door, an Opus-class task. Set with `issue_set_effort` (or `issue_open`'s `effort` param, once the issue is a project item).
- **priority:** the shared project's Priority field — `urgent` / `high` / `medium` / `low`. Set with `issue_set_priority` (or `issue_open`'s `priority` param).
```

Line 59, replace `type and complexity set` with `type, effort, and priority set`.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md skills/managing-work-with-issues/SKILL.md
git commit -m "docs: point complexity/type automation guidance at the new Effort/Priority fields"
```

---

### Task 7: Full build, typecheck, and test pass

**Files:** none (verification only)

- [ ] **Step 1: Typecheck**

Run: `cd mcp/github && npm run typecheck`
Expected: no errors.

- [ ] **Step 2: Full test suite**

Run: `cd mcp/github && npm test`
Expected: all tests pass.

- [ ] **Step 3: Build**

Run: `cd mcp/github && npm run build`
Expected: clean build, `dist/` updated. (`dist/` is `.gitignore`d — nothing to commit here.)

- [ ] **Step 4: Restart Claude Code**

The new/renamed tools (`issue_set_effort`, `issue_set_priority`, `issue_set_blocked_by`, `issue_list_blocked_by`, the simplified `issue_set_type`) are only callable after a restart — the running MCP server process is still the pre-build code. Note this to whoever picks up the project-schema-setup or fleet-backfill plans next; don't attempt to call these tools in the same session that built them.
