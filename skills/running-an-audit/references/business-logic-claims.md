# Business-logic claim fulfilment

The question: **for every claim the product makes, does the running system actually do it, in every situation the claim implies, all the way to the user?** Neighbouring realms cover parts of this and should be cited, not redone. Formula correctness is `domain-science-validity`. Safety-floor enforcement is `data-integrity-safety`. Whether a spec section is built at all is `feature-completeness`. Tier and flag coherence is `product-spec-coherence`. This realm owns *behaviour across situations* and *end-to-end wiring*. Feature-completeness asks "is it built?" and misses a feature that is built, tested and never triggered in the situation the copy promises.

## Enumerate claims before tracing any

Claims come from two places, and the second is the larger and less examined one:

- **The spec**, section by section.
- **Every copy surface.** Landing and feature pages, FAQ and JSON-LD answers, store listings, positioning and press docs, ad copy, onboarding screens, upsell and paywall copy, email and push templates. In one run the copy surfaces held ~312 distinct claims against ~600 in the spec, and produced proportionally more contradictions: copy is edited by people who don't read the code.

Count the claims and record the count. Split the audit **by system** (training, nutrition, billing, coaching, social…), one auditor each. Give marketing copy its own auditor, because it cuts across every system. Otherwise each system auditor reads only the copy for its own keywords, and cross-system promises ("reads across modules", "adapts to everything you log") fall between them.

## One row per claim × situation

| Column | What it holds |
|---|---|
| Claim (source) | Verbatim, with the file or spec section. |
| Situation | The circumstance the claim implies it handles. Enumerate the unhappy ones explicitly. |
| Trigger chain | engine function → caller (route / cron / hook) → what is persisted → where the user sees it, as `path#symbol`. |
| Seen at | The screen, push or email where the value arrives. |
| Proof | The test that covers *that situation* and can go red, or the reproduction run. |
| Verdict | `holds` / `partial` / `broken` / `claimed-not-built` / `built-not-wired` / `untested` / `value-gap`. |

The map is a deliverable, not scaffolding. Land it in the repo with a pointer-drift guard (every `path#symbol` resolves: the path suffix names a tracked file, and the symbol still appears in it). The next audit then starts from the rows that held instead of re-tracing them.

## Situations to force for every adaptive claim

An "adapts to X" claim is only as good as its worst X. The ones that break most often:

- **No history yet**: first week, first program, empty leaderboards.
- **Missing or sparse input**: a weekly rather than daily logger, a missed week, a stalled wearable. Watch for *rows counted as days*: "three low days in a row" computed over the last three records, whatever their dates.
- **Input arriving through a second path**: the same value logged by check-in, watch, import or integration instead of the primary form. Adaptations wired to one writer are the most common `partial`.
- **State changing mid-cycle**: an injury, equipment change, schedule change or goal change after the plan was generated. Rules applied only at generation time silently ignore everything after it.
- **A human override**: coach, admin or user setting. Enumerate *every* automatic write path (engine, cron, webhook) and prove each one reads the override. One skipped path is a broken invariant.
- **Entitlement changes**: trial end, downgrade, lapse, a comp or seat granted by a third party. Check automations that keep writing for a user who no longer has the tier.
- **Time**: the user's local day vs UTC, DST, travel, a once-a-day tick deciding a deadline the UI shows to the minute.
- **Repetition**: a retried job, create-then-delete, a duplicated webhook. Check rewards and counters especially.
- **The undo**: does reverting an automatic change restore only that change, or a whole snapshot that also discards the user's later edits?

## Run it; don't reason about it

Where the logic is pure, write a scenario script that feeds the situation to the real function and records input → output. Run it several ticks forward for anything cumulative. In one run the largest defects (an adjustment compounding to ~2× in three weeks, a deload cadence that never met its own spec) were invisible from any single call and obvious by tick 5.

Then ask production **whether the claimed behaviour has ever fired**: "how many automatic adjustments were written in 30 days". A behaviour that has never fired for a real user makes every finding against it latent. Say so in the epic; it changes priority, not validity.

**Production reads are the dangerous step.** Give auditors exactly one helper: the direct (session) database URL, each query wrapped in `BEGIN READ ONLY; …; ROLLBACK`. Never use a transaction-pooler URL with a session-level setting (`PGOPTIONS`, `SET`). The pooler shares backends across clients, so a "safety" setting like `default_transaction_read_only=on` leaks to other clients and fails the production app's own writes. Never write a connection string to a file.

## Severity for this realm

- 🔴 A claim to paying or prospective users that is false in the common case, or a situation that produces a harmful prescription.
- 🟠 A claimed adaptation that silently never fires, or fires and never reaches the user. Also any automatic path that overrides a human override.
- 🟡 Fails in a named edge situation.
- 🟢 Polish.

A copy claim contradicted by the code is a finding against whichever side is wrong. Where the spec, the copy and the code disagree three ways, surface all three and propose one resolution. Don't pick silently.

## Gates

For an adaptation claim, the gate is a test that **feeds the situation and asserts the adaptation**: three low scores across three weeks → no deload; a rehab episode started mid-block → today's session contains no contraindicated pattern. For a copy claim, the gate is a copy test that fails when the page names a behaviour the code no longer has. Both kinds are cheap, and neither exists by default.
