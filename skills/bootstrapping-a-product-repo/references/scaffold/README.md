# Scaffold files

Copied into a new repo by the `bootstrapping-a-product-repo` skill. Two files are named to survive
being stored here:

| Here | Copy to |
| --- | --- |
| `gitignore` | `.gitignore` — a real `.gitignore` in this directory would make git ignore the scaffold's own contents |
| everything else | same path |

## Placeholders

`package.json` carries `REPO_NAME_LOWERCASE`. Replace it with the repo name, lowercased, no spaces.
Nothing else is templated — every other file is identical in every repo, which is the reason they live
here rather than being re-authored per repo.

## One name that must not change

- **`CI Success`** — the `ci-success` job's display name in `ci.yml`. The `StagePR` and `ProdPR`
  rulesets require it by that exact string; renaming it silently unprotects the branch. It is the
  only required status check — `lint-pr-title` (PR-title linting) lives inside `ci.yml` and joins
  `ci-success`'s `needs:` rather than being independently required.

This is why one ruleset definition is portable across every repo in the org.

## What is deliberately absent

`.github/ISSUE_TEMPLATE/` and `.github/PULL_REQUEST_TEMPLATE.md`. `GarrettMakesItLLC/.github` supplies
those org-wide to every repo that does not define its own. A local copy wins over the org default, so
adding one means a template change has to be made in every repo forever and nothing notices a missed
one.

## `ci.yml` is a floor, not a finished gate

It runs formatting and markdown lint, which is everything a repo with no application code has. As
`apps/` and `packages/` land, add typecheck, test, and build jobs — and add them to `ci-success`'s
`needs:`, or a failure there will not block the merge.
