# Security, authorization & tenant-isolation audit

Enumerate the surface first, then check every entry. A security audit that samples is a security audit that missed the one.

## Route-by-route, every route

Build the list from the router, not from the pages that call it. For each route:

- **Is authentication attached at all?** A cheap first pass that finds real holes: compare the route count per file against the number of `authenticate`/`requireAuthUser` references in it. Any file where they don't match gets read line by line.
- **Prefer default-deny.** Middleware that authenticates everything with an explicit public allow-list beats per-route opt-in, because the failure mode of forgetting is a 401 rather than a leak.
- **Does the guard check the thing its name implies?** The recurring finding is a role guard that verifies a session exists but never checks the actual role assignment.
- **Wrong-owner responses are 404, not 403** — a 403 confirms the resource exists.
- **Every request body, query, and param is schema-validated** (Zod) at the boundary.

## Tenant and ownership isolation

- **Cross-tenant foreign keys.** An ORM row-level filter scopes what you *read*; it does not stop an untrusted id in a request body from being *written* into a child row. Every untrusted id must resolve through a tenant-scoped parent lookup first, and a null result is a 400/404. Enumerate the child models the automatic filter cannot scope and check each one.
- **RLS deny-by-default on every table**, verified by querying the catalog rather than reading migrations — the finding is always the four tables that were added after the policy sweep.
- **Revoke DML grants to the anonymous and authenticated roles** that the data API exposes but the app never uses. Defense in depth behind RLS, and the grant is what turns one RLS mistake into a breach.
- **Public endpoints spread internal fields.** The fix is an explicit field allow-list on the response, not a deny-list of the fields you remembered.

## Input, output, and transport

- Injection: parameterized queries only; no raw SQL outside a reviewed, tested seam.
- XSS: no unsanitized HTML injection; CSP present and **enforced, not report-only** (report-only is the most common false pass in this realm).
- Security headers: HSTS, `X-Content-Type-Options`, `Referrer-Policy`, frame ancestors.
- **SSRF** via any user-supplied URL that the server fetches — avatar/image URLs, webhooks, imports. Validate scheme, host, and resolved address.
- CORS: no stale preview or wildcard origin reachable in production.
- File upload: type sniffing, size limit, storage isolation, no execution path.
- Webhooks: signature verified on every one, replay window enforced.
- Redirects: no open redirect through a `next`/`returnTo` param.

## Sessions, credentials, and secrets

Session timeout and rotation; lockout and throttling on auth endpoints; password policy; MFA (TOTP) available for privileged accounts; bot protection on public auth surfaces. Secrets: none in client-bundled code, none in the repo (secret scanning in CI), rotated after any exposure — *carried forward, not rotated* is a finding in its own right. Privileged keys (service-role) never reachable from the client bundle.

## Rate limiting and cost

- Every expensive, sensitive, or third-party-billed path is rate limited. Absent limits and **in-memory limits that don't survive a cold start or a second instance** are the same finding.
- Sweep for unmetered third-party API calls in loops or on hot paths — the billing surprise is the incident.

## Dependencies

Vulnerability scan in CI, **without `continue-on-error`** — check that the job actually fails, because the masked-advisories finding recurs. Lockfile integrity, no unvetted transitive additions in the diff, key/package provenance.

## Findings from live signal

Sweeping unresolved production error-tracker issues and filing what is real is its own audit, and one of the highest-yield: these are failures already reaching users. Use the Sentry MCP; dedupe against existing issues.

## Report structure

Findings carry `severity`, and where applicable `cwe` and `owasp` mapping, so the epic can roll up by OWASP Top 10 and by the compliance regimes in scope.

Two sections are mandatory and usually omitted:

- **Verified safe, no change needed** — e.g. RLS deny-by-default across all N tables, all webhooks signature-verified, no path traversal in the docs allow-list. This is what makes the next audit cheaper and dates any later regression.
- **Not verified** — most often "live-app verification not run". State it.

## Gates

Durable tests per finding class rather than a fixed report: CSP present and enforced, HTTPS/HSTS enforced, input validation on every route (derived from the router), rate limiting effective, no anonymous DML grants, RLS enabled on every table. A generated security report whose severity buckets are all empty while the recommendations file lists high-priority items is not a gate — it is a vacuous pass, and finding one is itself a finding.
