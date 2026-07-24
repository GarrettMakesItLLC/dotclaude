---
description: Monorepo layout & hosting defaults — workspaces, package boundaries, Vercel/Railway, PR-title lint
paths:
  - "**/package.json"
  - "**/pnpm-workspace.yaml"
  - "**/turbo.json"
  - "**/vercel.json"
  - "**/railway.json"
  - "**/railway.toml"
  - "**/vitest.config.*"
  - "**/jest.config.*"
---

# Monorepo layout & hosting

## Monorepos

- pnpm workspaces (newer repos: AdventureOS) or npm workspaces (older: MuscleBuddy, RedThreadEvents).
- Common layout: `apps/web/`, optionally `apps/server/`, `packages/{engine,types,ui,database}/`.
- `packages/engine` (where present) is **pure deterministic logic** — no I/O, no DB, no Node built-ins. Fully unit-testable, and carries coverage thresholds.
- The web app never imports from the server package; comms via REST only.

## Hosting

- **Vercel** for frontends (Next.js and Vite both).
- **Railway** for separate backend services (Fastify) not deployable on Vercel.
- Postgres + Redis via Vercel Marketplace (Neon + Upstash) or Supabase.

## Merge model & releases

- **Squash-merge repos lint the PR title, not the commits** — GitHub uses the PR title verbatim as the squash commit subject. Enforce conventional-commit format on it (`amannn/action-semantic-pull-request`); breaking changes use `!`.
- That keeps `main` a conventional-commit log **`semantic-release`** can parse for version bump and changelog; curated release notes are prepended to the generated ones.
- Repos that don't squash keep commit-level commitlint instead.
