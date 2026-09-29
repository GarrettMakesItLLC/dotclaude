# Off-site presence audit: social accounts, ad accounts, analytics property, listings

Everything a product says and spends outside its own repo: the social accounts and every post on them, the live ad accounts, the analytics property's configuration, the store and business listings, and the brand's footprint in search and directories. It is the realm no code scan reaches. The accounts are configured in consoles, the posts sit in a scheduler's queue, and the repo holds, at best, the plan that produced them.

**The live account is the target, and the repo is the claim about it.** A campaign doc, a content calendar or a listing doc says what should be live. Read what *is* live through the platform's API, and treat every difference as a finding, in either direction. The most productive single check in this realm is that comparison: a fix that corrected the doc and was never pushed to the account, an account setting nobody recorded, or a guard that reads the doc and so cannot see the account.

Its neighbours: `growth-ads-conversion.md` owns the on-site half (event definitions, where they fire, consent gating on the site). This realm owns the account half (which of those events the analytics property keys and the ad platform bids on). A claims defect in ad or post copy is filed here and tagged for `legal-compliance.md`.

## Before dispatching

- **Find the credentials first, and pull the data once.** The scheduler (Upload-Post, Buffer, the product's own board), ad-platform API tokens, the analytics Admin/Data API and the store console API are usually already on the box. Check the owner ledger before writing "no access". Scheduler history and queues run to hundreds of KB. Have the lead dump them to files once (the full history, every page, plus the whole queue) and give auditors the files. Otherwise each auditor re-pages the API and trips its rate limit.
- **Split by sub-surface, one auditor each:** organic social (accounts + every post + the queue), paid (every ad account), measurement (analytics property + ad-platform datasets), listings and footprint (stores, business profiles, directories, brand SERP, logged-out profile pages). Paid and measurement both touch conversion actions. Tell them so, and expect to merge one finding.
- **Strictly read-only.** GET, search and report queries only: no mutate, post, pause or reply. State it in the brief. The OAuth token exchange is the only permitted POST.
- **Tell auditors what counts as owner action.** A config change an agent could apply with a credential already on the box is not owner action. File it at its normal severity with the exact API call in the Fix line. Owner action is for a console-only setting, billing, identity verification, or enabling spend.

## Organic social

- **Outcome per platform, per post.** Pull per-post analytics and compute the median impressions per post, per platform. A platform at a median of 0–2 is publishing to nobody, and the finding is the *queue* still feeding it. Count the queued placements.
- **Identity:** display name, handle, avatar, bio and bio link on every platform, read logged out, against the repo's bios doc. Check which identity each account is connected through: a brand Page administered from a personal profile shows that person's name in connected-account data, dataset names and post attribution. Look for posts that landed on a personal profile instead of the page.
- **Every link in every post and every queued post:** it resolves on the final hop, lands on the page the caption promises, and carries UTMs matching the measurement plan. "0 of N links carry a UTM" is a common result, and it is the cause of an "unattributed social traffic" symptom in the measurement sub-surface.
- **Lint the queue, not just the history.** Run every platform's rules over every queued placement: weighted length (X counts a URL as 23), caption limits, hashtag caps (current platform limits: verify against the platform's published announcement, don't recall them), a "link in bio" on a platform with no bio link, banned characters, prices or claims an owner decision has retired. A failure class in the history (403s, over-length rejections, a wrong id format) recurs in the queue until something checks it. Count the recurrences.
- **Duplicates and cadence.** Look for companion posts (covers, stories, reels) that land on the same feed as the parent. Compare actual weekly cadence per platform against the documented cadence.
- **Anomalous engagement.** Likes, shares and saves each at 25–40% of views, with zero comments, follows and profile visits, does not come from an organic audience. Flag it before any "double down on the top posts" rule selects those posts.
- **Posts that never published.** Inbox and draft deliveries, and rows with no public URL. A doc recording a launch post to a channel whose history has zero rows is a finding.

## Paid

- **Enumerate the account:** every campaign, ad group or ad set, ad, keyword, asset, audience, conversion action and budget, with status, review or policy state, and ad strength.
- **Conversion actions are the highest-value read.** Which actions are primary and biddable, and what each one actually counts. Trace an imported analytics conversion back to its source event and any event-create rule behind it: a "Sign Up" built from `page_view` on `/signup` counts visits, not signups. Look for hidden or non-primary actions that are the real signal, and for leftover actions from a platform's smart or local-campaign setup (calls, directions) that are primary on an app with no phone line.
- **Ad copy against current product truth and against retractions.** Search closed issues for claims that were retracted in the doc, then grep the live ad text for them. Responsive ads mix headlines and descriptions freely, so a retraction made in one field still serves from the other.
- **Settings a doc specifies and a default overrides:** geo target type (presence vs presence-or-interest), network partners, CTA buttons, display paths, and tracking templates or URL tags on every active ad.
- **Posture checks that read the wrong field.** When a repo script asserts account posture, check that it reads the field the platform documents as controlling that setting. A check reading a similarly named field passes whatever the setting is.
- **Leftovers:** smoke-test or tool-generated campaigns left in the account, assets pending review for days, spend ledgers describing an older account state.

## Measurement (account side)

- Enumerate the property: data streams, key events, event-create and event-edit rules, custom definitions, links, retention, enhanced-measurement toggles, attribution, signals, redaction. Record which settings have **no API** (internal-traffic filter state, unwanted referrals, cross-domain, consent settings) and route them to owner action with literal steps.
- **Event retention** at the default 2 months silently truncates every exploration and funnel. Standard reports hide the gap.
- **Reconcile across platforms:** ad-platform link clicks or landing-page views vs analytics sessions for the same ads and dates. A ratio far below what consent and in-app browsers explain means a tagging gap: ads without URL tags, or click-id arrivals classified as organic.
- **Bot share:** sessions from datacenter cities (ad-platform review crawlers, cloud regions) with no engagement. Before blaming the consent gate, reproduce a fresh no-consent load and capture the vendor requests. Zero requests means the bots accept the banner, not that the gate leaks.
- **Self-referrals** from the auth provider and the payment checkout steal attribution from every member who signs in with them.

## Listings and footprint

- **Store console API** (App Store Connect, Play Developer API): every localized field against the listing doc, screenshots per device class (and what each one actually shows), age rating as computed (not as intended), availability, review detail, and accessibility and privacy declarations. Where no credential exists, fetch the public listing and say so.
- **Business profiles** (Google Business and equivalents): category, website, hours, photos, description, and the pin as rendered publicly. Maps is JavaScript-only, so render it with a headless browser. On a scheduler connected to several businesses, check that a default location is set, or a post can land on the wrong business.
- **Directories and aggregators** named in the repo's outreach docs: claimed, live, and carrying current positioning. A ticked checkbox with no listing is a finding. Prove a "no results" search shape with a known-present query before reading absence.
- **Brand SERP and handles:** what ranks for the brand, stale indexed titles (compare the served title across browser and crawler user agents to rule out cloaking), name collisions, handles held by others on each platform, and cheap typo or TLD domains still unregistered.

## Gates

External state can't be gated by an ordinary PR check. The gate is a **read-back**: a scheduled or pre-release script that queries the account and compares it with the repo's declared state. For example: a queue lint run before the scheduler publishes; a posture script asserting conversion-action primacy, retention, geo target type and a copy denylist over live ad text; a store-listing diff against the parsed listing doc. Say which read-back catches each finding, or that none can.

## Severity

🔴 live spend landing on a broken destination; a suspended account or policy strike; a false health or earnings claim running publicly; credentials or PII exposed. 🟠 money or posts wasted at scale (a platform publishing to nobody with hundreds more queued; optimisation blind because the primary conversion counts the wrong thing); a split brand identity on a public account. 🟡 a defect in a subset, missing attribution, drift between account and doc. 🟢 polish.
