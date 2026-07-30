# Competitor & market analysis

The only realm whose evidence is external, unverifiable from the repo, and actively polluted. The method is therefore mostly about provenance.

## Structure

1. **Issues filed from this analysis** — a table, up front.
2. **Already tracked, deliberately not duplicated.**
3. **Locked decisions: do NOT build X** — with the full evidence chain, recorded so it isn't re-litigated. The highest-value section in the document.
4. **Table stakes in `<year>` — no credit for shipping these.** Name them, and state plainly which the product has.
5. **Where the segment is still genuinely differentiated** — the only place a roadmap item should come from.
6. **Pricing shape** — Product | Annual | Free tier.
7. **Strategic threats that emerged this year.**
8. **Verification caveats** — below, mandatory.

## Provenance rules

- **`null` means unknown and must stay `null`.** Never interpolate a plausible price or a probable feature. Better a confident comparison with gaps than a fabricated one; a missing price renders "See site", not a guess.
- **Name the sources by class**, and name what was unreachable — a blocked forum, a vendor with no public pricing page, sources that disagree with each other.
- **Vendor-published claims are self-validated.** Say so; never restate one as a finding.
- **Search results for consumer software are heavily polluted by AI-generated affiliate content.** Prefer hands-on review publications, app-store review pages, and primary vendor documentation, and state which of those a claim rests on.
- Every comparative claim that will appear in *marketing* has to clear `legal-compliance.md` — Lanham Act and FTC substantiation, trademark notice, and an "accurate as of `<date>`" that is real.

## The feature matrix belongs in code

A prose comparison rots invisibly; a typed one is testable. Keep canonical feature rows in a data module with a test asserting:

- Every competitor carries every row, in the same order.
- `boolean | null` per cell, `null` preserved as unknown.
- A single reviewed-date constant that **can only move when every cell has been re-verified** — not per-competitor, or it drifts one column at a time.

Re-verification is quarterly, and it is scheduled work with an issue, not a memory.
