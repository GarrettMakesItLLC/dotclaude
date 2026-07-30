# Feature-completeness & gap analysis

Four distinct questions, easily conflated. Pick the one being asked; run more than one only with separate sub-tracks.

## 1. Spec drift — does the implementation match the spec?

Section by section, with `file:line`. The high-yield findings are not missing features but **drifted constants**: reward values, level tables, tier counts, thresholds, caps — each of which was edited on one side only.

**The spec is not automatically right.** Every drift item resolves one of two ways: schedule the code change, or update the spec to match reality. A drift list where neither happened is the drift, restated.

## 2. Built but not surfaced — is the shipped capability reachable?

The pattern is a mature engine behind a thin interface: solid in the engine room, thin on the bridge. Method: inventory capability by domain, then check each for a user-reachable entry point.

Output shape that worked: headline finding → cross-cutting themes → **domain maturity table** (Domain | State: solid / partial / skeleton | Biggest gap) → prioritized roadmap where every item has a **stable ID** (`QW-*` quick win, `BB-*` big bet), an issue, an effort, and a theme. Companion documents reference those IDs and never mint new ones.

## 3. Orphan and dead surface — what exists that nothing uses?

- Registered routes with no caller in any client; whole CRUD sets that were never wired.
- `@deprecated`, `legacy`, `TODO: remove`, v1/v2 naming collisions.
- Unused exports (`ts-prune`), orphaned components, dead feature flags.
- Duplicate displays of the same concept — pick the one first-class surface and demote the rest.

This deliverable is **audit-only by design**: every finding is triaged into *wire it up* or *delete it* with a one-line rationale, and filed. Fixing inline turns one reviewable audit into an unreviewable diff.

## 4. Cross-repo parity — what does the more mature sibling have that this one should adopt?

Run as parallel code-verified tracks (CI/build, DX/testing, transferable features). Two sections are mandatory, and both are usually missing:

- **Already present here, excluded** — otherwise the reader can't tell coverage from omission.
- **Deferred / low value, not filed** — one line of reason each. This is where a parity analysis earns its keep, by killing work rather than creating it.

## Cross-cutting: what a completeness audit must always check

- **Mock data masquerading as a feature** — `Math.random()` in a production path, synthetic fallbacks presented as real data, simulated third-party calls. Always a finding, sometimes a safety liability (see `data-integrity-safety.md`).
- **Forked implementations.** Byte-identical copies of the same module in three places is a live bug, not tech debt. Gate with a drift-detection script — and make it fail, not warn: a warning-only drift audit is how the third fork arrived.
- **Environment allow-lists standing in for authorization** (`ADMIN_EMAILS` and relatives).
- **In-memory state that doesn't survive a cold start** — rate limiters, caches, counters.
- **A published invariant with no enabled-path coverage.** Six documented guarantees behind a flag with zero tests on the enabled path is a completeness gap, not a testing gap.

## Method notes

- Dispatch one auditor per domain and synthesize; a single reader over a wide surface produces an unevenly-deep list.
- The deliverable that earns re-reading is the **priority matrix**: Domain | Status (done / partial / missing) | Priority P0–P3 | Effort S/M/L/XL | one line. Then wave sequencing. Then the per-domain detail.
- Record **anti-patterns not to port** and **decisions not to build**, with the evidence chain, so neither is re-litigated.
- Include a **stop rule** where the audit is driving an abstraction or a migration — a stated condition under which the approach is wrong and the work halts.
