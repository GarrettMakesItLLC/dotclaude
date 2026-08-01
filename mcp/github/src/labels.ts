export interface LabelSpec {
  name: string;
  color: string; // 6-hex, no leading '#'
  description: string;
}

/** Every status value, in lifecycle order — the single source of truth for `status:*`. */
export const ISSUE_STATUSES = [
  "backlog",
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
 */
export const ISSUE_COMPLEXITIES = ["trivial", "standard", "complex"] as const;
export type IssueComplexity = (typeof ISSUE_COMPLEXITIES)[number];

/**
 * Marker labels — orthogonal to status/type/source, and to each other. `epic`
 * says what an issue *is* in the tracker's shape; `launch-blocker` says what it
 * gates. Neither is a state, so neither is mutually exclusive with anything.
 */
export const ISSUE_MARKERS = ["epic", "launch-blocker"] as const;
export type IssueMarker = (typeof ISSUE_MARKERS)[number];

/**
 * Where a report came from. The first two are an app's in-app reporter; the
 * per-app values name the app for reports cross-filed elsewhere; `agent` and
 * `code-review` are internal provenance, which is why `defaultStatus` treats
 * them like the owner rather than like an unverifiable third-party report.
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

/** Sources whose reports are trusted as verified — no owner verification step. */
export const TRUSTED_SOURCES: readonly IssueSource[] = ["owner", "agent", "code-review"];

/**
 * Label appearance, keyed by taxonomy value rather than by label name, so a new
 * status/type/source is a type error until it has one.
 */
type LabelStyle = Omit<LabelSpec, "name">;

const STATUS_STYLES: Record<IssueStatus, LabelStyle> = {
  backlog: { color: "c5def5", description: "Captured, not yet scoped or prioritized" },
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

const COMPLEXITY_STYLES: Record<IssueComplexity, LabelStyle> = {
  trivial: {
    color: "b4e7ce",
    description: "Mechanical, single-file, no judgment calls — a Haiku-class task",
  },
  standard: {
    color: "cfe2f3",
    description: "Bounded scope, known patterns — the default, Sonnet-class task",
  },
  complex: {
    color: "e07a5f",
    description: "Cross-cutting, ambiguous, or one-way-door — an Opus-class task",
  },
};

const MARKER_STYLES: Record<IssueMarker, LabelStyle> = {
  epic: { color: "7057ff", description: "Index issue: carries the scope and its sub-issues, never worked directly" },
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

/** The `complexity:*` label name for a complexity value. */
export function complexityLabel(complexity: IssueComplexity): string {
  return `complexity:${complexity}`;
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
  ...ISSUE_TYPES.map((t) => ({ name: typeLabel(t), ...TYPE_STYLES[t] })),
  ...ISSUE_COMPLEXITIES.map((c) => ({ name: complexityLabel(c), ...COMPLEXITY_STYLES[c] })),
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

/** Every `status:*` label name — the mutually-exclusive status set. */
export const STATUS_LABEL_NAMES: string[] = ISSUE_STATUSES.map(statusLabel);

/** GitHub native issue-type name (title-cased) for a given type label value. */
export function nativeTypeName(type: IssueType): string {
  return { bug: "Bug", feature: "Feature", task: "Task" }[type];
}
