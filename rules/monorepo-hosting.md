---
description: Monorepo layout & hosting defaults — workspaces, package boundaries, Vercel/Railway
paths:
  - "**/package.json"
  - "**/pnpm-workspace.yaml"
  - "**/turbo.json"
  - "**/vercel.json"
  - "**/railway.json"
  - "**/railway.toml"
---

# Monorepo layout & hosting

## Monorepos

- pnpm workspaces (newer repos: AdventureOS) or npm workspaces (older: MuscleBuddy, RedThreadEvents).
- Common layout: `apps/web/`, optionally `apps/server/`, `packages/{engine,types,ui,database}/`.
- `packages/engine` (where present) is **pure deterministic logic** — no I/O, no DB, no Node built-ins. Fully unit-testable.
- Web app never imports from the server package; comms via REST only.

## Hosting

- **Vercel** for frontends (Next.js + Vite both deploy here).
- **Railway** for separate backend services (Fastify) when not deployable on Vercel.
- Postgres + Redis usually via Vercel Marketplace (Neon + Upstash) or Supabase.
