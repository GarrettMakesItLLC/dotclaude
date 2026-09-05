# Resilience & dependency concentration audit

The question: **name every single thing whose failure takes the product down, and say what happens when it does.** Not a security realm (nobody is attacking) and not a performance realm (nothing is slow) — which is exactly why the findings sit unowned until the outage.

Method is enumeration, then one question per entry: *if this is unavailable for four hours, what does a user see?* An answer of "I don't know" is the finding.

## The concentration inventory

Build the list from configuration and lockfiles, not from memory. For each, record what it does, what it costs to lose, and whether a substitute exists.

- **Vendors and third-party APIs** — auth, database, payments, email, storage, analytics, AI/LLM providers, maps, geocoding. Each is somebody else's uptime.
- **Regions and availability zones** — a single-region database with a single-region app is a stated choice or a finding; there is no third option.
- **Credentials** — one API key, one service account, one OAuth app, one domain registrar login. A key with no documented rotation path is an outage waiting on an expiry date. Check for keys with hard expiries nobody has diarized.
- **Runtime dependencies** — packages doing load-bearing work. Flag any that is unmaintained (no release in ~18 months), has a single maintainer, is a wrapper thin enough that vendoring is cheaper than depending, or has a license incompatible with the product's distribution.
- **Human** — one person who can deploy, one person who holds the DNS. Real, and file it as owner action rather than pretending it's a code finding.
- **Money** — one payment processor, and one customer or channel supplying a majority of revenue. Out of scope for a code audit, in scope for a launch-readiness one; note it and move on.

## Blast radius

For each dependency on the inventory:

- **Does its failure degrade the product, or stop it?** A recommendations API that takes the dashboard down with it is the finding — the recommendation was never load-bearing, but nothing said so in code. Non-essential calls fail soft, render an absent state, and never block the shell.
- **Is there a timeout?** Every outbound call has an explicit one. The default in most clients is "forever," and a hung upstream converts into an exhausted connection pool and a total outage — a dependency failure that becomes an availability incident by way of a missing five-line configuration is the most common shape here.
- **Retries are bounded, backed off, and jittered**, and only on idempotent operations. An unbounded retry loop against a struggling upstream is a self-inflicted denial of service, and retrying a non-idempotent write is a `data-integrity-safety.md` finding (see write paths).
- **Circuit breaker or bulkhead** on anything called on a hot path, so one slow dependency can't consume every worker.
- **Is there a fallback, and has it been exercised?** Cached-last-known, a queue for later, a second provider, or an explicitly-stated unavailable state. **A fallback that substitutes plausible data is a safety finding, not a resilience win** — see `data-integrity-safety.md`; failing visibly is the correct behavior.
- **Does the failure reach the error tracker?** A degraded path that silently returns empty is worse than one that throws, because nobody learns it is happening.

## Portability and lock-in

Not an argument for abstraction layers everywhere — an argument for knowing the number.

- **State the exit cost per vendor**, in a sentence: how the data comes out, what replaces the API surface, how long. A vendor with no export path for the product's primary data is a finding regardless of how happy the relationship is.
- **Proprietary APIs concentrated at a seam or scattered through the codebase?** Scattered is not automatically wrong; unexamined is.
- **The build runs somewhere other than the one platform that hosts it** — or at minimum, could. A build that only works inside one provider's pipeline is a dependency nobody counted.
- **Data has a tested restore, not just a backup.** An untested backup is a belief. Restore it once, time it, and write the number down — RPO/RTO claims are also a legal exposure where published (`data-integrity-safety.md`).

## Supply chain

Overlaps `security-access-control.md`'s dependency scan, which owns CVEs and lockfile integrity. This file owns *continuity*: not "is this package vulnerable" but "what if this package stops existing."

- Dependencies pinned via lockfile; the lockfile is committed and CI installs from it frozen.
- No dependency installed from a git URL, a fork, or an unversioned tag on a production path.
- Postinstall scripts inventoried — each one is arbitrary code from a third party running in CI with the environment.
- License compatibility checked for anything shipped or distributed, not just anything imported.

## Cost concentration

The billing analogue of the same question, and it belongs here because the failure mode is identical: one metered dependency, no ceiling.

- **Every metered third-party call has a budget alert on the provider side**, at a number, with somebody notified. LLM inference, geocoding, SMS, and email are the four that surprise people.
- **An unmetered path reachable by an unauthenticated user is both a cost finding and a security finding** — hand the rate-limiting analysis to `security-access-control.md` and file the budget alert here.
- A per-request cost estimate for the three most expensive endpoints. Absent that number, no capacity decision is being made, it is being discovered.

## Gates

- **The inventory itself is the durable artifact** — a checked-in document listing each dependency, its blast radius, its fallback, and its exit cost. A finding here that produces only issues gets re-derived by the next audit; an inventory gets diffed.
- A drift check that the inventory names every entry in the lockfile's direct dependencies and every configured external service, so a vendor added in a PR fails the build until it is described.
- A test per non-essential dependency asserting the surface renders its absent state when the call errors — the same test shape as `data-integrity-safety.md`'s unavailable-state assertion, and worth writing once as a shared helper.
- Timeout and retry configuration is assertable at boot: refuse to start if any registered client has no timeout set.
- Backup restore is a scheduled, dated exercise, not a PR check. It records red days rather than skipping them.
