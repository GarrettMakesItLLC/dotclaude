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

## Merge model & releases

- **Squash-merge repos: lint the PR title, not the commits.** On a squash merge, GitHub uses the **PR title** verbatim as the commit subject — so the PR title is what lands on `main`. Enforce conventional-commit format on it (e.g. `amannn/action-semantic-pull-request`); a breaking change uses `!`.
- That keeps `main` a clean conventional-commit log that **`semantic-release`** can parse to derive the version bump and changelog automatically. Curated release notes are prepended to the generated ones.
- (Repos that don't squash keep commit-level commitlint instead.)
