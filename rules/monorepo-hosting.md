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

## Email sending domains

Transactional and marketing mail never share a sending domain, and neither sends from the root.

- Root (`brand.com`) carries the domain's baseline reputation and the human mail — never a bulk sender.
- **Transactional / app mail**: `mail.brand.com`. Password resets, receipts, invites, alerts.
- **Marketing / lifecycle mail**: `e.brand.com`. Campaigns, newsletters, re-engagement — this is where the complaint risk lives.
- **Cold outbound**, where it exists, is a separate domain entirely, expendable by design.

Sharing one domain means a campaign to a stale list takes password-reset delivery down with it, and nothing in the app reports an error. Reputation builds per-domain over weeks, so the split has to precede the volume.

Each sending subdomain carries SPF ending `-all` and under the 10-lookup limit, aligned 2048-bit DKIM, and a DMARC record moved off `p=none` with `rua=` pointing somewhere that is actually read. Verify against production DNS, not the ESP dashboard.

## Merge model & releases

- **Squash-merge repos lint the PR title, not the commits** — GitHub uses the PR title verbatim as the squash commit subject. Enforce conventional-commit format on it (`amannn/action-semantic-pull-request`); breaking changes use `!`.
- That keeps `main` a conventional-commit log **`semantic-release`** can parse for version bump and changelog; curated release notes are prepended to the generated ones.
- Repos that don't squash keep commit-level commitlint instead.
