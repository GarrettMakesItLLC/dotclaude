# Growth, ads & conversion instrumentation audit

The realm where broken plumbing is indistinguishable from a bad product: a campaign underperforms, the dashboard says so, and the actual cause is a conversion event that stopped firing three weeks ago. Nothing else in this skill checks whether the *measurement* is true, and every growth decision downstream inherits the error.

Two halves, and they fail differently. **Instrumentation** fails silently and is mechanically checkable. **Conversion experience** fails visibly and needs judgement. Run both; file them separately.

## Instrumentation

Enumerate from the router, the way `security-access-control.md` does — every route, every conversion-relevant event — not from the pages that happen to have a tag.

- **Every analytics and ads tag fires on every route it is meant to.** The recurring finding: a pixel installed on the homepage and silently absent from the three routes added since, or present in a layout that a route group bypasses. Verify by loading the deployed routes and reading the network requests, not by grepping for the script tag.
- **Conversion events fire exactly once, on the real event.** A purchase event on page-render rather than on confirmed payment inflates every downstream number; a double-fire on a client-side re-render does the same. Reproduce each conversion end to end.
- **Server-side conversion tracking (Conversions API / server-side tagging) where the platform supports it.** Browser-only pixels lose a large and unmeasurable share of events to ad blockers, ITP, and iOS. Where both browser and server events exist, **the deduplication key is set on both sides** — otherwise every conversion is counted twice, which is the same defect as not counting it, in the more expensive direction.
- **Consent gating is real.** A tag that fires before consent is a `privacy-data-processing.md` finding first and a wiring finding second — but the wiring half belongs here: consent mode configured so denied consent degrades to modeled/cookieless rather than to nothing, and consent state actually reaching the tag rather than a banner that sets a cookie nothing reads. The two audits share one enumeration; don't build it twice.
- **UTM parameters survive the funnel.** An auth redirect, a client-side router, a marketing→app domain hop, or a payment provider's return URL that drops query params breaks attribution invisibly and shows up as a channel going to zero weeks later. Walk one real journey per acquisition channel — ad click → landing → signup → activation → paid — and confirm the parameters and the anonymous ID survive every hop, including the cross-domain one.
- **Anonymous identity stitches to the user record on signup.** Without it, no acquisition source is ever attributable to revenue, and the whole funnel is two disconnected datasets.
- **The events the product needs, not the events the SDK ships with.** Activation, the aha-moment action, trial start, subscription created, churn, expansion. A product tracking pageviews and purchases has no funnel; it has two endpoints of one.
- **The numbers reconcile.** Pick one week and compare the ad platform, the analytics tool, the app database, and the payment processor for the same metric. They will not match exactly; a gap you can't explain is the finding.

## Conversion experience

Judgement-shaped, per surface, and reproduced live rather than read.

- **Ad-to-landing-page congruence.** The ad's headline, offer, and imagery match the page it lands on. A mismatch is the highest-cost, most-common paid-acquisition defect: the spend is real, the bounce is immediate, and no dashboard names the cause.
- **One landing page per offer**, not the homepage as the destination for every campaign. Where a campaign points at the homepage, the finding is the absent page, not the ad.
- **A single primary CTA per surface**, repeated rather than competed with. Enumerate the calls to action per page; more than one primary action is a decision the user has been handed.
- **The value proposition is above the fold, names an outcome, and names who it's for.** Vague hero copy is `visual-anti-slop.md`'s finding as well — file once, tag both; blocking severity on a paid landing page.
- **Objections answered on the page**: pricing visible or explicitly explained, proof that traces to something real (`visual-anti-slop.md` owns fabricated social proof, and it is a legal finding via `legal-compliance.md`), a security/privacy answer where the product asks for sensitive data, and a stated cancellation/refund path.
- **Signup friction is counted.** Number of fields, number of steps, whether a credit card is required before value, whether email verification blocks the first useful action. Each is a stated choice or a finding.
- **Form failure keeps the entered values and says what to fix, per field** — also `ux-coherence.md` and `accessibility.md`. On a paid landing page it is a spend-destroying defect, so it carries higher severity here than the same bug in the app.
- **The mobile version of every paid landing page is the one that gets checked first** — that is where the traffic is. Hand the breakpoint mechanics to `responsive-mobile.md`; what belongs here is that the CTA is reachable without scrolling past a wall of text and the form is usable one-handed.
- **Pricing page**: plans distinguishable in one pass, the recommended plan marked, annual/monthly toggle honest about the discount, and every plan's limits stated rather than implied.

## Spend guardrails

- Budget caps and alerting on every ad account — the runaway-spend incident is an owner action, and it belongs on the completed-external-actions ledger, not re-derived each audit.
- Conversion tracking is verified working **before** a campaign scales, and there is a stated rule saying so. Scaling spend on unverified tracking is the expensive version of every finding above.
- Landing pages used by paid traffic are excluded from `noindex` sweeps and included in uptime monitoring — a paid landing page that 500s burns budget at full rate with no error anyone sees.

## Gates

- **A test per conversion event asserting it fires once, with the expected payload shape, on the real trigger** — Playwright against the deployed target, reading the outbound network request. This is the guard that makes the whole realm maintainable, and its absence is why instrumentation rots.
- A route-enumerated assertion that every tag meant to be global is present on every route, derived from the router — same enumeration as `seo-metadata.md`'s meta-tag test; write it once and assert both.
- A UTM-preservation test walking the cross-domain hop, because that is the break that never announces itself.
- Consent gating asserted in both states: with consent denied, no tag network request is made at all.
- Ad-to-page congruence, offer quality, and copy are a human pass. State in the epic's *Not verified* section which campaigns were reviewed and which weren't.
