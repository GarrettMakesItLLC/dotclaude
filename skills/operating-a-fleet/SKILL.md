---
name: operating-a-fleet
description: Use when more than one machine, or more than a couple of agent sessions, are working one repo at the same time — deciding who implements, who validates and who merges, taking the single fleet-wide integrator lease, batching related issues into one PR, and running a local CI replica when GitHub Actions is unavailable or too expensive to be the gate. Covers the degraded-mode wave procedure and the reconcile pass that runs after every merge.
allowed-tools: Bash(bin/fleet-lease.sh:*), Bash(bin/fleet-reconcile.sh:*), Bash(bin/ci-replica.sh:*), Bash(bin/fleet-mode.sh:*), Bash(gh api:*), Bash(git:*), mcp__github-rest__issue_open, mcp__github-rest__issue_comment, mcp__github-rest__pr_create, mcp__github-rest__pr_auto_merge
---

# Operating a fleet

Several machines and several agent sessions per machine work the same repo. The scarce resource is
not compute — it is **merge order**. Everything here exists so that many sessions can produce work in
parallel while exactly one of them decides what lands next.

**A machine-count of one is a valid fleet.** The same procedure runs on a single box, with one session
holding each lease in turn. Nothing below needs a second machine to be worth doing; the second machine
only makes the roles concurrent.

## Roles are leases, not machines

Three capabilities. Never assign them to hardware — a machine takes a role for a while and gives it
back, and one machine can hold two roles at once as long as the concurrency rule holds.

| Role | What it does | How many at once |
|---|---|---|
| **Implementer** | Takes a batch of related issues, builds one PR for it, verifies its own slice | Many. Several per machine. |
| **Validator** | Checks out one SHA and runs the gate against it. Pushes nothing, ever. | Many — but **never two on the same SHA**. Duplicate validation is the most expensive way to learn nothing. |
| **Integrator** | Resolves across batches, decides merge order, merges, runs reconcile | **Exactly one, fleet-wide.** Merges serialize; two integrators produce a conflict mess and a half-merged tree. |

The integrator holds a lease. The other two roles do not need one — they need a claim on their work
(`managing-work-with-issues`) and, for the validator, a SHA nobody else has taken.

### Taking the integrator lease

`bin/fleet-lease.sh` is the mechanism. The lease is a **remote ref**, created atomically the same way
`issue_claim` creates a claim ref, so a second machine's attempt fails loudly instead of racing:

```bash
bin/fleet-lease.sh take integrator --ttl 5400 --note "wave 3 integration"
bin/fleet-lease.sh renew integrator          # before the TTL expires, if still working
bin/fleet-lease.sh release integrator        # the moment the wave is merged
bin/fleet-lease.sh status integrator         # who holds it, since when, stale or not
```

The ref carries the holder identity and a timestamp, so `status` can say *stale* rather than only
*held*. A stale lease is force-releasable **with evidence** — a reason naming what you checked:

```bash
bin/fleet-lease.sh release integrator --force \
  --reason "holder laptop/garrett idle 3h, no push to any batch/* since <sha>, #8137 last comment 4h ago"
```

Never force-release on age alone. Age plus *no activity* is evidence; age by itself is a slow wave.

## Coordination lives on the remote

**No shared state in a local file.** A local file is invisible to the other machine, and the failure
mode is silent: both sessions read a consistent-looking world and act on different ones. The only
shared state is what the remote holds — **GitHub issues, PR bodies, and refs**.

Each repo gets one **standing coordination issue**, pinned in the runbook or linked from `CLAUDE.md`.
It carries, in comments:

- `READY <sha>` from the integrator — this exact tree is frozen and wants a gate run.
- `## Run N` from a validator — a PASS/FAIL/NOT-RUN table, and for each failure the command, the exit
  code, a log excerpt, and the **owning batch**, so the fix has an address.
- `ALL GREEN @ <sha>` when a full run passes. Merge authorization is that line, for that SHA.

MuscleBuddy#8137 (standing) and MuscleBuddy#8132 (one wave) are the worked examples — read both before
writing a new one. #8132 shows the per-wave shape; #8137 shows it generalized into a standing gate.

## Two modes, and the one variable between them

The only thing that changes is **what authorizes a merge.**

| | **Normal** | **Degraded** |
|---|---|---|
| Merge authorization | CI green on the PR | `ALL GREEN @ <sha>` from a validator's local CI replica |
| Serialization | The merge queue | The integrator lease |
| Unit of work | One PR per batch of 3–8 related issues | One integration branch per wave, the batch PRs stacked into it |
| Branch rules | Untouched | Lifted per merge and restored immediately after |

**Enter degraded mode when** Actions refuses jobs (billing stop, outage, org-level block), or the open
PR queue is past ~20 and the queue itself is the bottleneck, or the month's Actions spend is over
budget.

**Leave it when** CI is green again *and* the queue has drained. Leaving is not automatic — the last
integrator says so on the coordination issue and restores the rules.

### Which mode is this repo in? Do not guess, and do not wait to be told

`bin/fleet-mode.sh` answers it, and `hooks/fleet-mode-report.sh` puts the answer in front of every
session at SessionStart — silent when CI is healthy, loud when it is not. The two facts have two
different kinds of source, and keeping them apart is the whole design:

- **Is CI answering?** Observable, and it changes without anyone editing anything, so it is **probed**
  live. A billing refusal has a specific signature: a run that concludes `failure` seconds after
  starting, jobs that executed zero steps, across more than one workflow. Nothing a repo does to
  itself looks like that.
- **Has degraded mode been authorized?** Not observable at all, so it is **declared** — committed, in
  `<repo>/.claude/fleet-mode.json`.

Because the probe is the authority on the first, a declaration that went stale is *caught* rather than
believed: a repo still declaring `degraded` while Actions is running jobs again is reported as a stale
declaration, which is the failure a marker file alone can never see. When the probe cannot tell — no
`gh`, no network, no runs — it says **unknown** and guesses nothing, because telling a session to trust
a gate that is not running is worse than telling it nothing.

Full matrix, the signature, the file format and the caching: `references/mode-detection.md`.

**Degraded mode is owner-authorized policy, not an agent's call.** An agent may *observe* the triggers
and say so; entering the mode means lifting branch protection, which needs Garrett's authorization for
this repo, in writing, on the coordination issue. An agent that finds itself wanting degraded mode
files or comments and stops.

The wave procedure, and the traps that cost a full session the first time through, are in
`references/degraded-mode.md`.

## The gate in degraded mode: a declarative CI replica

An agent reading `ci.yml` and improvising the equivalent locally is not a gate. Two validators did
exactly that on one tree and disagreed about what counted — one skipped the a11y postbuild checks, the
other skipped the license audit, and both reported green. A gate two people can read differently is
not measuring anything.

So the replica is **declarative**. Each repo carries `.claude/ci-replica.json` naming its jobs, their
commands in order, their env (including what must be *unset*), whether they need a data plane, a
wall-clock expectation, and — crucially — a `"local": false` marker for jobs that cannot run here at
all (macOS runners, CodeQL). `bin/ci-replica.sh` runs it:

```bash
bin/ci-replica.sh --list                   # what this repo declares
bin/ci-replica.sh                          # run every local job, print the table
bin/ci-replica.sh --job lint --job test    # re-run only what failed
bin/ci-replica.sh --base origin/main       # a promotion: diff checks measure against main
```

It captures real exit codes, writes a per-job log, never pipes a verification command, and prints
PASS / FAIL / NOT-RUN. **NOT-RUN is not PASS**, and the script says so in the summary rather than
letting a green-looking table imply coverage it does not have. A `"local": false` job is reported
NOT-RUN every run, by design — that is the honest statement about a macOS build on a Linux box.

Schema, every field, and a documented example: `references/ci-replica-manifest.md`.

## Batching is normal-mode behaviour too

The real bottleneck during a 4-agents-per-machine burst is not CI — it is the **pre-push gate**, which
serializes on one box's memory and one check lock. Batching cuts the number of times that gate runs.

This is already the rule: see `CLAUDE.md` § **Batch PRs**. Nothing here changes it. What the fleet adds
is *who decides the batch*: the integrator groups issues into batches and says so on the coordination
issue, so two implementers do not each build a PR containing the same shared file.

A batch is 3–8 issues that touch the same subsystem and would resolve against each other anyway. A
batch spanning three subsystems is not a batch, it is an unreviewable diff.

## After every merge: reconcile

The failure this fixes is issues that shipped and never closed. A merge with the rules lifted skips
the workflow that normally closes issues and clears labels, and `Closes #A, #B` on one line closes
only `#A` — so the tracker drifts away from the code, silently, in the direction of looking like more
work remains than does.

```bash
bin/fleet-reconcile.sh --last 5            # dry run: what it would do
bin/fleet-reconcile.sh --pr 8135 --apply   # act on one merged PR
```

Run it after **every** merge, in both modes. In normal mode it is usually a no-op, and a no-op that
takes four seconds is the cheapest possible way to know the tracker is true.

## Standing rules for every session in a fleet

- **Never `pkill` by pattern on a shared box.** Every pattern matches a sibling agent's process. Kill
  only a PID you started and recorded.
- **Never end a turn waiting on a background task.** A Bash call over 10 minutes is auto-backgrounded,
  and nothing delivers its completion to a subagent whose turn has ended. Run long work detached with
  an exit-code marker and poll in foreground loops under 9 minutes.
- **Never glob loosely in a shared scratchpad.** Another session's files are in there. One agent
  inflated a `Closes` census from 87 to 176 by globbing a scratch directory it shared — and the number
  looked plausible, which is why it survived. Name your own subdirectory and glob inside it.
- **eslint OOMs above roughly 12 files per invocation** on these boxes. Chunk it, and read the exit
  code of each chunk rather than a pipe's.
