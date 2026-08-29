# Site hygiene & launch-tells audit

The cheapest realm in this skill and the one users judge fastest. Nothing here is architecturally interesting; every item is a small, visible sign that the site was shipped rather than finished. They cluster — a site with a stale copyright year usually also has a default 404 and three dead footer links — which is why they get one pass rather than one finding at a time.

`visual-anti-slop.md` covers tells of *generated* work (the emoji icon, the template hero, the builder watermark). This file covers tells of *unfinished* work. Run them together on any launch-readiness pass; file into whichever fits and don't duplicate.

**Reproduce, don't read.** Every item below is checked by loading the deployed target and clicking, at both a desktop and a phone viewport. A grep proves a link exists in the source, not that it resolves.

## Dead ends

- **No broken links.** Crawl the deployed site and check every internal link's status, then every external one. The recurring findings: a footer link to a page that was renamed, a nav item pointing at a route that was never built, a docs link to a moved anchor, and an external link to a vendor page that 404'd a year ago. Include links inside content and inside emails.
- **Footer links resolve and are real.** The footer is where placeholder links go to die — `#`, `/coming-soon`, a Privacy Policy linking to the Terms, a social icon pointing at a profile that doesn't exist. Every footer link either resolves to real content or is removed. A social icon for an account the product doesn't have is worse than no icon.
- **No unused or dead navigation.** A nav item leading to an empty page, a disabled tab with no explanation, a menu entry for a feature that was cut. If it isn't built, it isn't in the nav.
- **No broken or inert buttons.** Click every button and link on every surface. The failure modes: a handler that was never wired, a `<div>` styled as a button with no handler, a submit that posts to a route that no longer exists, a button whose disabled state never lifts, and a link with `href="#"`. Anything that looks interactive and does nothing is a finding, and a `<div>` acting as a button is also an `accessibility.md` finding.
- **A custom 404 page**, matching the product's design, carrying the site's navigation and a route back — not the framework's default and not a blank page. **Treat its absence as high severity on any public product**: it is the surface a user meets at their most confused moment, and the default page reads as an abandoned site. A custom 500/error page on the same basis.

## Placeholder residue

- **No lorem ipsum, no "Your Company Here", no `TODO`, no `[placeholder]`** on any user-reachable surface. Grep the templates and content for the obvious markers, then look at the rendered pages, because the interesting ones aren't greppable.
- **No stub or sample content presented as real** — a demo testimonial, a fake stat, an example blog post, a seeded user visible in production. Where the content is data rather than copy this is a `data-integrity-safety.md` finding (fabricated data), and where it's social proof it is a `legal-compliance.md` one. File it once, in the most severe realm.
- **No placeholder images** — the gray box, the stock avatar, the framework's default OG image.
- **Form placeholder text is not doing a label's job.** A placeholder that disappears on focus and was the field's only label is an `accessibility.md` failure; here it is a finished-ness finding too.
- **Contact details are real and current** — the support email is monitored, the address is the actual address, the phone number rings.

## Identity and metadata

Most of these are `seo-metadata.md`'s findings; they appear here because they are also the visible tells, and a hygiene pass finds them faster than a metadata audit does. File them into `seo-metadata.md` and cross-reference — don't duplicate the issue.

- **Favicon present** across the sizes browsers and OS integrations expect, and it is the product's mark — not the framework's default and not a single 16×16 `.ico`.
- **Page titles are per-page, specific, and human** — not the site name repeated on every route, not "Home", not the framework's placeholder. Check the browser tab and the search-result rendering, both.
- **Meta descriptions present and written per page**, not truncated body text and not absent, on every indexable route.
- **OG image renders** in an actual unfurl. Paste the link into a chat client and look at it.
- **The production domain is the real domain** — no `*.vercel.app` reachable and indexed as the canonical, no staging subdomain in a shared link.

## Small correctness

- **Copyright year is current and updates itself.** A hardcoded year is the finding, and the fix is one expression, not a calendar reminder. `© {new Date().getFullYear()}` — or the build-time equivalent — plus a founding year where the range is meaningful. A site advertising last year is a stronger abandonment signal than most people expect.
- **The logo links to home**, from every page, on every viewport. Universal convention, and its absence is the most-clicked dead element on the web.
- **Phone numbers are `tel:` links** and **email addresses are `mailto:` links**, everywhere they appear — on mobile a plain-text phone number is a copy-paste chore standing between a user and a conversion. Physical addresses link to a map.
- **External links that should open in a new tab do**, with `rel="noopener"`; and links that shouldn't, don't. Pick the convention, apply it consistently (`ux-coherence.md`'s remit), and never open internal navigation in a new tab.
- **Legal pages exist and are reachable from the footer** — privacy policy, terms, and anything the regime requires. Their *content* is `legal-compliance.md`'s; their presence and reachability is this pass.
- **The site works with a trailing slash and without**, and one canonicalizes to the other.
- **`robots.txt` and `sitemap.xml` resolve** on the production domain — checking that they exist in the repo is not the same check.

## Feedback and flow

Overlaps `ux-coherence.md`, which owns the *consistency* question. Here the question is only presence: does the user ever end up with no idea what happened?

- **Every mutation produces a visible success message**, and it says what happened in the product's terms rather than "Success". A form that submits and returns silently to the same view is indistinguishable from a form that failed.
- **Every failure produces a visible, specific error message** that says what to do next. "Something went wrong" on a payment page is the same as no message. Field-level errors sit next to their field and the entered values survive (`ux-coherence.md`, `accessibility.md`).
- **The primary flows complete end to end**, walked as a new user with a fresh account: sign up → verify → first useful action → the product's core action → upgrade/pay → cancel. Anywhere the next step isn't obvious is a finding, and anywhere it dead-ends is a blocker. This walk finds more than any static read in this file.
- **Destructive actions confirm, and non-destructive ones don't.** A confirmation dialog on a benign action trains the user to dismiss the one that matters.

## Gates

Most of this realm is genuinely automatable, which is what separates it from the judgement-shaped realms — an audit here that produces only issues will be run again next quarter.

- **A link checker over the built site in CI**, failing on internal 404s and reporting external ones (external links are flaky; report rather than fail, but do report). This single check owns the broken-link, dead-footer, and dead-nav findings permanently.
- **A test asserting the 404 route renders the custom page** with the site nav present — otherwise a routing change silently restores the default.
- **A grep gate over built output for placeholder markers** (`lorem ipsum`, `TODO`, `Your Company`, `example.com`, `placeholder`) failing the build.
- **A test asserting the rendered footer's copyright year equals the current year** — trivially satisfied by the dynamic expression, and it is what keeps the hardcoded year from coming back.
- Route-enumerated assertions for title, meta description, and favicon presence — the same test `seo-metadata.md` specifies; write it once.
- A test asserting the logo element is a link to `/`.
- Broken-button and flow findings need the live walk. State in the epic's *Not verified* section which flows were actually walked.
