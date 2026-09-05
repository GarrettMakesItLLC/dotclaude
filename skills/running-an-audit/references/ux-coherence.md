# UX coherence audit

Not a design critique. The question is whether the same *kind* of thing behaves the same way everywhere — inconsistency the user has to learn is the defect. Findings here are cheap to fix and invisible to every other realm's checklist.

Each of these audits ends by writing its outcome as a rule in the repo's IA/design doc, **so the next surface doesn't need the audit repeated.** An audit here whose output is only issues will be run again.

## Confirmation and the way back

Enumerate every submit and mutation call site. For each:

- Classify the resolution as **auto-return**, **inline**, or **interstitial** — and an interstitial needs a stated reason.
- The same *kind* of action resolves the same way everywhere.
- Every page has a logical parent and a back action that doesn't dead-end.
- **Errors keep the entered values.** Always. This is also a WCAG concern.
- **A toast is a receipt, never the only feedback** — and it must be announced (`role="status"`/`role="alert"`), not just rendered.

## Progressive disclosure

Inventory every surface added since the last pass and check it against the repo's disclosure mechanism. Two named failure modes:

- A beginner shown advanced machinery on day one.
- An advanced user with no way past the beginner scaffolding.

Every advanced surface has a **stated reveal condition**. Acceptance is behavioral, not analytical: a first-run account and a mature account each produce a coherent interface, checked end to end rather than reasoned about.

## One concept, one first-class surface

Sweep for the same concept displayed in several places with divergent formatting, rounding, or freshness. Promote one canonical presentation and demote or delete the rest. Divergent *numbers* for one concept is a data-integrity finding, not a UX one — see `data-integrity-safety.md`.

## Empty, loading, and error states

Every list, table, and async surface has all three, in text, and the empty state says what to do next. Loading states don't reflow the layout. This overlaps `accessibility.md`'s live-region checklist — check them together.

The repo picks one convention for each and applies it everywhere; the defaults, and the reason a surface deviates, belong in the design doc:

- **Skeletons where the shape is known, spinners only where it isn't.** A list, table, card grid, or profile header gets a skeleton matching its real dimensions — it reserves the layout (which is also the CLS fix), says what is coming, and reads faster than the same wait behind a spinner. A spinner is for an indeterminate wait with no known shape, and for the pending state on a control the user just pressed. A full-page spinner on a route whose layout is entirely predictable is the finding.
- **Optimistic by default on mutations that almost always succeed** — toggles, likes, checkboxes, reorders, inline renames, adding to a list — with a visible rollback on failure. Pessimistic deliberately on anything whose outcome the client can't predict (payment, destructive actions), and the deliberateness is stated. Mechanics and the mandatory failure path: `web-delivery-performance.md`.
- **Every mutation ends in a visible success message in the product's terms**, and every failure in a specific one that says what to do next. Presence is `site-hygiene-launch-tells.md`'s check; consistency of *kind* is this file's.

## Common polish surfaces

Not a checklist of features to build — a checklist of *presence and consistency* wherever the product has already committed to the pattern elsewhere. Flag a surface only where its absence breaks a pattern the rest of the product establishes, not because the list below is exhaustive of what a mature product could have: skip-to-content and password-visibility toggles (also accessibility findings, see `accessibility.md`), sticky/scroll-aware headers, breadcrumbs on nested routes, print stylesheet on content meant to be printed, "back to top" on long scroll surfaces, a thank-you/confirmation step after every meaningful form submit.

Three of these carry enough weight to name separately:

- **Every icon-only button has a tooltip**, not merely an accessible name. `accessibility.md` requires the name so a screen reader can announce it; the tooltip is for the sighted user who cannot tell a "duplicate" glyph from an "export" one. One tooltip component, one delay, one placement rule, applied to every icon-only control in the product — and on touch, where hover doesn't exist, the control carries a visible label instead (`responsive-mobile.md`). A row of unlabelled glyphs is the most common instance of this finding by a wide margin.
- **A custom 404**, high severity on any public product — owned by `site-hygiene-launch-tells.md`, which also carries the gate.
- **Mobile navigation** — presence, behavior, and breakpoints are `responsive-mobile.md`'s; what belongs here is that the mobile nav offers the same destinations, in the same order, under the same names as the desktop one.

## Copy consistency

No hardcoded user-facing strings outside the i18n layer; keys added for every new surface; dark-mode variants present on every new component. These are lint-gateable, and should be lint-gated rather than audited twice.
