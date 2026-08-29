---
description: Frontend conventions — Next.js/Vite, Tailwind, dark mode, a11y, icons, i18n
paths:
  - "**/*.tsx"
  - "**/*.jsx"
  - "**/components/**"
  - "**/app/**"
---

# Frontend conventions

- **Next.js (App Router)** for new web apps; Vite + React for older / PWA repos. Tailwind for styling.
- Dark mode (`dark:` variants) required on new components.
- WCAG 2.1 AA contrast. Where the repo has a web CI, enforce it with an **axe** (axe-core via Playwright) lane over public + authenticated-mocked routes.
- Lucide icons unless the repo specifies another set. A custom SVG matches the set's grid, stroke width, and corner radius, uses `currentColor`, and is optimized — a one-off export that ignores all three is visible as janky next to the library icons.
- Named font weights only, from the design system's set, each with a stated meaning. Four weights on one screen is a defect, not a style.
- In i18n repos: no hardcoded English strings in JSX — use `useTranslations`.

## Rendering & delivery

- **Static by default.** A route whose content changes on a deploy cadence is SSG (or ISR/PPR with a stated revalidation window); per-request rendering is the exception that names its reason. Marketing, pricing, docs, blog, and campaign landing pages are never client-rendered-only — a crawler, a social unfurl, and an answer engine all read the HTML response, not the rendered DOM.
- **`'use client'` sits at the leaf, not the root.** One uncached `cookies()`/`headers()`/`searchParams` read at the top of a layout opts the whole subtree out of static rendering — keep it below the boundary.
- **`next/image` (or the framework's equivalent) for every image**, with explicit dimensions, responsive `sizes`, and `loading="lazy"` below the fold but never on the LCP image. This includes user uploads, which is where the multi-megabyte files actually are.
- **Self-hosted, preloaded fonts** with `font-display: swap` and a matched fallback metric.
- **Fetched data goes through a query cache** (TanStack Query / SWR / the framework's own), never hand-rolled `useEffect` + `fetch` + `useState` — that pattern has no dedupe, no cache, and no retry, and produces the same request three times on one mount.

## Loading, feedback & motion

- **Skeletons where the shape is known; spinners only for indeterminate waits and in-button pending states.** Skeleton dimensions match the real content so nothing reflows.
- **Optimistic updates by default** on mutations that almost always succeed (toggles, likes, reorders, inline renames), each with a visible rollback on failure. Pessimistic deliberately on payments and destructive actions. An optimistic update with no failure path is a correctness bug, not a UX choice.
- Every mutation ends in a visible, specific success or error message. A silent return is indistinguishable from a failure.
- Every icon-only control has both an accessible name and a tooltip; on touch it carries a visible label instead.

## Responsive

- **No horizontal document scroll at any viewport.** `overflow-x: hidden` on `body` is symptom suppression — fix the offending element. Long unbroken strings get `overflow-wrap: anywhere`.
- Mobile navigation exists below the nav breakpoint, offers every desktop destination, traps focus, closes on Escape and on route change, and restores focus to its trigger.
- `100dvh`, not `100vh`, for full-height mobile layouts; safe-area insets respected; viewport meta is `width=device-width, initial-scale=1` and never disables zoom.
- Tap targets ≥44×44px; no hover-only affordance without a touch equivalent; inputs carry the right `type`/`inputmode`/`autocomplete` and are ≥16px so iOS doesn't zoom.

## Finished-ness

These are the tells that a site shipped rather than finished, and they are cheap enough to be defaults rather than audit findings:

- A custom 404 (and 500) carrying the product's design and navigation — **required in every product**, not a nice-to-have.
- Dynamic copyright year (`new Date().getFullYear()`), never hardcoded.
- Logo links to `/` from every page. Phone numbers are `tel:`, email addresses are `mailto:`.
- No placeholder copy, stub links (`href="#"`), or nav entries for unbuilt features on any user-reachable surface.
- Per-page `<title>` and meta description; a real favicon set; an OG image that renders in an actual unfurl.
