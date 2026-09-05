# Product & spec coherence

The question: **is the product specification a single, internally consistent description that the code, the tiers, the flags, the roadmap and the marketing all agree with?** Gap analysis (spec says X, code lacks X) belongs to `feature-completeness`; this realm is the spec's own consistency and the product logic that sits above any one feature.

## Checklist
- **Spec internal contradictions.** Two sections that state different numbers, defaults, or rules for the same thing. Terms used with two meanings. A glossary entry that no section uses.
- **Tier and entitlement logic.** The tier constant vs every entitlement check vs the pricing page vs the generated tier tables: four sources, all must agree. A feature gated in the API but shown ungated in the UI (or vice versa). Grandfathering and downgrade behavior.
- **Feature flags.** Matrix vs code vs prod values: flags on in code but documented off, flags with no reader, flags whose off-branch is dead. A flag older than 90 days with no kill-switch rationale.
- **Roadmap vs tracker.** Every roadmap lane's owning epic: open, correct, and its children match the lane's stated scope.
- **Coach sovereignty invariant.** Trace three AI-suggestion paths to their coach override; any path where AI output reaches a member without a coach being able to override is a finding.
- **Data ownership invariant.** Coach access ends with the relationship: find the revocation path and a read it does not cover.
- **Onboarding contract.** What the spec promises a new member sees on day one vs the wizard's actual output for three personas (beginner, returning lifter, coach). Run the generator on fixtures.
- **Copy and naming.** One concept, one name, across spec, UI, API and docs. A rank called two things.
- **Product decisions with no record.** Behaviors in code that the spec neither prescribes nor forbids and that a member would notice — list them; each is a spec gap.

## Gates
A generated tier table drift test (verify it fires); an entitlement-parity test between API guards and UI gates; a flag-reader test; a spec-term consistency check.
