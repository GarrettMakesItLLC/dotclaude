export interface LabelSpec {
  name: string;
  color: string; // 6-hex, no leading '#'
  description: string;
}

/** Every status value, in lifecycle order — the single source of truth for `status:*`. */
export const ISSUE_STATUSES = [
  "ready",
  "blocked",
  "waiting",
  "in-progress",
  "in-review",
] as const;
export type IssueStatus = (typeof ISSUE_STATUSES)[number];

export const ISSUE_TYPES = ["bug", "feature", "task"] as const;
export type IssueType = (typeof ISSUE_TYPES)[number];

/**
 * How much judgment a task takes, and which model it calls for. Orthogonal to
 * type/status/source — a bug fix and a feature can each be trivial or complex.
 * Lives on the shared Project's Effort field, not a label (see project.ts).
 */
export const ISSUE_EFFORTS = ["trivial", "standard", "complex"] as const;
export type IssueEffort = (typeof ISSUE_EFFORTS)[number];

/** Lives on the shared Project's Priority field, not a label. */
export const ISSUE_PRIORITIES = ["urgent", "high", "medium", "low"] as const;
export type IssuePriority = (typeof ISSUE_PRIORITIES)[number];

/**
 * Marker labels — orthogonal to status/type/source. `launch-blocker` says what
 * an issue gates. Not a state, so not mutually exclusive with anything.
 *
 * No `epic` marker: GitHub's native sub-issue hierarchy already shows an
 * issue is an epic in the UI (open/closed sub-issue count, parent/child
 * links) — a label restating that is pure duplication.
 */
export const ISSUE_MARKERS = ["launch-blocker"] as const;
export type IssueMarker = (typeof ISSUE_MARKERS)[number];

/**
 * Where a report came from — provenance metadata only, doesn't affect initial
 * status. The first two are an app's in-app reporter; the per-app values name
 * the app for reports cross-filed elsewhere; `agent` and `code-review` are
 * internal provenance.
 */
export const ISSUE_SOURCES = [
  "owner",
  "user-feedback",
  "agent",
  "code-review",
  "musclebuddy",
  "redthread",
  "adventureos",
] as const;
export type IssueSource = (typeof ISSUE_SOURCES)[number];

/**
 * Label appearance, keyed by taxonomy value rather than by label name, so a new
 * status/type/source is a type error until it has one.
 */
type LabelStyle = Omit<LabelSpec, "name">;

const STATUS_STYLES: Record<IssueStatus, LabelStyle> = {
  ready: { color: "0e8a16", description: "Fully scoped, ready to start" },
  blocked: { color: "b60205", description: "Needs the owner: a decision, a credential, or verification" },
  waiting: { color: "d4c5f9", description: "Depends on another issue; needs nothing from the owner" },
  "in-progress": { color: "fbca04", description: "Claimed by an agent and actively being worked" },
  "in-review": { color: "1d76db", description: "PR open, awaiting review/merge" },
};

const TYPE_STYLES: Record<IssueType, LabelStyle> = {
  bug: { color: "d73a4a", description: "Something is broken" },
  feature: { color: "a2eeef", description: "New capability" },
  task: { color: "bfd4f2", description: "Chore / maintenance / non-feature work" },
};

const RETIRED_EFFORT_COLORS: Record<IssueEffort, string> = {
  trivial: "8d6e63",
  standard: "4db6ac",
  complex: "e07a5f",
};

const MARKER_STYLES: Record<IssueMarker, LabelStyle> = {
  "launch-blocker": { color: "cc0000", description: "Must clear before public launch" },
};

const SOURCE_STYLES: Record<IssueSource, LabelStyle> = {
  owner: { color: "fef2c0", description: "Reported by the owner through an app's feedback flow" },
  "user-feedback": { color: "d876e3", description: "Reported by a user through an app's feedback flow" },
  agent: { color: "c2e0c6", description: "Surfaced by an autonomous agent (audit, sweep, investigation)" },
  "code-review": { color: "8b5cf6", description: "Surfaced during code review" },
  musclebuddy: { color: "5319e7", description: "Originated from MuscleBuddy user feedback" },
  redthread: { color: "e99695", description: "Originated from RedThread user feedback" },
  adventureos: { color: "0052cc", description: "Originated from AdventureOS user feedback" },
};

/** The `type:*` label name for a type value. */
export function typeLabel(type: IssueType): string {
  return `type:${type}`;
}

/** Model tiers, weakest first — matches the minimum an effort tier calls for. */
const MODEL_TIERS = ["haiku", "sonnet", "opus"] as const;
type ModelTier = (typeof MODEL_TIERS)[number];

const EFFORT_MIN_TIER: Record<IssueEffort, ModelTier> = {
  trivial: "haiku",
  standard: "sonnet",
  complex: "opus",
};

/** The tier a model id names, by substring match (`claude-opus-5` → `opus`), or null if unrecognized. */
function modelTier(modelId: string): ModelTier | null {
  const lower = modelId.toLowerCase();
  // Checked strongest-first: an id could plausibly contain more than one tier name.
  for (let i = MODEL_TIERS.length - 1; i >= 0; i--) {
    if (lower.includes(MODEL_TIERS[i])) return MODEL_TIERS[i];
  }
  return null;
}

/**
 * A human-readable warning when `callerModel` is under-provisioned for
 * `effort`, or null when it meets or exceeds the minimum (including when
 * either input is unrecognized — silence, not a false positive, is the safe
 * failure mode for a heuristic this coarse).
 */
export function effortModelMismatch(
  effort: IssueEffort,
  callerModel: string,
): string | null {
  const caller = modelTier(callerModel);
  if (!caller) return null;
  const required = EFFORT_MIN_TIER[effort];
  if (MODEL_TIERS.indexOf(caller) >= MODEL_TIERS.indexOf(required)) return null;
  return (
    `caller is running "${callerModel}" (${caller}-tier) but this issue carries an ` +
    `Effort of ${effort}, which calls for ${required}-tier or stronger.`
  );
}

/** The `status:*` label name for a status value. */
export function statusLabel(status: IssueStatus): string {
  return `status:${status}`;
}

/** The `source:*` label name for a feedback source value. */
export function sourceLabel(source: IssueSource): string {
  return `source:${source}`;
}

/** The full label taxonomy provisioned into every repo. */
export const ISSUE_LABELS: LabelSpec[] = [
  ...ISSUE_STATUSES.map((s) => ({ name: statusLabel(s), ...STATUS_STYLES[s] })),
  ...ISSUE_SOURCES.map((s) => ({ name: sourceLabel(s), ...SOURCE_STYLES[s] })),
  ...ISSUE_MARKERS.map((m) => ({ name: m, ...MARKER_STYLES[m] })),
];

/**
 * GitHub's stock labels that duplicate an axis of the taxonomy at the same
 * color. They are retitled rather than deleted, because they are still attached
 * to closed issues and deleting a label erases it from that history.
 */
export const DEPRECATED_LABELS: LabelSpec[] = [
  { name: "bug", color: "ededed", description: "DEPRECATED historical label — use type:bug on new work" },
  { name: "enhancement", color: "ededed", description: "DEPRECATED historical label — use type:feature on new work" },
  { name: "documentation", color: "ededed", description: "DEPRECATED historical label — use type:task on new work" },
  { name: "epic", color: "7057ff", description: "DEPRECATED — GitHub's native sub-issue hierarchy already shows this; do not apply to new issues" },
  { name: "status:backlog", color: "c5def5", description: "DEPRECATED — no milestone set is backlog; do not apply to new issues" },
  ...ISSUE_TYPES.map((t) => ({
    name: typeLabel(t),
    color: TYPE_STYLES[t].color,
    description: `DEPRECATED — use the native GitHub issue type instead of ${typeLabel(t)}`,
  })),
  ...ISSUE_EFFORTS.map((e) => ({
    name: `complexity:${e}`,
    color: RETIRED_EFFORT_COLORS[e],
    description: `DEPRECATED — use the Effort project field instead of complexity:${e}`,
  })),
];

/**
 * GitHub's stock labels with no place in a solo tracker — `good first issue`
 * also squats `epic`'s color. Reported by `labels_audit` and removed with
 * `label_delete`; never deleted implicitly by `labels_ensure`.
 */
export const REMOVABLE_DEFAULT_LABELS: readonly string[] = [
  "good first issue",
  "help wanted",
  "invalid",
  "question",
];

/** Every label name the taxonomy knows about, canonical or retired. */
export function isKnownLabel(name: string): boolean {
  return (
    ISSUE_LABELS.some((l) => l.name === name) ||
    DEPRECATED_LABELS.some((l) => l.name === name) ||
    REMOVABLE_DEFAULT_LABELS.includes(name)
  );
}

/**
 * Every `status:*` label name, live or retired — the set a status write strips
 * before applying the new one. Retired values belong here because they are
 * still attached to issues opened before they were retired: stripping only the
 * live names would leave such an issue wearing two status labels at once.
 */
export const STATUS_LABEL_NAMES: string[] = [
  ...ISSUE_STATUSES.map(statusLabel),
  ...DEPRECATED_LABELS.filter((l) => l.name.startsWith("status:")).map((l) => l.name),
];

/** GitHub native issue-type name (title-cased) for a given type label value. */
export function nativeTypeName(type: IssueType): string {
  return { bug: "Bug", feature: "Feature", task: "Task" }[type];
}
