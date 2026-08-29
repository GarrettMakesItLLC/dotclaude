# Email & sending-domain audit

Email is the only part of the product that a third party can switch off unilaterally, and the switch is thrown by reputation, not by code. The realm exists because nothing else in this skill looks at DNS, and because the failure is invisible from inside: mail is accepted, the app logs a success, and the message lands in spam or is dropped silently. **Assume nothing about delivery without evidence from outside the app.**

Sending mail is not the same as delivering it. Every finding here distinguishes *sent* (the ESP accepted it) from *delivered* (it reached an inbox) from *seen*.

## Sending-domain architecture

The single highest-leverage finding in this realm, and the one nearly always wrong on a product built by one person: **transactional and marketing mail must not share a sending domain.**

- **Send from subdomains of the brand domain, never the root.** The root domain (`brand.com`) carries the domain's baseline reputation and receives the human mail; burn it and you lose password resets, invoices, and replies at the same time. Sending from the root is the finding, even when everything else is configured correctly.
- **A subdomain per traffic class**, each with its own reputation:
  - **Transactional / app mail** — password resets, receipts, invites, alerts. Low volume, near-100% engagement, must never be delayed. Typically `mail.brand.com` or `app.brand.com`.
  - **Marketing / lifecycle mail** — newsletters, campaigns, promotions, re-engagement. Higher volume, lower engagement, carries the complaint risk. Typically `e.brand.com`, `news.brand.com`, or `go.brand.com`.
  - **Cold outbound**, where it exists, is a *different domain entirely* — not a subdomain of the brand. Its reputation is expected to be damaged, and it must be able to be abandoned without touching the brand's mail. Cold outbound also has its own consent and legal exposure — hand that to `legal-compliance.md`.
- **The consequence of sharing is the whole finding**: one campaign to a stale list drives the complaint rate up and takes password-reset delivery down with it. Users can't log in, and nothing in the app reports an error. Separate the subdomains before volume matters, not after — reputation is built per-domain over weeks, so the fix has a lead time the incident won't wait for.
- **Reply-to is monitorable.** `noreply@` on anything a human might reasonably answer is both a deliverability signal and a UX finding. Where a `noreply` sender is deliberate, the mail says where to reply instead.
- **Separate ESPs per class is fine and often correct** (transactional through a developer ESP, marketing through a lifecycle platform) — but the domain separation is what matters, and having two ESPs on one subdomain is the same finding as one ESP on one subdomain.

## Authentication — check the DNS, not the dashboard

Resolve the records yourself (`dig TXT`, `dig CNAME`) against the live production domain. A provider dashboard showing a green check is the provider's claim about its own setup; the receiving server reads DNS.

- **SPF** present on each sending subdomain, ending `-all` (hard fail), and **under the 10-DNS-lookup limit** — the recurring finding is a record that accreted four `include:` entries as vendors were added and now silently exceeds the limit, which makes SPF fail permanently for every message. Count the lookups; don't eyeball the string.
- **DKIM** published and signing, 2048-bit, and **aligned** with the visible `From:` domain. An unaligned signature passes DKIM and fails DMARC, which is the confusing failure mode.
- **DMARC** present, and **not left at `p=none`**. `p=none` is a monitoring posture, not a policy, and the finding is a record that has sat at `none` since setup with the `rua=` reports going to an address nobody reads. The progression is `none` → `quarantine` → `reject`, moved on evidence from the aggregate reports. Note that the major mailbox providers now enforce authentication requirements on bulk senders, and a `p=none` record is increasingly not sufficient — verify the current thresholds against the providers' published sender requirements before citing a number, and cite the text you read.
- **`rua=` points somewhere a human or a tool actually reads.** A DMARC report address that black-holes is a guard that exists and never fires.
- **BIMI** only after `p=quarantine`/`p=reject` is in force; treat its absence as a finding only where brand presentation in the inbox is a stated goal.
- **MX and the receiving side** — a sending subdomain that also needs to receive (replies, bounces) has the MX to do it; bounce handling that nothing processes means suppression lists never grow.

## Reputation, warm-up, and list health

- **A new sending domain is warmed** — staggered volume over weeks, engaged recipients first. Blasting a full list from a cold domain is the fastest way to a permanent reputation problem, and it is not recoverable by fixing the DNS afterward.
- **Dedicated IP only at volume**; below the provider's stated threshold a shared pool has better reputation than an unwarmed dedicated IP. State the volume, then decide — don't inherit the choice from a plan tier.
- **Complaint rate and bounce rate are monitored against the providers' published thresholds**, and the monitoring alerts rather than sitting on a dashboard. The complaint threshold is the number that ends a sending program.
- **Suppression is honored across every send path.** The finding: an unsubscribe recorded in the marketing platform while the app's own transactional path still mails the address, or a hard bounce that never becomes a suppression. Enumerate every code path that can send mail and check each reads the same suppression source.
- **List hygiene**: no purchased or scraped lists (also a `legal-compliance.md` finding), sunset policy for chronically unengaged recipients, re-engagement before removal, and no address that entered the list without a traceable consent event.
- **One-click unsubscribe** (`List-Unsubscribe` and `List-Unsubscribe-Post` headers) on every marketing message, honored within the published window. An unsubscribe link buried in a footer image is the failure this header exists to prevent.

## What the product actually sends

Enumerate every send site in the codebase — grep the ESP client, not the templates — and for each:

- **Which class is it, and is it going out of the right subdomain?** A transactional receipt sent through the marketing platform is a common and invisible misroute.
- **Is a failure to send observable?** An ESP call whose error is swallowed means password resets fail silently. This is the email-shaped version of `performance-ops.md`'s "cron throws into the void."
- **Is the send idempotent?** A retried job that re-sends an invoice is a user-facing incident.
- **Does every message render in plain text and in a dark-mode client?** Image-only mail is a spam signal and an accessibility failure at once.
- **Are the lifecycle flows that the product's model requires actually present?** Welcome, activation/onboarding, abandoned-intent, dunning/failed-payment, win-back. A missing dunning flow is revenue leaking on a schedule; file it as a finding, not a roadmap idea. Depth on flow content and copy belongs to the `email-marketing-bible` skill — this audit checks presence, routing, and instrumentation, not subject-line craft.
- **Consent and legal**: every marketing send traces to a consent record, the physical address is present, and the regime in scope (CAN-SPAM / CASL / GDPR) is satisfied — that analysis is `legal-compliance.md`'s and `privacy-data-processing.md`'s, not re-derived here.

## What this audit cannot settle

**The DNS half is auditable from outside; the ESP half is not.** Resolving records proves what is published; it does not prove what the provider will accept, issue, or let you configure. Findings that turn on provider capability need a round-trip through the provider before their fix text is final, and stating them as settled produces confident, wrong remediation steps.

Observed instances, worth knowing before writing a fix:

- **A provider may not offer the key size the standard asks for.** One ESP issues 1024-bit DKIM with no option to change it; "regenerate at 2048-bit" is then not a step the owner can take, and the real mitigation is elsewhere in the record.
- **A provisioned subdomain is not necessarily a spare sending domain.** A `send.` subdomain carrying SPF and a bounce MX is frequently the *Return-Path* subdomain the ESP created for the apex — reusing it as a visible `From:` breaks bounce handling.
- **DNS may not be writable where you expect.** A domain held at one registrar's nameservers cannot have records written through a hosting provider's API, however the domain appears in that provider's dashboard.

**Verify every provisioning write by reading it back.** A provider's write API can accept a field, answer `200` with a well-formed object, and ignore it — observed: `POST /webhooks` with `"status": "disabled"` returning a correct-looking object and creating the webhook *enabled*, because the REST endpoint silently drops a field the vendor's own SDK exposes. The mutation's success response is not evidence that the mutation did what it said; only a subsequent read is. This applies to the `PATCH` that fixes it too.

**Provision in the safe order: create the receiver disabled, ship the handler, then enable.** An endpoint pointed at a route that does not exist yet collects delivery failures immediately, and the provider auto-disables it after enough of them — leaving something that reads as configured, records nothing, and is discovered only when someone asks why there are no suppressions. Same shape as the rest of this section: present, well-formed, inert.

Watch for two receivers on one URL. Only one signing secret can be current, so the losing endpoint fails signature verification on every delivery, retries, and is auto-disabled — with the same silent-zero-suppressions result.

Report provider-capability limits as owner action naming the round-trip, not as a fix. And sequence the fix so it cannot make delivery worse: **publish and verify SPF and a DKIM selector on the new subdomain before moving any traffic to it.** Sending from an unauthenticated subdomain under an enforcing DMARC policy authenticates worse than the apex it left, so the switch ships defaulted off until the records resolve.

## Gates

- **A scheduled check resolving SPF, DKIM selector, and DMARC for every sending subdomain, asserting the policy strings** — this is the one that matters, because DNS drifts when a vendor is added and nothing in CI notices. It runs on a schedule against production DNS, not in the PR pipeline.
- A test asserting every send path reads the shared suppression list before dispatching.
- A test asserting a send failure surfaces to the error tracker rather than being swallowed.
- Complaint- and bounce-rate alerting is an owner action configured in the ESP — check the dashboard or the completed-external-actions ledger before filing it as missing.
- Inbox placement and rendering are live-signal checks (seed-list test, real client rendering). State plainly in the epic's *Not verified* section where only DNS and code were read.
