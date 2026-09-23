# Degraded mode: the wave procedure

Degraded mode is what runs when CI cannot be the gate. Entering it lifts branch protection, so it is
**owner-authorized policy** — an agent observes the trigger and asks; it does not decide.

Work moves in **waves**. A wave is a set of batch PRs, stacked into one integration branch, validated
once, merged once.

## The loop

1. **Integrator takes the lease.** `fleet-lease.sh take integrator --ttl 5400 --note "wave N"`.
   No lease, no merging. If the take fails, you are an implementer or a validator this wave.

2. **Integrator builds the integration branch.** `integration/<date>-wN`, cut from the trunk, with each
   batch PR's branch merged in and every conflict resolved. Open it as one PR. The batch PRs stay open
   and unmerged — the integration branch is what lands.

3. **Freeze and announce.** Push nothing more to any branch in the wave. Comment `READY <sha>` on the
   coordination issue. The SHA is the contract: everything downstream is about that SHA and no other.

4. **A validator takes the SHA.** It says so on the issue before starting, because two validators on
   one SHA is pure waste. Check the SHA out in a local-only worktree — never a branch that can be
   pushed — and run `ci-replica.sh` plus whatever the manifest marks as needing a data plane.

5. **Validator reports.** `## Run N` with the PASS/FAIL/NOT-RUN table. Each failure gets the command,
   the exit code, a log excerpt, and the **owning batch**. A failure with no owner is a failure nobody
   will fix.

6. **Integrator fixes on the integration branch**, pushes, and posts a new `READY <sha>`. The validator
   re-runs what failed plus anything the fix could plausibly touch — and always the full suite on the
   final SHA, because a targeted re-run has never been the thing that catches the interaction.

7. **`ALL GREEN @ <sha>`.** Only now does the integrator merge, and **only that SHA** — see the pin
   rule below.

8. **Restore the rules, then reconcile.** `fleet-reconcile.sh --pr <N> --apply`, then release the
   lease. The wave is not over until the tracker matches the code.

## Leaving degraded mode: repay what the window owes

Every `NOT-RUN` in a window's run reports is a verdict CI still owes: a path-filtered job that the
first post-window PR will skip, a scheduled scan whose next run becomes the new baseline and absorbs the
window's findings unattributed, a nightly lane that is the only enforcement of something. Keep them in
a committed ledger while the window is open, and name it from `.claude/fleet-mode.json`:

```json
{ "mode": "degraded", "issue": "Owner/Repo#N", "owedVerdicts": ".claude/owed-verdicts.json" }
```

The ledger is `{ "items": [ { "id", "verdict", "howToPay", "paid": null } ] }`; a payment records the
run that measured it, the SHA and the result (a red result is a payment when it names the issue it
filed; the debt is the missing measurement, not a pass). `fleet-mode.sh` lists the unpaid ids in the
degraded banner, in the stale-declaration banner once Actions is back, and, after the file says
`normal`, in a `VERDICTS OWED` banner that stays until the ledger is settled.

**Do not set `mode` back to `normal` while an item is unpaid.** The first run that can pay a debt is
the first one after Actions returns, so pay each then (dispatch the lane, record the run), and only
then declare normal. A repo can also make the debt a gate: MuscleBuddy's
`scripts/ci/owed-verdicts.test.ts` fails every CI run ON Actions while its ledger has an unpaid item,
so the first PR after the window is the one that records the payments.

## Traps

Each of these cost a session the first time. They are listed in the order they bite.

**Content-hash pins must be recomputed on the combined tree, never resolved by picking a side.**
A legal-document hash, a lockfile integrity value, a bundle digest: both sides of the conflict are
correct for their own tree and wrong for the merged one. Taking either produces a file that passes
review and fails verification. Rebuild the pin from the merged content.

**Regenerate, never hand-merge.** Migration checksums, generated API docs, sitemap lastmod maps,
compliance registers, component inventories, engine digests — every one of these is derived. A
hand-merge of a derived file is a lie that looks like a resolution. Delete the conflict, run the
generator, commit what it produced.

**Run the compliance verify FIRST.** It is the cheapest check and the one that invalidates the others:
if the register disagrees with the tree, every downstream failure is noise about a tree that was never
consistent. Establish the tree is coherent, then spend the hour on the test suite.

**Re-check migration timestamps across batches.** Two batches, each internally ordered and valid alone,
interleave wrongly when stacked: batch A's `2026-09-12` migration lands after batch B's `2026-09-10`,
and the combined history is out of order even though neither PR was. Check the ordering of the
*combined* set, and renumber in the integration branch.

**Restore a lifted org ruleset with `bypass_actors` only.** Replaying a full backup of the ruleset
JSON 422s on `/conditions`. Capture the ruleset before lifting, but restore by PATCHing back the
`bypass_actors` array you emptied — not the whole document.

**Pin the merge to the validated SHA.** Merge by explicit SHA, not by branch name. A branch name
resolves at merge time, so a late push — an implementer who missed the freeze, an automated commit —
rides in unvalidated and the `ALL GREEN` line now describes a tree that was never merged.

**The duration-budget discriminator.** A job over its wall-clock budget means two different things.
Over budget when run **alone** is structural — the job genuinely got slower, and that is a real
finding. Over budget **only in-suite** is contention: other agents on the box. Re-run the one job by
itself before filing anything, because the two have opposite fixes.

**Never `pkill` by pattern.** Every pattern on a shared box matches a sibling agent. Kill only a PID
you started and recorded.

**Never end a turn waiting on a background task.** A Bash call over 10 minutes is auto-backgrounded and
never notifies a subagent. Run long work detached with an explicit exit-code marker file and poll for
that marker in foreground loops under 9 minutes.

**Chunk eslint.** Above roughly 12 files per invocation it OOMs on these boxes, and an OOM-killed
eslint behind a pipe reports the pipe's exit code. Chunk the file list and read each chunk's own
status.

**Never glob loosely in a shared scratchpad.** Another session's files are in there. A `Closes` census
went from 87 to 176 that way, and the inflated number looked plausible enough to act on. Work in a
subdirectory you named.
