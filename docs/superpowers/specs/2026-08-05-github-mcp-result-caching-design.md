# `github-rest` MCP: process-lifetime result caching

## Problem

`mcp/github` already caches the auth token, default repo, and project fields/items
for the life of the stdio process (`github.ts`, `project.ts`) — but `issue_view`,
`pr_view`, and `repo_get` hit the network fresh on every call. A `Workflow`
fan-out where several subagents each independently look up the same issue (a
common shape — e.g. every verifier in a review pipeline re-reading the finding's
source issue) re-fetches and re-serializes it once per agent, for identical
results.

## Goal

Cache single-object reads for the life of the MCP process, invalidated the
instant this same process writes to that object — never a source of staleness
within a session, only of avoided duplicate work.

## Design

`github.ts` gains a small generic memo, next to the existing `cachedToken`/
`cachedRepo`:

```ts
const objectCache = new Map<string, unknown>();

function cacheKey(kind: string, repo: string, id: number | string): string {
  return `${kind}:${repo}#${id}`;
}

async function cachedGet<T>(key: string, fetcher: () => Promise<T>): Promise<T> {
  if (objectCache.has(key)) return objectCache.get(key) as T;
  const value = await fetcher();
  objectCache.set(key, value);
  return value;
}

function invalidate(key: string): void {
  objectCache.delete(key);
}
```

Wrapped around exactly three reads — `issue_view`, `pr_view`, `repo_get` — the
ones with a stable single-object key and no query parameters that would change
what "the same call" means. **`issue_list` stays uncached**: its result depends
on the full parameter set (state, labels, limit, pagination), which multiplies
key space for comparatively little payoff since `issue_list` already omits
`body` and is the cheap tool per the existing slimming work.

Every write tool that touches a single issue or PR (`issue_update`,
`issue_set_status`, `issue_set_type`, `issue_set_labels`, `issue_set_effort`,
`issue_set_priority`, `issue_comment`, `issue_claim`, `pr_update`, `pr_merge`,
…) calls `invalidate(cacheKey(...))` for that number after a successful write,
before returning. Missing one is a correctness bug (stale read later in the same
session), so this is enforced the same way the rest of `mcp/github` enforces
its own conventions — a shared test helper that asserts every write tool in
`issues.ts`/`pr.ts` invalidates the object it touches, not a rule to remember
by hand per tool.

No TTL, no cross-process sharing, no persistence — the process boundary is the
cache boundary, same lifetime as the token/repo caches already in `github.ts`.

## Non-goals

- Caching `issue_list`/`pr_list` — parameter-keyed caching for list endpoints is
  a different, harder problem (staleness on label/status changes to *any* item
  in the list, not just one); not worth it until the single-object cache proves
  out.
- Cross-session or on-disk caching. The MCP process restarts with every Claude
  Code session; a warm cache surviving that would need its own invalidation
  story this doesn't need yet.

## Testing

TDD, matching this repo's existing style in `mcp/github`: `slim.test.ts`-style
unit coverage for `cachedGet`/`invalidate` in isolation, then integration-style
tests per tool — `issue_view` called twice returns the same object without a
second fetch (assert the mock fetcher call count), `issue_set_status` on a
cached issue clears it so the next `issue_view` re-fetches.
