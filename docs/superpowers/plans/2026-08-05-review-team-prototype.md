# Review Team Prototype Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and locally validate the standalone multi-model review-team pipeline (triage → lens dispatch via `opencode`/OpenRouter → structured-output parsing → cross-model verification → comment formatting) as a tested TypeScript package, per Step 1 ("prototype standalone... before wiring up CI") of `docs/superpowers/specs/2026-08-05-review-team-design.md`.

**Architecture:** A single Node/TypeScript package, `tools/review-team/`, exposing pure/testable functions for each pipeline stage (triage, config loading, lens execution, output parsing, dedupe, verification, formatting), composed by one orchestrator function. The only untested surface is the thin CLI entrypoint and the actual `opencode` subprocess call, which is validated manually against real `opencode` output in Task 1 before any parsing code is written against assumed syntax.

**Tech Stack:** TypeScript (strict, `NodeNext` module resolution, ES2022 target — matches `mcp/github`), Vitest, Zod for schema validation, the `yaml` package for config parsing, `picomatch` for glob matching, Node's built-in `child_process`/`node:child_process` for the `opencode` subprocess. No new runtime framework — this mirrors the existing `mcp/github` package shape exactly.

**Confirmed opencode facts this plan relies on** (verified against `opencode.ai/docs/cli/` and `opencode.ai/docs/providers/` before writing any code against them):
- Non-interactive invocation: `opencode run [message..]`.
- Model selection: `--model provider/model` (short form `-m`), e.g. `-m openrouter/moonshotai/kimi-k2`.
- `--format json` returns **raw JSON event stream**, not a clean final answer — NOT usable for structured findings. The pipeline instead relies on a prompt-level contract (final answer ends in a single fenced ` ```json ` block) parsed out of default-format stdout.
- Auth: `opencode` reads `OPENROUTER_API_KEY` directly from the environment at startup — no interactive `/connect` step needed in CI/scripts.
- `--auto` auto-approves permissions (needed for non-interactive runs that touch the filesystem/tools).

## Global Constraints

- TypeScript strict mode, `NodeNext` module/resolution, ES2022 target, `type: "module"` — copied from `mcp/github/tsconfig.json` and `package.json`.
- Test runner: Vitest (`vitest run`), tests colocated as `*.test.ts` next to the source file, no separate `vitest.config.ts` (matches `mcp/github`, which has none).
- No network calls, no real `opencode` subprocess execution in unit tests — every function that shells out takes an injectable function parameter so tests use fakes.
- Findings/config schemas are Zod schemas; invalid input throws with the Zod error, never silently coerces.
- This plan does NOT include: wiring a GitHub Actions workflow, the `GarrettMakesItLLC/ci` composite action, or fetching a live PR diff from GitHub. Those are Step 2/3 of the spec's rollout plan and depend on this prototype's findings (real cost numbers, parsing reliability) — out of scope here by design, not an oversight.

---

### Task 1: Manual opencode + OpenRouter spike (no code)

**Files:** none — this is a manual validation task, its output is a short findings note added to the spec's risk section in a later task.

**Interfaces:** N/A (produces confidence that the "confirmed opencode facts" above are accurate, which every later task's code depends on).

- [ ] **Step 1: Install opencode and obtain an OpenRouter key**

Follow `https://opencode.ai/docs/` install instructions, and create a key at `https://openrouter.ai/settings/keys`.

- [ ] **Step 2: Export the key and run a trivial non-interactive prompt**

```bash
export OPENROUTER_API_KEY=sk-or-...
opencode run "Reply with the literal text OK" --model openrouter/moonshotai/kimi-k2 --auto
```

Expected: the process exits 0 and prints a response containing "OK" to stdout, with no interactive prompt/browser popup. If it fails, this plan's Task 3 assumptions are wrong and must be revised before continuing — stop and re-verify against current opencode docs rather than guessing.

- [ ] **Step 3: Validate the fenced-JSON-block contract on a real diff**

Pick a small real past PR in any repo you have checked out locally. From that checkout:

```bash
git diff main...<branch> > /tmp/sample.diff
opencode run "Review this diff for correctness bugs. Diff: $(cat /tmp/sample.diff). End your response with a single fenced \`\`\`json code block containing a JSON array of objects with keys file, line, description, confidence (0-100). If there are no issues, output an empty array." --model openrouter/moonshotai/kimi-k2 --auto > /tmp/sample-output.txt
cat /tmp/sample-output.txt
```

Expected: stdout contains a single fenced ` ```json ` block near the end, containing a JSON array matching the requested shape. Note any deviations (e.g., extra prose after the block, multiple blocks, malformed JSON) — Task 5's parser must handle whatever the real behavior turns out to be, not the idealized case.

- [ ] **Step 4: Record findings**

Write one paragraph (in the PR description or a scratch note, not a new doc file) covering: did the JSON-block contract work reliably across 2-3 more sample diffs, roughly how many tokens/seconds did one lens run take, and did `--auto` avoid any interactive prompts. This informs whether Task 5's parser needs to be more lenient than the happy path.

---

### Task 2: Package scaffold

**Files:**
- Create: `tools/review-team/package.json`
- Create: `tools/review-team/tsconfig.json`
- Create: `tools/review-team/src/types.ts`

**Interfaces:**
- Produces: `Finding`, `MergedFinding`, `RiskTier`, `DiffStats`, `LensSpec`, `ReviewTeamConfig` types, used by every later task.

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "@garrett/review-team",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "description": "Multi-model PR review pipeline (triage, opencode/OpenRouter lens dispatch, cross-model verification, comment formatting).",
  "scripts": {
    "build": "tsc",
    "typecheck": "tsc --noEmit",
    "test": "vitest run"
  },
  "dependencies": {
    "picomatch": "^4.0.2",
    "yaml": "^2.6.1",
    "zod": "^4.4.3"
  },
  "devDependencies": {
    "@types/node": "^26.0.0",
    "@types/picomatch": "^3.0.1",
    "typescript": "^6.0.3",
    "vitest": "^3.0.0"
  }
}
```

- [ ] **Step 2: Create `tsconfig.json`** (identical to `mcp/github/tsconfig.json`)

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2023"],
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "types": ["node"],
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "declaration": true,
    "sourceMap": true,
    "outDir": "dist",
    "rootDir": "src"
  },
  "include": ["src/**/*.ts"],
  "exclude": ["node_modules", "dist"]
}
```

- [ ] **Step 3: Create `src/types.ts`**

```typescript
export interface Finding {
  file: string;
  line: number;
  description: string;
  confidence: number;
  model: string;
  lens: string;
}

export interface MergedFinding {
  file: string;
  line: number;
  description: string;
  confidence: number;
  models: string[];
  lenses: string[];
}

export interface DiffStats {
  filesChanged: string[];
  linesChanged: number;
}

export type RiskTier = "small" | "standard" | "high";

export interface LensSpec {
  name: string;
  minTier: RiskTier;
  model: string;
  prompt: string;
}

export interface ReviewTeamConfig {
  sensitivePaths: string[];
  sizeThresholds: {
    standardLines: number;
    highLines: number;
  };
  lenses: LensSpec[];
}
```

- [ ] **Step 4: Install dependencies and verify the build**

Run: `cd tools/review-team && npm install && npm run typecheck`
Expected: no errors (there's no code yet beyond `types.ts`, so this just confirms the toolchain is wired correctly).

- [ ] **Step 5: Commit**

```bash
git add tools/review-team/package.json tools/review-team/tsconfig.json tools/review-team/src/types.ts tools/review-team/package-lock.json
git commit -m "chore(review-team): scaffold prototype package"
```

---

### Task 3: Risk-tier triage

**Files:**
- Create: `tools/review-team/src/triage.ts`
- Test: `tools/review-team/src/triage.test.ts`

**Interfaces:**
- Consumes: `DiffStats`, `ReviewTeamConfig`, `RiskTier` from `./types.ts`.
- Produces: `triageRiskTier(diff: DiffStats, config: ReviewTeamConfig): RiskTier`, `tierAtLeast(tier: RiskTier, min: RiskTier): boolean` — both used by Task 8's orchestrator.

- [ ] **Step 1: Write the failing tests**

```typescript
// tools/review-team/src/triage.test.ts
import { describe, expect, it } from "vitest";
import { tierAtLeast, triageRiskTier } from "./triage.js";
import type { ReviewTeamConfig } from "./types.js";

const baseConfig: ReviewTeamConfig = {
  sensitivePaths: ["auth/**", "payments/**"],
  sizeThresholds: { standardLines: 50, highLines: 300 },
  lenses: [],
};

describe("triageRiskTier", () => {
  it("returns small for a tiny diff touching no sensitive paths", () => {
    const tier = triageRiskTier(
      { filesChanged: ["README.md"], linesChanged: 5 },
      baseConfig,
    );
    expect(tier).toBe("small");
  });

  it("returns standard once linesChanged crosses standardLines", () => {
    const tier = triageRiskTier(
      { filesChanged: ["src/util.ts"], linesChanged: 51 },
      baseConfig,
    );
    expect(tier).toBe("standard");
  });

  it("returns high once linesChanged crosses highLines", () => {
    const tier = triageRiskTier(
      { filesChanged: ["src/util.ts"], linesChanged: 301 },
      baseConfig,
    );
    expect(tier).toBe("high");
  });

  it("returns high for any sensitive-path match regardless of size", () => {
    const tier = triageRiskTier(
      { filesChanged: ["auth/login.ts"], linesChanged: 3 },
      baseConfig,
    );
    expect(tier).toBe("high");
  });
});

describe("tierAtLeast", () => {
  it("orders small < standard < high", () => {
    expect(tierAtLeast("standard", "small")).toBe(true);
    expect(tierAtLeast("small", "standard")).toBe(false);
    expect(tierAtLeast("high", "high")).toBe(true);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd tools/review-team && npx vitest run src/triage.test.ts`
Expected: FAIL — `Cannot find module './triage.js'`.

- [ ] **Step 3: Implement `src/triage.ts`**

```typescript
// tools/review-team/src/triage.ts
import picomatch from "picomatch";
import type { DiffStats, ReviewTeamConfig, RiskTier } from "./types.js";

const TIER_ORDER: Record<RiskTier, number> = {
  small: 0,
  standard: 1,
  high: 2,
};

export function tierAtLeast(tier: RiskTier, min: RiskTier): boolean {
  return TIER_ORDER[tier] >= TIER_ORDER[min];
}

export function triageRiskTier(
  diff: DiffStats,
  config: ReviewTeamConfig,
): RiskTier {
  const isMatch = picomatch(config.sensitivePaths);
  const touchesSensitivePath = diff.filesChanged.some((file) =>
    isMatch(file),
  );
  if (touchesSensitivePath) {
    return "high";
  }
  if (diff.linesChanged >= config.sizeThresholds.highLines) {
    return "high";
  }
  if (diff.linesChanged >= config.sizeThresholds.standardLines) {
    return "standard";
  }
  return "small";
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd tools/review-team && npx vitest run src/triage.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add tools/review-team/src/triage.ts tools/review-team/src/triage.test.ts
git commit -m "feat(review-team): add risk-tier triage"
```

---

### Task 4: Config loading and validation

**Files:**
- Create: `tools/review-team/src/config.ts`
- Test: `tools/review-team/src/config.test.ts`
- Create: `tools/review-team/review-team.example.yml`

**Interfaces:**
- Consumes: `ReviewTeamConfig`, `RiskTier` from `./types.ts`.
- Produces: `loadReviewTeamConfig(yamlText: string): ReviewTeamConfig` — used by Task 8's CLI/orchestrator.

- [ ] **Step 1: Write the failing tests**

```typescript
// tools/review-team/src/config.test.ts
import { describe, expect, it } from "vitest";
import { loadReviewTeamConfig } from "./config.js";

const validYaml = `
sensitivePaths:
  - "auth/**"
  - "payments/**"
sizeThresholds:
  standardLines: 50
  highLines: 300
lenses:
  - name: general
    minTier: small
    model: openrouter/moonshotai/kimi-k2
    prompt: "Review for correctness bugs."
  - name: security
    minTier: standard
    model: openrouter/deepseek/deepseek-v3.2
    prompt: "Review for security issues."
`;

describe("loadReviewTeamConfig", () => {
  it("parses a valid config", () => {
    const config = loadReviewTeamConfig(validYaml);
    expect(config.sensitivePaths).toEqual(["auth/**", "payments/**"]);
    expect(config.sizeThresholds).toEqual({ standardLines: 50, highLines: 300 });
    expect(config.lenses).toHaveLength(2);
    expect(config.lenses[0]).toEqual({
      name: "general",
      minTier: "small",
      model: "openrouter/moonshotai/kimi-k2",
      prompt: "Review for correctness bugs.",
    });
  });

  it("defaults sensitivePaths to an empty array when omitted", () => {
    const config = loadReviewTeamConfig(`
sizeThresholds:
  standardLines: 50
  highLines: 300
lenses: []
`);
    expect(config.sensitivePaths).toEqual([]);
  });

  it("throws on an invalid minTier value", () => {
    expect(() =>
      loadReviewTeamConfig(`
sizeThresholds:
  standardLines: 50
  highLines: 300
lenses:
  - name: general
    minTier: extreme
    model: openrouter/x/y
    prompt: "hi"
`),
    ).toThrow();
  });

  it("throws when sizeThresholds is missing", () => {
    expect(() => loadReviewTeamConfig(`lenses: []`)).toThrow();
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd tools/review-team && npx vitest run src/config.test.ts`
Expected: FAIL — `Cannot find module './config.js'`.

- [ ] **Step 3: Implement `src/config.ts`**

```typescript
// tools/review-team/src/config.ts
import { parse } from "yaml";
import { z } from "zod";
import type { ReviewTeamConfig } from "./types.js";

const riskTierSchema = z.enum(["small", "standard", "high"]);

const lensSchema = z.object({
  name: z.string().min(1),
  minTier: riskTierSchema,
  model: z.string().min(1),
  prompt: z.string().min(1),
});

const configSchema = z.object({
  sensitivePaths: z.array(z.string()).default([]),
  sizeThresholds: z.object({
    standardLines: z.number().positive(),
    highLines: z.number().positive(),
  }),
  lenses: z.array(lensSchema),
});

export function loadReviewTeamConfig(yamlText: string): ReviewTeamConfig {
  const parsed = parse(yamlText);
  return configSchema.parse(parsed);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd tools/review-team && npx vitest run src/config.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Write the example config**

```yaml
# tools/review-team/review-team.example.yml
sensitivePaths:
  - "auth/**"
  - "payments/**"
  - "migrations/**"
  - "infra/**"

sizeThresholds:
  standardLines: 50
  highLines: 300

lenses:
  - name: general
    minTier: small
    model: openrouter/moonshotai/kimi-k2
    prompt: |
      You are reviewing a pull request diff for correctness bugs: logic errors,
      off-by-one mistakes, null/undefined handling, incorrect boundary checks.
      Ignore style nitpicks and anything a linter/typechecker would catch.
      End your response with a single fenced ```json code block containing a
      JSON array of objects with keys: file, line, description, confidence
      (0-100). Use an empty array if there are no issues.

  - name: security
    minTier: standard
    model: openrouter/deepseek/deepseek-v3.2
    prompt: |
      You are reviewing a pull request diff for security issues: injection,
      auth/authorization bypass, hardcoded secrets, unsafe deserialization,
      unvalidated input crossing a trust boundary.
      End your response with a single fenced ```json code block containing a
      JSON array of objects with keys: file, line, description, confidence
      (0-100). Use an empty array if there are no issues.

  - name: performance
    minTier: standard
    model: openrouter/qwen/qwen3-coder
    prompt: |
      You are reviewing a pull request diff for performance issues: N+1
      queries, unbounded loops over unbounded data, blocking calls on a hot
      path, quadratic algorithms on inputs that can be large.
      End your response with a single fenced ```json code block containing a
      JSON array of objects with keys: file, line, description, confidence
      (0-100). Use an empty array if there are no issues.

  - name: adversarial
    minTier: high
    model: openrouter/moonshotai/kimi-k2
    prompt: |
      You are trying to break this change. Look for the input, ordering, or
      concurrency scenario the author didn't consider that would make this
      fail in production.
      End your response with a single fenced ```json code block containing a
      JSON array of objects with keys: file, line, description, confidence
      (0-100). Use an empty array if there are no issues.
```

- [ ] **Step 6: Commit**

```bash
git add tools/review-team/src/config.ts tools/review-team/src/config.test.ts tools/review-team/review-team.example.yml
git commit -m "feat(review-team): add config loader and example lens catalog"
```

---

### Task 5: opencode lens runner

**Files:**
- Create: `tools/review-team/src/opencode-runner.ts`
- Test: `tools/review-team/src/opencode-runner.test.ts`

**Interfaces:**
- Consumes: `LensSpec` from `./types.ts`.
- Produces: `LensRunResult` type, `runLens(lens: LensSpec, diffText: string, opts: RunLensOptions): Promise<LensRunResult>` — used by Task 8's orchestrator. `opts.spawnFn` and `opts.timeoutMs` are the injection points Task 8's tests and the guardrail logic rely on.

- [ ] **Step 1: Write the failing tests**

```typescript
// tools/review-team/src/opencode-runner.test.ts
import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import { runLens } from "./opencode-runner.js";
import type { LensSpec } from "./types.js";

const lens: LensSpec = {
  name: "general",
  minTier: "small",
  model: "openrouter/moonshotai/kimi-k2",
  prompt: "Review for bugs.",
};

function fakeProcess() {
  const proc: any = new EventEmitter();
  proc.stdout = new EventEmitter();
  proc.stderr = new EventEmitter();
  proc.kill = vi.fn();
  return proc;
}

describe("runLens", () => {
  it("invokes opencode with the expected args and returns stdout", async () => {
    const proc = fakeProcess();
    const spawnFn = vi.fn(() => proc);

    const resultPromise = runLens(lens, "diff contents", {
      spawnFn,
      timeoutMs: 5000,
    });

    proc.stdout.emit("data", Buffer.from("hello "));
    proc.stdout.emit("data", Buffer.from("world"));
    proc.emit("close", 0);

    const result = await resultPromise;

    expect(spawnFn).toHaveBeenCalledWith(
      "opencode",
      [
        "run",
        expect.stringContaining("Review for bugs."),
        "--model",
        "openrouter/moonshotai/kimi-k2",
        "--auto",
      ],
      expect.any(Object),
    );
    expect(result).toEqual({
      lens: "general",
      model: "openrouter/moonshotai/kimi-k2",
      status: "ok",
      stdout: "hello world",
    });
  });

  it("reports status 'failed' on non-zero exit", async () => {
    const proc = fakeProcess();
    const spawnFn = vi.fn(() => proc);

    const resultPromise = runLens(lens, "diff contents", {
      spawnFn,
      timeoutMs: 5000,
    });

    proc.stdout.emit("data", Buffer.from("partial"));
    proc.emit("close", 1);

    const result = await resultPromise;
    expect(result.status).toBe("failed");
    expect(result.stdout).toBe("partial");
  });

  it("kills the process and reports status 'timeout' when timeoutMs elapses", async () => {
    vi.useFakeTimers();
    const proc = fakeProcess();
    const spawnFn = vi.fn(() => proc);

    const resultPromise = runLens(lens, "diff contents", {
      spawnFn,
      timeoutMs: 1000,
    });

    vi.advanceTimersByTime(1000);
    const result = await resultPromise;

    expect(proc.kill).toHaveBeenCalled();
    expect(result.status).toBe("timeout");
    vi.useRealTimers();
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd tools/review-team && npx vitest run src/opencode-runner.test.ts`
Expected: FAIL — `Cannot find module './opencode-runner.js'`.

- [ ] **Step 3: Implement `src/opencode-runner.ts`**

```typescript
// tools/review-team/src/opencode-runner.ts
import type { ChildProcess, SpawnOptionsWithoutStdio } from "node:child_process";
import { spawn as nodeSpawn } from "node:child_process";
import type { LensSpec } from "./types.js";

export type SpawnFn = (
  command: string,
  args: string[],
  options: SpawnOptionsWithoutStdio,
) => ChildProcess;

export interface RunLensOptions {
  spawnFn?: SpawnFn;
  timeoutMs: number;
  cwd?: string;
}

export interface LensRunResult {
  lens: string;
  model: string;
  status: "ok" | "failed" | "timeout";
  stdout: string;
}

const JSON_BLOCK_INSTRUCTION =
  'End your response with a single fenced ```json code block containing a JSON array of findings (file, line, description, confidence). Use an empty array if there are no issues.';

export function runLens(
  lens: LensSpec,
  diffText: string,
  opts: RunLensOptions,
): Promise<LensRunResult> {
  const spawnFn = opts.spawnFn ?? nodeSpawn;
  const prompt = `${lens.prompt}\n\nDiff:\n${diffText}\n\n${JSON_BLOCK_INSTRUCTION}`;

  return new Promise((resolve) => {
    const proc = spawnFn(
      "opencode",
      ["run", prompt, "--model", lens.model, "--auto"],
      { cwd: opts.cwd },
    );

    let stdout = "";
    let settled = false;

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      proc.kill();
      resolve({ lens: lens.name, model: lens.model, status: "timeout", stdout });
    }, opts.timeoutMs);

    proc.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });

    proc.on("close", (code: number | null) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({
        lens: lens.name,
        model: lens.model,
        status: code === 0 ? "ok" : "failed",
        stdout,
      });
    });
  });
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd tools/review-team && npx vitest run src/opencode-runner.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add tools/review-team/src/opencode-runner.ts tools/review-team/src/opencode-runner.test.ts
git commit -m "feat(review-team): add opencode subprocess runner with timeout guardrail"
```

---

### Task 6: Structured-output parsing

**Files:**
- Create: `tools/review-team/src/parse-findings.ts`
- Test: `tools/review-team/src/parse-findings.test.ts`

**Interfaces:**
- Consumes: `Finding` from `./types.ts`.
- Produces: `parseFindings(stdout: string, lens: string, model: string): Finding[]` — used by Task 8's orchestrator on every `LensRunResult.stdout`.

- [ ] **Step 1: Write the failing tests**

```typescript
// tools/review-team/src/parse-findings.test.ts
import { describe, expect, it } from "vitest";
import { parseFindings } from "./parse-findings.js";

describe("parseFindings", () => {
  it("extracts findings from a well-formed fenced json block", () => {
    const stdout = `Here is my review.\n\n\`\`\`json\n[{"file":"src/a.ts","line":10,"description":"bug","confidence":80}]\n\`\`\`\n`;
    const findings = parseFindings(stdout, "general", "openrouter/x/y");
    expect(findings).toEqual([
      {
        file: "src/a.ts",
        line: 10,
        description: "bug",
        confidence: 80,
        lens: "general",
        model: "openrouter/x/y",
      },
    ]);
  });

  it("returns an empty array when no fenced block is present", () => {
    const findings = parseFindings("no issues found", "general", "openrouter/x/y");
    expect(findings).toEqual([]);
  });

  it("returns an empty array on malformed JSON instead of throwing", () => {
    const stdout = "```json\n[{not valid json}]\n```";
    expect(() => parseFindings(stdout, "general", "openrouter/x/y")).not.toThrow();
    expect(parseFindings(stdout, "general", "openrouter/x/y")).toEqual([]);
  });

  it("uses the last fenced json block when multiple are present", () => {
    const stdout = [
      "```json",
      '[{"file":"draft.ts","line":1,"description":"ignore me","confidence":10}]',
      "```",
      "Actually, final answer:",
      "```json",
      '[{"file":"final.ts","line":2,"description":"real","confidence":90}]',
      "```",
    ].join("\n");
    const findings = parseFindings(stdout, "general", "openrouter/x/y");
    expect(findings).toHaveLength(1);
    expect(findings[0].file).toBe("final.ts");
  });

  it("drops individual entries missing a required field but keeps the rest", () => {
    const stdout = `\`\`\`json\n[{"file":"a.ts","line":1,"description":"ok","confidence":50},{"file":"b.ts"}]\n\`\`\``;
    const findings = parseFindings(stdout, "general", "openrouter/x/y");
    expect(findings).toHaveLength(1);
    expect(findings[0].file).toBe("a.ts");
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd tools/review-team && npx vitest run src/parse-findings.test.ts`
Expected: FAIL — `Cannot find module './parse-findings.js'`.

- [ ] **Step 3: Implement `src/parse-findings.ts`**

```typescript
// tools/review-team/src/parse-findings.ts
import { z } from "zod";
import type { Finding } from "./types.js";

const rawFindingSchema = z.object({
  file: z.string().min(1),
  line: z.number(),
  description: z.string().min(1),
  confidence: z.number().min(0).max(100),
});

const FENCED_JSON_BLOCK = /```json\s*([\s\S]*?)```/g;

export function parseFindings(
  stdout: string,
  lens: string,
  model: string,
): Finding[] {
  const blocks = [...stdout.matchAll(FENCED_JSON_BLOCK)];
  if (blocks.length === 0) {
    return [];
  }
  const lastBlock = blocks[blocks.length - 1][1];

  let parsedJson: unknown;
  try {
    parsedJson = JSON.parse(lastBlock);
  } catch {
    return [];
  }

  if (!Array.isArray(parsedJson)) {
    return [];
  }

  const findings: Finding[] = [];
  for (const item of parsedJson) {
    const result = rawFindingSchema.safeParse(item);
    if (result.success) {
      findings.push({ ...result.data, lens, model });
    }
  }
  return findings;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd tools/review-team && npx vitest run src/parse-findings.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add tools/review-team/src/parse-findings.ts tools/review-team/src/parse-findings.test.ts
git commit -m "feat(review-team): parse findings from opencode fenced-json output"
```

---

### Task 7: Dedupe and cross-model verification

**Files:**
- Create: `tools/review-team/src/dedupe.ts`
- Test: `tools/review-team/src/dedupe.test.ts`
- Create: `tools/review-team/src/verify.ts`
- Test: `tools/review-team/src/verify.test.ts`

**Interfaces:**
- Consumes: `Finding`, `MergedFinding` from `./types.ts`.
- Produces: `dedupeFindings(findings: Finding[]): MergedFinding[]`, `pickVerifierModel(originalModel: string, allModels: string[]): string`, `buildVerifyPrompt(finding: Finding, diffText: string): string`, `parseVerifyResult(stdout: string): { confirmed: boolean; note?: string }` — all used by Task 8's orchestrator for the high-tier path.

- [ ] **Step 1: Write the failing dedupe tests**

```typescript
// tools/review-team/src/dedupe.test.ts
import { describe, expect, it } from "vitest";
import { dedupeFindings } from "./dedupe.js";
import type { Finding } from "./types.js";

const f = (over: Partial<Finding>): Finding => ({
  file: "src/a.ts",
  line: 10,
  description: "issue",
  confidence: 60,
  lens: "general",
  model: "openrouter/x/y",
  ...over,
});

describe("dedupeFindings", () => {
  it("returns an empty array for empty input", () => {
    expect(dedupeFindings([])).toEqual([]);
  });

  it("keeps findings on different files or distant lines separate", () => {
    const result = dedupeFindings([f({ line: 10 }), f({ file: "src/b.ts", line: 10 }), f({ line: 50 })]);
    expect(result).toHaveLength(3);
  });

  it("merges findings on the same file within one line of each other", () => {
    const result = dedupeFindings([
      f({ line: 10, model: "openrouter/x/y", lens: "general", confidence: 60 }),
      f({ line: 11, model: "openrouter/a/b", lens: "security", confidence: 90 }),
    ]);
    expect(result).toHaveLength(1);
    expect(result[0]).toEqual({
      file: "src/a.ts",
      line: 10,
      description: "issue",
      confidence: 90,
      models: ["openrouter/x/y", "openrouter/a/b"],
      lenses: ["general", "security"],
    });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd tools/review-team && npx vitest run src/dedupe.test.ts`
Expected: FAIL — `Cannot find module './dedupe.js'`.

- [ ] **Step 3: Implement `src/dedupe.ts`**

```typescript
// tools/review-team/src/dedupe.ts
import type { Finding, MergedFinding } from "./types.js";

export function dedupeFindings(findings: Finding[]): MergedFinding[] {
  const merged: MergedFinding[] = [];

  for (const finding of findings) {
    const existing = merged.find(
      (m) => m.file === finding.file && Math.abs(m.line - finding.line) <= 1,
    );
    if (existing) {
      existing.confidence = Math.max(existing.confidence, finding.confidence);
      if (!existing.models.includes(finding.model)) {
        existing.models.push(finding.model);
      }
      if (!existing.lenses.includes(finding.lens)) {
        existing.lenses.push(finding.lens);
      }
      continue;
    }
    merged.push({
      file: finding.file,
      line: finding.line,
      description: finding.description,
      confidence: finding.confidence,
      models: [finding.model],
      lenses: [finding.lens],
    });
  }

  return merged;
}
```

- [ ] **Step 4: Run the dedupe tests to verify they pass**

Run: `cd tools/review-team && npx vitest run src/dedupe.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Write the failing verify tests**

```typescript
// tools/review-team/src/verify.test.ts
import { describe, expect, it } from "vitest";
import { buildVerifyPrompt, parseVerifyResult, pickVerifierModel } from "./verify.js";
import type { Finding } from "./types.js";

describe("pickVerifierModel", () => {
  it("picks a model different from the original", () => {
    const picked = pickVerifierModel("openrouter/a/a", [
      "openrouter/a/a",
      "openrouter/b/b",
      "openrouter/c/c",
    ]);
    expect(picked).not.toBe("openrouter/a/a");
    expect(["openrouter/b/b", "openrouter/c/c"]).toContain(picked);
  });

  it("throws if no alternative model exists", () => {
    expect(() => pickVerifierModel("openrouter/a/a", ["openrouter/a/a"])).toThrow();
  });
});

describe("buildVerifyPrompt", () => {
  it("includes the finding description and the diff", () => {
    const finding: Finding = {
      file: "src/a.ts",
      line: 10,
      description: "possible null deref",
      confidence: 70,
      lens: "general",
      model: "openrouter/a/a",
    };
    const prompt = buildVerifyPrompt(finding, "diff text here");
    expect(prompt).toContain("possible null deref");
    expect(prompt).toContain("diff text here");
    expect(prompt).toContain("src/a.ts:10");
  });
});

describe("parseVerifyResult", () => {
  it("parses a confirmed result", () => {
    const stdout = '```json\n{"confirmed": true, "note": "yep"}\n```';
    expect(parseVerifyResult(stdout)).toEqual({ confirmed: true, note: "yep" });
  });

  it("fails closed (confirmed: false) when no block is present", () => {
    expect(parseVerifyResult("no block here")).toEqual({ confirmed: false });
  });

  it("fails closed (confirmed: false) on malformed JSON", () => {
    expect(parseVerifyResult("```json\n{not valid}\n```")).toEqual({ confirmed: false });
  });
});
```

- [ ] **Step 6: Run the verify tests to verify they fail**

Run: `cd tools/review-team && npx vitest run src/verify.test.ts`
Expected: FAIL — `Cannot find module './verify.js'`.

- [ ] **Step 7: Implement `src/verify.ts`**

```typescript
// tools/review-team/src/verify.ts
import { z } from "zod";
import type { Finding } from "./types.js";

export function pickVerifierModel(originalModel: string, allModels: string[]): string {
  const alternative = allModels.find((model) => model !== originalModel);
  if (!alternative) {
    throw new Error(`No verifier model available (only ${originalModel} configured)`);
  }
  return alternative;
}

export function buildVerifyPrompt(finding: Finding, diffText: string): string {
  return [
    `Another reviewer flagged this potential issue in ${finding.file}:${finding.line}:`,
    `"${finding.description}" (confidence: ${finding.confidence}/100)`,
    "",
    "Diff:",
    diffText,
    "",
    'Decide whether this is a real issue. End your response with a single fenced ```json code block: {"confirmed": boolean, "note": string (optional)}.',
  ].join("\n");
}

const verifyResultSchema = z.object({
  confirmed: z.boolean(),
  note: z.string().optional(),
});

const FENCED_JSON_BLOCK = /```json\s*([\s\S]*?)```/g;

export function parseVerifyResult(stdout: string): { confirmed: boolean; note?: string } {
  const blocks = [...stdout.matchAll(FENCED_JSON_BLOCK)];
  if (blocks.length === 0) {
    return { confirmed: false };
  }
  try {
    const parsed = JSON.parse(blocks[blocks.length - 1][1]);
    const result = verifyResultSchema.safeParse(parsed);
    return result.success ? result.data : { confirmed: false };
  } catch {
    return { confirmed: false };
  }
}
```

- [ ] **Step 8: Run the verify tests to verify they pass**

Run: `cd tools/review-team && npx vitest run src/verify.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 9: Commit**

```bash
git add tools/review-team/src/dedupe.ts tools/review-team/src/dedupe.test.ts tools/review-team/src/verify.ts tools/review-team/src/verify.test.ts
git commit -m "feat(review-team): add finding dedupe and cross-model verification"
```

---

### Task 8: Comment formatting and orchestrator

**Files:**
- Create: `tools/review-team/src/format-comment.ts`
- Test: `tools/review-team/src/format-comment.test.ts`
- Create: `tools/review-team/src/orchestrator.ts`
- Test: `tools/review-team/src/orchestrator.test.ts`
- Create: `tools/review-team/src/cli.ts`

**Interfaces:**
- Consumes: everything produced by Tasks 3–7.
- Produces: `formatComment(findings: MergedFinding[], incompleteLenses: string[]): string`, `runReviewTeam(opts: RunReviewTeamOptions): Promise<{ tier: RiskTier; comment: string }>` — `runReviewTeam` is the top-level entrypoint the (out-of-scope, future) GitHub Action step will call.

- [ ] **Step 1: Write the failing format-comment tests**

```typescript
// tools/review-team/src/format-comment.test.ts
import { describe, expect, it } from "vitest";
import { formatComment } from "./format-comment.js";
import type { MergedFinding } from "./types.js";

describe("formatComment", () => {
  it("reports no issues found when there are none", () => {
    const comment = formatComment([], []);
    expect(comment).toContain("No issues found");
  });

  it("lists each finding with file:line and contributing models", () => {
    const findings: MergedFinding[] = [
      {
        file: "src/a.ts",
        line: 10,
        description: "possible null deref",
        confidence: 90,
        models: ["openrouter/a/a", "openrouter/b/b"],
        lenses: ["general", "security"],
      },
    ];
    const comment = formatComment(findings, []);
    expect(comment).toContain("Found 1 issue");
    expect(comment).toContain("src/a.ts:10");
    expect(comment).toContain("possible null deref");
    expect(comment).toContain("openrouter/a/a");
    expect(comment).toContain("openrouter/b/b");
  });

  it("notes lenses that did not complete", () => {
    const comment = formatComment([], ["security"]);
    expect(comment).toContain("security lens did not complete");
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd tools/review-team && npx vitest run src/format-comment.test.ts`
Expected: FAIL — `Cannot find module './format-comment.js'`.

- [ ] **Step 3: Implement `src/format-comment.ts`**

```typescript
// tools/review-team/src/format-comment.ts
import type { MergedFinding } from "./types.js";

export function formatComment(
  findings: MergedFinding[],
  incompleteLenses: string[],
): string {
  const lines: string[] = ["### Review team", ""];

  if (findings.length === 0) {
    lines.push("No issues found.");
  } else {
    lines.push(`Found ${findings.length} issue${findings.length === 1 ? "" : "s"}:`, "");
    findings.forEach((finding, index) => {
      lines.push(
        `${index + 1}. ${finding.description} (${finding.file}:${finding.line}, flagged by ${finding.models.join(", ")})`,
        "",
      );
    });
  }

  if (incompleteLenses.length > 0) {
    lines.push("", ...incompleteLenses.map((lens) => `_${lens} lens did not complete._`));
  }

  lines.push("", "🤖 Generated by the review team (opencode + OpenRouter).");

  return lines.join("\n");
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd tools/review-team && npx vitest run src/format-comment.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Write the failing orchestrator tests**

```typescript
// tools/review-team/src/orchestrator.test.ts
import { describe, expect, it, vi } from "vitest";
import { runReviewTeam } from "./orchestrator.js";
import type { LensRunResult } from "./opencode-runner.js";
import type { LensSpec, ReviewTeamConfig } from "./types.js";

const config: ReviewTeamConfig = {
  sensitivePaths: ["auth/**"],
  sizeThresholds: { standardLines: 50, highLines: 300 },
  lenses: [
    { name: "general", minTier: "small", model: "openrouter/a/a", prompt: "general" },
    { name: "security", minTier: "standard", model: "openrouter/b/b", prompt: "security" },
    { name: "adversarial", minTier: "high", model: "openrouter/c/c", prompt: "adversarial" },
  ],
};

function jsonBlock(payload: unknown): string {
  return "```json\n" + JSON.stringify(payload) + "\n```";
}

describe("runReviewTeam", () => {
  it("only runs the small-tier lens for a small diff", async () => {
    const runLensFn = vi.fn(
      async (): Promise<LensRunResult> => ({
        lens: "general",
        model: "openrouter/a/a",
        status: "ok",
        stdout: jsonBlock([]),
      }),
    );

    const result = await runReviewTeam({
      diffStats: { filesChanged: ["README.md"], linesChanged: 5 },
      diffText: "diff",
      config,
      runLensFn,
    });

    expect(result.tier).toBe("small");
    expect(runLensFn).toHaveBeenCalledTimes(1);
    expect(runLensFn.mock.calls[0][0].name).toBe("general");
  });

  it("runs general+security for a standard diff and merges findings", async () => {
    const runLensFn = vi.fn(async (lens: LensSpec): Promise<LensRunResult> => ({
      lens: lens.name,
      model: lens.model,
      status: "ok",
      stdout: jsonBlock([
        { file: "src/a.ts", line: 10, description: `${lens.name} issue`, confidence: 70 },
      ]),
    }));

    const result = await runReviewTeam({
      diffStats: { filesChanged: ["src/a.ts"], linesChanged: 60 },
      diffText: "diff",
      config,
      runLensFn,
    });

    expect(result.tier).toBe("standard");
    expect(runLensFn).toHaveBeenCalledTimes(2);
    expect(result.comment).toContain("Found 1 issue");
  });

  it("runs the verify pass for a high-tier diff and drops unconfirmed findings", async () => {
    const runLensFn = vi.fn(async (lens: LensSpec): Promise<LensRunResult> => {
      if (lens.name === "verify") {
        return {
          lens: "verify",
          model: lens.model,
          status: "ok",
          stdout: jsonBlock({ confirmed: false }),
        };
      }
      return {
        lens: lens.name,
        model: lens.model,
        status: "ok",
        stdout: jsonBlock([
          { file: "auth/login.ts", line: 1, description: `${lens.name} issue`, confidence: 70 },
        ]),
      };
    });

    const result = await runReviewTeam({
      diffStats: { filesChanged: ["auth/login.ts"], linesChanged: 5 },
      diffText: "diff",
      config,
      runLensFn,
    });

    expect(result.tier).toBe("high");
    expect(result.comment).toContain("No issues found");
  });

  it("notes a lens as incomplete instead of throwing when it fails", async () => {
    const runLensFn = vi.fn(async (lens: LensSpec): Promise<LensRunResult> => {
      if (lens.name === "security") {
        return { lens: "security", model: lens.model, status: "timeout", stdout: "" };
      }
      return { lens: lens.name, model: lens.model, status: "ok", stdout: jsonBlock([]) };
    });

    const result = await runReviewTeam({
      diffStats: { filesChanged: ["src/a.ts"], linesChanged: 60 },
      diffText: "diff",
      config,
      runLensFn,
    });

    expect(result.comment).toContain("security lens did not complete");
  });
});
```

- [ ] **Step 6: Run the tests to verify they fail**

Run: `cd tools/review-team && npx vitest run src/orchestrator.test.ts`
Expected: FAIL — `Cannot find module './orchestrator.js'`.

- [ ] **Step 7: Implement `src/orchestrator.ts`**

```typescript
// tools/review-team/src/orchestrator.ts
import { formatComment } from "./format-comment.js";
import { dedupeFindings } from "./dedupe.js";
import type { LensRunResult, RunLensOptions } from "./opencode-runner.js";
import { parseFindings } from "./parse-findings.js";
import { tierAtLeast, triageRiskTier } from "./triage.js";
import type { DiffStats, Finding, LensSpec, ReviewTeamConfig, RiskTier } from "./types.js";
import { buildVerifyPrompt, parseVerifyResult, pickVerifierModel } from "./verify.js";

export interface RunReviewTeamOptions {
  diffStats: DiffStats;
  diffText: string;
  config: ReviewTeamConfig;
  runLensFn: (lens: LensSpec, diffText: string, opts: RunLensOptions) => Promise<LensRunResult>;
  timeoutMs?: number;
}

export interface RunReviewTeamResult {
  tier: RiskTier;
  comment: string;
}

export async function runReviewTeam(
  opts: RunReviewTeamOptions,
): Promise<RunReviewTeamResult> {
  const tier = triageRiskTier(opts.diffStats, opts.config);
  const selectedLenses = opts.config.lenses.filter((lens) =>
    tierAtLeast(tier, lens.minTier),
  );

  const allFindings: Finding[] = [];
  const incompleteLenses: string[] = [];

  for (const lens of selectedLenses) {
    const result = await opts.runLensFn(lens, opts.diffText, {
      timeoutMs: opts.timeoutMs ?? 120_000,
    });
    if (result.status !== "ok") {
      incompleteLenses.push(lens.name);
      continue;
    }
    allFindings.push(...parseFindings(result.stdout, lens.name, lens.model));
  }

  let survivingFindings = allFindings;

  if (tier === "high" && allFindings.length > 0) {
    const allModels = opts.config.lenses.map((lens) => lens.model);
    const confirmed: Finding[] = [];
    for (const finding of allFindings) {
      const verifierModel = pickVerifierModel(finding.model, allModels);
      const verifyLens: LensSpec = {
        name: "verify",
        minTier: "high",
        model: verifierModel,
        prompt: buildVerifyPrompt(finding, opts.diffText),
      };
      const verifyResult = await opts.runLensFn(verifyLens, opts.diffText, {
        timeoutMs: opts.timeoutMs ?? 120_000,
      });
      if (verifyResult.status !== "ok") {
        continue;
      }
      const { confirmed: isConfirmed } = parseVerifyResult(verifyResult.stdout);
      if (isConfirmed) {
        confirmed.push(finding);
      }
    }
    survivingFindings = confirmed;
  }

  const merged = dedupeFindings(survivingFindings);
  const comment = formatComment(merged, incompleteLenses);

  return { tier, comment };
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd tools/review-team && npx vitest run src/orchestrator.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 9: Write the thin CLI entrypoint**

```typescript
// tools/review-team/src/cli.ts
import { readFileSync } from "node:fs";
import { runLens } from "./opencode-runner.js";
import { loadReviewTeamConfig } from "./config.js";
import { runReviewTeam } from "./orchestrator.js";
import type { DiffStats } from "./types.js";

function parseDiffStats(diffText: string): DiffStats {
  const filesChanged = [...diffText.matchAll(/^diff --git a\/(\S+) /gm)].map(
    (match) => match[1],
  );
  const linesChanged = [...diffText.matchAll(/^[+-](?![+-])/gm)].length;
  return { filesChanged, linesChanged };
}

async function main(): Promise<void> {
  const [, , diffPath, configPath] = process.argv;
  if (!diffPath || !configPath) {
    console.error("Usage: review-team <diff-file> <config-file>");
    process.exitCode = 1;
    return;
  }

  const diffText = readFileSync(diffPath, "utf8");
  const config = loadReviewTeamConfig(readFileSync(configPath, "utf8"));
  const diffStats = parseDiffStats(diffText);

  const { tier, comment } = await runReviewTeam({
    diffStats,
    diffText,
    config,
    runLensFn: runLens,
  });

  console.log(`tier: ${tier}\n\n${comment}`);
}

main();
```

Note: this entrypoint is intentionally untested (thin glue over already-tested functions) and is what you run manually in Task 9 against real `opencode` output — it is not wired into CI by this plan.

- [ ] **Step 10: Run the full test suite**

Run: `cd tools/review-team && npm run typecheck && npm test`
Expected: typecheck passes with no errors; all tests across every file pass.

- [ ] **Step 11: Commit**

```bash
git add tools/review-team/src/format-comment.ts tools/review-team/src/format-comment.test.ts tools/review-team/src/orchestrator.ts tools/review-team/src/orchestrator.test.ts tools/review-team/src/cli.ts
git commit -m "feat(review-team): add comment formatting, orchestrator, and CLI entrypoint"
```

---

### Task 9: Real-world validation run

**Files:** none — this exercises the CLI built in Task 8 against a real diff and real `opencode`/OpenRouter calls, to gather the accuracy/cost data the spec's rollout step 1 requires before anyone builds the GitHub Actions wiring.

**Interfaces:** N/A.

- [ ] **Step 1: Run the CLI against a real small diff**

```bash
cd tools/review-team
export OPENROUTER_API_KEY=sk-or-...
git diff main...<some-branch> > /tmp/real.diff
npx tsx src/cli.ts /tmp/real.diff review-team.example.yml
```

Expected: prints `tier: small` (or whatever the diff's size implies) followed by a formatted comment. If it throws, the failure is almost certainly in the fenced-JSON-block contract not matching what real `opencode` output looks like for this prompt/model combination — revisit Task 6's parser against the actual captured stdout, don't just retry.

- [ ] **Step 2: Run it against a diff large/sensitive enough to hit the high tier**

Repeat Step 1 with a diff that touches a path matching `review-team.example.yml`'s `sensitivePaths`, or exceeds `highLines`. Confirm the verify pass fires (visible via added latency/output) and that the final comment only contains confirmed findings.

- [ ] **Step 3: Record cost and accuracy notes**

For 3-5 real diffs across tiers, note: total wall-clock time per tier, rough OpenRouter dollar cost per tier (from the OpenRouter dashboard usage page), and whether findings looked reasonable (spot-check, not exhaustive). This data is what determines whether Step 2/3 of the spec's rollout plan (wiring into dotclaude's CI, then product repos) is worth doing as designed — it is the deliverable of this entire plan, not a footnote.
