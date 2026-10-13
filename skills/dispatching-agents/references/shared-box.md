# One box, many agents

Several sessions share one machine, one npm cache and one pool of memory. These failures come out of that, and none of them look like what they are.

## `Bus error` from vitest is memory, not code

esbuild SIGBUSes when swap is exhausted, even on a trivial `1+1` test immediately after a clean `npm ci`, so it reads as a broken install or a corrupt binary. Check `free -h` first: swap at its limit with a dozen concurrent `tsc`/`eslint` in `ps aux` is the answer. Take the check lock (`~/.claude/bin/with-check-lock.sh`, or the repo's own `bin/with-check-lock.sh` where it still has one) and wait for the queue. Retrying is what keeps swap exhausted. Plain `tsc --noEmit` survives this and eventually finishes, so it is worth running while you wait.

## `ENOENT` on `~/.npm/_cacache/content-v2/...` is another agent's install

Not a corrupt cache. Serialize behind the check lock. Never `npm cache clean --force`: every other running install is reading from it.

## `@gmi/*` needs a working `NODE_AUTH_TOKEN`

The token must be non-empty and able to read `@garrettmakesitllc` packages, whichever credential it came from. Test the property, not the origin: `bin/doctor.sh` does a registry GET for one package and reports pass or fail without printing the token. An empty or revoked token is the worst case: `npm ci` exits 0 having silently omitted every `@gmi/*` package. The tell is some `@gmi/*` imports failing with TS2307 while others resolve in the same run.

When GitHub Packages itself refuses downloads (`403 … billing limit`), no token helps: run `~/.claude/bin/degraded-registry.sh on`, which routes installs to a local mirror (`skills/operating-a-fleet/references/degraded-registry.md`). Never substitute versions or install `--offline` instead.

## `EALLOWREMOTE` is npm 12, not auth

`Fetching packages of type "remote" have been disabled` on a GitHub Packages dependency is npm 12's `allow-remote` default. The pinned `corepack npm@10.8.2` path does not hit it.

## Never `pkill` by pattern

A pattern match (`pkill -f vitest`, `pkill node`) cannot tell whose session started a process. A pattern broad enough to catch your runaway also catches a sibling's build, test run or dev server, and neither side can attribute the kill. Kill by a PID you started and can prove you own (`kill $MY_PID`, or a PID captured from your own `&`/`run_in_background` launch).

## Secrets files and credential output

A secrets file (`~/.config/secrets/*`, `*/agent.env`, `~/.musclebuddy/*.env`, `~/.redthread/*.env`, any other `*.env`) is read name-only or redacted — `grep -oE '^(export )?[A-Za-z_][A-Za-z0-9_]*='` or `sed 's/=.*/=<redacted>/'` — or sourced, never `cat`/`head`/`tail`-ed. A command whose job is to print a credential (`staging-db-url.sh`, `railway variables`, `printenv`, `echo $DATABASE_URL`, `gh auth token`) is captured with `$(…)` or redirected, never left to print. `hooks/secret-read-guard.sh` blocks the reads and bare prints; `hooks/credential-output-guard.sh` redacts and reports any credential that still reaches a Bash result. A prompt saying so is not enough — the hooks are the enforcement (see RedThreadEvents#2419).
