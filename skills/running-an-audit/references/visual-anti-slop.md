# Visual anti-slop audit

The question is whether the product *reads* as built by hand for this brand, or as the median output of a generator that has seen ten thousand SaaS landing pages. `avoiding-ai-slop` covers the same failure mode in prose — predictable phrasing, formulaic structure, a voice that could belong to anyone. This file is the visual and product counterpart: the same tells, expressed in layout, color, and interaction instead of sentences. Load both when a launch-readiness pass touches anything user-facing; don't restate `avoiding-ai-slop`'s rules here, and don't restate these in a copy review.

None of this is a design-system defect the way `ux-coherence.md`'s findings are — a slop tell can be perfectly consistent across the app and still be slop. Consistency is necessary and not sufficient.

## Chrome and iconography

- **Emoji standing in for icons.** 🔥 as a streak indicator, 💪 as a workout-complete badge — cheap to reach for, and the first thing a practiced eye clocks as generated rather than designed. An icon set (the design system's own, or a licensed one) is the fix; an emoji is never a placeholder that becomes acceptable at launch.
- **Colored status dots as the sole state indicator** — a bare green/yellow/red circle with no label repeats both a WCAG finding (`accessibility.md`: color is never the sole indicator) and a slop tell at once. Pair every dot with text or an icon shape, not just a second color.
- **Cursive or script display fonts** on anything other than a deliberate, brand-specific choice made once and applied consistently — the reflexive reach for a script font on a hero headline is one of the most recognizable generated-template tells there is.
- **Purple/violet as the unexamined default accent.** Not a ban on purple — a ban on purple *because nothing else was considered*. If the brand's actual palette (check `@gmi/design`'s tokens, or the product's own token file) lands on violet on purpose, that's not a finding; violet appearing on a surface the token system doesn't specify is.

## Layout and structure

- **The cookie-cutter template**: hero → three-column feature grid → testimonial carousel → final CTA, in that order, with no surface that couldn't be swapped into a different product's marketing site unchanged. The tell isn't any one section — it's the whole page having no section that only this product could have.
- **Single-column layout with no width adaptation** past a phone viewport — content that never uses the horizontal space a tablet or desktop viewport actually offers reads as an unstyled draft even when every individual component is polished.
- **Fake or placeholder social proof**: fabricated testimonials, invented reviewer names, a "10,000+ users" counter with no real number behind it, a visitor or "X people viewing this" counter that isn't wired to anything real. This is a `legal-compliance.md` finding as much as a visual one — FTC deception covers a fabricated claim of popularity exactly as it covers a fabricated product claim — so file it once, tagged into both realms rather than duplicated.
- **Vague, AI-sounding hero copy** — "Unlock your potential," "Elevate your workflow," a value proposition that names no specific outcome and would fit any product in the category. This is `avoiding-ai-slop`'s "be specific" rule applied to the highest-visibility fifty words on the site; treat a slop finding in hero copy as blocking in a way the same finding three paragraphs into a help article is not.
- **Builder-tool watermark left in** ("Built with Lovable/Bolt/v0" badges, boilerplate favicon, an unclaimed `*.vercel.app`/`*.netlify.app` URL as the production domain) — the cheapest tell there is, and the one most likely to still be sitting there at launch.
- **Default charting-library look with no real data behind it** — the stock line-chart component dropped in because a dashboard needed *a* chart, showing a shape with no stated units or source. If the chart doesn't earn its axis labels, it's decoration, not data — file it the same way as a fabricated metric (see "Fake or placeholder social proof" above).

## Dark patterns

These are UX findings with a legal edge — `legal-compliance.md` covers the ROSCA/CPRA authority; this section is the product-surface tell that signals the pattern exists before you've traced the legal citation.

- **Cancellation harder than signup.** Signup is one primary button; cancellation buried behind a retention flow, a required phone call, or a multi-step interstitial designed to attrit the attempt is the finding, independent of whether it's technically "self-serve." Cross-file with `legal-compliance.md`'s California ARL item — this is the visual signature of that legal finding.
- **Auto-renewal with no reminder.** A subscription that renews without a notice email or in-app warning in the days before the charge is a dark pattern even where the original disclosure was compliant at signup — ongoing consent isn't a one-time event. Cross-file with `legal-compliance.md`'s ROSCA item the same way.

## Gates

Some of this is mechanically checkable and belongs in the condensed ambient checklist in `finishing-work/SKILL.md` rather than waiting for an audit pass — new emoji-as-icon usage and new unreviewed purple/violet accents are the two cheap enough to catch per-diff. The rest needs a human or a full launch-readiness pass:

- Emoji-as-icon: greppable (`grep`-scan new/changed files for emoji codepoints in JSX/template literals used as UI content, not as data) — a lint rule is worth adding to `@gmi/eslint-config` if this recurs across products rather than re-grepping by hand each time.
- Fabricated social proof and fake counters: no static gate: verify every number on a marketing surface traces to a real source, the same evidence discipline as `competitor-analysis.md`'s `null`-means-unknown rule — a plausible-looking number with no source is a fabrication, not a rounding choice.
- Dark patterns: reproduce the actual flow (start a cancellation, let a trial run to renewal) rather than reading the code that's supposed to implement it — the gap between "the code has a cancel button" and "the flow doesn't attrit the user" only shows up live.
- Template-shape and hero-copy tells: a human pass, not a script. State plainly in the epic which surfaces got a fresh-eyes look and which didn't — an unstated skip here reads as coverage.
