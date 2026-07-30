# Accessibility audit

**Standard: WCAG 2.2 Level AA.** Level A is a floor with no exceptions; AA is the de facto legal standard under ADA Title III; AAA is never a whole-app target. axe tag: `wcag22aa`.

## What automation can and cannot settle

axe-core cannot press Tab, cannot press Escape, and cannot verify that focus returned to the trigger. A page-load scan sees the initial render only, so anything behind a click — dialogs, disclosure panels, menus, toasts — needs its own spec that opens it first. Treat the automated scan as the floor and the keyboard pass as the audit.

Do not promote a scoped scan to a full-page scan until every component on that page has been swept, or the page false-fails and the gate gets disabled.

## The per-change checklist (five questions)

1. **Keyboard** — reachable and operable with Tab / Enter / Space / Escape alone?
2. **Focus** — visible indicator, and does focus move *into* a dialog on open and *back to the trigger* on close?
3. **Labels** — every control has a `<label>` or `aria-label`; every icon-only button is named?
4. **Live content** — async error / success / loading announced via `role="alert"` / `role="status"` + `aria-live`, not merely rendered?
5. **Contrast** — 4.5:1 against the *actual* background, including translucency and overlays, measured by tooling and never by eye?

## Surface checklist

- Semantic landmarks; heading hierarchy with no skipped levels; `lang` on `<html>`; skip link to main.
- Every field labelled, `aria-required` where required; errors carry `role="alert"` + `aria-describedby`; **errors preserve the entered values**; `fieldset`/`legend` for grouped inputs.
- Focus indicators ≥3:1 against adjacent colors. **2.4.11 Focus Not Obscured** — sticky headers and bottom bars are the usual culprits.
- State announced, not just styled: `aria-expanded`, `aria-selected`, `aria-current`, `aria-disabled` (prefer over the `disabled` attribute where the control must stay discoverable).
- Decorative images `alt=""`; meaningful images described by purpose, not appearance.
- Contrast 4.5:1 body / 3:1 large text / **3:1 non-text — 1.4.11 covers control borders and focus rings**, the most-missed criterion.
- Color is never the sole indicator of state, error, or category.
- **2.5.8 Target Size** — 24×24 CSS px minimum, with the spacing exception understood before claiming it.
- Placeholder text is never the only label (**3.3.2**).
- Modals: focus moves in, focus is trapped, Escape closes, focus returns, `role="dialog"` + `aria-modal` + `aria-labelledby`, background content `inert`.
- Tables: caption, `scope`/`headers`, sort state announced, empty state stated in text.
- External and download links indicate what they are, in the accessible name.

## Recurring findings — check these first

- **Muted-token contrast** (`text-zinc-500` and its relatives) fails against the surfaces it's used on. This has been fixed by sweep and returned every time: the gate is a **token-pair contrast test**, asserting each foreground/background token combination in light *and* dark mode. A sweep without that test is a re-run scheduled.
- **Component-level coverage, page-level gap.** Components have `jest-axe` tests; the assembled page has no scan. Report coverage as a measured ratio (`33/58 files`), not as an adjective.
- **Modals, forms, and select/combobox widgets** are always the weak spot when coverage is partial.

## Gates

- `jsx-a11y` lint, adopted tier by tier: dry-run `npx eslint <files>` to see what would fire, fix, then append the glob to the `overrides` entry. Widening the glob before fixing is how the rule gets disabled.
- Component `jest-axe` tests; route-level Playwright axe specs asserting **zero** violations across `wcag2a`/`wcag2aa`/`wcag21a`/`wcag21aa`/`wcag22aa`, over public *and* authenticated projects.
- Token-pair contrast test (see above).
- The axe lane is a **required check**, or it isn't a gate.

## Exceptions

An exception is legitimate only when it names the criterion's own escape clause (e.g. 2.5.8 "Essential") **and** provides an equivalent accessible presentation, and is recorded in the repo's accessibility doc. Anything not listed there is a bug, not a known limitation.

## Physical space (ADA 2010 / ASTM / IBC)

A separate realm with separate authorities — relevant wherever the product models a real space (gym floor plans, venue layouts, route accessibility). Every rule carries `id`, `title`, `standard`, `citation`, `severity`, and the citation is non-null by test.

Authorities: *2010 ADA Standards for Accessible Design* (access-board.gov), *ASTM F2115* (motorized treadmills), *International Building Code* (means of egress).

Worked rules: accessible unit per equipment type (§236 / §1004.1); accessible route clear width 915 mm, reduced to 815 mm for runs ≤610 mm (§403.5.1); protruding objects ≤100 mm between 685–2030 mm (§307.2); door maneuvering clearances (§404.2.4, Table 404.2.4.1 — six approach cells); turning space 1525 mm circle or 915 mm T-arm (§304.3.1); an entrance must be mapped at all.

Every figure is read from the published text, not recalled.
