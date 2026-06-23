import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const BASE_URL = "https://api.github.com";
const USER_AGENT = "github-rest-mcp";
const API_VERSION = "2022-11-28";

let cachedToken: string | null = null;
let cachedRepo: string | null = null;

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
  const init: RequestInit = { method };
  if (options.body !== undefined) {
    init.body = JSON.stringify(options.body);
  }

  let retriedAuth = false;
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const token = await getToken();
    const headers = buildHeaders(token);
    if (options.body !== undefined) {
      headers["Content-Type"] = "application/json";
    }
    const res = await fetch(url, { ...init, headers });

    if (res.status === 401 && !retriedAuth) {
      // Token may be stale — refetch once and retry once.
      retriedAuth = true;
      cachedToken = null;
      continue;
    }

    if (!res.ok) {
      const detail = await parseErrorBody(res);
      throw new Error(
        `GitHub API ${method} ${path} failed: HTTP ${res.status}${
          detail ? ` — ${detail}` : ""
        }`,
      );
    }

    if (res.status === 204) {
      return undefined as T;
    }

    const text = await res.text();
    if (!text) return undefined as T;
    return JSON.parse(text) as T;
  }
}

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

/** Cap a requested limit to the GitHub per_page maximum of 100 (default 30). */
export function perPage(limit?: number): number {
  const n = limit ?? 30;
  if (!Number.isFinite(n) || n < 1) return 30;
  return Math.min(Math.floor(n), 100);
}

/** Render a value as a single pretty-printed JSON text content block. */
export function jsonText(value: unknown): {
  content: { type: "text"; text: string }[];
} {
  return {
    content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
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
