---
description: Testing conventions — Vitest/Jest units, real-DB integration, Playwright E2E
paths:
  - "**/*.test.ts"
  - "**/*.test.tsx"
  - "**/*.spec.ts"
  - "**/*.spec.tsx"
  - "**/*.test.js"
  - "**/tests/**"
  - "**/e2e/**"
---

# Testing conventions

- Unit tests (Vitest or Jest) for pure logic.
- **Integration tests hit a real database** — never mock Prisma.
- E2E via Playwright.
- Coverage thresholds enforced on engine packages where defined.
