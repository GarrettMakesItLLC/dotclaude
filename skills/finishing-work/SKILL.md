---
name: finishing-work
description: 'Use when wrapping up a coding task, before claiming done, opening a PR or handing back: definition-of-done checklist, PR body, clean workspace. Not for mid-task checkpoints.'
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git worktree:*), Bash(git branch:*), Bash(git checkout:*), Bash(git pull:*), mcp__github-rest__pr_create, mcp__github-rest__pr_update, mcp__github-rest__pr_view, mcp__github-rest__pr_checks, mcp__github-rest__issue_open, mcp__github-rest__issue_set_status
---

# Finishing work

Layers on `superpowers:finishing-a-development-branch` and `superpowers:verification-before-completion`.

## 1. Definition of done

The verification rules are in CLAUDE.md (*Verify before a handoff*), enforced in part by `verify-reminder.sh`; §2–§4 below hold their detail. What this checklist adds is everything *besides* green checks — run it against the actual diff, don't assume:

- [ ] Change verified live (app runs, UI exercised) where that's feasible.
- [ ] No debug logging, commented-out code, dead code, or scratch files in the diff.
- [ ] No unrelated / scope-creep changes in the diff.
- [ ] No secrets; `.env` not staged.

**For a feature, all four layers land in the same PR** — a feature with any of them deferred is unfinished, not shipped:

- [ ] **Tests** — unit *and* integration covering the new paths, not a smoke test that only proves it imports.
- [ ] **Docs** — README / architecture / runbook updated in this change, not filed as a follow-up.
- [ ] **Seed / fixture data** — the feature is exercisable in staging with realistic data, and you exercised it there.
- [ ] **Observability** — failures surface somewhere Garrett would actually see them (logs, error tracker), and errors are handled rather than swallowed. Add a kill switch only if the feature genuinely warrants one; don't gate it dark by default (see `rules/data-api.md`).

Any box you can't check goes in the summary explicitly. Never present unverified work as done, and never describe a feature as complete while a layer is outstanding — say which layer is missing and why.

**A local gate that can skip itself is not a gate.** Some pre-commit hooks degrade silently under load — RedThread's ESLint wrapper gates on free memory and skips when the machine is contended, which is exactly the state parallel agents put it in. Every agent then reports "committed, hooks passed" truthfully and every PR goes red on lint in CI. Before the push, name each local gate the repo runs and whether it can self-skip; for any that can, run it explicitly in the foreground on the changed files (`npx eslint <files>`) and read its exit code. "Run typecheck, CI runs the rest" assumes the hook ran.

**Push through `bin/git-push.sh` in any repo whose pre-push hook runs the full gate.** git opens the transport before it runs the hook, so a hook that takes minutes leaves an idle connection that gets dropped: the push exits 141 with the ref unmoved and the gate already paid for. The wrapper runs the hook first, on its own, then pushes with the connection open for the transfer only, and compares the pushed ref against `git ls-remote` — an exit code alone has not been evidence of a landed push. Same arguments as `git push`; it prints a log path on its first line. `git push --no-verify` stays blocked by `git-guard.sh`.

**Before every push, read `git diff --stat origin/<base>...HEAD` — it must list only your files.** Under parallel merging the base branch moves while you work, and two habits silently undo other people's landed work: squashing with `git reset --soft origin/<base>` (which folds every sibling merge since you branched into a commit that deletes it — 108 files, once) and pushing a rebase without looking. Squash against the merge base only: `git reset --soft $(git merge-base origin/<base> HEAD)`. And after any rebase that touched `package.json` or the lockfile, reinstall before trusting lint or typecheck — a dependency bump you just pulled in shows up as bogus `no-unsafe-*` errors on lines you never touched.

### Regression checklist

The mechanically-checkable subset of `running-an-audit`'s realms, run against this diff — not a dispatch, not a full audit. Under a minute:

- [ ] No test disabled, skipped, or loosened to let this diff pass.
- [ ] No unjustified lint-disable comment added.
- [ ] Any new route or form: security headers / CSRF / secure cookie flags present (`../running-an-audit/references/security-access-control.md`).
- [ ] No secrets in the diff; no API key reachable from a frontend bundle.
- [ ] Any new image: alt text. Any new page: meta title + description, exactly one `<h1>` (`../running-an-audit/references/seo-metadata.md`).
- [ ] No new emoji-as-icon usage; no new purple/violet accent that isn't already in the token system (`../running-an-audit/references/visual-anti-slop.md`).
- [ ] Any new async surface: loading, error, and empty states present, using a skeleton where the shape is known rather than a spinner — see `../running-an-audit/references/ux-coherence.md`, don't re-derive it here.
- [ ] Any new UI at a phone viewport: no horizontal document scroll, tap targets ≥44px, no hover-only affordance (`../running-an-audit/references/responsive-mobile.md`).
- [ ] Any new icon-only button: accessible name *and* tooltip. Any new link or button: it actually goes somewhere (`../running-an-audit/references/site-hygiene-launch-tells.md`).
- [ ] Any new mutation: wrapped in a transaction if multi-step, idempotent if externally triggered, and it produces a visible success or error message (`../running-an-audit/references/data-integrity-safety.md`).
- [ ] Any new outbound call: explicit timeout, and a stated behaviour when the dependency is down (`../running-an-audit/references/resilience-dependencies.md`).
- [ ] Any new client-side role or permission check: the server-side counterpart exists (`../running-an-audit/references/security-access-control.md`).

## 2. Reading a check's result

- **Never pipe a verification command.** Run it bare and read its exit code; pipe only after the status is captured (`cmd; rc=$?` or `set -o pipefail`). A killed process reports the pipe's exit code, not its own: `npx eslint <files> | tail -20` reads clean whether lint passed or the OOM-killer took eslint out mid-run, and the second is common under swarm load. When a hook fails with a message that doesn't match the diff (`Task failed to spawn` from lint-staged, for instance), suspect the environment first: `dmesg | grep -i "killed process"` settles it (see #186).
- **A synthesized completion is not proof.** A `Monitor` event, a background task's `tasks/<id>.output` file and a `run_in_background` Bash task's own notification have each reported `completed` / `exit code 0` while the output file was still empty and the process unfinished (see #217), or while the command had exited non-zero — a `git commit` whose pre-commit hook failed, a failing `npm test` (see #351). Redirect the command to a self-named log (`cmd > scratchpad/build.log 2>&1; echo "EXIT=$?" >> scratchpad/build.log`) and read that file and the real artifact (`git log`, the test summary).

## 3. Arming auto-merge

- **Arm once the branch is final, not merely when the PR is open.** Arming means "merge the instant checks pass, whatever the branch says then", so every push after arming races a merge already authorised. For a dispatched agent that has finished, open and final are the same moment. They come apart when a reviewer finds a defect after checks clear: a push after arming must re-check that it landed on a still-open PR, and if the PR merged first, the correction needs its own PR. A reviewer with a fix for an armed PR checks `state` first.
- **One arming chain.** `mcp__github-rest__pr_auto_merge` first. If the `github-rest` MCP is unavailable, send the bare `enablePullRequestAutoMerge` mutation with `gh api graphql`. If arming is throttled — GraphQL's secondary limit can refuse the mutation while `rate_limit` still shows thousands remaining, so there is nothing to sleep until — wait for green, then `pr_merge`. Never merge on red or pending, and never `gh pr merge --auto`: it issues extra GraphQL calls that trip the secondary limit under concurrent-agent load (see #238).
- **Read back the right field.** `pr_auto_merge` returns `armed` (read back, not inferred), `in_merge_queue`, `auto_merge_request` and `merge_state_status`; trust `armed`. On a repo with a required merge queue, `auto_merge_request` is null for a queued PR by design — `in_merge_queue` is the signal there, and reading the wrong one looks exactly like a dropped request (see #259). Off the queue, a request can genuinely vanish: `CLEAN`, all checks green, `auto_merge_request: null`, no event (see #236). §8 handles both.

## 4. Destructive git under concurrency

Three habits destroy work silently. The remedy for all three is to address the real artifact by path, at a known ref.

- **`git stash` is repo-wide.** `refs/stash` is one stack shared by every worktree of a repo; a linked worktree isolates the working tree and index, never the ref namespace, so two agents interleaving push and pop take each other's entries with no error. Commit to your branch instead; `git reset --soft HEAD~1` undoes it. `git-guard.sh` blocks it wherever a sibling worktree exists.
- **Commit before you break anything on purpose.** Reverting a deliberate break with `git checkout -- <file>` reverts to the last commit and silently takes any unrelated uncommitted work in that file with it. Start the break from a clean tree, or `cp <file> <file>.bak` and `mv` it back.
- **Break it by restoring the real defect.** `git checkout <sha-that-had-the-bug> -- <path>` (or `git checkout origin/<trunk> -- <path>` where the defect predates the branch) gives the genuine input. A hand-written break can be strictly easier than the real one — unused where the original was used, shallower, missing the second file it interacted with — and passing it proves nothing. If a guard does not fire on a hand-written break, suspect the break first. The same trap applies to live probes: an authorization probe made harmless by naming a nonexistent column was rejected before reaching the authorization check. Making the input safer or simpler moves it out of the code path under test.

`git checkout <ref> -- <path>` is also the answer to the first two: it reads a file back at a known ref without popping a stash and without discarding uncommitted work.

## 5. Account for every finding

Walk the findings you accumulated this session — bugs noticed in passing, tests you skipped, docs left stale, rough edges in code you touched. Each one is either **in this diff** or **has an issue number**. There is no third bucket (CLAUDE.md: *Finish what you find*).

- **Fixable here ⇒ fix it here.** Adjacent and unblocked counts as here. Do it now, in this branch, before the PR — a second PR costs another round of context, review, and CI, and usually never happens.
- **Genuinely out of scope or needs Garrett ⇒ file it** per **managing-work-with-issues**, batching related findings into one issue. Reference each from the PR (`Follow-up: #123`) and name it in the summary.

Don't spawn an agent per follow-up. If a filed issue is ready to work, work it next yourself, or leave it for a later session — CLAUDE.md (*Execution*) keeps spawn counts low and delegates only independent, sizeable tracks, and fanning out on your own leftovers is the expensive way to do what fixing-in-place already handles.

Before writing the PR body, state the count out loud: *N findings — M fixed in this diff, K filed as #…*. A finding you can't place in one of those two buckets is one you dropped.

## 6. PR description

- **What & why** — a sentence or two on the change and its motivation, not a file-by-file restatement of the diff.
- **Test evidence** — what you ran, and that it passed.
- **Linked issues** — `Closes #N` for what it resolves, `Follow-up: #123` for what it spawned.
- **Screenshots** for UI or otherwise reviewer-visible changes.
- Conventional-commit-style title.

Canonical shapes live in `~/dotclaude/templates/` — roll them into each repo's `.github/` so the structure is enforced there too.

## 7. Leave the workspace ready

1. `git worktree remove .worktrees/<name>` (from the main checkout).
2. `git branch -d <branch>` once merged or its PR is open (`-D` only if Garrett explicitly abandoned it).
3. `git checkout main && git pull`.
4. Confirm: `git status` clean, `git worktree list` shows no leftovers.

If the branch was an `issue-<N>-*` claim abandoned without a PR, `claim_release` it so the other machine can pick the issue up. `commit-commands:clean_gone` sweeps branches whose remotes are already deleted.

## 8. The one come-back after arming auto-merge

Arming (`pr_auto_merge`) is a request the remote can later revoke: a PR can drop out of auto-merge with every check green, `mergeStateStatus: CLEAN`, and no event explaining it (§3 above). The single generous wakeup the session-owning level schedules after arming (a dispatched subagent arms and stops; its dispatcher comes back) is the one cheap confirmation — so it does more than look for red checks. For every PR still open when it fires, read the arming back (`pr_auto_merge` returns `armed`, `in_merge_queue`, `auto_merge_request`; `pr_view` shows the same) and re-arm any that is clean, green, not in the queue, and no longer armed. Only then treat a still-open PR as needing a real fix.
