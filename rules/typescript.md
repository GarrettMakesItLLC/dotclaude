---
description: TypeScript conventions — strict mode, type-only imports, promise/lint rules
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.mts"
  - "**/*.cts"
---

# TypeScript conventions

- **Strict mode everywhere.** No `any` — use `unknown` and narrow.
- `import type { ... }` for type-only imports (`consistent-type-imports: error`).
- All promises must be awaited or explicitly voided (`no-floating-promises`, `no-misused-promises`).
- Unused vars allowed only with a `_` prefix.
- ESLint runs with `--max-warnings 0` in CI.
