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
  /** Every field's current value, keyed by the field's lowercased name (e.g. `effort`, `status`). */
  fields: Record<string, unknown>;
}

interface RawProjectItem {
  id: string;
  content?: { number?: number; repository?: string };
  [fieldKey: string]: unknown;
}

let cachedFields: ProjectField[] | null = null;

async function listProjectFields(): Promise<ProjectField[]> {
  if (cachedFields) return cachedFields;
  const out = await execGh([
    "project", "field-list", String(PROJECT_NUMBER),
    "--owner", PROJECT_OWNER, "--format", "json",
  ]);
  const parsed = JSON.parse(out) as { fields: ProjectField[] };
  cachedFields = parsed.fields;
  return cachedFields;
}

/** A named custom field on the shared work project. Throws if no field has that exact name. */
export async function getProjectField(name: string): Promise<ProjectField> {
  const fields = await listProjectFields();
  const field = fields.find((f) => f.name === name);
  if (!field) {
    throw new Error(
      `Project field "${name}" not found on GarrettMakesItLLC — Work (#${PROJECT_NUMBER}).`,
    );
  }
  return field;
}

/** The shared work project's item for a repo issue, or null if it isn't a project item. */
export async function findProjectItem(
  owner: string,
  repo: string,
  issueNumber: number,
): Promise<ProjectItemInfo | null> {
  const out = await execGh([
    "project", "item-list", String(PROJECT_NUMBER),
    "--owner", PROJECT_OWNER, "--format", "json", "--limit", "1000",
  ]);
  const parsed = JSON.parse(out) as { items: RawProjectItem[] };
  const match = parsed.items.find(
    (item) =>
      item.content?.number === issueNumber && item.content?.repository === `${owner}/${repo}`,
  );
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
