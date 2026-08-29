# Responsive & mobile audit

Most traffic is mobile and most development happens on a 27-inch monitor. That gap is the entire realm. The findings are cheap, unambiguous, embarrassing when a user finds them first, and invisible to every other checklist in this skill because a desktop screenshot of a broken mobile layout looks fine.

**Reproduce at real viewports.** Use the Chrome DevTools MCP (`resize_page`, `emulate`) or Playwright against the deployed target — reading CSS and reasoning about breakpoints does not find these. Check at minimum 360×640 (small phone), 390×844 (common phone), 768 (tablet portrait), 1024, and 1440. Then check one landscape phone viewport, which is where the fixed-height hero and the unreachable modal footer live.

## Horizontal overflow — the flagship finding

**No page scrolls horizontally at any viewport. Ever.** There is no legitimate exception at the document level; a wide table or a code block scrolls inside its own container, and the body does not.

- Detect it mechanically rather than by eye: at each viewport, assert `document.documentElement.scrollWidth <= window.innerWidth`. A 4px overflow is invisible in a screenshot and still produces the rubber-banding, off-centre feel that reads as broken.
- **Find the culprit, don't paper over it.** `overflow-x: hidden` on `body` is a symptom-suppressor that hides the offending element rather than fixing it, and it breaks `position: sticky` on the way past. Bisect to the actual element — the usual suspects: a fixed-width container, an unconstrained image or `<video>`, a wide table, a long unbroken string (a URL, an API key, an email address) with no `overflow-wrap`, a negative margin, a grid whose `minmax` has no `0` minimum, an absolutely-positioned decoration, a `100vw` element inside a scrollbar-bearing page.
- Long user-generated strings get `overflow-wrap: anywhere` wherever they render — this is the overflow that only appears with real data, which is why it survives every review of the empty state.

## Layout at each breakpoint

- **Nothing is clipped, truncated without recourse, or overlapping.** Read the actual rendered text, not the design intent.
- **Multi-column layouts collapse in a sensible order**, and the content order after collapse still reads correctly — a sidebar that lands above the article on mobile is a finding.
- **Tables have a mobile strategy**, stated once and applied everywhere: horizontal scroll inside a container with a visible affordance, or reflow to stacked cards. A table that just overflows is the default failure.
- **Modals and sheets fit.** The classic: a modal taller than the viewport whose action buttons sit below the fold with no internal scroll, so the primary action is unreachable. Check every modal on the smallest viewport and in landscape.
- **Fixed and sticky elements don't eat the screen.** A sticky header, a cookie banner, and a support widget together can leave a phone with a third of its viewport. Sum them at 360×640.
- **Safe-area insets respected** on notched devices (`env(safe-area-inset-*)`) — a bottom-fixed CTA under the home indicator is untappable.
- **`100vh` is not used for a full-height mobile layout** — it excludes the dynamic browser chrome and clips. Use `100dvh` (with a `vh` fallback) or a flex layout.
- **Zoom is not disabled.** `user-scalable=no` or `maximum-scale=1` in the viewport meta is a WCAG failure (`accessibility.md`) and a mobile finding; the viewport meta is `width=device-width, initial-scale=1` and nothing else.
- **Content reflows at 320px width and at 200% zoom** without loss of function — WCAG 1.4.10, and it is the same fix as everything above.

## Mobile navigation

- **A mobile navigation exists.** A desktop nav bar that squeezes, wraps, or disappears below its breakpoint is the finding — and "disappears" is the worst version, because the site loses navigation entirely and nothing errors.
- The trigger is an icon **with an accessible name and a visible label or tooltip** (`accessibility.md` owns the name; `ux-coherence.md` owns the tooltip convention), it toggles `aria-expanded`, and it is at least 44×44px.
- **The open menu traps focus, closes on Escape, closes on route change, and returns focus to the trigger.** Not closing on navigation is the bug users hit most.
- **Background scroll is locked while the menu is open**, and unlocks — including when the menu is closed by a route change rather than by the button.
- Every destination in the desktop nav is reachable from the mobile nav. A nav that silently drops items below a breakpoint is a dead end.

## Touch

- **Tap targets ≥ 44×44px** with adequate spacing — WCAG 2.5.8 covers the minimum; the practical finding is a row of icon buttons at 24px each.
- **No hover-only affordance.** Anything revealed on `:hover` — a tooltip, a menu, an edit control, a delete button on a row — is unreachable on touch unless there is a tap path to the same thing. Enumerate hover-revealed controls; each one is a finding until a touch equivalent exists.
- **Inputs use the right `type` and `inputmode`** so the correct keyboard appears (`email`, `tel`, `numeric`, `decimal`), plus `autocomplete` tokens. Wrong keyboard on a phone form is a measurable conversion loss (`growth-ads-conversion.md`).
- **Font size ≥16px on inputs** on iOS, or the browser zooms on focus and the layout jumps.
- Custom gestures (swipe, drag, long-press) have a non-gesture equivalent — WCAG 2.5.1.
- The focused input is not covered by the on-screen keyboard or a sticky footer.

## Mobile performance

Mobile is where the performance budget is actually spent — the same findings as `web-delivery-performance.md`, measured on the device class that matters. Run Lighthouse mobile with throttling, not desktop; the responsive `srcset` finding and the bundle finding are both twice as costly here. Don't re-derive them in this realm — measure mobile, and file into that file.

## Gates

- **A Playwright test asserting no horizontal overflow at each named viewport, across a route list derived from the router.** Cheap, deterministic, catches the regression class permanently, and its absence is why this recurs.
- A visual-regression or screenshot pass at the same viewport set, so a layout break is a diff rather than a discovery.
- Tap-target size and viewport-meta are axe-checkable — fold them into the existing axe lane rather than a second tool.
- A test asserting the mobile menu opens, traps focus, closes on route change, and restores focus.
- Real-device checks (notch insets, keyboard behavior, landscape) are not gateable. State in the epic's *Not verified* section which physical devices were used, if any.
