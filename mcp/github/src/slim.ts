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

/**
 * Label objects carry six fields for a name the caller already recognises.
 *
 * Non-array input yields `[]` rather than throwing: a projection is cosmetic,
 * and an endpoint answering 200 with an unexpected shape must not turn a write
 * that already succeeded into a reported failure.
 */
export function labelNames(labels: unknown): string[] {
  if (!Array.isArray(labels)) return [];
  return labels
    .map((l) => (typeof l === "string" ? l : ((l as RawLabel | null)?.name ?? "")))
    .filter(Boolean);
}

export function actorLogins(actors: unknown): string[] {
  if (!Array.isArray(actors)) return [];
  return actors.map((a) => (a as RawActor | null)?.login ?? "").filter(Boolean);
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

/**
 * A ticked box on an issue body's owner-action checklist.
 *
 * An agent writes an `⛔ Owner action required` list unchecked, so a `[x]`
 * anywhere in the body is somebody answering — and it is the ONE signal for
 * that which a machine can read. Comment author cannot be used: every agent
 * posts under the owner's account, so the only thing separating his reply from
 * an agent's is its voice.
 *
 * This exists because scanning for OUTSTANDING actions (`- [ ]`) hides an
 * answered issue by construction — the answered row is precisely the one that
 * does not match. A sweep of 56 blocked issues reported all 56 unanswered
 * while three carried complete answers (#315).
 */
export function hasTickedOwnerAction(body: string | null | undefined): boolean {
  return body != null && /^\s*[-*]\s*\[[xX]\]/m.test(body);
}

/**
 * Why an issue is an index rather than pickable work, or `null` if it is work.
 *
 * `status:ready` means "scoped and startable". An epic is explicitly not
 * startable — `managing-work-with-issues` calls it "an index, not work: its
 * body links its children and carries the scope statement, and nothing is ever
 * implemented on it directly". Both wear the same label, and nothing in the
 * taxonomy separates them, so a `ready` count silently overstates the backlog
 * (#395: NetWorthy reported 20 ready issues and had zero ready leaves).
 *
 * Two ways to be an index, because either one alone misses half the set:
 *
 *   - `"sub-issues"` — GitHub already knows: the issue has children. Costs
 *     nothing per-issue and needs no migration.
 *   - `"body-marker"` — a CHILDLESS epic, which the first test cannot see at
 *     all. Twelve of NetWorthy's sixteen roadmap epics had no sub-issues filed
 *     and were indistinguishable from leaf issues nobody had started. They are
 *     `source:owner`, they carry real milestones, and they are correctly
 *     `ready` by the taxonomy as written — the label simply cannot express
 *     "this is an index". The body can, and does, verbatim.
 *
 * Returned as a reason rather than a boolean so a caller can tell a parent from
 * a childless epic. They need different handling: the first has children to
 * claim instead, the second has nothing yet and wants decomposing.
 */
export type IndexReason = "sub-issues" | "body-marker";

/** The line every roadmap epic body carries, matched loosely enough to survive rewording around it. */
const INDEX_BODY_MARKER = /never implemented directly/i;

export function indexReason(raw: {
  sub_issues_summary?: { total?: number; completed?: number } | null;
  body?: string | null;
}): IndexReason | null {
  if ((raw.sub_issues_summary?.total ?? 0) > 0) return "sub-issues";
  if (raw.body != null && INDEX_BODY_MARKER.test(raw.body)) return "body-marker";
  return null;
}

/**
 * Further project an already-slimmed object down to just the named keys —
 * the common case is a dedupe pass across many issues/PRs that only needs
 * `number`/`title`/`state` (#184). `undefined`/empty `fields` returns `obj`
 * unchanged, so this is a no-op unless a caller opts in. An unrecognized key
 * name is silently dropped rather than erroring — a projection is cosmetic,
 * not a contract worth failing a whole list call over.
 */
export function pick<T extends Record<string, unknown>>(
  obj: T,
  fields: string[] | undefined,
): Partial<T> {
  if (!fields || fields.length === 0) return obj;
  const out: Record<string, unknown> = {};
  for (const key of fields) {
    if (key in obj) out[key] = obj[key];
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
    // Surfaced even when the body is not returned, so a LIST shows it. An
    // agent scanning a blocked queue never opens the answered one otherwise.
    owner_action_answered: hasTickedOwnerAction(raw.body) ? true : undefined,
    // Same reasoning: an agent sizing a backlog from a `status:ready` count
    // reads the list, not each body. Without this the count is the thing that
    // sends it at an empty backlog (#395).
    is_index: indexReason(raw) ?? undefined,
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
