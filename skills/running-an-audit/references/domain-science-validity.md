# Domain-science validity

The question: **where the product computes or recommends something from a scientific or clinical basis, is the formula the one the cited source actually gives, applied within its stated population and range, and does the UI say so?** Fitness, nutrition and health products silently drift from their sources.

Shares surfaces with `data-integrity-safety` (the crash/cutoff behavior of a safety path belongs there; whether the threshold is the published one belongs here) and `legal-compliance` (medical-claim language).

## Checklist
- **Enumerate every formula and threshold.** Grep the engine and server for named equations (Mifflin, Harris-Benedict, Katch-McArdle, Cunningham, Epley/Brzycki/Lombardi 1RM, Wilks/DOTS/IPF, RPE→%1RM tables, protein g/kg ranges, TDEE activity multipliers, BP bands, HRV/RHR baselines, sleep, BMI/BF% estimators, VO2 estimators, bio-age, healthspan markers) and every magic constant on a recommendation path.
- **Trace each to its source.** The comment or doc must cite the paper/guideline; the constant must match it (read, don't recall — fetch the source or a reputable secondary). Population and range limits (age, sex, athlete status, BMI) — is the input checked?
- **Unit and rounding correctness.** kg/lb, cm/in, kcal/kJ, mg/dL vs mmol/L; rounding that biases (always-down macros); integer division.
- **Progression and programming logic.** Volume landmarks (MEV/MAV/MRV), deload triggers, frequency per muscle, exercise-order rules, rest-time defaults, autoregulation — are they consistent with the cited framework and with each other? Two rules that can both fire and contradict.
- **Nutrition.** Macro floors and ceilings vs guidelines (protein ≥ x g/kg, fat floor, fibre), refeed/diet-break logic, adherence tolerance, food-KB nutrient math (serving size × per-100g), micronutrient RDAs by age/sex.
- **Health signal policy.** For each signal in the target repo's `docs/health-signal-policy.md`, does the code respect its `act`/`reinforce`/`describe` ruling? A `describe` signal that changes a target is a finding.
- **Recovery and readiness scores.** Baseline windows, personal vs population defaults, missing-data behavior; the same score computed in two places (server vs client) must agree — run both on one fixture.
- **Edge inputs.** Zero, negative, extreme, adolescent, pregnant, elderly, amputee/adaptive, very low or very high bodyweight — what does each formula do?
- **Explanations.** Where a number is shown, is its basis available to the member ("why this target")? A recommendation with no rationale is a UX finding filed under `ux-coherence`; a rationale that misstates the formula is filed here.

## Gates
Golden-value tests per formula pinned to the cited source's worked example; a range-check test per input; a parity test for any score computed in two places; a test that every constant on a recommendation path carries a source comment.
