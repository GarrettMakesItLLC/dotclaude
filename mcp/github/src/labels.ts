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

export const ISSUE_SOURCES = [
  "owner",
  "user-feedback",
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

const SOURCE_STYLES: Record<IssueSource, LabelStyle> = {
  owner: { color: "fef2c0", description: "Reported by the owner through an app's feedback flow" },
  "user-feedback": { color: "d876e3", description: "Reported by a user through an app's feedback flow" },
  musclebuddy: { color: "5319e7", description: "Originated from MuscleBuddy user feedback" },
  redthread: { color: "e99695", description: "Originated from RedThread user feedback" },
  adventureos: { color: "0052cc", description: "Originated from AdventureOS user feedback" },
};

/** The `type:*` label name for a type value. */
export function typeLabel(type: IssueType): string {
  return `type:${type}`;
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
  ...ISSUE_SOURCES.map((s) => ({ name: sourceLabel(s), ...SOURCE_STYLES[s] })),
];

/** Every `status:*` label name — the mutually-exclusive status set. */
export const STATUS_LABEL_NAMES: string[] = ISSUE_STATUSES.map(statusLabel);

/** GitHub native issue-type name (title-cased) for a given type label value. */
export function nativeTypeName(type: IssueType): string {
  return { bug: "Bug", feature: "Feature", task: "Task" }[type];
}
