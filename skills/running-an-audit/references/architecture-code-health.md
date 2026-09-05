# Architecture & code health

The question: **does the code still have the shape its own documentation claims, and will the next change land where the docs say it should?** Findings are boundary violations, load-bearing duplication, and drift between what `ARCHITECTURE.md` / the rules files say and what the tree does.

Shares surfaces with `test-ci-gate-integrity` (a boundary with a lint rule that doesn't fire belongs there) and `resilience-dependencies` (an unmaintained dependency belongs there; a dependency imported across a forbidden boundary belongs here).

## Checklist

- **Dependency boundaries, enforced or aspirational.** For each documented rule (engine imports only types; web never imports server; native consumes web's build output only), find the mechanism: an ESLint `no-restricted-imports`, a dependency-cruiser config, a tsconfig `paths` absence, a test. Then look for a violation the mechanism misses — a dynamic import, a `require`, a type-only import that pulls a runtime dep, a path alias that resolves around the rule.
- **The pure core is pure.** Grep the engine (or equivalent) for `process.`, `Date.now`, `Math.random`, `fetch`, `fs`, `crypto`, `prisma`. Each hit is either injected (fine) or ambient (finding).
- **Duplication that has already diverged.** Two implementations of one concept (a formula, a validator, a formatter, a permission check) where one has been fixed and the other not. Prefer `git log -L` evidence of divergence over a mere similarity count.
- **Dead code with a live reader.** Exports with zero importers that a doc, a script or a feature flag still references; feature flags whose both branches are identical; routes registered with no client caller and no API doc row. Use knip/ts-prune output if present, but verify each by grep before citing.
- **God modules and hot files.** Files over ~1500 lines, or touched in >30% of the last 200 commits; modules importing from >40 others. Report only where the shape causes an observable cost (merge conflicts in git history, a test that can't isolate).
- **Type safety escape hatches.** `as any`, `as unknown as`, `@ts-ignore`, `@ts-expect-error` without a reason, non-null assertions on values that can be null at runtime (trace one). Count them per package and cite the ones on a data or auth path.
- **Error handling shape.** `catch {}` and `catch (e) { return false }` on paths whose caller distinguishes failure; errors logged and swallowed where a caller retries; `Promise.all` where one rejection abandons in-flight siblings that had side effects.
- **Config as code drift.** `.env.example` vs every `process.env.X` read in the tree (both directions); feature-flag matrix vs flags actually read; documented commands vs `package.json` scripts.
- **Docs that describe a previous tree.** `ARCHITECTURE.md`, `.claude/rules/*.md`, `CLAUDE.md`, `docs/*.md` claims that name a file, symbol, or behavior that no longer exists. Check every `path` or backticked symbol they cite.
- **Module cohesion.** If a cohesion map exists, does it agree with the import graph? A module the map says is self-contained but which imports three others is a finding.

## Gates that fit this realm

A boundary rule as a lint rule or dependency-cruiser config in the required CI leg; a purity test that greps the pure package for ambient globals; a docs-pointer test that fails when a cited path or symbol disappears; a knip/ts-prune job that is a required check, not advisory.
