# Model-Selection Complexity Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `complexity:trivial/standard/complex` label axis to the shared GitHub label taxonomy (`mcp/github`), provision it fleet-wide, backfill existing open issues, and add the subagent-dispatch model-selection rule to global `CLAUDE.md` — so tasks route to Haiku/Sonnet/Opus by actual complexity instead of habit.

**Architecture:** `mcp/github/src/labels.ts` is the taxonomy's single source of truth — `labels_ensure`/`labels_audit` already provision/audit whatever is in its exported `ISSUE_LABELS` array, so adding a fourth axis there is enough to make it fleet-wide with zero changes to those two tools. `issue_open` (the all-in-one issue-creation tool) gets an optional `complexity` param composed into its label set the same way `type`/`source` already are. A new `issue_set_complexity` tool mirrors the existing `issue_set_type` (label-replace only — GitHub has no native complexity field to mirror, unlike issue type). `CLAUDE.md` gets one new rule line; no code there.

**Tech Stack:** TypeScript, Zod, Vitest, the existing `mcp/github` tool-registration pattern (`server.registerTool`, `ghRequest`, `jsonText`/`errorResult`).

## Global Constraints

- Three tiers only: `trivial` → Haiku, `standard` → Sonnet (default), `complex` → Opus. No native GitHub field for complexity — label only.
- New label colors must be distinct from every existing label's color — `test/labels.test.ts`'s `"gives every label a distinct name and color"` test enforces this automatically; picked colors (verified against every existing `STATUS_STYLES`/`TYPE_STYLES`/`MARKER_STYLES`/`SOURCE_STYLES` entry) are `b4e7ce` (trivial), `cfe2f3` (standard), `e07a5f` (complex).
- No `any` in `src/`; match existing style exactly (zod schema, `ghRequest`/`errorResult`/`jsonText`, `.js` import specifiers).
- Verify with `npm run typecheck && npm test && npm run build` in `mcp/github` after every task that touches its code.
- **The running MCP server only serves a new/changed tool after `npm run build` in `mcp/github` AND a Claude Code restart.** The fleet-wide provisioning task (running `labels_ensure` per repo) and the backfill sweep cannot run in the same session that builds this code — Task 6 below documents the exact commands for the next session instead of running them now.
- dotclaude is `autonomous-merge` and single-tier: commit directly to `main`, no PR needed.

---

### Task 1: Add the `complexity:*` label axis to `labels.ts`

**Files:**
- Modify: `mcp/github/src/labels.ts`
- Test: `mcp/github/test/labels.test.ts`

**Interfaces:**
- Produces: `ISSUE_COMPLEXITIES` (`readonly ["trivial", "standard", "complex"]`), `type IssueComplexity`, `complexityLabel(c: IssueComplexity): string` (returns `` `complexity:${c}` ``) — consumed by Task 2 and Task 3.
- `ISSUE_LABELS` gains three entries (`complexity:trivial`, `complexity:standard`, `complexity:complex`) — consumed transitively by `labels_ensure`/`labels_audit` (no code change needed in `src/tools/labels.ts`).

- [ ] **Step 1: Write the failing test**

Add to `mcp/github/test/labels.test.ts`, inside the existing top-level `describe` block that already has `"gives every label a distinct name and color..."` (do not create a new describe block — this belongs with the other taxonomy-shape assertions):

```typescript
  it("includes a complexity:* axis with exactly three tiers", async () => {
    const { ISSUE_COMPLEXITIES, ISSUE_LABELS, complexityLabel } = await import("../src/labels.js");
    expect([...ISSUE_COMPLEXITIES].sort()).toEqual(["complex", "standard", "trivial"]);
    for (const c of ISSUE_COMPLEXITIES) {
      expect(ISSUE_LABELS.some((l) => l.name === complexityLabel(c))).toBe(true);
    }
    expect(complexityLabel("trivial")).toBe("complexity:trivial");
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp/github && npx vitest run test/labels.test.ts -t "includes a complexity"`
Expected: FAIL — `ISSUE_COMPLEXITIES` (or `complexityLabel`) is not exported / undefined.

- [ ] **Step 3: Implement**

In `mcp/github/src/labels.ts`, add after the `ISSUE_TYPES` block (right after `export type IssueType = ...`):

```typescript
/**
 * How much judgment a task takes, and which model it calls for. Orthogonal to
 * type/status/source — a bug fix and a feature can each be trivial or complex.
 */
export const ISSUE_COMPLEXITIES = ["trivial", "standard", "complex"] as const;
export type IssueComplexity = (typeof ISSUE_COMPLEXITIES)[number];
```

Add a new styles record after `TYPE_STYLES`:

```typescript
const COMPLEXITY_STYLES: Record<IssueComplexity, LabelStyle> = {
  trivial: {
    color: "b4e7ce",
    description: "Mechanical, single-file, no judgment calls — a Haiku-class task",
  },
  standard: {
    color: "cfe2f3",
    description: "Bounded scope, known patterns — the default, Sonnet-class task",
  },
  complex: {
    color: "e07a5f",
    description: "Cross-cutting, ambiguous, or one-way-door — an Opus-class task",
  },
};
```

Add the label-name helper after `typeLabel`:

```typescript
/** The `complexity:*` label name for a complexity value. */
export function complexityLabel(complexity: IssueComplexity): string {
  return `complexity:${complexity}`;
}
```

Add complexity entries to `ISSUE_LABELS` (append after the `ISSUE_TYPES.map(...)` line, before `ISSUE_SOURCES.map(...)`):

```typescript
export const ISSUE_LABELS: LabelSpec[] = [
  ...ISSUE_STATUSES.map((s) => ({ name: statusLabel(s), ...STATUS_STYLES[s] })),
  ...ISSUE_TYPES.map((t) => ({ name: typeLabel(t), ...TYPE_STYLES[t] })),
  ...ISSUE_COMPLEXITIES.map((c) => ({ name: complexityLabel(c), ...COMPLEXITY_STYLES[c] })),
  ...ISSUE_SOURCES.map((s) => ({ name: sourceLabel(s), ...SOURCE_STYLES[s] })),
  ...ISSUE_MARKERS.map((m) => ({ name: m, ...MARKER_STYLES[m] })),
];
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp/github && npx vitest run test/labels.test.ts`
Expected: PASS, including the pre-existing `"gives every label a distinct name and color"` test (confirms no color collision) and the pre-existing `labels_ensure`/`labels_audit` tests (which reference `ISSUE_LABELS.length`, so they scale automatically).

- [ ] **Step 5: Typecheck**

Run: `cd mcp/github && npm run typecheck`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add mcp/github/src/labels.ts mcp/github/test/labels.test.ts
git commit -m "feat(mcp): add complexity:* label axis (trivial/standard/complex)"
```

---

### Task 2: Add the `issue_set_complexity` tool

**Files:**
- Modify: `mcp/github/src/tools/issues.ts`
- Test: `mcp/github/test/issues.test.ts`

**Interfaces:**
- Consumes: `ISSUE_COMPLEXITIES`, `complexityLabel`, `type IssueComplexity` from Task 1's `../labels.js`.
- Produces: registered tool `issue_set_complexity(repo, number, complexity)` → `{ number, complexity, labels }`, mirroring `issue_set_type`'s return shape (label-replace only, no native-field PATCH).

- [ ] **Step 1: Write the failing test**

Add to `mcp/github/test/issues.test.ts`, directly after the existing `describe("issue_set_type", ...)` block:

```typescript
describe("issue_set_complexity", () => {
  it("replaces complexity:* labels, preserving non-complexity labels", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "GET" && url.endsWith("/issues/7")) {
        return makeResponse({
          status: 200,
          body: { labels: [{ name: "complexity:trivial" }, { name: "status:ready" }] },
        });
      }
      if (init.method === "PUT" && url.endsWith("/labels")) {
        const sent = JSON.parse(init.body as string).labels as string[];
        expect(sent).toContain("complexity:complex");
        expect(sent).toContain("status:ready");
        expect(sent).not.toContain("complexity:trivial");
        return makeResponse({ status: 200, body: sent.map((n) => ({ name: n })) });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_set_complexity");
    const res = await handler({ repo: "octo/repo", number: 7, complexity: "complex" });
    expect(res.isError).toBeFalsy();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp/github && npx vitest run test/issues.test.ts -t "issue_set_complexity"`
Expected: FAIL — `issue_set_complexity not registered`.

- [ ] **Step 3: Implement**

In `mcp/github/src/tools/issues.ts`, update the import from `../labels.js` to include the new exports:

```typescript
import {
  ISSUE_SOURCES,
  ISSUE_STATUSES,
  ISSUE_TYPES,
  ISSUE_COMPLEXITIES,
  typeLabel,
  nativeTypeName,
  statusLabel,
  sourceLabel,
  complexityLabel,
  TRUSTED_SOURCES,
  type IssueSource,
  type IssueStatus,
  type IssueType,
  type IssueComplexity,
} from "../labels.js";
```

Add the new tool registration directly after the existing `issue_set_type` block (after its closing `);`):

```typescript
  server.registerTool(
    "issue_set_complexity",
    {
      description:
        "Set an issue's complexity:* label (trivial/standard/complex), replacing any existing " +
        "complexity:* label. No native GitHub field to mirror — label only, unlike issue_set_type.",
      inputSchema: {
        repo: repoParam,
        number: z.number().int().positive().describe("Issue number."),
        complexity: z.enum(ISSUE_COMPLEXITIES).describe("Complexity tier."),
      },
    },
    async ({ repo, number, complexity }) => {
      try {
        const { owner, name } = await resolveRepo(repo);

        const issue = await ghRequest<{ labels: { name: string }[] }>(
          `/repos/${owner}/${name}/issues/${number}`,
        );
        const kept = issue.labels
          .map((l) => l.name)
          .filter((n) => !n.startsWith("complexity:"));
        const next = [...kept, complexityLabel(complexity)];
        const data = await ghRequest<RawLabel[]>(
          `/repos/${owner}/${name}/issues/${number}/labels`,
          { method: "PUT", body: { labels: next } },
        );
        return jsonText({ number, complexity, labels: labelNames(data) });
      } catch (err) {
        return errorResult(err);
      }
    },
  );
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp/github && npx vitest run test/issues.test.ts -t "issue_set_complexity"`
Expected: PASS.

- [ ] **Step 5: Typecheck and full test run**

Run: `cd mcp/github && npm run typecheck && npx vitest run`
Expected: all pass — `IssueComplexity` type is imported but this task doesn't use it as a standalone annotation anywhere yet (Task 3 does); if `tsc` flags it as unused, that's expected until Task 3 lands in the same file, so run this check again at the end of Task 3 rather than treating an unused-import warning here as a blocker.

- [ ] **Step 6: Commit**

```bash
git add mcp/github/src/tools/issues.ts mcp/github/test/issues.test.ts
git commit -m "feat(mcp): add issue_set_complexity tool"
```

---

### Task 3: Add `complexity` to `issue_open`

**Files:**
- Modify: `mcp/github/src/tools/issues.ts`
- Test: `mcp/github/test/issues.test.ts`

**Interfaces:**
- Consumes: `ISSUE_COMPLEXITIES`, `complexityLabel` (already imported in Task 2).
- Produces: `issue_open`'s schema gains optional `complexity`; its label composition includes `complexity:*` when passed, alongside `type:*`/`source:*`/`status:*`.

- [ ] **Step 1: Write the failing test**

Add to `mcp/github/test/issues.test.ts`, inside the existing `describe("issue_open", ...)` block (add as a new `it`, alongside its sibling tests — read the existing tests in that block first to match its exact mocking style before adding this one):

```typescript
  it("includes complexity:* in the label set when complexity is passed", async () => {
    fetchMock.mockImplementation(async (url: string, init: { method?: string; body?: string }) => {
      if (init.method === "POST" && url.endsWith("/issues")) {
        const body = JSON.parse(init.body as string);
        expect(body.labels).toContain("complexity:complex");
        return makeResponse({ status: 201, body: { number: 42, id: 1001 } });
      }
      if (init.method === "GET" && url.endsWith("/issues/42")) {
        return makeResponse({ status: 200, body: { number: 42, labels: [{ name: "complexity:complex" }] } });
      }
      return makeResponse({ status: 500 });
    });
    const handler = await getIssueHandler("issue_open");
    const res = await handler({ repo: "octo/repo", title: "Something hard", complexity: "complex" });
    expect(res.isError).toBeFalsy();
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp/github && npx vitest run test/issues.test.ts -t "includes complexity"`
Expected: FAIL — either a zod validation error (`complexity` not in schema) or the label assertion fails because `complexity:complex` is missing from the composed label set.

- [ ] **Step 3: Implement**

In `mcp/github/src/tools/issues.ts`, add to `issue_open`'s `inputSchema` (directly after the existing `source` field):

```typescript
        complexity: z
          .enum(ISSUE_COMPLEXITIES)
          .optional()
          .describe(
            "How much judgment the task takes: trivial (Haiku-class), standard (Sonnet-class, " +
              "the default), or complex (Opus-class, cross-cutting/ambiguous/one-way-door).",
          ),
```

Update the handler's destructured params and label composition (the existing line reads
`async ({ repo, title, body, type, status, source, milestone, parent, assignees }) => {`):

```typescript
    async ({ repo, title, body, type, status, source, complexity, milestone, parent, assignees }) => {
      try {
        const { owner, name } = await resolveRepo(repo);
        const effectiveStatus: IssueStatus = status ?? defaultStatus(source, type);

        const labels = [statusLabel(effectiveStatus)];
        if (type) labels.push(typeLabel(type));
        if (source) labels.push(sourceLabel(source));
        if (complexity) labels.push(complexityLabel(complexity));
```

(Everything after this in the handler is unchanged — leave the rest of `issue_open`'s body exactly as it is.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp/github && npx vitest run test/issues.test.ts`
Expected: all PASS, including the new test and every pre-existing `issue_open` test.

- [ ] **Step 5: Full verify**

Run: `cd mcp/github && npm run typecheck && npx vitest run && npm run build`
Expected: typecheck clean, all tests pass, build succeeds with no errors. This is the full verification bar for this task since it's the last code change in this file.

- [ ] **Step 6: Commit**

```bash
git add mcp/github/src/tools/issues.ts mcp/github/test/issues.test.ts
git commit -m "feat(mcp): add complexity param to issue_open"
```

---

### Task 4: Add the subagent-dispatch rule to `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md:` (Execution section)

**Interfaces:** none — documentation only.

- [ ] **Step 1: Read the current Execution section**

```bash
grep -n "^## Execution" -A 15 CLAUDE.md
```

Confirm the section still reads as it did at the start of this plan (the escalation-ladder bullet: "Escalate inline → one subagent → parallel subagents / `Workflow` → agent teams...").

- [ ] **Step 2: Add the new bullet**

Insert this as a new bullet directly after the "Escalate inline → ..." bullet in the `## Execution` section:

```markdown
- **Set the model by the subtask's own complexity, not by inheriting the session's.** `Agent` and `Workflow`'s `agent()` calls both take a `model` param — use it: mechanical, single-file, no-judgment-call work (Haiku-class) shouldn't ride on an Opus session, and genuinely cross-cutting/ambiguous/one-way-door work (Opus-class) shouldn't be quietly done at Sonnet just because that's the session default. When a subtask maps to an issue carrying a `complexity:*` label, that label is the answer — otherwise judge it the same way.
```

- [ ] **Step 3: Verify**

```bash
grep -n "Set the model by the subtask" CLAUDE.md
git diff CLAUDE.md
```

Expected: one match; diff shows exactly one added bullet, nothing else touched.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add subagent model-selection-by-complexity rule"
```

---

### Task 5: Push and confirm

**Files:** none (git operations only).

- [ ] **Step 1: Push**

```bash
git push
```

- [ ] **Step 2: Confirm the build is still clean end-to-end**

```bash
cd mcp/github && npm run typecheck && npx vitest run && npm run build
```

Expected: clean. This is the same command as Task 3 Step 5, re-run once more after Task 4's unrelated doc commit to confirm nothing regressed in between.

---

### Task 6: Record the post-restart provisioning steps (not runnable this session)

**Files:** none — this task only records commands for a future session; nothing here is executed now.

**Why this task exists:** per the Global Constraints, the running MCP server only serves `issue_set_complexity` and `issue_open`'s new `complexity` param after `npm run build` in `mcp/github` (done in Task 3) **and** a Claude Code restart. `labels_ensure` (unchanged code, but now provisioning three new entries from `ISSUE_LABELS`) needs the restart too, since the server process holding the old `ISSUE_LABELS` array is still running until then.

- [ ] **Step 1: Record the fleet-wide provisioning command, to run after the next Claude Code restart**

```bash
for repo in GarrettMakesItLLC/MuscleBuddy GarrettMakesItLLC/RedThreadEvents GarrettMakesItLLC/AdventureOS GarrettMakesItLLC/NetWorthy GarrettMakesItLLC/dotclaude GarrettMakesItLLC/ci; do
  echo "=== $repo ==="
  # Use the labels_ensure MCP tool (mcp__github-rest__labels_ensure), not gh api directly —
  # it composes create-or-update per label and reports a created/updated summary.
done
```

Note for whoever runs this: call the `labels_ensure` tool once per repo above (`repo: "<owner/name>"`), not a raw loop — it's an MCP tool call, not a shell command. List it out per repo rather than scripting the loop, so a failure on one repo is visible instead of silently continuing.

- [ ] **Step 2: Record the backfill sweep, to run after Step 1's provisioning succeeds**

For each repo in the list above: list open issues (`issue_list` with `state: open`), and for each one without a `complexity:*` label, call `issue_set_complexity` with a tier judged from the issue's title/body/type using the same heuristic from the design spec (`docs/superpowers/specs/2026-08-01-model-selection-complexity-labels-design.md`): mechanical/single-file/no-judgment → `trivial`; bounded/known-pattern/default → `standard`; cross-cutting/ambiguous/one-way-door/multi-repo → `complex`. One-time sweep — do not make this a recurring job.

- [ ] **Step 3: No commit** (this task only recorded instructions; nothing was executed or changed on disk beyond this plan file itself, which isn't committed per the writing-plans convention)

---

## Self-Review Notes

- **Spec coverage:** Tiers/mapping (Global Constraints + Task 1's colors), taxonomy source of truth + `labels_ensure`/`labels_audit` zero-touch (Task 1's Architecture note, verified against real `src/tools/labels.ts` which iterates `ISSUE_LABELS` directly), `issue_open`'s complexity param (Task 3), `issue_set_complexity` tool (Task 2), issue-label application at creation + backfill (Task 6), subagent dispatch rule (Task 4), mid-task self-escalation and opencode auto-dispatch explicitly out of scope (not built anywhere in this plan — correctly absent).
- **Placeholder scan:** no TBD/TODO; every code block is real, matching the actual current file contents read during planning (not invented).
- **Type/name consistency:** `ISSUE_COMPLEXITIES` / `IssueComplexity` / `complexityLabel` used identically across Tasks 1–3; `issue_set_complexity`'s param name `complexity` matches `issue_open`'s new param name.
- **Restart constraint honored:** Task 6 is explicitly non-executable this session and says so, rather than pretending `labels_ensure` can run now against code that isn't loaded yet.
