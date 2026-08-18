import { execGh, ghGraphQL } from "./github.js";

const PROJECT_OWNER = "GarrettMakesItLLC";
const PROJECT_NUMBER = 2;
const PROJECT_ID = "PVT_kwDOEa9MV84BfYTK";

export interface ProjectFieldOption {
  id: string;
  name: string;
}

export interface ProjectField {
  id: string;
  name: string;
  options?: ProjectFieldOption[];
}

export interface ProjectItemInfo {
  id: string;
  /** Every project-board field's current value, keyed by the field's
   * lowercased name (e.g. `effort`, `status`). */
  fields: Record<string, unknown>;
}

let cachedFields: ProjectField[] | null = null;

/** Per-issue memo for `findProjectItem`, process lifetime — same reasoning as
 * `cachedFields`: a targeted GraphQL lookup is already cheap (one query, not
 * the whole board), this just avoids repeating it for the same issue within
 * one session. */
const cachedItemsByIssue = new Map<string, ProjectItemInfo | null>();

/**
 * The one-time fix for either signature below: `gh auth refresh -s project`
 * grants the scope; a token that already carries `project` satisfies the
 * narrower `read:project` check these commands actually make.
 */
const PROJECT_SCOPE_HINT =
  "gh CLI's token is missing the `project` OAuth scope GitHub Projects " +
  "commands require — run `gh auth refresh -s project` to grant it (see " +
  "mcp/github/README.md), then retry.";

/**
 * Matches both observed shapes of a scope-starved `gh project` token (#4051):
 * gh's own explicit scope error, and "unknown owner type" — a token missing
 * `read:project` fails owner-type resolution first and surfaces that opaque
 * message instead of the real cause. Both are deterministic for a given
 * token, not transient, so neither is worth retrying on its own; the retry
 * below exists only for the genuine concurrent-`gh`-process race (#147).
 */
function isProjectPermissionError(message: string): boolean {
  return /missing required scopes/i.test(message) || /unknown owner type/i.test(message);
}

function wrapProjectError(err: unknown): Error {
  const message = err instanceof Error ? err.message : String(err);
  if (!isProjectPermissionError(message)) {
    return err instanceof Error ? err : new Error(message);
  }
  return new Error(`${PROJECT_SCOPE_HINT} (${message})`);
}

/**
 * `gh project field-list`/`item-list --owner <org>` intermittently fails with
 * "unknown owner type" — reproduced across multiple concurrent agent sessions
 * (#147) but not on a single isolated invocation, which points at a race in
 * gh's own owner-type resolution under concurrent `gh` processes sharing one
 * `~/.config/gh`, not a wrong flag. One retry clears the race in practice.
 *
 * A second failure — or an immediate scope error, which no retry clears — is
 * rethrown via `wrapProjectError` so a missing-scope token produces one
 * actionable message instead of gh's opaque raw text.
 */
async function execGhProjectCmd(args: string[]): Promise<string> {
  try {
    return await execGh(args);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    if (!message.includes("unknown owner type")) throw wrapProjectError(err);
    try {
      return await execGh(args);
    } catch (retryErr) {
      throw wrapProjectError(retryErr);
    }
  }
}

async function fetchProjectFields(): Promise<ProjectField[]> {
  const out = await execGhProjectCmd([
    "project", "field-list", String(PROJECT_NUMBER),
    "--owner", PROJECT_OWNER, "--format", "json",
  ]);
  const parsed = JSON.parse(out) as { fields: ProjectField[] };
  return parsed.fields;
}

const FIND_ITEM_QUERY = `
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      issue(number: $number) {
        projectItems(first: 20) {
          nodes {
            id
            project { id }
            fieldValues(first: 30) {
              nodes {
                __typename
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  field { ... on ProjectV2FieldCommon { name } }
                }
                ... on ProjectV2ItemFieldTextValue {
                  text
                  field { ... on ProjectV2FieldCommon { name } }
                }
                ... on ProjectV2ItemFieldNumberValue {
                  number
                  field { ... on ProjectV2FieldCommon { name } }
                }
                ... on ProjectV2ItemFieldDateValue {
                  date
                  field { ... on ProjectV2FieldCommon { name } }
                }
              }
            }
          }
        }
      }
    }
  }
`;

interface FieldValueNode {
  __typename: string;
  name?: string;
  text?: string;
  number?: number;
  date?: string;
  field?: { name?: string } | null;
}

interface FindItemResponse {
  repository: {
    issue: {
      projectItems: {
        nodes: Array<{
          id: string;
          project: { id: string };
          fieldValues: { nodes: FieldValueNode[] };
        }>;
      };
    } | null;
  } | null;
}

function fieldValueOf(node: FieldValueNode): unknown {
  switch (node.__typename) {
    case "ProjectV2ItemFieldSingleSelectValue":
      return node.name;
    case "ProjectV2ItemFieldTextValue":
      return node.text;
    case "ProjectV2ItemFieldNumberValue":
      return node.number;
    case "ProjectV2ItemFieldDateValue":
      return node.date;
    default:
      return undefined;
  }
}

/**
 * A named custom field on the shared work project. Throws if no field has that
 * exact name.
 *
 * Caches the field list for the process lifetime, but a cache miss triggers one
 * refetch before giving up — a field created after this process started (e.g.
 * by separate schema-setup work) must not be permanently invisible just because
 * an earlier lookup cached the list without it.
 */
export async function getProjectField(name: string): Promise<ProjectField> {
  if (!cachedFields) cachedFields = await fetchProjectFields();
  let field = cachedFields.find((f) => f.name === name);
  if (!field) {
    cachedFields = await fetchProjectFields();
    field = cachedFields.find((f) => f.name === name);
  }
  if (!field) {
    throw new Error(
      `Project field "${name}" not found on GarrettMakesItLLC — Work (#${PROJECT_NUMBER}).`,
    );
  }
  return field;
}

/**
 * The shared work project's item for a repo issue, or null if it isn't a
 * project item.
 *
 * Queries the specific issue's `projectItems` connection directly via GraphQL
 * instead of paginating the whole board (previously `gh project item-list
 * --limit 1000`, which on a project with thousands of items burned the
 * shared 5000/req-hr GraphQL quota in a handful of calls — every lookup
 * refetched the entire project regardless of which one issue was wanted,
 * platform#490). One targeted query costs the same whether the project has
 * ten items or ten thousand.
 *
 * Caches per issue for the process lifetime — cheap to keep since each entry
 * is now one small lookup, not a multi-thousand-item list.
 */
export async function findProjectItem(
  owner: string,
  repo: string,
  issueNumber: number,
): Promise<ProjectItemInfo | null> {
  const key = `${owner}/${repo}#${issueNumber}`;
  if (cachedItemsByIssue.has(key)) return cachedItemsByIssue.get(key)!;

  const data = await ghGraphQL<FindItemResponse>(FIND_ITEM_QUERY, {
    owner,
    repo,
    number: issueNumber,
  });
  const nodes = data.repository?.issue?.projectItems.nodes ?? [];
  const match = nodes.find((node) => node.project.id === PROJECT_ID);

  let result: ProjectItemInfo | null = null;
  if (match) {
    const fields: Record<string, unknown> = {};
    for (const fv of match.fieldValues.nodes) {
      const name = fv.field?.name;
      if (!name) continue;
      const value = fieldValueOf(fv);
      if (value !== undefined) fields[name.toLowerCase()] = value;
    }
    result = { id: match.id, fields };
  }

  cachedItemsByIssue.set(key, result);
  return result;
}

/** Drop a cached `findProjectItem` lookup — call after a write that changes
 * that issue's field values, so a later read in the same session isn't
 * served the pre-write snapshot. */
export function invalidateProjectItem(owner: string, repo: string, issueNumber: number): void {
  cachedItemsByIssue.delete(`${owner}/${repo}#${issueNumber}`);
}

/** Set a single-select field's value on a project item, by option id. */
export async function setProjectSingleSelect(
  itemId: string,
  fieldId: string,
  optionId: string,
): Promise<void> {
  await execGh([
    "project", "item-edit",
    "--id", itemId,
    "--project-id", PROJECT_ID,
    "--field-id", fieldId,
    "--single-select-option-id", optionId,
  ]);
}
