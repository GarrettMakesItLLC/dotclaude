# Legal & consumer-protection audit

Non-privacy legal exposure. Every item names its authority; a finding without one is a preference. Nothing here is legal advice, and the epic says so.

## Marketing and product claims

- **FTC deception** — every claim on a marketing surface is true of the product *as shipped to the reader*. The recurring failures: a landing page advertising a free feature that is Pro-gated (or the inversion), and copy omitting a material qualifying condition ("free challenge" that requires ten workouts).
- **Flag-gated features must not be advertised as available.** A comparison or feature page that lists something behind an unflipped flag is a false claim, not a roadmap.
- **Lanham Act / FTC comparative advertising** — competitor comparison pages must be accurate and substantiated. Carry "trademarks are the property of their respective owners" and "comparison accurate as of `<date>`", and hold the date to a real re-verification (see `competitor-analysis.md`).
- **YMYL copy review** before enabling any health, medical, financial, or longevity-adjacent surface. Check for implied diagnosis, treatment, or guaranteed outcome.
- Marketing surfaces are also checked against the repo's own canonical positioning doc — drift there is a finding even when nothing is untrue.

## Subscriptions and billing

- **ROSCA** — clear auto-renewal and trial-conversion disclosure *at the CTA and again at checkout*, before payment information is taken.
- **California ARL / cancel-easily laws** — self-serve cancellation effective at period end, reachable without a retention gauntlet; a coercive interstitial is the finding. Receipt and renewal-reminder emails enabled.
- **PCI-DSS** — card data never touches the origin; the audit checks that the hosted/Elements boundary actually holds.
- Refund and billing-dispute handling matches the published terms (CFPB fair-billing expectations where applicable).

## Users, minors, and content

- **COPPA** — age gate with server-side minimum-age enforcement; no under-13 collection path; and check the *defaults* for any minor-adjacent profile. Child profiles public-by-default and search-indexed is the worst finding in this realm and it has happened.
- **DMCA §512** — designated agent registered with the US Copyright Office (an external action: check the ledger before filing), notice-and-takedown flow, counter-notice, repeat-infringer strike policy.
- **Content-safety statutes** where user-to-user contact or classifieds exist: FOSTA-SESTA safe-harbor posture, CSAM detection and reporting obligations, platform-liability boundaries.

## Privacy-adjacent legal surfaces

Detailed in `privacy-data-processing.md`; these are the *published-document* halves:

- **CPRA** — "Your Privacy Choices / Do Not Sell or Share" link present and functional; sensitive-PI notice (§1798.121(a)).
- **Washington MHMDA (RCW 19.373)** — a designated policy section; note that it carries a private right of action.
- **ePrivacy / GDPR** — no analytics before consent; GPC honored.
- **CAN-SPAM** — physical postal address and working unsubscribe in every commercial email.

## Attribution and third-party licences

The cheapest findings to fix and the most expensive to miss, because the remedy is account termination rather than damages.

- **Affiliate programs (e.g. Amazon Associates) require a verbatim disclosure string.** Paraphrasing is a termination risk — diff the string character by character.
- Data-source attribution as the licence specifies: Open Food Facts (ODbL), Nutritionix, map and tile providers, wearable and health providers. Each provider's licence also constrains *use*, not just credit — e.g. provider data that may not be sent to an LLM.
- Open-source licence compliance scanned in CI, with the copyleft set failing the build; `LICENSE` present and `package.json` `license` field set.
- Font, icon, and image licences for anything shipped in the bundle.

## Regulated-activity compliance

Where the product touches a regulated activity, the checklist is the regulator's, and each rule cites it: aviation (FAA / CFR), marine (USCG), wilderness and outdoor standards, fishing and hunting licence eligibility, emergency-services integration (911 routing obligations, good-Samaritan and volunteer standards), professional liability and insurance framing, export control (ITAR, sanctions screening), AML transaction monitoring, and state sales-tax nexus.

## Gates

Most of this realm cannot be unit-tested, which is exactly why it recurs. What can be gated:

- Verbatim disclosure strings and required links: asserted by test against the rendered page.
- Feature-flag versus marketing-claim consistency: a test that reads the flag registry and fails when a claimed feature is not enabled in production config.
- Licence scanning and secret scanning in CI.
- Everything else gets a scheduled re-verification date in the epic, and a dated evidence artifact — not a memory.
