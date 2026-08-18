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

### Regression checklist

The mechanically-checkable subset of `running-an-audit`'s realms, run against this diff — not a dispatch, not a full audit. Under a minute:

- [ ] No test disabled, skipped, or loosened to let this diff pass.
- [ ] No unjustified lint-disable comment added.
- [ ] Any new route or form: security headers / CSRF / secure cookie flags present (`running-an-audit/references/security-access-control.md`).
- [ ] No secrets in the diff; no API key reachable from a frontend bundle.
- [ ] Any new image: alt text. Any new page: meta title + description, exactly one `<h1>` (`running-an-audit/references/seo-metadata.md`).
- [ ] No new emoji-as-icon usage; no new purple/violet accent that isn't already in the token system (`running-an-audit/references/visual-anti-slop.md`).
- [ ] Any new async surface: loading, error, and empty states present — see `running-an-audit/references/ux-coherence.md`, don't re-derive it here.

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
