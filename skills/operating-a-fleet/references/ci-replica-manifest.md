# The CI replica manifest

`bin/ci-replica.sh` reads `.claude/ci-replica.json` from the repo root. The manifest exists so that
the gate is a thing two validators read identically, instead of two agents each interpreting `ci.yml`.

The manifest is **not** generated from `ci.yml` — some CI jobs have no local equivalent and some local
checks are worth running that CI does not. It is hand-written, reviewed, and kept honest by the same
rule as any other config: when it drifts from `ci.yml`, the drift is a finding.

A worked example is in this directory as `ci-replica.example.json`. Copy it, delete what does not
apply, and keep the `"local": false` entries — those are the honest record of what your box cannot
measure.

## Top level

| Field | Type | Required | Meaning |
|---|---|---|---|
| `version` | integer | yes | Schema version. Currently `1`. The script refuses anything else rather than guessing. |
| `jobs` | array | yes | The jobs, in the order they should run. |
| `logDir` | string | no | Where per-job logs are written, relative to the repo root. Default `.ci-replica`. Gitignore it. |
| `env` | object | no | Environment applied to every job. Job-level `env` wins on a key collision. |
| `unset` | array of string | no | Variables removed from every job's environment before it runs. |

`unset` is load-bearing, not a nicety. On a box where `BASH_ENV` points at a shell profile, a `bash -c`
step silently re-sources it and gets the ambient value back — so a run can be pointed at the wrong
database, or the wrong Supabase project, and report a clean pass about the wrong thing. List every
variable that must not leak in.

## A job

| Field | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | Unique. What `--job` selects and what the table and log file are named after. |
| `commands` | array of string | yes | Run in order, in the repo root. A non-zero exit fails the job and skips its remaining commands. Empty for a `"local": false` job. |
| `env` | object | no | Job-scoped environment, merged over the top-level `env`. |
| `unset` | array of string | no | Job-scoped unsets, added to the top-level `unset`. |
| `local` | boolean | no | Default `true`. `false` means this job **cannot** run here — a macOS runner, a hosted scanner. Reported NOT-RUN every run. |
| `localReason` | string | when `local` is `false` | Why, and where it is verified instead. Printed in the table so the gap is visible, not inferred. |
| `needsDataPlane` | boolean | no | Default `false`. The job talks to a real database or a shared test branch. Skipped as NOT-RUN unless `--data-plane` is passed. |
| `dataPlaneReason` | string | when `needsDataPlane` | What it touches and how to provision it. |
| `budgetSeconds` | integer | no | Wall-clock expectation. Over it, the job is still PASS but is flagged `over budget`. |
| `mutatesTree` | array of glob | no | Paths this job is ALLOWED to leave changed in the working tree. Anything else it changes fails it — see below. |
| `withoutFiles` | array of path | no | Paths that must be ABSENT while this job runs. The runner moves each aside before the job's commands and puts it back afterwards, including when the job fails or the run is interrupted. Repo-relative; an absolute path or one escaping the root is refused. |

A command containing a newline is rejected at load: the plan is one command per line, and a multi-line
entry would silently run only its first line. Put a multi-step sequence in a repo script and name the
script here.

## The tree guard

Every job runs against **one** working tree, in sequence. A job that writes into
it silently changes what every later job measures, and GitHub Actions cannot see
this class of failure at all, because it gives each job its own checkout.

It is not hypothetical. MuscleBuddy's `build:budget` gained a `prebuild` step so
the gate would measure the catalogue Vercel compiles in; it did, and then left
the fetched catalogue in the tree. `marketing-budgets` runs before `a11y`, so the
axe sweep scanned show routes the committed tree does not have and reported a
WCAG violation on a page that exists in no commit. Two validators read that as a
real accessibility regression before anyone found the cause.

So the runner snapshots `git status --porcelain -uall` before each job and again
after, and a job that leaves an undeclared change fails with exit 91:

```
    ! tree-guard: marketing-budgets changed undeclared files:
        apps/web/src/data/db-shows.generated.ts
        Every later job now measures a tree no commit describes.
        Restore them, or declare them in this job's `mutatesTree`.
```

Three things about it are deliberate:

- **It runs after a FAILING job too.** Otherwise the first red job hides the dirt
  it left for the next one — and a timed-out or half-finished command is exactly
  when a tree gets left mid-write.
- **`-uall`, not plain `--porcelain`.** Git collapses a newly created directory
  to `gen/`, and then no file-level pattern in `mutatesTree` can ever match what
  is inside it.
### `withoutFiles` — a file whose mere presence changes the answer

Some jobs are only meaningful against a tree that does NOT contain a given
file. Two of MuscleBuddy's did, for unrelated reasons: an authenticated axe
scan inherited a live Supabase session from `apps/web/.env.local` and hung on
the sign-in screen, and a native build declared `VITE_API_URL` to mirror CI
while the same `.env.local` said `localhost`, so the repo's ambient-env guard
failed the job on the disagreement in about seven seconds.

Both were carried as prose in `$localDeviations` — "move the file aside, run,
put it back" — which is not enforcement. A validator who forgot got a failure
whose message pointed somewhere else entirely; the native one read as a stray
shell export.

```json
{
  "name": "native",
  "withoutFiles": ["apps/web/.env.local"],
  "commands": ["npm run build:native"]
}
```

The move and the restore belong to the runner, not to a human's memory. The
restore runs after a FAILING job and on SIGINT/SIGTERM too — a run that aborts
leaving a repo's `.env.local` renamed is worse than the problem the field
solves. It also runs before the working-tree check, so a moved-aside file never
reads as the job having deleted it.

Name the field for the mechanism, not the case: `.env.local` is simply the
first path that needed it.

- **An intentional write is DECLARED, beside `local` and `needsDataPlane`.** A
  job that is supposed to write says so in the manifest, which makes it
  reviewable rather than discovered. Entries are `fnmatch` globs against the
  repo-relative path.

`--no-tree-guard` turns it off for a run. That is for debugging the guard itself;
a job that legitimately writes wants `mutatesTree`, because the flag disables the
check for every job at once.

## Reading the result

`PASS` and `FAIL` mean what they say. **`NOT-RUN` never means PASS** — it means the gate has a hole,
and the summary names each hole so the validator's report on the coordination issue can carry it.
A wave merged on a table containing a `NOT-RUN` job is a wave merged with that job unverified, which
may be entirely fine and must be stated rather than assumed.

An `over budget` flag is ambiguous on its own: over budget when run **alone** is structural, over
budget only **in-suite** is contention from sibling agents. Re-run the one job with `--job <name>`
before treating it as a finding.

## Where the manifest lives

One per repo, at `.claude/ci-replica.json`, committed. It is config, not scratch — a validator on
another machine reads the same file, which is the whole point.
