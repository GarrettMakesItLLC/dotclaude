# SEO & metadata audit

The question is whether a search engine, a social-share unfurl, or an LLM crawler can find the page, understand what it is, and render it correctly when a human never will read the HTML directly. A page that looks finished in the browser and is invisible to every one of those three readers is the recurring finding — the audit exists because nothing else in this skill checks the `<head>`.

Some of this overlaps `accessibility.md` by coincidence, not duplication: `lang` on `<html>`, heading hierarchy, and alt-text coverage are accessibility findings first and SEO findings second, because a screen reader and a crawler read the same signal. Don't re-audit them here — cite the finding from there if it recurs, and treat this file as the part of the `<head>` and page contract accessibility doesn't reach.

## Per-page metadata

Enumerate every route the way `security-access-control.md` enumerates from the router, not from the pages that happen to look complete:

- **Unique `<title>` and meta description per page.** A template that renders the same title on every route is the single most common finding, and it's invisible until you diff the rendered `<head>` across two routes.
- **Canonical tag** on every page, pointing at the URL the app wants indexed — required wherever the same content is reachable through more than one path (query params, trailing slash, a preview domain).
- **Open Graph and Twitter Card**: `og:title`, `og:description`, `og:image` (sized per platform spec, not the favicon), `og:url`. Missing `og:image` is what makes a shared link render as bare text instead of a card — verify with an actual unfurl, not by reading the tag.
- **Exactly one `<h1>` per page**, and it names the page's actual subject rather than the site name. This is a duplicate-`<h1>`-tags finding here even where the heading hierarchy itself is otherwise unbroken (`accessibility.md`'s concern is skipped levels, not count).
- **Structured data (schema.org / JSON-LD)** matching the page's actual content type — `Article`, `Product`, `FAQPage`, `LocalBusiness` where a physical location or service area applies. Validate against the type's required fields, not just "some JSON-LD is present."

## Crawlability and indexing

- **`robots.txt` is present and deliberately scoped** — the finding is either absent (crawlers get the default, which is sometimes wrong) or a blanket `Disallow: /` left over from staging, which de-indexes production silently. Diff it against what's actually meant to be public.
- **`llms.txt`, AI-crawler access, and citation-shaped content** are `answer-engine-visibility.md`'s realm — including the finding this file cannot see, which is a CDN or WAF rule returning 403 to AI crawlers while `robots.txt` welcomes them. Run that file alongside this one wherever answer-engine visibility matters; don't re-derive it here.
- **`sitemap.xml`** generated (not hand-maintained — same generated-artifact discipline as `SKILL.md`'s "Generated audit artifacts" section), referenced from `robots.txt`, and submitted in Search Console. Submission is an owner action — check the property exists before filing it as missing.
- **Favicon** present across the sizes modern browsers and OS integrations expect (not just a single 16×16 `.ico`), and it renders — an absent favicon is a cheap, visible tell that the site went out the door unfinished.
- A page meant to be unindexed (an internal tool, a preview environment) carries `noindex` explicitly — relying on obscurity is not a control.

## Rendering and content depth

- **Marketing/landing pages are pre-rendered (SSG/SSR), not client-rendered-only.** `view-source` on a marketing route showing an empty shell is the tell — a crawler and a social-share unfurl both see nothing. Cross-check against `performance-ops.md`'s bundle findings; this is the SEO-visible symptom of the same root cause.
- **Backlink sources** — directories, partner/integration listings, guest posts — are an owner-action growth lever, not a code finding; note current backlink profile as a baseline rather than filing it as a gap.
- **Content depth on indexable surfaces** (blog posts, guides, tool/calculator pages) — a marketing site with zero indexable content beyond the landing page has nothing for search to rank. Not a per-post count to hit; a stated content plan versus zero content is the actual finding.

## Tracking wiring

Analytics tags, ad pixels, conversion events, consent gating, and UTM survival through the funnel are `growth-ads-conversion.md`'s realm. They share this file's route enumeration — build it once and assert metadata and tag presence from the same list rather than deriving it twice.

## Gates

- Meta-tag presence (`title`, `description`, canonical, OG set) is assertable in a Playwright or route-level test that reads the rendered `<head>` for every route in the router — the same enumeration `security-access-control.md` builds for auth coverage. A missing tag fails the build, not a manual crawl.
- Sitemap generation is a build step with a drift check (route count in the router vs. entries in the sitemap), not a hand-edited file.
- `robots.txt` gets a test asserting it does not `Disallow` anything meant to be public — the blanket-disallow regression is cheap to catch and expensive to notice by way of a traffic graph.
- Structured data validated against the schema.org type definition in CI where the tooling supports it; otherwise a scheduled manual pass, dated like `competitor-analysis.md`'s reviewed-date convention.
- Favicon, per-page title, and meta-description presence are also the visible launch tells in `site-hygiene-launch-tells.md` — one route-enumerated test satisfies both files; file the finding here and cross-reference.
