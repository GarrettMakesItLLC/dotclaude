# User-journey audit

The question is whether a person in a stated situation can get from the first step to the outcome the product promises, with every value they enter arriving where it is later read. It runs the product by persona, not by module, so it finds what a module-scoped realm cannot: the seam between two modules that each work alone.

## Method: persona x situation

Build a matrix. Rows are personas (who they are, what they own, what they bring with them); columns are situations (first run, mid-use, returning after a gap, importing existing data, changing a unit preference, offline, a partial or failed step). Fill only the cells the product claims to serve. Each cell becomes a journey, and each journey a table:

| step | route/page | API | persisted | seen at | verdict |
|---|---|---|---|---|---|

`persisted` names the column or store the step writes; `seen at` names the surface that later reads it. A row with an empty `seen at` is a write nobody reads; an empty `persisted` on a step that claims to save is a lie.

The backbone is four realms scoped to the journey rather than the whole product: `business-logic-claims.md` (the claim made at each step), `feature-completeness.md` Q2 (can the user finish the job), `ux-coherence.md` (same kind of action resolves the same way), `responsive-mobile.md` (the journey on a phone).

## One auditor owns the shared surfaces

Onboarding, the dashboard, itinerary or schedule, gear or equipment, safety plans, imports, billing, the account page and units are walked by every persona. Assign each to exactly one auditor. Persona auditors own only their module's surfaces and forward a shared-surface gap to the owner by `SendMessage` in one to three lines (journey, step, what is wrong), then move on. Otherwise N auditors re-derive and re-file the same finding.

## Writer, reader, gate, per field

For every field a journey touches, find all three:

- **Writer**: the form or import that stores it. A server that accepts a field no form writes is dead input. This pattern was found six times in one audit (segment ids, vehicle weight rating, modification effects, vehicle id, species keys, route id).
- **Reader**: the panel, calculator or rule that consumes it. A dashboard that reads a field the writer never stores renders empty for everyone.
- **Gate**: the test that guards the pair. A test that feeds the reader a value the writer cannot produce is vacuous. Check that the fixture value is one a real form submission or import can emit.

## Import paths feed the same readers

Every import (a third-party app export, a file upload, a sync) must populate the same stored fields, in the same units and shapes, that the manual form does. Walk each import to the downstream panel. In the audit this came from, ForeFlight, Mountain Project and USCG day maths each silently emptied a downstream panel.

## Calculators: units and prefill

A calculator's inputs prefill from the member's own data and display in the member's unit preference. Check that changing the preference changes the prefill and the result, not only the label, and that a value the member already stored is not asked for again.

## Personas with no module

A persona the product claims to serve but has no module for gets an owner-decision issue describing the gap and the options, never a build plan. A new module is a one-way door.

## Severity for this realm

- 🔴 A journey that cannot be completed, or completes with a harmful or false result, for a persona the product markets to.
- 🟠 A writer with no reader, or a reader with no writer, on a field a journey depends on; an import that leaves a downstream panel empty.
- 🟡 Fails in a named situation; a vacuous gate.
- 🟢 Polish.

## Scope and limits

When the box is contended, run static-only: trace writer, reader and gate from code. List "live walk" explicitly under **Not verified** in the report; a static trace is not a walkthrough.
