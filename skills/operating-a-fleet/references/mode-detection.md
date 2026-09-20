# Knowing which mode a repo is in

Everything else in this skill branches on one question — what authorizes a merge — and for a long
time the only way a machine answered it was a human saying so. That fails in the direction that costs
most: a session opens PRs and waits on a gate that was refusing jobs before the session started, and
reads an empty check list as a green one.

`bin/fleet-mode.sh` answers it automatically, per repo, and `hooks/fleet-mode-report.sh` puts the
answer in front of every session at SessionStart. It is silent when CI is healthy and no degraded mode
is declared, because a banner on every session is a banner that gets ignored and then disabled.

## Two facts, two different kinds of source

Conflating these is what makes a marker file go stale exactly when it matters.

| | **Is CI answering?** | **Has degraded mode been authorized?** |
|---|---|---|
| Observable? | Yes, and it changes with nobody editing anything | No — it is a decision, not a state |
| So it is | **probed**, live, every few hours | **declared**, in `.claude/fleet-mode.json`, committed |
| Authority | the probe, always | the owner, in writing |

The declaration is a committed file rather than a gitignored dotfile because the skill's rule holds
here too: coordination lives on the remote. A committed file is remote state — every machine that
pulls reads the same one. What it must never be is the *only* source, which is the next section.

## The probe, and why its signature is specific

A billing stop does not look like a test failure. GitHub accepts the run, never hands it to a runner,
and marks it failed:

- the run concludes `failure`
- within a couple of seconds of starting
- and its jobs executed **zero steps**

The probe reads one page of `repos/<slug>/actions/runs` and calls it a refusal only when three signals
hold together, because each alone has an innocent explanation:

1. **several** instant failures — one fast flaky job does not repeat like that;
2. across **more than one workflow** — a repo does not break every workflow at once;
3. and the **most recent** run is one of them — otherwise it is history, not the present.

A repo with a single job that fails in two seconds therefore reads as normal, which is correct: that
is a bug in the repo, not a refused runner. A repo whose newest run executed reads as healthy even
with refusals behind it, which is how coming *out* of a billing stop is detected.

Self-hosted runners keep working through a billing stop, so a refused repo can still show one long
job inside an otherwise-instant run. The refusal test runs first for exactly that reason.

## What a stale declaration looks like

Because the probe is the authority on CI health, a declaration that went stale is **caught rather than
believed**:

- `refused` + declared `degraded` → degraded mode, and the banner says what to do in it.
- `refused` + nothing declared → the trigger, observed. The banner says there is no gate right now,
  that entering degraded mode lifts branch protection and is the owner's call in writing, and to say
  so on the coordination issue and stop.
- `healthy` + declared `degraded` → **stale declaration.** Actions is running jobs again while every
  machine still reads a mode this repo is no longer in. Leaving degraded mode is not automatic — the
  last integrator says so on the coordination issue and restores the rules.
- `healthy` + nothing declared → silence.
- no workflows and no runs → says so: nothing gates a merge here but what you ran locally.
- unreadable (no `gh`, no network, an unparseable response) → says **unknown**, and never guesses.
  A confidently wrong answer here tells a session to trust a gate that is not running, which is worse
  than no answer at all.

## The declaration file

`<repo>/.claude/fleet-mode.json`, committed:

```json
{
  "mode": "degraded",
  "issue": "GarrettMakesItLLC/MuscleBuddy#8137",
  "authorized_by": "garrett",
  "since": "2026-09-20"
}
```

Only `mode` is required (`normal` or `degraded`); `issue` is the standing coordination issue, echoed
into the banner so a session knows where to read and report. Absent, unparseable, or carrying any
other mode value, the file is treated as not declared — a malformed file must never be able to assert
degraded mode by accident.

## Cost

`report` is cache-first. A warm cache is a single small file read — tens of milliseconds, the same
tier as the account-ledger hook. A soft-stale cache (default 30 minutes) is served immediately while a
detached refresh updates it for the next session, so nothing waits. Only a cold cache, or one past the
hard TTL (default 4 hours), pays the one bounded `gh api` call in the foreground — once per repo, not
once per session.

```bash
bin/fleet-mode.sh status          # what this repo is in, human-readable, always prints
bin/fleet-mode.sh probe           # force a live re-probe and refresh the cache
bin/fleet-mode.sh probe --json    # the raw verdict
bin/fleet-mode.sh clear           # drop the cached verdict for this repo
```

Environment overrides, for a machine that wants different timing:
`FLEET_MODE_SOFT_TTL`, `FLEET_MODE_HARD_TTL`, `FLEET_MODE_PROBE_TIMEOUT`, `FLEET_MODE_CACHE_DIR`.
