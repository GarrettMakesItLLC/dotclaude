# API contract quality

The question: **is the REST surface consistent, versioned, documented, and safe to evolve?** Authz on routes belongs to `security-access-control`; this realm is the shape of the contract.

## Checklist
- **Consistency.** Naming (plural nouns, casing), verbs (PUT vs PATCH semantics), status codes (201 on create, 204 on delete, 409 vs 422), error envelope shape — one shape everywhere or a finding per deviation. Pagination: one style with a max page size on every list route (find the unbounded one).
- **Validation.** Every route body/query/params schema — routes with none; schemas that accept `any` or `.passthrough()`; numeric limits (a `limit` query with no max); ID formats validated.
- **Documentation drift.** The generated API index vs live routes (verify the generator's test fires); hand-written sections vs actual response shapes (diff three); OpenAPI if present vs routes.
- **Versioning and deprecation.** Versioned vs unversioned routes; deprecated routes with no sunset header/date and callers still hitting them; breaking changes since the last promoted release (`git diff main..dev -- apps/server/src/routes` for removed fields).
- **Client/server contract.** Types shared via the types package vs hand-typed in the web app; a response field the client reads that the server no longer sends (sample 20 routes).
- **Idempotency and safety.** Non-idempotent POSTs on retry paths (payments, imports) without an idempotency key; GETs with side effects; DELETEs soft in one place and hard in another.
- **Rate limits and payload limits.** Per-route limits present, sensible, and tested; body size limits; file upload limits vs the bucket's.
- **Caching headers.** `Cache-Control`, `ETag` on read-heavy public routes; `Vary` correctness; private data never cacheable.
- **Webhooks in.** Signature verification, replay protection, idempotent processing, and a dead-letter path for every inbound webhook.
- **Public API for third parties.** If one exists: scopes, key rotation, docs, changelog.

## Gates
A route-schema-presence test; an error-envelope test across all routes; the API index drift test verified to fire; a list-route max-page-size test; a shared-types parity test.
