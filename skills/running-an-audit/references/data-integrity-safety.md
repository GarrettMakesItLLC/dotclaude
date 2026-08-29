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

## Write paths

How the product writes is a correctness realm before it is a performance one. Enumerate every mutation — server action, API route handler, background job, webhook consumer — and check each. The recurring shape is a write that is *reasonable in isolation* and wrong as a sequence.

- **A multi-step write is one transaction, or it is a bug.** Create the order, decrement the stock, write the ledger row: any of those succeeding while a later one fails leaves a state the domain says cannot exist. The finding is three sequential `await`s with no transaction around them, and it is invisible until the day one of them throws.
- **Every externally-triggered write is idempotent, keyed.** Webhooks retry, jobs re-run, users double-click, and a network timeout is indistinguishable from a failure at the client. A natural key or an explicit idempotency key with a uniqueness constraint behind it is the fix; "the client only sends it once" is not. Pairs with `resilience-dependencies.md`'s retry rule — retrying a non-idempotent write is how one timeout becomes two invoices.
- **Read-modify-write under concurrency uses the database, not the application.** `SELECT`, add one in JavaScript, `UPDATE` loses writes under any real concurrency; an atomic increment or an optimistic-concurrency version column doesn't. Check every counter, balance, quota, and streak.
- **Upsert where the domain means upsert.** An insert that assumes absence, wrapped in a `findFirst` check, is a race with a uniqueness violation at the end of it.
- **Writes are not per-keystroke.** An autosave firing on every input event is a row rewritten fifty times to save one value. Debounce, batch, or save on blur/submit — and the reason is correctness as much as cost: fifty racing writes have no defined winner.
- **Derived values are computed, not stored** — unless stored deliberately, with the recompute path and the backfill that goes with it. A denormalized total that drifts from its source rows is the single most common data-integrity finding, and it drifts silently because both numbers look plausible.
- **No read-back after write to learn what was written.** The write already returned it; the extra round trip is a stale-read race in the cases that matter.
- **Bulk operations are chunked and bounded**, and a partial failure has a stated outcome — resumable, or all-or-nothing. A loop of individual writes over an unbounded set is a timeout with data half-written on the other side of it.
- **Soft delete or hard delete, decided once per model and applied consistently.** A mixed model is what produces the resurrected record and the orphaned child row. Where soft delete is used, every query path filters it — verify by enumeration, not by convention, since the one query that forgot is the whole finding.
- **Cascade behavior is declared in the schema**, not implied by application code that happens to delete children first.
- **An optimistic UI update has a rollback path.** Without it the user is shown a state the server rejected and never told otherwise — that is fabricated data by a different route, and belongs to this file rather than to the performance one that owns the technique (`web-delivery-performance.md`).

Gates: a test per invariant asserting the constraint holds under a concurrent double-submit; a uniqueness constraint in the schema for every idempotency key; and a scheduled reconciliation job for every denormalized aggregate, which reports drift rather than silently correcting it.

## Integrity checks worth their own findings

- Time zone correctness in anything user-facing that spans a day boundary — streaks, dailies, reminders computed in UTC against a local-day expectation.
- Recomputation triggers that fan out across unrelated scopes on every mutation.
- Uniqueness and duplicate-record paths: a duplicate session, a double-submitted log, a second row where the domain allows one.
- Numeric floors and ceilings on anything health-adjacent (calorie floors, load progression), reproduced through the real engine rather than reasoned about.
