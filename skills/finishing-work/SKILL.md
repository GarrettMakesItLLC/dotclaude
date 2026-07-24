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

## 2. Follow-ups

File them per **managing-work-with-issues** (that skill owns the when). Then don't just file and walk: dispatch a subagent in its own worktree to work each one in parallel, unless it's blocked, needs Garrett's input, or genuinely belongs in a separate session. Batch related findings into one issue. Reference each from the PR (`Follow-up: #123`) and list them with status in the final summary.

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
