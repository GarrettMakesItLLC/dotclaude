---
name: finishing-work
description: Use when wrapping up a coding task — before claiming something is done, opening a PR, or handing work back. Runs the definition-of-done checklist, files and dispatches follow-ups, writes the PR body, and leaves the workspace clean and ready.
---

# Finishing work

My personal finish-line procedure. Layer it on top of `superpowers:finishing-a-development-branch` and `superpowers:verification-before-completion` — this captures the specifics those skills don't know about.

## 1. Definition of done — verify, don't assume

Run the commands; never check a box you didn't actually confirm.

- [ ] Typecheck and lint clean (`--max-warnings 0` where CI enforces it).
- [ ] Tests pass — existing plus new ones covering the change.
- [ ] App runs / change verified live where feasible.
- [ ] No debug logging, commented-out code, dead code, or stray scratch files in the diff.
- [ ] No unrelated / scope-creep changes in the diff (those become follow-up issues — see step 2).
- [ ] Diff self-reviewed; no secrets committed; `.env` not staged.

If any box can't be checked, **say so explicitly in the summary** — never present unfinished or unverified work as done.

## 2. File and tackle follow-ups

For anything deferred — out of scope, big, unrelated, a known limitation, a flagged risk:

- `gh issue create` with a clear title and a short body (what + why + a `file:line` pointer); add a label if the repo uses them.
- **Don't just file it and walk away** — dispatch a subagent (in its own worktree) to address it in parallel, unless it's genuinely blocked, needs Garrett's input, or belongs in a separate session.
- Reference each issue from the PR (`Follow-up: #123`) and list them, with status (agent working it / blocked / parked), in the final summary.
- Batch related follow-ups into one issue rather than many tiny ones.

## 3. PR description

A PR body worth merging has:

- **What & why** — one or two sentences on the change and motivation, not a file-by-file restatement of the diff. Describe the **final state**, never the journey (no "first I tried X" / incremental progress diary).
- **Test evidence** — what you ran and that it passed.
- **Linked follow-ups** — `Follow-up: #123` for issues opened off this work; `Closes #N` for any it fully resolves.
- **Screenshots / notes** for UI or otherwise reviewer-visible changes.
- Conventional-commit-style title. Keep it tight.

## 4. Leave the workspace clean and ready

A task is done when the checkout is ready for the next one — not at "PR opened."

1. `git worktree remove .worktrees/<short-name>` (from the main checkout).
2. `git branch -d feature/<short-name>` once it's merged or its PR is open (`-D` only if Garrett explicitly abandoned it).
3. `git checkout main && git pull` to return to the default branch, current.
4. Verify: `git status` is clean and `git worktree list` shows no leftovers.

**Never** delete a worktree or branch with uncommitted or unpushed work without flagging it first. Use `commit-commands:clean_gone` to sweep branches whose remotes are already deleted (`[gone]`).
