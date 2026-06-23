---
description: Data & API-boundary conventions — Prisma, Zod, Supabase auth clients, secrets
paths:
  - "**/*.prisma"
  - "**/api/**"
  - "**/route.ts"
  - "**/route.tsx"
  - "**/actions/**"
  - "**/server/**"
---

# Data & API-boundary conventions

- **Prisma** for all database access — no raw SQL.
- **Run `prisma generate`** after `npm ci` / `pnpm install` and after any schema change.
- **Zod at every API boundary.** Never trust raw `req.body` or untyped query params.
- **Supabase Auth** where present. Two clients, never crossed: `supabaseServer()` (RSC / actions / handlers) vs `supabaseBrowser()` (`'use client'` only). Service-role key is server-only.
- Integration tests hit a **real database** — never mock Prisma.
- Never expose Supabase service-role keys, Stripe secret keys, or Vercel tokens in client-bundled code.
