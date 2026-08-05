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

/**
 * Fetch the GitHub token by spawning `gh auth token`.
 * Throws a clear, actionable error if `gh` is not authenticated.
 */
async function fetchToken(): Promise<string> {
  try {
    const { stdout } = await execFileAsync("gh", ["auth", "token"]);
    const token = stdout.trim();
    if (!token) {
      throw new Error("empty token");
    }
    return token;
  } catch {
    throw new Error(
      "Failed to obtain a GitHub token via `gh auth token`. " +
        "Run `gh auth login` to authenticate the GitHub CLI, then try again.",
    );
  }
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
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const token = await getToken();
    const headers = buildHeaders(token);
    if (init.body !== undefined) {
      headers["Content-Type"] = "application/json";
    }
    const res = await fetch(url, { ...init, headers });

    if (res.status === 401 && !retriedAuth) {
      // Token may be stale — refetch once and retry once.
      retriedAuth = true;
      cachedToken = null;
      continue;
    }

    return res;
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
  .describe('Target repository as "owner/name". Defaults to the repo of the current directory.');

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
        const { stdout } = await execFileAsync("gh", [
          "repo",
          "view",
          "--json",
          "nameWithOwner",
          "-q",
          ".nameWithOwner",
        ]);
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
 * Render a value as a single JSON text content block.
 *
 * Compact, not indented: a tool result is re-read on every subsequent turn of
 * the session, and indentation buys the model nothing on payloads already
 * projected down to the fields it reads (see `slim.ts`).
 */
export function jsonText(value: unknown): {
  content: { type: "text"; text: string }[];
} {
  return {
    content: [{ type: "text", text: JSON.stringify(value) }],
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
