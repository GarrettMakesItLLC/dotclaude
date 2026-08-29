---
name: running-an-audit
description: Use when running or scoping any audit, investigation, gap analysis, or compliance review — accessibility, privacy/data-processing, legal, security, feature completeness, competitor, performance, ops, UX, data integrity — or when deciding how deep to run one and where its findings land. Covers the method; per-realm checklists live in references/.
---

# Running an audit

An audit is **a scoped question, answered against a named target, with evidence, whose every finding lands somewhere.** Miss any of those four and it isn't an audit — it's an opinion that will be re-derived next quarter.

The method is here. The realm checklists are in `references/` — load only the realms in scope:

| Realm | Reference |
|---|---|
| Accessibility (WCAG 2.2 AA; physical space ADA/ASTM/IBC) | `references/accessibility.md` |
| Privacy & data processing (GDPR Art. 30, consent, retention) | `references/privacy-data-processing.md` |
| Legal & consumer protection (FTC, ROSCA, COPPA, DMCA, CPRA) | `references/legal-compliance.md` |
| Security, authz & tenant isolation | `references/security-access-control.md` |
| Feature completeness & gap analysis | `references/feature-completeness.md` |
| Competitor & market analysis | `references/competitor-analysis.md` |
| Data integrity & safety-critical paths | `references/data-integrity-safety.md` |
| Performance & operability (server side) | `references/performance-ops.md` |
| Client delivery & perceived performance | `references/web-delivery-performance.md` |
| Resilience & dependency concentration | `references/resilience-dependencies.md` |
| UX coherence | `references/ux-coherence.md` |
| Responsive & mobile | `references/responsive-mobile.md` |
| Site hygiene & launch tells | `references/site-hygiene-launch-tells.md` |
| SEO & metadata | `references/seo-metadata.md` |
| Answer-engine visibility (GEO) | `references/answer-engine-visibility.md` |
| Growth, ads & conversion instrumentation | `references/growth-ads-conversion.md` |
| Email & sending-domain deliverability | `references/email-deliverability.md` |
| Visual anti-slop (product/design counterpart to `avoiding-ai-slop`) | `references/visual-anti-slop.md` |

A realm not listed still runs on this method — write the checklist as you go and add the reference file in the same PR. **The table is the index: a file in `references/` missing from it, or a row pointing at no file, is drift and gets fixed in the PR that finds it.**

Several realms deliberately share a surface and must not each re-derive it. Where two files name the same finding, file it once in the more severe realm and tag the other — the pairs that recur are client-rendered marketing pages (`web-delivery-performance` / `seo-metadata` / `answer-engine-visibility`), consent-gated tags (`growth-ads-conversion` / `privacy-data-processing`), fabricated proof and metrics (`visual-anti-slop` / `legal-compliance` / `data-integrity-safety`), and icon-button naming (`accessibility` / `ux-coherence`).

## The two laws

**1. Gate it, or it recurs.** A finding whose fix ships without a check that fails on its return will be found again by the next audit — and the fix will be written again, slightly differently, next to the last one. Every finding's issue names its gate: the test, the lint rule, the CI job, or the generated-artifact drift check that makes the finding un-reintroducible. Where a finding genuinely cannot be gated (owner action, a judgement call, an external dashboard), the issue says so explicitly. "Fixed" without a gate is a deferral dressed as a resolution.

**2. Verify the guard fires.** A guard that exists and never runs is the most expensive outcome available: it converts an open problem into a false pass. Before trusting any check — existing or newly added — confirm it goes red. Dry-run the rule against known-bad input, or break the thing on purpose once. Specifically look for `continue-on-error`, a job that isn't a required check, a lint override whose glob doesn't match the files, an invariant with no enabled-path coverage, and a report generator whose every severity bucket is empty.

## Scope before you look

Write these four down before reading any code. An audit that starts by reading code produces a list of whatever happened to be interesting.

- **The question**, in one sentence, answerable yes/no or as a gap list.
- **The target**, nameable and pinnable: `origin/main @ <sha>`, a deploy URL, a released artifact — not "the app". A finding against an unnamed target can't be reproduced or retired.
- **The realms** in scope, and the ones deliberately out.
- **The depth**, below.

State the scope in the epic body. Half the re-scoping cost is that nobody could tell what the last audit covered.

## Depth

| Depth | Shape | Output |
|---|---|---|
| **sweep** | One realm, one pass, inline. Answers "is this broadly OK?" | Findings in the reply; an issue for each that survives verification. No epic, no milestone. |
| **realm** | One realm, exhaustive: enumerate the entire surface (every route, every form, every outbound call), then check each. Dispatch one auditor per sub-surface when the surface is wide. | Epic as index + issue per finding. Milestone if the findings are a batch of work. |
| **launch-readiness** | Every realm in scope, one dispatched auditor per realm, in parallel. Reproduce what can be reproduced. Adversarial self-check on every finding. | Dated milestone (`Pre-Launch Audit (YYYY-MM-DD)`), epic index with severity buckets, one issue per finding. |

Escalate depth for anything gating a launch, a legal position, or a claim made to users. Default to **sweep** when the question is "did I break something" — that's a review, and `/code-review` is cheaper.

## Dispatching auditors

For **realm** and **launch-readiness** depth, fan out with the `domain-auditor` agent — one per realm or sub-surface, in a single batch. Its standing instructions cover evidence, adversarial self-check, and returning findings rather than fixes. Give each auditor: the target ref, its realm's reference file, the scope boundary, and the dedupe list (below). Never let two auditors share a surface — overlapping findings cost more to reconcile than they cost to find.

## Dedupe before filing

This is what goes wrong most, and it's what makes an audit feel like a re-run.

- **Dedupe against closed issues, not just open ones.** A code-scanning pass re-derives every gap from the absence of code, so completed work is invisible to it unless you look for the closure.
- **Grep the owner-action ledger** (`docs/owner/completed-external-actions.md`, or the repo's equivalent) before filing anything about an external or dashboard-configured action. Registering an agent, standing up a monitor, setting a provider setting — none of these leave a trace in the repo, and re-asking for them is the single most common false finding.
- **Never infer "missing" from the absence of code for anything configured outside the repo.** Check the platform (Vercel/Railway/Supabase/Stripe MCPs), or file it as owner action with the literal steps.
- **Two audits that would overlap become one epic with sub-tracks.** Noticing the overlap and running them separately anyway is the failure — the reconciliation lands on whoever triages.

## A finding

```
Severity: 🔴 blocker | 🟠 high | 🟡 medium | 🟢 quality | 👤 owner action
Problem:    what is wrong, in one sentence, in terms of consequence
Evidence:   path/to/file.ts:120 — and, where the code runs, a reproduction
Fix:        the change, specific enough to estimate
Gate:       the check that fails if this returns — or why it can't be gated
Source:     <realm> audit, <target ref>
Confidence: high | medium — and what would raise it
```

- **Evidence is a `file:line`, a reproduction, or a cited clause. Otherwise it isn't a finding**, it's a suspicion — either verify it or report it as an open question.
- **Reproduce before filing** anything you can run. A finding that survives contact with the actual engine is worth ten that were reasoned about.
- **Every cited figure traces to published text**, read not recalled. A number in a compliance finding that can't be traced to its source is a bug, not a default.
- **Undecidable from available data ⇒ report it as undecidable, naming the criterion's own exception clause.** Do not apply the conservative figure and flag it anyway: over-flagging teaches the owner to ignore the rule, which costs more than the miss.
- **Batch the low-severity tail into one issue** with lettered sub-findings, each carrying its own `file:line`. Fifty issues of frontend polish is a tracker denial-of-service.

## Output contract

Findings land as tracked work — see **managing-work-with-issues** for the epic/milestone axes and the status rules. `blocked` findings need their `## ⛔ Owner action required` steps; `waiting` findings need `## ⏳ Waiting on #N`.

The epic is the index, and it carries four sections an audit is not finished without:

1. **Findings**, in severity buckets, each linking its issue.
2. **Verified safe, no change needed** — what was checked and held. Without this, the next audit re-checks everything, and a later regression can't be dated.
3. **Not verified** — what the method could not reach. Live-app behavior, external dashboards, anything a static read can't settle. State it plainly; an unstated limit reads as coverage.
4. **Findings that did not become issues** — deduped-away, deliberately declined, or judged not worth building, each with its evidence chain. A decision *not* to build something is the most expensive thing to re-litigate; record it here so it isn't.

## Generated audit artifacts

A compliance record, evidence file, or coverage report that is generated must be regenerated by CI and drift-checked — otherwise it silently goes stale, and then blocks unrelated work the day someone notices. Pair it with the inverse check too: an entry in the register that the published policy no longer discloses is as much a finding as one the policy discloses and the register omits.

And **evidence expires.** A control passing on a pull request proves something about that pull request — not that the system was compliant on any date. Where a date matters (legal, certification), the evidence lane is scheduled, writes one dated artifact per run to a durable location, and **records red days rather than skipping them**: a failed run is the finding.
