# Data integrity & safety-critical paths

The realm a webapp checklist misses entirely, and the one where a finding has consequences outside the software. Run it wherever the product informs a physical decision — conditions, weather, avalanche, marine, medical, dosage, emergency contact — or holds data whose loss is irreversible.

## Fabricated data is a safety finding, not a code smell

Synthetic, placeholder, or fallback data presented in a surface a user acts on is the most serious finding available in this realm, and it hides well because it renders correctly.

- `Math.random()`, hardcoded sample values, or a "demo" fixture reachable in a production path.
- **A fallback that substitutes plausible data when the real source fails.** Weather, conditions, and forecast fallbacks are the canonical case: the user cannot tell the difference, and acts on it. The correct behavior is to fail visibly and say the source is unavailable.
- Simulated third-party calls — SOS dispatch, SMS, emergency notification — that report success without doing anything.
- A computed figure whose inputs are partly unavailable, rendered without indicating the gap.

Every such path either sources real data, or states its unavailability in the interface. Gate it with a test asserting the surface renders the unavailable state when the source errors, plus a lint/grep guard against the random and fixture symbols in production paths.

## Safety-critical behavior

- Safety-critical notifications **cannot be opt-out-able**, and there is a test asserting the settings path cannot disable them.
- Emergency paths (SOS, incident report, contact obligations) are exercised end to end against a real integration in a test environment, not mocked into passing.
- Where a regulator or standards body defines the content (avalanche bulletins, marine warnings, protocol checklists), the citation is in the code and the figures are read from the published text — see the citation doctrine in `accessibility.md`'s physical-space section.
- Degraded and offline behavior is defined for every safety surface: what a user sees with no network is part of the feature, not an edge case.
- **Any user-facing AI chat surface has a self-harm/crisis-language response path** — detection plus a hardcoded resource (crisis line, not a model-generated one) rather than relying on the base model's default behavior, which is not a substitute for a tested, owned response.

## Offline resilience and durability

- Offline-first surfaces: queued actions survive a restart, sync is idempotent, conflicts have a stated resolution, and the queue has a bound.
- The offline state is a designed surface, not a browser error page.
- Backups: RPO/RTO stated and matching what the provider actually offers — a retention claim exceeding the platform's ceiling is a finding and a legal one if it's published.
- Snapshot before any destructive migration; reversibility stated per migration.

## Retention and deletion as a first-class surface

Retention is its own realm-adjacent audit when the product carries an admin retention system: policies declared per data class, upcoming-deletion visibility, automated execution with health and alerting, and a compliance report generated rather than written. Cross-check every one of these against the Art. 30 register in `privacy-data-processing.md` — a sweep that exists in code but not in the register, or vice versa, is a finding on both sides.

## Integrity checks worth their own findings

- Time zone correctness in anything user-facing that spans a day boundary — streaks, dailies, reminders computed in UTC against a local-day expectation.
- Recomputation triggers that fan out across unrelated scopes on every mutation.
- Uniqueness and duplicate-record paths: a duplicate session, a double-submitted log, a second row where the domain allows one.
- Numeric floors and ceilings on anything health-adjacent (calorie floors, load progression), reproduced through the real engine rather than reasoned about.
