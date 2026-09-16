---
name: finishing-work
description: Use when wrapping up a coding task — before claiming something is done, opening a PR, or handing work back. Runs the definition-of-done checklist, writes the PR body, and leaves the workspace clean and ready.
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git worktree:*), Bash(git branch:*), Bash(git checkout:*), Bash(git pull:*), mcp__github-rest__pr_create, mcp__github-rest__pr_update, mcp__github-rest__pr_view, mcp__github-rest__pr_checks, mcp__github-rest__issue_open, mcp__github-rest__issue_set_status
---

# Finishing work

Layers on `superpowers:finishing-a-development-branch` and `superpowers:verification-before-completion`.

## 1. Definition of done

Verification itself is covered by CLAUDE.md and `verify-reminder.sh`. What this checklist adds is everything *besides* green checks — run it against the actual diff, don't assume:

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

**Before every push, read `git diff --stat origin/<base>...HEAD` — it must list only your files.** Under parallel merging the base branch moves while you work, and two habits silently undo other people's landed work: squashing with `git reset --soft origin/<base>` (which folds every sibling merge since you branched into a commit that deletes it — 108 files, once) and pushing a rebase without looking. Squash against the merge base only: `git reset --soft $(git merge-base origin/<base> HEAD)`. And after any rebase that touched `package.json` or the lockfile, reinstall before trusting lint or typecheck — a dependency bump you just pulled in shows up as bogus `no-unsafe-*` errors on lines you never touched.

### Regression checklist

The mechanically-checkable subset of `running-an-audit`'s realms, run against this diff — not a dispatch, not a full audit. Under a minute:

- [ ] No test disabled, skipped, or loosened to let this diff pass.
- [ ] No unjustified lint-disable comment added.
- [ ] Any new route or form: security headers / CSRF / secure cookie flags present (`running-an-audit/references/security-access-control.md`).
- [ ] No secrets in the diff; no API key reachable from a frontend bundle.
- [ ] Any new image: alt text. Any new page: meta title + description, exactly one `<h1>` (`running-an-audit/references/seo-metadata.md`).
- [ ] No new emoji-as-icon usage; no new purple/violet accent that isn't already in the token system (`running-an-audit/references/visual-anti-slop.md`).
- [ ] Any new async surface: loading, error, and empty states present, using a skeleton where the shape is known rather than a spinner — see `running-an-audit/references/ux-coherence.md`, don't re-derive it here.
- [ ] Any new UI at a phone viewport: no horizontal document scroll, tap targets ≥44px, no hover-only affordance (`running-an-audit/references/responsive-mobile.md`).
- [ ] Any new icon-only button: accessible name *and* tooltip. Any new link or button: it actually goes somewhere (`running-an-audit/references/site-hygiene-launch-tells.md`).
- [ ] Any new mutation: wrapped in a transaction if multi-step, idempotent if externally triggered, and it produces a visible success or error message (`running-an-audit/references/data-integrity-safety.md`).
- [ ] Any new outbound call: explicit timeout, and a stated behaviour when the dependency is down (`running-an-audit/references/resilience-dependencies.md`).
- [ ] Any new client-side role or permission check: the server-side counterpart exists (`running-an-audit/references/security-access-control.md`).

## 2. Account for every finding

Walk the findings you accumulated this session — bugs noticed in passing, tests you skipped, docs left stale, rough edges in code you touched. Each one is either **in this diff** or **has an issue number**. There is no third bucket (CLAUDE.md: *Finish what you find*).

- **Fixable here ⇒ fix it here.** Adjacent and unblocked counts as here. Do it now, in this branch, before the PR — a second PR costs another round of context, review, and CI, and usually never happens.
- **Genuinely out of scope or needs Garrett ⇒ file it** per **managing-work-with-issues**, batching related findings into one issue. Reference each from the PR (`Follow-up: #123`) and name it in the summary.

Don't spawn an agent per follow-up. If a filed issue is ready to work, work it next yourself, or leave it for a later session — CLAUDE.md (*Execution*) keeps spawn counts low, and fanning out on your own leftovers is the expensive way to do what fixing-in-place already handles.

Before writing the PR body, state the count out loud: *N findings — M fixed in this diff, K filed as #…*. A finding you can't place in one of those two buckets is one you dropped.

## 3. PR description

- **What & why** — a sentence or two on the change and its motivation, not a file-by-file restatement of the diff.
- **Test evidence** — what you ran, and that it passed.
- **Linked issues** — `Closes #N` for what it resolves, `Follow-up: #123` for what it spawned.
- **Screenshots** for UI or otherwise reviewer-visible changes.
- Conventional-commit-style title.

Canonical shapes live in `~/dotclaude/templates/` — roll them into each repo's `.github/` so the structure is enforced there too.

## 4. Leave the workspace ready

1. `git worktree remove .worktrees/<name>` (from the main checkout).
2. `git branch -d <branch>` once merged or its PR is open (`-D` only if Garrett explicitly abandoned it).
3. `git checkout main && git pull`.
4. Confirm: `git status` clean, `git worktree list` shows no leftovers.

If the branch was an `issue-<N>-*` claim abandoned without a PR, `claim_release` it so the other machine can pick the issue up. `commit-commands:clean_gone` sweeps branches whose remotes are already deleted.

## 5. The one come-back after arming auto-merge

Arming (`pr_auto_merge`) is a request the remote can later revoke: a PR can drop out of auto-merge with every check green, `mergeStateStatus: CLEAN`, and no event explaining it (CLAUDE.md, *Verify before a handoff*). The single generous wakeup you schedule after arming is the one cheap confirmation — so it does more than look for red checks. For every PR still open when it fires, read the arming back (`pr_auto_merge` returns `armed`, `in_merge_queue`, `auto_merge_request`; `pr_view` shows the same) and re-arm any that is clean, green, not in the queue, and no longer armed. Only then treat a still-open PR as needing a real fix.
