import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { z } from "zod";

const execFileAsync = promisify(execFile);

const BASE_URL = "https://api.github.com";
const USER_AGENT = "github-rest-mcp";
const API_VERSION = "2022-11-28";

let cachedToken: string | null = null;
let cachedRepo: string | null = null;
let cachedViewer: string | null = null;

/**
 * Env with `GH_TOKEN`/`GITHUB_TOKEN` stripped — used to ask `gh` for its
 * KEYRING credential specifically, since `gh` prefers an env-var token over its
 * own stored login whenever one is present.
 *
 * This is a way of naming one candidate, not a policy about which wins. See
 * `selectToken` below for that.
 */
const GH_KEYRING_ENV = (() => {
  const env = { ...process.env };
  delete env.GH_TOKEN;
  delete env.GITHUB_TOKEN;
  return env;
})();

/**
 * The scopes this server actually needs. `project` covers the Projects v2
 * fields (Effort, Priority); `read:project` is the read-only form GitHub also
 * accepts for the queries here.
 */
const REQUIRED_SCOPES = ["repo", "read:org", "workflow", "project"] as const;

/** Whether a scope set satisfies one required scope, allowing read-only forms. */
function satisfies(scopes: Set<string>, required: string): boolean {
  if (scopes.has(required)) return true;
  return scopes.has(`read:${required}`);
}

/**
 * The classic OAuth scopes a token carries, or `null` when that is unknowable —
 * a fine-grained PAT reports no `x-oauth-scopes` header at all, and a failed
 * probe must not be read as "no scopes".
 */
async function probeScopes(token: string): Promise<Set<string> | null> {
  try {
    const res = await fetch(`${BASE_URL}/`, { headers: buildHeaders(token) });
    if (!res.ok) return null;
    const header = res.headers.get("x-oauth-scopes");
    if (header == null) return null;
    return new Set(
      header
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean),
    );
  } catch {
    return null;
  }
}

/**
 * Choose between the keyring login and the ambient `GH_TOKEN`/`GITHUB_TOKEN` by
 * MEASURING both, rather than by assuming which is wider.
 *
 * This used to strip the env var unconditionally, on the theory that the
 * interactive `gh auth login` is the wider-scoped credential. That is true on
 * some machines (#219, #205, #204, #203, #188) and exactly backwards on others:
 * on one box the keyring login carried `gist, read:org, repo, workflow` while
 * the stripped PAT carried `project` as well, so the fallback was what lost the
 * scope — and Effort and Priority silently stopped being settable (#263, #225).
 *
 * Neither credential is reliably the better one, so neither gets to be the
 * default. Both are probed for the scopes this server needs and the one
 * covering more of them wins. Ties, and any candidate whose scopes cannot be
 * read (a fine-grained PAT reports none), fall back to the keyring — the prior
 * behaviour, so this is never worse than before and is better wherever the
 * measurement actually distinguishes them.
 */
async function selectToken(): Promise<{ token: string; source: string }> {
  let keyring: string | null = null;
  try {
    const { stdout } = await execFileAsync("gh", ["auth", "token"], { env: GH_KEYRING_ENV });
    keyring = stdout.trim() || null;
  } catch {
    keyring = null;
  }

  const ambient = (process.env.GH_TOKEN || process.env.GITHUB_TOKEN || "").trim() || null;

  if (!keyring && !ambient) {
    throw new Error(
      "Failed to obtain a GitHub token: `gh auth token` produced nothing and no " +
        "GH_TOKEN/GITHUB_TOKEN is set. Run `gh auth login` to authenticate the " +
        "GitHub CLI, then try again.",
    );
  }
  if (!ambient) return { token: keyring as string, source: "gh keyring" };
  if (!keyring) return { token: ambient, source: "GH_TOKEN/GITHUB_TOKEN" };
  if (keyring === ambient) return { token: keyring, source: "gh keyring" };

  const [keyringScopes, ambientScopes] = await Promise.all([
    probeScopes(keyring),
    probeScopes(ambient),
  ]);
  if (!keyringScopes || !ambientScopes) return { token: keyring, source: "gh keyring" };

  const score = (scopes: Set<string>) =>
    REQUIRED_SCOPES.filter((r) => satisfies(scopes, r)).length;
  return score(ambientScopes) > score(keyringScopes)
    ? { token: ambient, source: "GH_TOKEN/GITHUB_TOKEN" }
    : { token: keyring, source: "gh keyring" };
}

/**
 * Env for a spawned `gh`, carrying the token this server chose.
 *
 * Spawned `gh` has to agree with `ghRequest` about which credential is in use,
 * or the Projects v2 calls that go through `execGh` fail on a scope the REST
 * calls have. Resolved lazily because choosing requires network probes.
 */
let ghSpawnEnv: NodeJS.ProcessEnv | null = null;
async function spawnEnv(): Promise<NodeJS.ProcessEnv> {
  if (ghSpawnEnv) return ghSpawnEnv;
  try {
    ghSpawnEnv = { ...GH_KEYRING_ENV, GH_TOKEN: await getToken() };
  } catch {
    // No resolvable credential. `gh` may still have one this server could not
    // read, and it will produce its own error if not — which is a better
    // message than anything about token selection. Degrade to the stripped
    // env, which is what this did before.
    ghSpawnEnv = GH_KEYRING_ENV;
  }
  return ghSpawnEnv;
}

/**
 * Process-lifetime memo for single-object reads (`issue_view`, `pr_view`,
 * `repo_get`) — same lifetime as `cachedToken`/`cachedRepo` above. Every write
 * tool that touches the object a key names must call `invalidate` for that
 * key after a successful write, before returning, or a later read in the same
 * session goes stale.
 */
const objectCache = new Map<string, unknown>();

/** Build the cache key for a single-object read: `kind:owner/name#id`. */
export function cacheKey(kind: string, repo: string, id: number | string): string {
  return `${kind}:${repo}#${id}`;
}

/** Return the cached value for `key`, or fetch it once and cache it. */
export async function cachedGet<T>(key: string, fetcher: () => Promise<T>): Promise<T> {
  if (objectCache.has(key)) return objectCache.get(key) as T;
  const value = await fetcher();
  objectCache.set(key, value);
  return value;
}

/** Drop `key` from the object cache — call after any write that changes it. */
export function invalidate(key: string): void {
  objectCache.delete(key);
}

/** The widest of the available credentials — see `selectToken`. */
async function fetchToken(): Promise<string> {
  const { token } = await selectToken();
  return token;
}

/**
 * Run a `gh` subcommand and return its trimmed stdout. Used only for the
 * handful of operations REST has no equivalent for (Projects v2 fields) —
 * everything else goes through `ghRequest`, never this.
 */
export async function execGh(args: string[]): Promise<string> {
  try {
    const { stdout } = await execFileAsync("gh", args, {
      maxBuffer: 32 * 1024 * 1024,
      env: await spawnEnv(),
    });
    return stdout.trim();
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    throw new Error(`gh ${args.join(" ")} failed: ${message}`);
  }
}

async function getToken(): Promise<string> {
  if (cachedToken) return cachedToken;
  cachedToken = await fetchToken();
  // The spawn env holds a copy of the token, so a refetch (a 401/403 retry)
  // has to invalidate it too or `gh` keeps using the credential REST just
  // rejected.
  ghSpawnEnv = null;
  return cachedToken;
}

function buildHeaders(token: string): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": API_VERSION,
    "User-Agent": USER_AGENT,
  };
}

interface RequestOptions {
  method?: string;
  /** Parsed and JSON-stringified as the request body. */
  body?: unknown;
  /** Query params appended to the path. */
  query?: Record<string, string | number | undefined>;
}

function buildUrl(path: string, query?: RequestOptions["query"]): string {
  const url = new URL(path.startsWith("http") ? path : `${BASE_URL}${path}`);
  if (query) {
    for (const [key, value] of Object.entries(query)) {
      if (value !== undefined) url.searchParams.set(key, String(value));
    }
  }
  return url.toString();
}

interface GitHubErrorBody {
  message?: string;
  errors?: unknown;
}

async function parseErrorBody(res: Response): Promise<string> {
  let detail = "";
  try {
    const body = (await res.json()) as GitHubErrorBody;
    if (body.message) detail = body.message;
    if (body.errors) {
      detail += ` ${JSON.stringify(body.errors)}`;
    }
  } catch {
    // body was not JSON; status alone is the best signal
  }
  return detail.trim();
}

/**
 * Perform the authenticated fetch with the cached token. On a 401 the token is
 * refetched once and the request retried exactly once. Returns the raw
 * `Response` regardless of status — callers decide how to handle non-2xx.
 *
 * This is the single place the token + single-401-retry behavior lives;
 * `ghRequest` and `ghPaginate` both delegate here so the logic is not
 * duplicated.
 */
async function ghFetch(
  url: string,
  init: RequestInit & { body?: string } = {},
): Promise<Response> {
  let retriedAuth = false;
  let throttled = 0;
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const token = await getToken();
    const headers = buildHeaders(token);
    if (init.body !== undefined) {
      headers["Content-Type"] = "application/json";
    }
    const res = await fetch(url, { ...init, headers });

    // The SECONDARY limit, which is a different thing from the quota
    // `gh api rate_limit` reports and needs a different response. It throttles
    // bursts of mutations under concurrent-agent load while the primary quota
    // still shows thousands remaining — so the documented "check rate_limit and
    // sleep until reset" recovery has nothing to sleep until, and six retries
    // at a fixed 60s all failed identically (#172).
    //
    // Classified before the 401/403 branch below, because it arrives as a 403
    // and would otherwise be read as a stale credential and burn the one auth
    // retry on a problem no token can fix.
    if (await isSecondaryLimit(res) && throttled < THROTTLE_BACKOFF_MS.length) {
      const retryAfter = Number(res.headers.get("retry-after"));
      const waitMs = Number.isFinite(retryAfter) && retryAfter > 0
        ? retryAfter * 1000
        : THROTTLE_BACKOFF_MS[throttled];
      throttled += 1;
      await sleep(waitMs);
      continue;
    }

    // 401 is an invalid token; 403 is a valid token that lacks a scope. Both
    // mean the cached one is the wrong credential to be holding, and only the
    // first was invalidating it.
    //
    // That gap is worse than it sounds: granting the missing scope with
    // `gh auth refresh` changes nothing until the process restarts, and the
    // error keeps reciting the OLD scope list while `gh auth status` shows the
    // new one. The two disagree indefinitely and the message points at a
    // settings page that already looks correct (#302).
    //
    // Retried once either way — a second 403 after a fresh token is a real
    // permission answer, not a stale cache, and must surface.
    if ((res.status === 401 || res.status === 403) && !retriedAuth) {
      retriedAuth = true;
      cachedToken = null;
      continue;
    }

    return res;
  }
}

/**
 * Backoff for the secondary limit, in ms. Bounded and short: this is a burst
 * throttle that clears in seconds, and a caller waiting on a tool call is worse
 * served by a long sleep than by an error saying what to do instead.
 */
const THROTTLE_BACKOFF_MS = [2_000, 8_000, 20_000];

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** The phrases GitHub uses for the secondary limit, across REST and GraphQL. */
const SECONDARY_LIMIT_RE =
  /secondary rate limit|abuse detection|rate limit already exceeded|exceeded a secondary/i;

/**
 * Whether a response is the secondary limit rather than a permission problem or
 * the primary quota. Reads a CLONE so the caller still gets an unconsumed body.
 */
async function isSecondaryLimit(res: Response): Promise<boolean> {
  if (res.status !== 403 && res.status !== 429) return false;
  if (res.headers.get("retry-after")) return true;
  // `x-ratelimit-remaining: 0` with a 403 is the PRIMARY quota, which is a
  // different failure with a real reset time — not this.
  if (res.headers.get("x-ratelimit-remaining") === "0") return false;
  try {
    return SECONDARY_LIMIT_RE.test(await res.clone().text());
  } catch {
    return false;
  }
}

/** Thrown for any non-2xx GitHub API response. Carries the numeric HTTP status
 * so callers can branch on it without parsing the message string. */
export class GhHttpError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = "GhHttpError";
  }
}

/**
 * Build the standard non-2xx error: HTTP status plus the GitHub error `message`
 * (and `errors` if present). The token is never included.
 */
async function requestError(
  method: string,
  path: string,
  res: Response,
): Promise<GhHttpError> {
  const detail = await parseErrorBody(res);
  return new GhHttpError(
    `GitHub API ${method} ${path} failed: HTTP ${res.status}${
      detail ? ` — ${detail}` : ""
    }`,
    res.status,
  );
}

/**
 * Perform a GitHub REST request. REST only — never GraphQL.
 * On a 401 the token is refetched once and the request retried once.
 * On any other non-2xx, throws an Error including the HTTP status and the
 * GitHub error `message` (and `errors` if present).
 */
export async function ghRequest<T = unknown>(
  path: string,
  options: RequestOptions = {},
): Promise<T> {
  const url = buildUrl(path, options.query);
  const method = options.method ?? "GET";
  const init: RequestInit & { body?: string } = { method };
  if (options.body !== undefined) {
    init.body = JSON.stringify(options.body);
  }

  const res = await ghFetch(url, init);

  if (!res.ok) {
    throw await requestError(method, path, res);
  }

  if (res.status === 204) {
    return undefined as T;
  }

  const text = await res.text();
  if (!text) return undefined as T;
  return JSON.parse(text) as T;
}

interface GraphQLError {
  message: string;
}

interface GraphQLResponse<T> {
  data?: T;
  errors?: GraphQLError[];
}

/**
 * Perform a single GitHub GraphQL request. Only for what REST genuinely has no
 * equivalent for (Projects v2 field reads/writes) — everything else goes
 * through `ghRequest`. Unlike `gh project item-list`, this lets a caller ask
 * for exactly the fields it needs (e.g. one issue's project item) instead of
 * paginating the entire board, which is what made `findProjectItem` expensive
 * on a project with thousands of items (#490).
 */
export async function ghGraphQL<T = unknown>(
  query: string,
  variables: Record<string, unknown> = {},
): Promise<T> {
  const res = await ghFetch(`${BASE_URL}/graphql`, {
    method: "POST",
    body: JSON.stringify({ query, variables }),
  });

  if (!res.ok) {
    throw await requestError("POST", "/graphql", res);
  }

  const body = (await res.json()) as GraphQLResponse<T>;
  if (body.errors?.length) {
    const detail = body.errors.map((e) => e.message).join("; ");
    // GraphQL reports the secondary limit as a 200 carrying an error, so the
    // HTTP-level handling in `ghFetch` never sees it. Not retried here — the
    // mutation may well have taken effect, and a blind retry on a write is
    // worse than an honest failure. Said in terms the caller can act on
    // instead, because the obvious next move (sleep until the reset that
    // `rate_limit` reports) is the one that cannot work (#172).
    if (SECONDARY_LIMIT_RE.test(detail)) {
      throw new Error(
        `GitHub GraphQL error: ${detail}\n\n` +
          "This is the SECONDARY (burst/abuse) limit, not the primary quota — `gh api rate_limit` " +
          "will still show thousands remaining, and its reset time is not the one to wait for. " +
          "It clears in seconds to minutes under reduced concurrency. Retry a few times with real " +
          "backoff; if arming auto-merge is what failed, the fallback is to wait for checks to go " +
          "green and then merge — never merge now with checks pending.",
      );
    }
    throw new Error(`GitHub GraphQL error: ${detail}`);
  }
  if (body.data === undefined) {
    throw new Error("GitHub GraphQL response had no data");
  }
  return body.data;
}

/** Extract the `rel="next"` URL from a `Link` response header, if present. */
function parseNextLink(linkHeader: string | null): string | undefined {
  if (!linkHeader) return undefined;
  // e.g. `<https://api.github.com/...&page=2>; rel="next", <...>; rel="last"`
  for (const part of linkHeader.split(",")) {
    const match = /<([^>]+)>\s*;\s*(.+)/.exec(part.trim());
    if (!match) continue;
    const [, target, params] = match;
    if (/\brel\s*=\s*"?next"?/.test(params)) return target;
  }
  return undefined;
}

interface PaginateOptions<T> {
  query?: RequestOptions["query"];
  /** Max items to return after filtering. Clamped to 1000, default 30. */
  limit?: number;
  /** Only items passing this predicate count toward `limit` and are returned. */
  filter?: (item: T) => boolean;
  /** Hard cap on pages fetched, regardless of `limit`. Default 10. */
  maxPages?: number;
}

const MAX_PER_PAGE = 100;
const DEFAULT_MAX_PAGES = 10;

/**
 * Fetch a paginated GitHub list endpoint, following `Link: rel="next"` headers.
 *
 * Requests `per_page=100` per page and accumulates items. When `filter` is
 * provided only items passing it count toward `limit` and appear in the result.
 * Stops at the first of: `limit` items collected, no `next` page, or `maxPages`
 * pages fetched. The result is sliced to `limit`. Non-2xx pages throw via the
 * same error path as `ghRequest`.
 */
export async function ghPaginate<T = unknown>(
  path: string,
  opts: PaginateOptions<T> = {},
): Promise<T[]> {
  const limit = listLimit(opts.limit);
  const maxPages = opts.maxPages ?? DEFAULT_MAX_PAGES;
  const filter = opts.filter;

  let url: string | undefined = buildUrl(path, {
    ...opts.query,
    per_page: MAX_PER_PAGE,
  });
  const collected: T[] = [];
  let pages = 0;

  while (url && pages < maxPages && collected.length < limit) {
    pages += 1;
    const res = await ghFetch(url, { method: "GET" });
    if (!res.ok) {
      throw await requestError("GET", path, res);
    }

    const text = await res.text();
    const items = (text ? JSON.parse(text) : []) as T[];
    for (const item of items) {
      if (filter && !filter(item)) continue;
      collected.push(item);
      if (collected.length >= limit) break;
    }

    url = parseNextLink(res.headers.get("Link"));
  }

  return collected.slice(0, limit);
}

/** Shared `repo` param schema for tools that target a GitHub repository. */
export const repoParam = z
  .string()
  .optional()
  .describe(
    'Target repository as "owner/name". Defaults to the repo of THIS MCP SERVER PROCESS\'S OWN launch directory — not the calling agent\'s current Bash cwd. If your Bash tool has cd\'d into a different repo\'s checkout or worktree, you MUST pass this explicitly or the call silently lands in the wrong repo.',
  );

export interface RepoRef {
  owner: string;
  name: string;
}

// Match GitHub's own allowed charset for owner/repo so a malformed value can't
// corrupt the REST URL path (e.g. an embedded `?` or `#`).
const REPO_SHAPE = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;

/**
 * Resolve the target repo for a tool call. Validates explicit `"owner/name"`,
 * otherwise resolves (and caches) the default repo for the current directory
 * via `gh repo view`. Throws a clear error if neither is available.
 */
export async function resolveRepo(repo?: string): Promise<RepoRef> {
  let nameWithOwner = repo;

  if (!nameWithOwner) {
    if (!cachedRepo) {
      try {
        const { stdout } = await execFileAsync(
          "gh",
          ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
          { env: await spawnEnv() },
        );
        cachedRepo = stdout.trim();
      } catch {
        cachedRepo = null;
      }
    }
    if (!cachedRepo) {
      throw new Error(
        'Could not resolve a default repository for the current directory. ' +
          'Pass the `repo` parameter explicitly as "owner/name".',
      );
    }
    nameWithOwner = cachedRepo;
  }

  if (!REPO_SHAPE.test(nameWithOwner)) {
    throw new Error(
      `Invalid repo "${nameWithOwner}". Expected the format "owner/name".`,
    );
  }

  const [owner, name] = nameWithOwner.split("/");
  return { owner, name };
}

/** Resolve and cache the authenticated user's login (for the `@me` sentinel). */
export async function getViewerLogin(): Promise<string> {
  if (cachedViewer) return cachedViewer;
  const user = await ghRequest<{ login: string }>("/user");
  cachedViewer = user.login;
  return cachedViewer;
}

const DEFAULT_LIMIT = 30;
const MAX_LIMIT = 1000;

/**
 * Clamp a user-supplied list limit to a sane maximum (1000), defaulting to 30.
 * This is the total number of items a paginated list tool returns, not a single
 * page size — `ghPaginate` always requests pages of 100.
 */
export function listLimit(limit?: number): number {
  const n = limit ?? DEFAULT_LIMIT;
  if (!Number.isFinite(n) || n < 1) return DEFAULT_LIMIT;
  return Math.min(Math.floor(n), MAX_LIMIT);
}

/**
 * Above this many characters a result is rejected outright rather than handed
 * back as an unusable blob — reproduced at `issue_list({ limit: 400 })`
 * against a large repo, which returned a 185,000-character single line the
 * calling agent could not consume (#181). Comfortably below that reproduction
 * size so the same shape of call fails fast with actionable guidance instead
 * of silently degrading.
 */
const MAX_RESULT_CHARS = 100_000;

/**
 * Render a value as a single JSON text content block.
 *
 * Compact, not indented: a tool result is re-read on every subsequent turn of
 * the session, and indentation buys the model nothing on payloads already
 * projected down to the fields it reads (see `slim.ts`).
 *
 * Throws rather than returning an oversized payload (#181) — callers already
 * wrap their `jsonText(...)` call in a try/catch that routes into
 * `errorResult`, so this surfaces as a normal tool error, not a crash.
 */
export function jsonText(value: unknown): {
  content: { type: "text"; text: string }[];
} {
  const text = JSON.stringify(value);
  if (text.length > MAX_RESULT_CHARS) {
    throw new Error(
      `Result too large to return (${text.length} chars, max ${MAX_RESULT_CHARS}). ` +
        "Narrow the request: lower `limit`, add more specific filters, or — for " +
        "issue_list/pr_list — pass `fields` to project down to just the keys you need.",
    );
  }
  return {
    content: [{ type: "text", text }],
  };
}

/** Wrap an Error as an MCP tool error result. */
export function errorResult(err: unknown): {
  content: { type: "text"; text: string }[];
  isError: true;
} {
  const message = err instanceof Error ? err.message : String(err);
  return {
    content: [{ type: "text", text: message }],
    isError: true,
  };
}
