# Answer-engine visibility (GEO) audit

`seo-metadata.md` asks whether a crawler can find and understand the page. This file asks a different question: **when an LLM answers a question this product should own, is this product the source it cites?** Ranking tenth is a search outcome; being uncited is a generative-engine outcome, and the second one is increasingly the traffic that converts.

Treat this realm as *load-bearing only where answer-engine visibility is a stated goal.* Where it isn't stated, run the crawler-access section anyway — being accidentally invisible is a finding regardless — and note the rest as not in scope.

The tactics here are less settled than SEO's. **Cite what you read, and date it.** A claim about how a specific engine weights something, taken from a vendor's blog, is a vendor claim (`competitor-analysis.md`'s provenance rules apply verbatim). What is stable is the mechanism: retrieval needs access, extraction needs structure, and citation needs attribution-worthy substance.

## Crawler access — check this first, it's binary

Everything downstream is irrelevant if the crawler is blocked. This is where the real findings are, and they are almost always accidental.

- **`robots.txt` does not block AI crawlers by accident.** Enumerate the user-agents actually named — `GPTBot`, `ClaudeBot`, `PerplexityBot`, `Google-Extended`, `CCBot`, `Bingbot` among others — and confirm each disallow is a decision someone made. A blanket `Disallow: /` for unknown agents, or a `Disallow` copied from a template, silently removes the product from every answer engine. Whichever way the decision goes, it must be a decision: opting out is legitimate, opting out by accident is the finding.
- **The CDN or WAF isn't rejecting them either.** This is the finding `robots.txt` review misses entirely: bot-management rules, a rate limiter, or an aggressive challenge page returning 403/429 to AI crawlers while `robots.txt` welcomes them. Verify by requesting real pages with each crawler's user-agent and reading the status code — don't infer it from the config.
- **Content is in the HTML response.** An answer engine's crawler is far less likely than Googlebot to execute JavaScript. A client-rendered page is invisible here even when it ranks fine in search. This is the same root cause as `web-delivery-performance.md`'s rendering finding — file once, tag both.
- **Nothing worth citing sits behind a login, a paywall, an interstitial, or a cookie wall.** Whatever is meant to be the citable answer is publicly fetchable.
- **`llms.txt`** present and pointing at the canonical, citable content — an emerging convention rather than a standard, so treat its absence as a low-severity finding and its *incorrectness* (stale links, pointing at gated pages) as a higher one.

## Extractability

Generative engines retrieve passages, not pages. A correct answer buried in a 2,000-word narrative loses to a worse answer stated in two sentences under a matching heading.

- **Every substantive page answers its question in its first paragraph**, then elaborates. The inverted pyramid, for the same reason journalism uses it.
- **Headings are literal questions or literal topics**, matching how the question is actually asked, and the text under each heading answers *that* heading without depending on the section above it. A passage that only makes sense in sequence doesn't survive retrieval.
- **Facts are stated as facts** — a number with its unit, a definition in one sentence, a comparison in a table. Tables, lists, and definition blocks extract cleanly; a paragraph hedging around the same content does not.
- **Structured data matching the content type**, validated against the schema.org definition — `FAQPage`, `HowTo`, `Product`, `Article` with a real `author` and `datePublished`. This is `seo-metadata.md`'s check; here it matters because it is what lets an engine attribute a claim to an entity.
- **Entity clarity**: the product, the company, and the people are named consistently everywhere, with an `Organization`/`Person` schema and matching profiles off-site. An engine that cannot resolve who is speaking has no reason to attribute the claim.
- **Freshness is visible** — a real `dateModified` that reflects actual revision, not a build timestamp. A stale-looking page is deprioritized; a lying timestamp is worse.

## Citation-worthiness

- **Original, checkable substance.** Proprietary data, a benchmark you ran, a method, a number nobody else has. Content that restates the consensus has nothing to cite *to* — it is the median of the training data already.
- **Claims are attributed and sourced** on the page. Engines preferentially cite pages that themselves cite.
- **Off-site presence where the engines actually retrieve from** — the community and reference surfaces for the category (documentation sites, established directories, comparison and review sites, relevant community threads). This is owner-action growth work, not a code finding; note the current footprint as a baseline rather than filing "not enough mentions" as a gap.
- **Comparison and alternatives pages** exist and are honest, because the comparative query is the highest-intent one an engine gets asked. Anything comparative that will be published has to clear `legal-compliance.md`'s substantiation bar and `competitor-analysis.md`'s `null`-means-unknown rule — a fabricated competitor limitation is a legal finding, not an SEO tactic.

## Measurement

Without this the whole realm is unfalsifiable.

- **A fixed prompt set** — the 20–50 questions the product should be cited for — run against the engines in scope on a schedule, recording whether the product appears and what was cited instead. The prompt set is checked into the repo; a prompt set held in someone's head can't show a trend.
- **Baseline before changing anything**, or no later measurement means anything.
- Referral traffic from answer engines segmented in analytics (the referrer strings exist; the finding is that nobody split them out).
- Share of voice against the named competitors, from the same prompt runs.

## Gates

- **A test asserting the AI-crawler user-agents named in the policy receive 200 and a body containing the page's `<h1>`**, run against production on a schedule. This is the whole realm's one mechanical guard and it catches every accidental-invisibility regression — a CDN rule change, a WAF ruleset update, a `robots.txt` edit.
- `robots.txt` assertion that no user-agent block was added without an accompanying decision recorded in the repo.
- Structured-data validation in CI where tooling allows.
- The prompt-set run is scheduled work with a dated artifact per run — evidence expires here exactly as it does in `SKILL.md`'s compliance-evidence rule, and a run that finds zero citations is a recorded result, not a skipped run.
