import { execGh } from "./github.js";

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
  /**
   * Every field's current value, keyed by the field's lowercased name (e.g.
   * `effort`, `status`), plus `labels`/`title`/`repository` — everything on
   * the raw item except `id`/`content`.
   */
  fields: Record<string, unknown>;
}

interface RawProjectItem {
  id: string;
  content?: { number?: number; repository?: string };
  [fieldKey: string]: unknown;
}

let cachedFields: ProjectField[] | null = null;
let cachedItems: RawProjectItem[] | null = null;

async function fetchProjectFields(): Promise<ProjectField[]> {
  const out = await execGh([
    "project", "field-list", String(PROJECT_NUMBER),
    "--owner", PROJECT_OWNER, "--format", "json",
  ]);
  const parsed = JSON.parse(out) as { fields: ProjectField[] };
  return parsed.fields;
}

async function fetchProjectItems(): Promise<RawProjectItem[]> {
  const out = await execGh([
    "project", "item-list", String(PROJECT_NUMBER),
    "--owner", PROJECT_OWNER, "--format", "json", "--limit", "1000",
  ]);
  const parsed = JSON.parse(out) as { items: RawProjectItem[] };
  return parsed.items;
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

function matchItem(
  items: RawProjectItem[],
  owner: string,
  repo: string,
  issueNumber: number,
): RawProjectItem | undefined {
  return items.find(
    (item) =>
      item.content?.number === issueNumber && item.content?.repository === `${owner}/${repo}`,
  );
}

/**
 * The shared work project's item for a repo issue, or null if it isn't a
 * project item.
 *
 * Caches the item list for the process lifetime, but a cache miss triggers one
 * refetch before giving up — an issue added to the project after this process
 * started must not be permanently invisible just because an earlier lookup
 * cached the list without it.
 */
export async function findProjectItem(
  owner: string,
  repo: string,
  issueNumber: number,
): Promise<ProjectItemInfo | null> {
  if (!cachedItems) cachedItems = await fetchProjectItems();
  let match = matchItem(cachedItems, owner, repo, issueNumber);
  if (!match) {
    cachedItems = await fetchProjectItems();
    match = matchItem(cachedItems, owner, repo, issueNumber);
  }
  if (!match) return null;
  const { id, content: _content, ...fields } = match;
  return { id, fields };
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
