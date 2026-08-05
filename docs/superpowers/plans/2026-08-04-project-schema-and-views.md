# Project Schema and Views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task (sequential — each task depends on the project state the previous one left). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Effort and Priority custom fields to the shared `GarrettMakesItLLC — Work` project (#2), widen its Status field to match the `status:*` label taxonomy (plus a `Done` bucket for closed items), and add three new views (Blocked, By Priority, Epics).

**Architecture:** Pure GitHub Projects configuration — no code. Field/view creation goes through `gh project field-create`/`gh project view-create` where the CLI supports it; widening the existing Status field's options requires `gh api graphql` (the CLI has no `field-edit`), using `updateProjectV2Field`'s `singleSelectOptions` input, which accepts an optional `id` per option — passed for the three options being kept, omitted for the four being added, so existing item values on kept options survive the mutation intact.

**Tech Stack:** `gh` CLI, `gh api graphql` (one-time ops calls, not new product code — see [[2026-08-04-project-fields-mcp-tooling]] for why the MCP server itself stays REST-only).

**Depends on:** Nothing — independent of the MCP tooling plan. Run before or after it; the fleet-backfill plan needs both done.

## Global Constraints

- Target project: `GarrettMakesItLLC — Work`, org project #2, node id `PVT_kwDOEa9MV84BfYTK`, owner `GarrettMakesItLLC`.
- Every mutating step is followed by a read-back verification step — this plan changes shared org state, not a local file, so "the command didn't error" is not sufficient confirmation.
- Confirmed today via live introspection: `ProjectV2SingleSelectFieldOptionInput` takes `{ id?, name, color, description }`; valid `color` enum values are `GRAY, BLUE, GREEN, YELLOW, ORANGE, RED, PINK, PURPLE`. Current Status field option ids: Todo=`f75ad846`, In Progress=`47fc9ee4`, Done=`98236657`. Status field id: `PVTSSF_lADOEa9MV84BfYTKzhZrmM4`.

---

### Task 1: Add the Effort field

- [ ] **Step 1: Create the field**

```bash
gh project field-create 2 --owner GarrettMakesItLLC \
  --name "Effort" --data-type SINGLE_SELECT \
  --single-select-options "Trivial,Standard,Complex" \
  --format json
```

- [ ] **Step 2: Verify**

```bash
gh project field-list 2 --owner GarrettMakesItLLC --format json | python3 -c '
import json, sys
fields = json.load(sys.stdin)["fields"]
f = next(f for f in fields if f["name"] == "Effort")
assert [o["name"] for o in f["options"]] == ["Trivial", "Standard", "Complex"], f
print("OK", f["id"], [o["id"] for o in f["options"]])
'
```

Expected: prints `OK <field-id> [<3 option ids>]` with no assertion error. Record the field id — Plan A's `issue_set_effort`/`issue_set_priority` tools look it up live by name, but it's useful for spot-checking later steps.

---

### Task 2: Add the Priority field

- [ ] **Step 1: Create the field**

```bash
gh project field-create 2 --owner GarrettMakesItLLC \
  --name "Priority" --data-type SINGLE_SELECT \
  --single-select-options "Urgent,High,Medium,Low" \
  --format json
```

- [ ] **Step 2: Verify**

```bash
gh project field-list 2 --owner GarrettMakesItLLC --format json | python3 -c '
import json, sys
fields = json.load(sys.stdin)["fields"]
f = next(f for f in fields if f["name"] == "Priority")
assert [o["name"] for o in f["options"]] == ["Urgent", "High", "Medium", "Low"], f
print("OK", f["id"])
'
```

Expected: prints `OK <field-id>`.

---

### Task 3: Widen the Status field to match the `status:*` taxonomy

Final option set (7, not 6): the six `status:*` label values, plus `Done` — kept for closed items, since GitHub's built-in "auto-move to Done on close" project automation depends on a `Done`-named option existing. `Todo` is renamed to `Backlog` (same option id, so any item currently `Todo` becomes `Backlog` for free — a reasonable default, since untriaged items belong in backlog). `In Progress` and `Done` keep their ids and names unchanged. `Ready`, `Blocked`, `Waiting`, `In Review` are new.

- [ ] **Step 1: Run the mutation**

```bash
gh api graphql -f query='
mutation($fieldId: ID!, $options: [ProjectV2SingleSelectFieldOptionInput!]!) {
  updateProjectV2Field(input: { fieldId: $fieldId, singleSelectOptions: $options }) {
    projectV2Field {
      ... on ProjectV2SingleSelectField { id name options { id name } }
    }
  }
}' \
  -f fieldId="PVTSSF_lADOEa9MV84BfYTKzhZrmM4" \
  -F 'options[0][id]=f75ad846' -f 'options[0][name]=Backlog' -f 'options[0][color]=BLUE' -f 'options[0][description]=Captured, not yet scoped or prioritized' \
  -f 'options[1][name]=Ready' -f 'options[1][color]=GREEN' -f 'options[1][description]=Fully scoped, ready to start' \
  -f 'options[2][name]=Blocked' -f 'options[2][color]=RED' -f 'options[2][description]=Needs the owner: a decision, a credential, or verification' \
  -f 'options[3][name]=Waiting' -f 'options[3][color]=PURPLE' -f 'options[3][description]=Depends on another issue; needs nothing from the owner' \
  -F 'options[4][id]=47fc9ee4' -f 'options[4][name]=In Progress' -f 'options[4][color]=YELLOW' -f 'options[4][description]=Claimed by an agent and actively being worked' \
  -f 'options[5][name]=In Review' -f 'options[5][color]=BLUE' -f 'options[5][description]=PR open, awaiting review/merge' \
  -F 'options[6][id]=98236657' -f 'options[6][name]=Done' -f 'options[6][color]=GRAY' -f 'options[6][description]=Closed'
```

If `gh api graphql`'s array-of-objects variable syntax (`-f 'options[0][name]=...'`) doesn't parse as the nested list GraphQL expects (it's finicky with lists-of-objects), fall back to passing the whole `options` array as one JSON-encoded variable instead:

```bash
gh api graphql -f query='
mutation($fieldId: ID!, $options: [ProjectV2SingleSelectFieldOptionInput!]!) {
  updateProjectV2Field(input: { fieldId: $fieldId, singleSelectOptions: $options }) {
    projectV2Field { ... on ProjectV2SingleSelectField { id name options { id name } } }
  }
}' \
  -f fieldId="PVTSSF_lADOEa9MV84BfYTKzhZrmM4" \
  -f options='[
    {"id":"f75ad846","name":"Backlog","color":"BLUE","description":"Captured, not yet scoped or prioritized"},
    {"name":"Ready","color":"GREEN","description":"Fully scoped, ready to start"},
    {"name":"Blocked","color":"RED","description":"Needs the owner: a decision, a credential, or verification"},
    {"name":"Waiting","color":"PURPLE","description":"Depends on another issue; needs nothing from the owner"},
    {"id":"47fc9ee4","name":"In Progress","color":"YELLOW","description":"Claimed by an agent and actively being worked"},
    {"name":"In Review","color":"BLUE","description":"PR open, awaiting review/merge"},
    {"id":"98236657","name":"Done","color":"GRAY","description":"Closed"}
  ]' --input -
```

(Check `gh api graphql --help` for the exact flag to pass a JSON-typed variable — `-F` forces raw/non-string but a list-of-objects variable typically needs the request built as JSON via `--input -` piping a full `{"query":...,"variables":{...}}` document instead of `-f`/`-F` flags, since those are string/number scalar-only. Use whichever of the two invocations above actually round-trips; verify with Step 2 either way.)

- [ ] **Step 2: Verify**

```bash
gh project field-list 2 --owner GarrettMakesItLLC --format json | python3 -c '
import json, sys
fields = json.load(sys.stdin)["fields"]
f = next(f for f in fields if f["name"] == "Status")
names = [o["name"] for o in f["options"]]
assert names == ["Backlog", "Ready", "Blocked", "Waiting", "In Progress", "In Review", "Done"], names
print("OK", names)
'
```

Expected: prints `OK [...]` with the 7 names in that order.

- [ ] **Step 3: Confirm no item lost its value unexpectedly**

```bash
gh project item-list 2 --owner GarrettMakesItLLC --format json --limit 1000 | python3 -c '
import json, sys
items = json.load(sys.stdin)["items"]
missing = [i["content"]["url"] for i in items if not i.get("status") and i.get("content", {}).get("url")]
print(f"{len(missing)} open items now have no Status value (expected: previously-Todo/Done items renamed fine; previously-unset items still unset)")
'
```

This is informational, not a hard gate — items that were already unset stay unset (that's exactly the backlog the fleet-backfill plan exists to fix). What it should *not* show is every single item losing its value; if it does, the mutation replaced ids instead of reusing them and the previous Todo/In Progress/Done values were wiped — stop and investigate before continuing to Task 4.

---

### Task 4: Add the "Blocked" view

- [ ] **Step 1: Create the view**

```bash
gh api graphql -f query='
mutation($projectId: ID!) {
  createProjectV2View(input: { projectId: $projectId, name: "Blocked", layout: TABLE_LAYOUT }) {
    projectV2View { id name }
  }
}' -f projectId="PVT_kwDOEa9MV84BfYTK"
```

- [ ] **Step 2: Configure its filter**

The CLI/API can create a view but setting its saved filter string (`status:Blocked OR status:Waiting`) isn't exposed through `gh project`'s subcommands as of `gh` 2.67 — open the view in the browser (`gh project view 2 --owner GarrettMakesItLLC --web`), select the new "Blocked" tab, and set the filter to `status:"Blocked",status:"Waiting"` through the UI's filter bar. This is a one-time manual step; note it as such rather than scripting around a gap that doesn't exist in the CLI.

- [ ] **Step 3: Verify**

```bash
gh api graphql -f query='
query { organization(login: "GarrettMakesItLLC") { projectV2(number: 2) { views(first: 20) { nodes { name } } } } }' \
  --jq '.data.organization.projectV2.views.nodes[].name'
```

Expected: output includes `Blocked` alongside the five existing view names.

---

### Task 5: Add the "By Priority" view

- [ ] **Step 1: Create the view**

```bash
gh api graphql -f query='
mutation($projectId: ID!) {
  createProjectV2View(input: { projectId: $projectId, name: "By Priority", layout: TABLE_LAYOUT }) {
    projectV2View { id name }
  }
}' -f projectId="PVT_kwDOEa9MV84BfYTK"
```

- [ ] **Step 2: Configure grouping/sort**

Same CLI gap as Task 4 — open the view in the browser, group by "Priority", sort within group by... (owner's preference at setup time; a reasonable default is descending Priority, then Status). Manual, one-time.

- [ ] **Step 3: Verify**

Same query pattern as Task 4 Step 3, checking for `By Priority` in the view name list.

---

### Task 6: Add the "Epics" view

- [ ] **Step 1: Create the view**

```bash
gh api graphql -f query='
mutation($projectId: ID!) {
  createProjectV2View(input: { projectId: $projectId, name: "Epics", layout: BOARD_LAYOUT }) {
    projectV2View { id name }
  }
}' -f projectId="PVT_kwDOEa9MV84BfYTK"
```

- [ ] **Step 2: Configure grouping**

Open in the browser, set the board's group-by to "Parent issue" (the field already exists on the project, confirmed unused in the brainstorming pass — this is what makes the board show one column per epic with its sub-issues, using the native `Sub-issues progress` field for the completion bar). Manual, one-time — same CLI gap as Tasks 4-5.

- [ ] **Step 3: Verify**

Same query pattern, checking for `Epics` in the view name list. The group-by setting itself isn't queryable through this same call; eyeball it in the browser once — this is a one-time setup view, not something that needs a scripted assertion.

---

### Task 7: Final state check

- [ ] **Step 1: Confirm the full field and view set**

```bash
echo "Fields:" && gh project field-list 2 --owner GarrettMakesItLLC --format json --jq '.fields[].name'
echo "Views:" && gh api graphql -f query='query { organization(login: "GarrettMakesItLLC") { projectV2(number: 2) { views(first: 20) { nodes { name } } } } }' --jq '.data.organization.projectV2.views.nodes[].name'
```

Expected fields: `Title, Assignees, Status, Labels, Linked pull requests, Milestone, Repository, Reviewers, Parent issue, Sub-issues progress, Created, Updated, Closed, Effort, Priority` (15 total — the original 13 plus Effort and Priority).
Expected views: `All Items (incl. closed sub-issues), Active Board, By Repository, In Progress (All Repos), Needs Triage, Blocked, By Priority, Epics` (8 total).
