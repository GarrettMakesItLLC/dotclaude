# Model gateway and subscription-account management

Two pieces of plumbing that get confused for each other, so read the boundary
first.

## The boundary, plainly

**Claude Code authenticates against a subscription, not an API key.** A Pro or
Max seat's capacity is bound to the account that signed in. It cannot be pooled
behind a proxy, it cannot be rented to a second machine, and no amount of
routing changes that. Nothing in this repo tries to work around it, and any
future thing that claims to should be read as a bug or a lie.

So the two halves are:

| | Claude Code sessions | Everything else |
|---|---|---|
| Auth | Subscription, `/login`, one account per session | API key |
| Managed by | `bin/claude-accounts.sh` + the SessionStart hook | The LiteLLM gateway |
| What management means | Knowing which of the three accounts is limited and until when | Routing by task class, fallbacks, spend caps |

The gateway carries API-key traffic: the Anthropic API where a key exists,
hosted cheap models, and local open-weight models. That is agent-adjacent
tooling — scripts, batch jobs, anything calling an OpenAI-compatible endpoint —
not the coding sessions themselves.

---

# Part 1: the gateway

## Architecture

```
  caller (script, batch job, agent tool)
      │  OpenAI-compatible HTTP, one master key
      ▼
  LiteLLM proxy   127.0.0.1:4000
      │  routes by TASK CLASS, not vendor
      ├── frontier        → Anthropic API   claude-opus-5
      ├── frontier-light  → Anthropic API   claude-sonnet-5
      ├── cheap           → Gemini API      gemini-3.8-flash
      └── local           → Ollama          qwen2.5-coder:7b   (127.0.0.1:11434)
```

LiteLLM runs as a plain user-level background process. **There is no Docker
daemon on this box** (no socket, no passwordless sudo — see
[#152](https://github.com/GarrettMakesItLLC/dotclaude/issues/152)), so the
containerised install upstream documents is not available and is not the path
here.

Install:

```bash
uv tool install 'litellm[proxy]'
```

Files:

| Path | What |
|---|---|
| `gateway/config.yaml` | Base proxy settings. Deliberately has no `model_list`. |
| `gateway/classes/<class>.yaml` | One `model_list` fragment per task class. |
| `gateway/classes.manifest` | Which env keys and which probe each class needs, and where it may fall back. |
| `~/.claude/gateway/runtime-config.yaml` | **Generated.** Composed on every start. Do not edit. |
| `~/.claude/gateway/gateway.log` | Proxy stdout and stderr, appended across restarts. |
| `~/.claude/gateway/gateway.pid` | PID of the running proxy. |
| `~/.claude/gateway/master.key` | Minted on first start, `0600`, never committed. |
| `~/.claude/gateway/state.env` | What the last start decided: port, live classes, waivers. |

`CLAUDE_GATEWAY_HOME` moves that whole directory; `GATEWAY_PORT` moves the port.

The composition step is the load-bearing part. A class whose credential is
missing never reaches the runtime config, and `gateway-up.sh` refuses to start
rather than composing without it. Waiving a class takes naming it:

```bash
bin/gateway-up.sh                                  # every class must be credentialled
bin/gateway-up.sh --allow-missing local            # run without local, on purpose
bin/gateway-up.sh --dry-run                        # compose and validate, start nothing
bin/gateway-status.sh                              # per-class readiness, not just up/down
bin/gateway-down.sh                                # stop the recorded PID, nothing else
```

`gateway-status.sh --quiet` exits 0 only when the proxy is up and answering, so
it composes into scripts.

Calling it:

```bash
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $(cat ~/.claude/gateway/master.key)" \
  -H 'Content-Type: application/json' \
  -d '{"model":"cheap","messages":[{"role":"user","content":"..."}]}'
```

`model` is the **class name**. That is the whole point: a caller asks for the
grade of judgment it needs, and which vendor answers is a config decision made
once, here, rather than a string pasted into forty scripts.

## Routing policy

The rule of thumb: **route by what a wrong answer costs, not by how hard the
task feels.** A label census that gets three issues wrong costs a re-run. A
migration review that gets one thing wrong costs a production incident, and it
will not announce itself as a routing decision when it does.

| Work | Class | Why |
|---|---|---|
| Issue triage, label censuses | `cheap` / `local` | Pattern-matching against a fixed taxonomy. Wrong answers are visible in the diff of the label change and cost one correction. |
| Log summarisation | `cheap` / `local` | The raw log stays available, so a bad summary is recoverable by reading it. Often large and private — prefer `local` when the log carries customer data. |
| Doc-drift diffs (does this doc still describe the code?) | `cheap` | Mechanical comparison with a human reading the result before anything changes. |
| Commit-message drafting | `cheap` | Reviewed at the moment it is written, and `git commit --amend` is free. |
| Test-name generation | `cheap` | The test body is written by something else; a bad name is a rename. |
| Release-note and changelog first drafts | `cheap` | Edited before publication by definition. |
| Bulk file classification, dead-code candidate lists | `local` | High volume, cheap verification, and the input is the whole repo. |
| **Code changes** | `frontier` | The output IS the artifact. Nothing downstream re-derives it. |
| **Code review** | `frontier` | A review that misses a defect is indistinguishable from a clean review. That is the single worst failure shape in this whole table. |
| **Integrations and API contracts** | `frontier` | Wire-shape mistakes surface in production, at a different layer, weeks later. |
| **Anything touching money** | `frontier` | Billing, Stripe, entitlements, spend caps. |
| **Anything touching auth** | `frontier` | Sessions, tokens, RLS, permission checks. |
| **Anything touching health data** | `frontier` | Regulated, and the blast radius is a person rather than a build. |
| **Migrations and backfills** | `frontier` | Often irreversible, and always against real rows. |
| Bounded frontier work: one-file refactors, a single well-specified fix, a focused review of a small diff | `frontier-light` | Same grade of judgment, smaller job. This is the default for frontier work that fits in one head. |

Two rules keep the table honest:

1. **When it is genuinely unclear which side something falls on, it is
   frontier.** The cheap classes exist to absorb volume, not to win arguments.
2. **Fallbacks never cross down.** `frontier` degrades to `frontier-light` and
   no further. `cheap` and `local` degrade into each other. A `frontier`
   request with no working Anthropic key returns an error; it does not return a
   flash model's opinion about a migration with the word "frontier" in the
   response envelope.

Fallbacks are declared per class in `gateway/classes.manifest` and pruned at
start time: a fallback naming a class that is not running is dropped, because
turning a clean upstream error into a routing error helps nobody.

## Adding or changing a model

To **repoint a class** (a model deprecates, a better one ships): edit that one
file, e.g. `gateway/classes/cheap.yaml`, and restart. Models are pinned by
explicit version rather than a `-latest` alias so the swap is a commit someone
reviewed. `gemini-2.5-flash` disappeared for new users mid-2026 with a 404 that
named its replacement; a pinned version turns that into one legible failure
instead of a silent quality change.

To **add a class**:

1. `gateway/classes/<name>.yaml` — the `model_list` fragment, indented two
   spaces (it is appended under `model_list:`).
2. A row in `gateway/classes.manifest`:
   `name|REQUIRED_ENV_KEYS|fallback,classes|probe-url`
   Leave the keys field empty for a class needing no credential; leave the probe
   empty for anything that is not a local server.
3. A row in the routing table above, with the reason. A class nobody can argue
   with is a class nobody will use correctly.
4. `bin/gateway-up.sh --dry-run` to confirm it composes.

Keys come from `~/.config/secrets/*.env`, which `gateway-up.sh` sources. Nothing
is read from the repo and nothing is written back to it.

## Budget knobs

This exercise started with a $1,000 surprise bill, so the defaults are small
enough that hitting one is an inconvenience.

**Without a database** (the default here):

- `gateway/config.yaml` → `litellm_settings.max_budget: 25` and
  `budget_duration: 30d`. A process-global cap in USD. Raise it by editing that
  file and restarting.
- It is **in-memory**: it resets when the proxy restarts, and it is global
  rather than per-key. Treat it as a circuit breaker against a runaway loop,
  not as accounting.
- `/spend/logs` and `/key/info` return HTTP 500 with
  `Database not connected`. That is expected, not a fault.

**With a database**, LiteLLM's virtual-key store unlocks per-key spend caps that
survive a restart, plus real spend reporting. Set `DATABASE_URL` to a Postgres
URL before `bin/gateway-up.sh`, then mint one key per caller with
`POST /key/generate` and a `max_budget`. Worth doing once more than one thing
calls the gateway; not worth standing up Postgres for a single caller.

Provider-side caps are the real backstop and are set in each vendor's console,
not here. A proxy-side cap protects against a loop in our code; it does not
protect against a key leaking.

## Local class

`local` expects Ollama on `127.0.0.1:11434` with the model pulled. Neither is
installed on this box today, which is why every start here waives it:

```bash
curl -fsSL https://ollama.com/install.sh | sh    # userspace, no root needed for the run
ollama serve &                                    # or the systemd unit, if the box has one
ollama pull qwen2.5-coder:7b
```

Until then `bin/gateway-status.sh` reports `local: no server answering at
http://127.0.0.1:11434/api/tags`, and `bin/gateway-up.sh` refuses to start
until someone passes `--allow-missing local`. The config tolerates its absence;
it does not hide it.

---

# Part 2: subscription accounts

Three Claude Pro accounts, 4+ agents per machine, three machines. A weekly limit
hit mid-flight and killed six agents mid-edit, with no warning.

**There is no API that reports remaining subscription quota.** The only
authoritative signal is the limit error, which names its reset time and arrives
by killing whatever was running. So this is a ledger of observations, and it is
exactly as good as the discipline of writing them down.

## The ledger

`bin/claude-accounts.sh`, backed by `~/.claude/claude-accounts.json` (`0600`,
outside git, per machine — `CLAUDE_ACCOUNTS_FILE` moves it).

```bash
bin/claude-accounts.sh init                         # seed three placeholders
bin/claude-accounts.sh add work-a --email a@x.com --note "main"
bin/claude-accounts.sh rm account-a                 # drop a placeholder

bin/claude-accounts.sh claim work-a                 # this machine/session is on it
bin/claude-accounts.sh release work-a

# The moment a session dies on a limit, record what the error said:
bin/claude-accounts.sh limit work-a --window weekly --until "Sunday 18:00"
bin/claude-accounts.sh limit work-b --window 5h --until "+4 hours"
bin/claude-accounts.sh clear work-a                 # it came back early

bin/claude-accounts.sh list                         # table: state, holder, note
bin/claude-accounts.sh suggest                      # which account to switch to
bin/claude-accounts.sh report                       # one line, or nothing
```

`--until` takes anything GNU `date` understands: an ISO stamp, `"Sunday 18:00"`,
`"+4 hours"`. It is stored as UTC. A limit with no reset time is refused,
because guessing at one is the thing this replaces.

An **expired** window reads as clear automatically. Nobody has to remember to
clear it, which matters: a stale entry that still says "limited" is how a
warning banner trains everyone to ignore it.

`suggest` prefers an account with no known limit that nobody is on, then one
with no known limit that someone else holds (two sessions on one account share
its quota, so it says so), and only then names the one that frees up soonest.

Switching is manual, in the session: `/login`, pick the account, carry on. There
is nothing to automate there and nothing here pretends otherwise.

## The session-start report

`hooks/claude-accounts-report.sh` runs on `SessionStart` and prints the ledger
state into the session's context:

```
Claude subscription accounts: work-a is limited until Sun 18:00Z (2d);
work-b, work-c are clear.
```

It is **silent when nothing is limited**. A banner on every session is a banner
that gets ignored and then disabled. It is one `python3` run against a small
local JSON file: no network, no git, tens of milliseconds. It always exits 0 —
a missing ledger, a corrupt one, or no `python3` leaves the session alone.

When every account is limited it says so explicitly and names the soonest reset,
because that is the one case where the right move is to stop dispatching agents
rather than to switch.

---

## Failure modes

| Symptom | What it is | What to do |
|---|---|---|
| `gateway-up: refusing to start — these classes have no working credential` | Working as designed. A class's key is absent and nobody has waived it. | Fix the credential in `~/.config/secrets/*.env`, or waive the class by name: `--allow-missing <class>`. Do not edit the manifest to make the problem disappear. |
| `Invalid model name passed in model=frontier` (HTTP 400) | The class is not in the running config, because it was waived at start. | `bin/gateway-status.sh` names the blocker. This is the intended shape of a missing key: a loud 400, never a cheaper model answering in its place. |
| `gateway-up: something is already serving ... and it is not ours` | Another process holds the port. Several agent sessions share this box. | `--port <n>`, or find the owner. Never a pattern kill: `pkill litellm` takes out a sibling session's proxy. |
| `gateway: process alive but not answering /health/readiness` | The proxy started and then wedged, usually on a bad config or an upstream hang. | `tail ~/.claude/gateway/gateway.log`. Then `bin/gateway-down.sh` and start again. |
| `NotFoundError ... is no longer available to new users` | A pinned model was retired. The error names its replacement. | Edit that one `gateway/classes/<class>.yaml`, restart, commit. |
| `local: no server answering at http://127.0.0.1:11434/api/tags` | Ollama is not running or not installed. | See **Local class** above, or run with `--allow-missing local`. |
| `/spend/logs` returns 500 `Database not connected` | Expected without `DATABASE_URL`. | See **Budget knobs**. The in-memory cap is still enforced. |
| A session dies mid-edit on a usage limit | The thing this whole second half exists for. | `bin/claude-accounts.sh limit <label> --until "<what the error said>"`, then `suggest`, then `/login` to that account. Record it before restarting, or the next session learns nothing. |
| Every account limited | No capacity anywhere. | `suggest` names the soonest reset. Stop dispatching agents until then; a dispatched agent will die mid-edit and lose its work. |
| The session-start banner says nothing | Correct when no account has a live limit window. | To check the ledger is actually wired up: `bin/claude-accounts.sh list`. |
