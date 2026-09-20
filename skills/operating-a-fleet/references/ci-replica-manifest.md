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

A command containing a newline is rejected at load: the plan is one command per line, and a multi-line
entry would silently run only its first line. Put a multi-step sequence in a repo script and name the
script here.

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
