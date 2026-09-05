# i18n, units & time

The question: **does the product behave correctly for a member who is not in the developer's locale, unit system, or time zone?** Streaks, crons, scheduling and unit conversion are where these bugs live.

## Checklist
- **Time zones.** Every `new Date()`, `toISOString().slice(0,10)`, `getDay()`, `setHours(0,0,0,0)` on a path that computes a "day" for a member: is the member's zone applied? Streaks, freezes, daily targets, check-in windows, fasting windows, cron cutoffs, "today" in the UI vs the server. DST transition: run the streak/schedule logic across a DST boundary fixture.
- **Cron and scheduler zones.** Cron expressions assume which zone; a "morning digest" that fires at 3am for half the members.
- **Units.** Metric/imperial preference honored on every input and display (plates, bars, dumbbells, bodyweight, height, distance, food serving sizes, blood markers mmol/mg). Round-trip conversions that lose precision. A stored value with an ambiguous unit column.
- **Number and date formatting.** `Intl` used with the member's locale or hardcoded `en-US`; decimal separators on inputs; 12/24h; week start (Monday vs Sunday) in calendars and weekly volume windows.
- **Strings.** Hardcoded English in the engine (should be keys); concatenated sentences that cannot be translated; pluralization by `s` suffix; RTL readiness if any locale is planned.
- **Currency.** Stripe prices per region; VAT/tax display; price strings hardcoded on marketing pages vs Stripe.
- **Locale-dependent data.** Food databases, exercise names, competition federations, gym metro seeds — what a non-US member sees.
- **Native and PWA.** Device locale honored in the wrapper; time zone changes while the app is open.

## Gates
A DST-boundary test per day-computation; a lint rule banning bare `new Date()` day math outside a `tz` helper; a units round-trip property test; a hardcoded-locale grep test.
