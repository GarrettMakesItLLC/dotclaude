/**
 * Projections from GitHub's REST payloads down to the fields an agent reads.
 *
 * An MCP tool result stays in the model's context for the rest of the session
 * and is re-read on every subsequent turn, so payload size here is a recurring
 * cost, not a one-off. A raw issue is ~6KB and a raw PR ~20KB, almost all of it
 * nested actor objects, full label objects for names we already have, and a
 * dozen `*_url` variants — none of which any caller reads.
 *
 * List projections omit `body`; single-object views keep it. Writes return an
 * acknowledgement of what changed rather than echoing the whole mutated object.
 */

export interface RawActor {
  login?: string;
}

export interface RawLabel {
  name?: string;
}

export interface RawMilestone {
  number?: number;
  title?: string;
}

export interface RawIssue {
  number?: number;
  title?: string;
  state?: string;
  state_reason?: string | null;
  draft?: boolean;
  body?: string | null;
  html_url?: string;
  comments?: number;
  created_at?: string;
  updated_at?: string;
  closed_at?: string | null;
  user?: RawActor | null;
  assignees?: RawActor[] | null;
  labels?: (RawLabel | string)[] | null;
  milestone?: RawMilestone | null;
  type?: { name?: string } | null;
  sub_issues_summary?: { total?: number; completed?: number } | null;
  pull_request?: unknown;
}

export interface RawPull {
  number?: number;
  title?: string;
  state?: string;
  draft?: boolean;
  merged?: boolean;
  mergeable?: boolean | null;
  mergeable_state?: string;
  body?: string | null;
  html_url?: string;
  created_at?: string;
  updated_at?: string;
  head?: { ref?: string; sha?: string } | null;
  base?: { ref?: string } | null;
  user?: RawActor | null;
  assignees?: RawActor[] | null;
  requested_reviewers?: RawActor[] | null;
  labels?: (RawLabel | string)[] | null;
}

export interface RawBranch {
  name?: string;
  protected?: boolean;
  commit?: { sha?: string } | null;
}

/** Label objects carry six fields for a name the caller already recognises. */
export function labelNames(labels: (RawLabel | string)[] | null | undefined): string[] {
  if (!labels) return [];
  return labels.map((l) => (typeof l === "string" ? l : (l.name ?? ""))).filter(Boolean);
}

export function actorLogins(actors: RawActor[] | null | undefined): string[] {
  if (!actors) return [];
  return actors.map((a) => a.login ?? "").filter(Boolean);
}

/** Drop keys that are absent or empty so a projection stays as small as it reads. */
function compact<T extends Record<string, unknown>>(obj: T): Partial<T> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue;
    if (Array.isArray(v) && v.length === 0) continue;
    out[k] = v;
  }
  return out as Partial<T>;
}

export function slimIssue(raw: RawIssue, opts: { body?: boolean } = {}): Record<string, unknown> {
  const sub = raw.sub_issues_summary;
  return compact({
    number: raw.number,
    title: raw.title,
    state: raw.state,
    state_reason: raw.state_reason,
    // Present only on the /issues endpoint's PR entries; callers filter on it.
    is_pull_request: raw.pull_request ? true : undefined,
    type: raw.type?.name,
    labels: labelNames(raw.labels),
    assignees: actorLogins(raw.assignees),
    author: raw.user?.login,
    milestone: raw.milestone?.title,
    comments: raw.comments,
    sub_issues: sub?.total ? `${sub.completed ?? 0}/${sub.total}` : undefined,
    created_at: raw.created_at,
    updated_at: raw.updated_at,
    closed_at: raw.closed_at,
    html_url: raw.html_url,
    body: opts.body ? (raw.body ?? "") : undefined,
  });
}

export function slimPr(raw: RawPull, opts: { body?: boolean } = {}): Record<string, unknown> {
  return compact({
    number: raw.number,
    title: raw.title,
    state: raw.state,
    draft: raw.draft,
    merged: raw.merged,
    mergeable: raw.mergeable,
    mergeable_state: raw.mergeable_state,
    head: raw.head ? compact({ ref: raw.head.ref, sha: raw.head.sha }) : undefined,
    base: raw.base?.ref ? { ref: raw.base.ref } : undefined,
    labels: labelNames(raw.labels),
    assignees: actorLogins(raw.assignees),
    requested_reviewers: actorLogins(raw.requested_reviewers),
    author: raw.user?.login,
    created_at: raw.created_at,
    updated_at: raw.updated_at,
    html_url: raw.html_url,
    body: opts.body ? (raw.body ?? "") : undefined,
  });
}

export function slimBranch(raw: RawBranch): Record<string, unknown> {
  return compact({
    name: raw.name,
    sha: raw.commit?.sha,
    protected: raw.protected,
  });
}

/**
 * A created comment echoes back the body the caller just sent. Confirming the
 * write needs only where it landed.
 */
export function slimComment(raw: { id?: number; html_url?: string; created_at?: string }): Record<
  string,
  unknown
> {
  return compact({
    id: raw.id,
    html_url: raw.html_url,
    created_at: raw.created_at,
  });
}
