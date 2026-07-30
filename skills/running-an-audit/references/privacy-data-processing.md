# Privacy & data-processing audit

The question is never "do we have a privacy policy". It is **"does the code do exactly what the published policy says, and no more?"** — checked in both directions.

## Disclosure drift is the finding class

Every privacy audit run so far found the code doing more than the policy admits. Check both directions, because both are violations:

- **Code exceeds the policy** — an undisclosed processor, a wider access grant, a retention window longer than stated, a default that contradicts the documented one.
- **Policy exceeds the code** — the policy claims a protection that does not exist in the product (a consent gate, an export, a deletion cascade). This is the worse one: the policy is the authority, because it is what the user agreed to.

## Enumerate, then diff

1. **Every outbound network call** — SDKs, analytics, error tracking, LLM providers, geocoding, email, wearable/health integrations, CI and hosting side-channels. Each is a sub-processor. Diff the list against the policy's disclosed recipients. Undisclosed sub-processors have been found in seven separate passes; assume the list is stale.
2. **Every write of personal data** — model by model from the schema, not from memory.
3. **Every deletion and retention path** — including crons. A job that bulk-deletes but is absent from the retention register is a finding, and a build failure if the register is generated.
4. **Every consent surface** — and then whether consent is *recorded*, below.
5. **Every read path that crosses users** — coach/admin/leaderboard access versus what the policy describes.

## Consent

- **A checkbox in the UI is not consent; a row in the ledger is.** The recurring failure is consent presented, accepted, and never persisted — verify against production rows, not the component.
- Consent records are **versioned** (Art. 7(1)): which policy version, when, by what mechanism.
- **Health, biometric, and other special-category data needs explicit consent (Art. 9(2)(a))** — and every write path to it must pass the gate, including the ones added later. A single endpoint bypassing the gate is a live violation, not a gap.
- Opt-in defaults must match the schema default *and* the policy. An "opt-in" that ships enabled is a finding.
- Analytics must not fire before consent; honor Global Privacy Control.
- Age gate with **server-side** minimum-age enforcement, not a client-side date picker (see `legal-compliance.md` for COPPA).

## The Art. 30 record of processing

Generate it from code; never hand-maintain it. Columns: controller · categories of data subject · purposes and legal bases · retention (data | retained for | sweep mechanism | where the window is declared | guard | purpose and basis) · coverage of erasure and portability · recipients (recipient | category | what it receives | **what it never receives** | when data moves).

Legal bases, named per purpose: Art. 6(1)(b) contract, 6(1)(a) consent, 6(1)(c) legal obligation, 6(1)(f) legitimate interest; Art. 9(2)(a) for special-category.

A control register alongside it: **Obligation | Control | Guard | Why this guard holds.** Obligations mapped to article — erasure Art. 17, portability Art. 20, portable formats Art. 20(1), explicit consent Art. 9(2)(a), consent record Art. 7(1), storage limitation Art. 5(1)(e), accountability Art. 5(2).

Three drift guards make the pack real rather than decorative:

- A cron that bulk-deletes but is absent from the retention register fails the build.
- A processor the policy discloses but the register does not describe fails the build — **and a register entry the policy no longer discloses fails it too.**
- Every path named in the register exists on disk.

## Rights: erasure and portability

Prove completeness by **derivation, not enumeration** — a test that reads the schema and asserts every model holding personal data is covered. Export is deliberately broader than deletion: a model that cascades on delete still holds personal data and must be exported.

## What the pack must not claim

An explicit non-claims section, so the pack is not read as more than it is: transfer bases are recorded, not continuously verified; which regimes apply and which do not (FTC Health Breach Notification Rule, CCPA/CPRA, Washington MHMDA, GDPR — and, where true, *not a HIPAA covered entity*); and that nothing in it has been reviewed by counsel.

## Verify against production, not the diff

A remediation that shipped is not a remediation that applied. The pattern that recurs: an opt-out ships, and the rows written before it stay exposed. Check live rows for consent coverage and for backfills the fix required — with `list_tables` / a read-only query, before claiming the finding closed.
