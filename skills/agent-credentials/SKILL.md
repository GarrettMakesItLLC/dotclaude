---
name: agent-credentials
description: Use when an agent in a product repo needs a credential, a database URL, or a CLI that seems missing — before concluding "I can't". Covers what is already in the shell, how Railway- and Vercel-held values are fetched, which CLIs are absent and what replaces them, and where the repo's own key list lives.
---

# Agent credentials

**You have more access than you assume. Check here before concluding "I can't."** "The key isn't set" almost always means *fetch it*, not *it does not exist*.

The repo's own key list — which keys it exports, under which prefix, which live only on Railway or Vercel, and any repo-specific trap — is its appendix, **`.claude/credentials.md`** in the repo root. Read it after this file. Its shape: [`references/appendix-template.md`](references/appendix-template.md).

The mechanics below are shared by every product repo: the scripts are dotclaude's (`~/.claude/bin/`), and the repo's `.claude/repo.json` holds its values (`~/dotclaude/docs/repo-manifest.md`).

## 1. What is already in your shell

Every agent shell sources, from `~/.bashrc`:

| File | Built by | Holds |
|---|---|---|
| `<stateDir>/agent.env` (e.g. `~/.musclebuddy/agent.env`) | `~/.claude/bin/agent-env-build.sh`, every session start | the repo's app keys read from its local `.env` files (and Railway, for keys the manifest names), bare and/or `<PREFIX>_`-aliased; database URLs **namespaced only** |
| `<stateDir>/ops.env` | `~/.claude/bin/ops-pull.sh`, at most every 12 h | the repo's Vercel `OPS_*` channel, prefix stripped — keys an agent needs that the app does not |
| `~/.config/secrets/*.env` | by hand, per machine | machine-wide tokens: `NODE_AUTH_TOKEN` (GitHub Packages PAT, `gmi.env`), `SUPABASE_ACCESS_TOKEN` (Supabase Management PAT), `GITHUB_TOKEN` |

`<stateDir>/cloud.env` is also written by `ops-pull.sh` but is **never sourced**: it can hold a production connection string, and `agent-env-build.sh` is its only reader.

Check what you actually have — **names only**. A secrets file is never `cat`-ed (`secret-read-guard.sh` blocks it):

```bash
env | grep -oE '^<PREFIX>_[A-Z0-9_]+=' | sort                  # the repo's prefixed names in this shell
grep -oE '^(export )?[A-Za-z_][A-Za-z0-9_]*=' <stateDir>/agent.env  # what the bundle carries
```

An empty value means the shell predates the build. Rebuild and start a new shell: `~/.claude/bin/agent-env-build.sh` (after `~/.claude/bin/ops-pull.sh` if the key rides the OPS channel). The builder prints what it emitted, what came from Railway, and what is absent — **that output is the authority**, not any list in a doc.

### Read the prefixed name, never the bare one

`~/.bashrc` sources several repos' bundles and the last export of a bare name wins. A bare `SUPABASE_URL` can belong to another product's project, and it fails silently: it answers with that project's schema. The `<PREFIX>_` alias is this repo's value or nothing — `agent-env-build.sh` `unset`s it when the key is absent here.

A native or bundled build is worse-exposed: Vite lets an already-set `process.env` value win over the app's `.env`, so a build baked in another product's `VITE_SUPABASE_URL` ships a binary talking to the wrong project, and sign-in fails with a generic "Invalid login credentials". Unset the bare `VITE_*` names before a build, or build from a guard that checks the resolved project ref.

### Database URLs are namespaced, and you opt in per command

`dotenv` never overrides an already-set variable, so a bare `DATABASE_URL` in a shell pins every seed, backfill and migration on the machine to it. The bundle exports `<PREFIX>_…DATABASE_URL` only:

```bash
DATABASE_URL="$MB_PROD_DATABASE_URL" npx prisma migrate status
```

The appendix says what each points at — often a live production database, with no separate local one.

## 2. Railway and Vercel

**Railway** holds the deployed server's environment.

- The **Railway MCP redacts every value** (it authenticates as an OAuth app). Use it for names, ids, logs and service config — a "set" variable is never evidence of its value.
- A **project token** (`RAILWAY_TOKEN`) is valid against Railway's GraphQL API but rejected by the `railway` CLI, which insists on a user-scoped `me` query first. `~/.claude/bin/lib/railway.sh` (`railway_kv <service> <env> <project-id>`) uses the API with a project token, else the CLI's interactive login.
- On the CLI route, strip every token variable: `env -u RAILWAY_TOKEN -u RAILWAY_API_TOKEN -u BASH_ENV sh -c 'railway variables --service <svc> --environment production --kv'`. A bare token overrides the interactive login, and a stale one denies everything while blaming permissions. `sh -c`, not `bash -c`: `BASH_ENV` would re-source the profile and restore the token.
- Never print a value, never write one to a file that outlives the command, and prefer `DIRECT_URL` over the pooled `DATABASE_URL` for `psql` (strip the `?pgbouncer=…` query either way).

**Vercel** holds the frontend's environment and the OPS channel.

- `vercel` is often off `PATH`; `npx vercel …` reuses the existing login. `~/.claude/bin/lib/vercel.sh` resolves it.
- A **sensitive** variable cannot be read back: `vercel env pull` writes the literal `[SENSITIVE]`, eleven characters that authenticate as garbage. `ops-pull.sh` drops such a line and fails naming it.

**How an agent-only secret is provisioned**, in this order:

1. **Vercel, `OPS_`-prefixed, `--no-sensitive`** — `vercel env add OPS_MY_KEY production --no-sensitive` (and preview, development). `ops-pull.sh` lands it in `ops.env` on every machine. This is the route for anything an agent needs that the app does not. Never name one `OPS_RAILWAY_TOKEN`/`OPS_VERCEL_TOKEN` — a bare export shadows the CLI login; `ops-pull.sh` refuses it.
2. **Railway** — only for a key the deployed server reads.
3. **The vendor dashboard** — only the owner can reach it.

**A credential that lives only on the machine that minted it is not provisioned.** A key in one box's `~/.config/secrets/` reads, from every other box, exactly like a key that exists nowhere. Put it on the channel the day it is minted, then prove the round trip — `ops-pull.sh`, then compare — rather than trusting the write.

**A key only the owner can mint** (an AI Studio key, a store API key) is one irreducible owner step, then one command: a script that reads the key from a prompt or stdin (never an argument — shell history keeps it), authenticates it against the vendor BEFORE storing it, writes it to the channel, pulls, and compares. A key that is wrong must fail at the first step, not three steps later inside a render.

**A file-shaped secret** (a signing key, an env bundle) rides the channel base64-encoded as `OPS_<NAME>_B64` and is listed in the manifest's `ops.fileSecrets`: `ops-pull.sh` decodes it to a mode-600 file under `<stateDir>` and never exports it. Encode with `base64 -w0 <file> | vercel env add OPS_<NAME>_B64 production --no-sensitive`.

### An MCP whose key is unset fails as if the key were WRONG

`~/.claude.json` gives an MCP its key by interpolation (`"Authorization": "ApiKey ${UPLOAD_POST_API_KEY}"`). Unset, that expands to `ApiKey ` and the API answers `401 Invalid API key format`. **Check the variable before debugging the key**: `env | grep -c '^UPLOAD_POST_API_KEY='`. Zero means the value has to arrive first.

### Supabase

`SUPABASE_ACCESS_TOKEN` is a **Management PAT**, org-wide: it reads any project's API keys, including service-role keys, and provisions resources. Name the project ref explicitly in every Management API call; never infer it from an ambient `SUPABASE_URL`.

`api.supabase.com` **403s the default `Python-urllib/x` User-Agent before it looks at the token** — indistinguishable from a revoked PAT. Send a real User-Agent, or use `curl`.

A staging database URL is **minted, never pasted**: `export STAGING_DATABASE_URL="$(~/.claude/bin/staging-db-url.sh)"` (session pooler, port 5432; the direct host is IPv6-only and the 6543 pooler breaks prepared statements).

## 3. GitHub Packages (`@gmi/*`)

`.npmrc` authenticates with `${NODE_AUTH_TOKEN}`, which must be the **PAT from `~/.config/secrets/gmi.env`** (`ghp_…`, `read:packages`). `gh auth token` (`gho_…`) has no packages scope and the registry answers it 403 — never `export NODE_AUTH_TOKEN=$(gh auth token)`. An EMPTY token is worse than a wrong one: `npm ci` exits 0 having silently omitted every `@gmi/*` package, surfacing later as TS2307 on files nobody touched. `npm-install-guard.sh` refuses an install with an empty or rejected token. Measure the ambient value when debugging a 403: `printenv NODE_AUTH_TOKEN | head -c 4`.

## 4. CLIs that are missing, or present and broken

Prefer the MCP — its availability does not vary by box: Supabase, Railway, Vercel, Prisma, Playwright, Sentry, Stripe, Notion, Upload-Post. **`~/.claude/bin/doctor.sh` (`npm run doctor`) reports which CLIs exist and which are present but NOT RUNNABLE** — ask it rather than trusting a table; a static list declares installed tools absent and routes agents around them.

| Tool | Use | Why |
|---|---|---|
| `railway` | the Railway MCP, or `railway_kv` above | the npm shim can be on `PATH` with its platform binary never fetched (repair: `npm install -g @railway/cli --foreground-scripts`); a bare token shadows the login |
| `vercel` | the Vercel MCP, or `npx vercel …` | often off `PATH` |
| `psql` | the Supabase MCP, or `node` with the repo's `pg` | not everywhere |
| `jq` | `node -e` / `python3 -m json.tool` | not everywhere |
| `docker` | schema-only work (`prisma migrate diff --from-… --to-… --script`); let CI run the DB tests | the daemon is usually down with no sudo |

`corepack` ships with Node: the lockfile is regenerated with `corepack npm@<pin> install`, never `npx npm@<pin>` (corepack picks the version from its own state and silently runs a different npm).

## Red flags

- Concluding a key "isn't available" without checking the shell, the OPS channel and Railway.
- Reading a bare `SUPABASE_URL`/`VITE_SUPABASE_URL` instead of the prefixed alias.
- `export DATABASE_URL=…` for the rest of a session instead of per command.
- `cat`-ing a secrets file, or printing a value to prove it exists.
- A 401 from an MCP debugged as a bad key before checking the variable is set.
- `NODE_AUTH_TOKEN=$(gh auth token)`.
