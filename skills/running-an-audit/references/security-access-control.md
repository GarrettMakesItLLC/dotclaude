# Security, authorization & tenant-isolation audit

Enumerate the surface first, then check every entry. A security audit that samples is a security audit that missed the one.

## Route-by-route, every route

Build the list from the router, not from the pages that call it. For each route:

- **Is authentication attached at all?** A cheap first pass that finds real holes: compare the route count per file against the number of `authenticate`/`requireAuthUser` references in it. Any file where they don't match gets read line by line.
- **Prefer default-deny.** Middleware that authenticates everything with an explicit public allow-list beats per-route opt-in, because the failure mode of forgetting is a 401 rather than a leak.
- **Does the guard check the thing its name implies?** The recurring finding is a role guard that verifies a session exists but never checks the actual role assignment.
- **Authorization is never client-side only.** A role or permission read in the browser to decide what to render is a display concern, and the server must re-check it on every request behind it. The signature finding: an admin panel gated by `if (user.role === 'admin')` in a React component, with the API routes it calls guarded by nothing — the entire panel is reachable by anyone who edits their local state or calls the endpoints directly. Enumerate every client-side role/permission/flag check and confirm the server-side counterpart exists for each; a client check with no server twin is a blocker, not a medium.
- **The client never receives what it isn't authorized to see**, on the theory that it will hide it. Hidden-but-present data in a payload, a props blob, or an RSC serialization is disclosed data.
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

Session timeout and rotation; bot protection on public auth surfaces.

- **Rate limiting and lockout on every authentication surface** — login, signup, password reset, email verification resend, MFA challenge, and any magic-link or OTP request. Per-account *and* per-IP, because either alone is trivially defeated. The recurring finding is a product that rate-limits its expensive API and leaves `/login` unlimited, which is the one endpoint an attacker actually wants unlimited. In-memory limiters that don't survive a cold start or a second instance are the same finding as no limiter.
- **Password strength enforced server-side**, and enforced by *entropy and breach status*, not by a composition rule — a length floor (12+), a check against a known-breached-password set (k-anonymity range query against a service, or a local list), and a block on obvious context words (the product name, the user's email local-part). Composition rules alone (one uppercase, one symbol) produce `Password1!` and are worse than a length floor. A client-side-only strength meter with no server check is the same defect as a client-side admin check.
- **MFA is available**, at minimum TOTP, and it is *required* for privileged accounts rather than merely offered. Recovery codes issued once, hashed at rest, and single-use. Where the product uses email OTP or magic links, those get their own rate limit, a short TTL, single use, and invalidation on consumption — an OTP with no attempt ceiling is a six-digit brute force.
- Session invalidation on MFA enrolment change, the same as on password change. Secrets: none in client-bundled code, none in the repo (secret scanning in CI), rotated after any exposure — *carried forward, not rotated* is a finding in its own right. Privileged keys (service-role) never reachable from the client bundle.

- **Passwords hashed** (bcrypt/argon2), never stored or logged plain.
- **Session token never in `localStorage`/`sessionStorage`** — an XSS becomes a full account takeover instead of nothing; httpOnly + secure + `SameSite` cookie, or short-lived memory token with rotation.
- **Sessions invalidated on password change and on logout everywhere** (not just the current device) — a stolen session outliving the password reset that was supposed to kill it is the recurring failure.
- **Password-reset links expire** (short TTL, single-use, invalidated once consumed) and **don't leak whether an account exists** — same response shape for "sent" regardless of whether the email matches a real account.
- **CSRF tokens on state-changing requests** wherever session auth is cookie-based (SPA-with-bearer-token architectures are exempt by design — state the exemption rather than a missing check).
- **Directory listing disabled** on any static/asset host; **no default admin route** (`/admin`, `/wp-admin`-shaped paths) left reachable from a scaffold.
- **Security events logged**: failed logins, privilege changes, admin actions — enough to reconstruct an incident, not just enough to know one happened.
- **Prod error responses never include a stack trace** or internal path — a generic message to the client, the real trace to the error tracker only.
- **IDs are not sequential/predictable** (UUID or equivalent) wherever enumeration would expose another tenant's records.
- **Request/response bodies aren't logged wholesale** — a full-body log is a PII and secret leak waiting on the next `console.log` left in.
- **AI-specific**: prompt-injection resistant to untrusted input reaching the system prompt or tool-call arguments; per-user/per-IP usage caps on any LLM-backed endpoint (the cost equivalent of rate limiting, and a distinct finding from it); user-supplied content never reaches a tool call's privileged arguments (file path, SQL, shell) unvalidated.
- **Storage buckets default-private**, checked against the actual provider config (Supabase/S3 bucket policy), not assumed from the app code — a bucket flipped public during debugging and never flipped back is a recurring finding.
- Amounts/prices computed and re-validated **server-side** from the source of truth, never trusted from a client-submitted value, on any path that touches payment.

## Rate limiting and cost

- Every expensive, sensitive, or third-party-billed path is rate limited. Absent limits and **in-memory limits that don't survive a cold start or a second instance** are the same finding.
- Sweep for unmetered third-party API calls in loops or on hot paths — the billing surprise is the incident.

## Dependencies

Vulnerability scan in CI, **without `continue-on-error`** — check that the job actually fails, because the masked-advisories finding recurs. Lockfile integrity, no unvetted transitive additions in the diff, key/package provenance. Continuity — an unmaintained or single-maintainer dependency, license compatibility, postinstall scripts, and what happens when a vendor is simply unavailable — is `resilience-dependencies.md`'s; this section owns vulnerabilities and provenance only.

## Findings from live signal

Sweeping unresolved production error-tracker issues and filing what is real is its own audit, and one of the highest-yield: these are failures already reaching users. Use the Sentry MCP; dedupe against existing issues.

## Report structure

Findings carry `severity`, and where applicable `cwe` and `owasp` mapping, so the epic can roll up by OWASP Top 10 and by the compliance regimes in scope.

Two sections are mandatory and usually omitted:

- **Verified safe, no change needed** — e.g. RLS deny-by-default across all N tables, all webhooks signature-verified, no path traversal in the docs allow-list. This is what makes the next audit cheaper and dates any later regression.
- **Not verified** — most often "live-app verification not run". State it.

## Gates

Durable tests per finding class rather than a fixed report: CSP present and enforced, HTTPS/HSTS enforced, input validation on every route (derived from the router), rate limiting effective, no anonymous DML grants, RLS enabled on every table. A generated security report whose severity buckets are all empty while the recommendations file lists high-priority items is not a gate — it is a vacuous pass, and finding one is itself a finding.
