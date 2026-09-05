# Client delivery & perceived performance audit

`performance-ops.md` is the server side — queries, indexes, jobs, the things a load test finds. This file is everything between the origin and the user's eye: how the page is rendered, how many bytes cross the wire, how they're cached, and what the interface does during the wait. A product can have a flawless query plan and still feel slow, and the findings here are the ones users actually describe.

Every finding carries a measurement and a target. "Feels slow" is a symptom to reproduce, not a finding to file. Use the Chrome DevTools MCP (`performance_start_trace`, `lighthouse_audit`, `list_network_requests`) against the deployed target — a local dev build measures the bundler, not the product.

## Rendering strategy

The first question for every route: **what does a client with no JavaScript see?** `view-source` (or `curl`) the route and read the response body — the browser's rendered DOM is not evidence.

- **Anything a crawler, an unfurl, or an LLM must read is statically rendered or server-rendered — never client-only.** Marketing pages, blog posts, pricing, docs, landing pages built for a campaign. A client-rendered marketing route is simultaneously an SEO finding (`seo-metadata.md`), a GEO finding (`answer-engine-visibility.md`), and a Core Web Vitals finding; file it once and tag all three rather than three times.
- **Statically hosted by default.** A page whose content changes on a deploy cadence has no business being rendered per request — SSG (or ISR/PPR with a stated revalidation window) is the default, and per-request rendering is the exception that names its reason. The tell is a route with no request-dependent data that still runs a server function on every hit: it pays latency and compute for nothing, and it takes the CDN out of the path.
- **The dynamic boundary is deliberate.** In App Router terms: one uncached `cookies()`/`headers()`/`searchParams` read at the top of a layout opts the entire subtree out of static rendering. Enumerate what forced each dynamic route to be dynamic; the recurring finding is a whole section rendered per-request because of one personalization detail that belongs in a client component or a suspended slot.
- **Client components are the leaf, not the root.** `'use client'` at the top of a page tree ships the whole tree to the browser. Check where the directive actually sits versus where interactivity actually starts.
- **Fonts are self-hosted and preloaded**, with `font-display: swap` and a matched fallback metric. A render-blocking third-party font request is a top-three LCP contributor and one of the cheapest fixes available.

## Bytes on the wire

- **Text responses are compressed.** Brotli (or gzip) on every JSON API response, HTML document, JS, and CSS. The recurring finding is a platform that compresses static assets automatically and *not* the JSON coming out of an API route or a separately-hosted backend — check the actual `content-encoding` response header per endpoint, don't assume the platform did it. An uncompressed JSON list response is routinely 5–10× its compressed size.
- **The payload is shaped for the surface, not for the ORM.** A list endpoint returning every column of every row so the client can use three fields is the same finding in a different costume; select explicitly. Watch for a serialized relation tree that the UI never descends into.
- **Images are optimized, sized, and modern-format.** AVIF/WebP with fallback, responsive `srcset`/`sizes` so a phone doesn't download a 2400px hero, explicit `width`/`height` (or aspect-ratio) so nothing reflows, `loading="lazy"` below the fold and *not* on the LCP image. The framework's image component (`next/image`) does all of this and the finding is almost always a raw `<img>` pointing at an unprocessed upload. **Check the user-upload path specifically** — a product that optimizes its own marketing assets and serves untouched multi-megabyte user avatars has the problem where its traffic is.
- **Bundle budget per entry chunk, enforced in CI.** That one is mechanically gateable, so an unenforced budget is itself the finding. Look for the classic accidental imports: a full icon set, a moment/date library with all locales, a chart library on a route with no chart, a server-only utility pulled into a client component.
- Code-split below-the-fold and route-level; lazy-load anything behind an interaction (modals, editors, maps).

## Caching, at every layer

The finding is nearly always a missing *layer*, not a wrong TTL. Establish which of these exist for each read path, and file the absent ones:

- **CDN / edge**: static and cacheable responses carry `Cache-Control` with a real `max-age` and `stale-while-revalidate`; immutable hashed assets get a year. A `no-store` blanket on everything — often inherited from a framework default or a middleware that touches every route — silently removes the CDN from the architecture.
- **Server / data cache**: tagged and revalidated on write (`cacheTag`/`updateTag`, or the framework's equivalent) rather than time-expired and hoped for. Time-based revalidation on data with a known invalidation event is a correctness smell as much as a performance one.
- **Client query cache**: a query library (TanStack Query, SWR, or the framework's own) holding fetched data with stale-while-revalidate semantics, so a back-navigation or a tab switch doesn't refetch what it already has. **The recurring finding is `useEffect` + `fetch` + `useState` hand-rolled per component**: no dedupe, no cache, no retry, no shared state, and the same endpoint hit three times on one page mount. Reproduce it in the network panel — three identical requests on mount is the evidence.
- **Request-level memoization** for anything derived more than once per request (the auth-user lookup, again).
- And the inverse: **cached data that must not be.** Per-user content served from a shared cache is a security finding, not a performance one — hand it to `security-access-control.md`.

## Perceived performance

Latency you cannot remove, you hide. These are cheap, high-visibility, and almost never filed.

- **Optimistic rendering on every mutation whose success is the overwhelmingly likely outcome** — a like, a toggle, a checkbox, a reorder, adding an item to a list, an inline rename. The interface commits immediately, reconciles on the server response, and rolls back visibly with an error on failure. A spinner on a button for 400ms while a boolean flips is the finding. The rollback path is not optional and is what makes this safe: an optimistic update with no failure path is a `data-integrity-safety.md` finding, because the user believes something happened that didn't.
- **Not optimistic where the result is genuinely uncertain** — payment, a destructive action, anything whose server-side outcome the client can't predict. Optimism there is a lie. State which mutations are deliberately pessimistic and why.
- **Skeleton loaders, not spinners**, on any surface whose shape is known before the data arrives — lists, cards, tables, profile headers. A skeleton reserves the layout (so nothing shifts, which is also the CLS fix), communicates what is coming, and reads as faster than the same wait behind a spinner. Reserve spinners for indeterminate waits with no known shape, and for in-button pending states.
- **No layout shift when content lands.** The skeleton's dimensions match the real content's. A skeleton that reflows on swap is worse than no skeleton.
- **Streaming and progressive rendering** where the framework supports it: the shell and above-the-fold content render while slow data suspends, instead of the whole route waiting on its slowest query.
- **Prefetch on intent** — link hover/viewport prefetch for the next likely navigation.
- **Instant feedback on every interaction.** Any control that can't respond within ~100ms shows a pending state on the control itself. A button that looks unpressed for 800ms gets pressed twice — which is also why the endpoint behind it needs the idempotency key (`data-integrity-safety.md`, write paths).

## Targets

State them, per product, in the repo — not in the audit. Without a stated target every measurement is an anecdote:

- LCP < 2.5s, INP < 200ms, CLS < 0.1, at p75, on mobile, on the real deployed target.
- Lighthouse mobile and desktop scores, separately, and mobile is the one that matters.
- Bundle budget per entry chunk, in KB, gzipped.
- API p95 for each of the three slowest endpoints.

## Gates

- **Bundle budget in CI**, failing the build. Non-negotiable and mechanically trivial.
- **Lighthouse CI (or an equivalent) on a fixed set of representative routes**, with asserted thresholds — as a required check, not an advisory artifact nobody opens.
- **A test asserting the marketing routes render their content server-side**: fetch the route, assert the `<h1>` text is present in the raw HTML body. This catches the client-only regression that no visual review ever catches.
- **A `content-encoding` assertion** on a representative API response — the compression regression is invisible and permanent.
- Image discipline is lint-gateable: a rule banning raw `<img>` in favor of the framework component, with an explicit allow-list for the cases that genuinely need it.
- Perceived-performance findings (optimistic vs. spinner, skeleton vs. spinner) are not statically gateable — they are a per-surface convention that belongs written into the repo's design doc so the next surface inherits it rather than being audited into it. Same discipline as `ux-coherence.md`.
