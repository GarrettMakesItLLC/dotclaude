export interface LabelSpec {
  name: string;
  color: string; // 6-hex, no leading '#'
  description: string;
}

/** The full label taxonomy provisioned into every repo. */
export const ISSUE_LABELS: LabelSpec[] = [
  { name: "status:backlog", color: "c5def5", description: "Captured, not yet scoped or prioritized" },
  { name: "status:ready", color: "0e8a16", description: "Fully scoped, ready to start" },
  { name: "status:blocked", color: "b60205", description: "Needs info/decision, or awaiting human verification" },
  { name: "status:in-progress", color: "fbca04", description: "Claimed by an agent and actively being worked" },
  { name: "status:in-review", color: "1d76db", description: "PR open, awaiting review/merge" },
  { name: "type:bug", color: "d73a4a", description: "Something is broken" },
  { name: "type:feature", color: "a2eeef", description: "New capability" },
  { name: "type:task", color: "bfd4f2", description: "Chore / maintenance / non-feature work" },
  { name: "source:musclebuddy", color: "5319e7", description: "Originated from MuscleBuddy user feedback" },
  { name: "source:redthread", color: "e99695", description: "Originated from RedThread user feedback" },
  { name: "source:adventureos", color: "0052cc", description: "Originated from AdventureOS user feedback" },
];

/** Every `status:*` label name — the mutually-exclusive status set. */
export const STATUS_LABEL_NAMES: string[] = ISSUE_LABELS.filter((l) =>
  l.name.startsWith("status:"),
).map((l) => l.name);

export type IssueType = "bug" | "feature" | "task";

export function typeLabel(type: IssueType): string {
  return `type:${type}`;
}

export type IssueStatus = "backlog" | "ready" | "blocked" | "in-progress" | "in-review";

/** The `status:*` label name for a status value. */
export function statusLabel(status: IssueStatus): string {
  return `status:${status}`;
}

/** GitHub native issue-type name (title-cased) for a given type label value. */
export function nativeTypeName(type: IssueType): string {
  return { bug: "Bug", feature: "Feature", task: "Task" }[type];
}
