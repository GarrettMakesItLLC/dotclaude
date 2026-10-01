# Product-repo manifest — `.claude/repo.json`

One JSON file in a product repo that holds the per-repo values dotclaude's
shared scripts read. The behaviour lives once, in `~/dotclaude/bin/`; a repo
carries only what differs. A repo with no manifest is untouched by all of it.

The file is tracked, so a worktree reads its own branch's copy. `~` at the
start of a path means `$HOME`. Every block is optional; a script that needs a
block the manifest lacks says so and exits non-zero. `REPO_MANIFEST=<path>`
in the environment overrides discovery (the self-tests use it).

## Top level

| Field | Type | Read by | Meaning |
|---|---|---|---|
| `name` | string | all | Display name in generated file headers. |
| `envPrefix` | string, `[A-Z0-9_]` | `agent-env-build.sh`, `ops-pull.sh`, `with-check-lock.sh` | The repo's namespace: `<PREFIX>_` aliases, `<PREFIX>_CHECK_*` knobs, the `<prefix>-verification-stale` drift marker. Never the check-lock files: those are box-wide `check.*` under `${XDG_CACHE_HOME:-~/.cache}/gmi-check-lock`, shared by every repo. |
| `stateDir` | path | `agent-env-build.sh`, `ops-pull.sh`, `setup-worktree.sh`, `doctor.sh`, `npm-install-guard.sh` | Per-machine home for `agent.env`, `ops.env`, `cloud.env` and file secrets, e.g. `~/.musclebuddy`. |

## `credentials` — `bin/agent-env-build.sh`

| Field | Type | Meaning |
|---|---|---|
| `sources` | paths | `.env` files relative to the MAIN checkout (or absolute / `~/`), highest priority first. `<stateDir>/cloud.env` is always appended last. |
| `direct` | keys | Exported under their real names. |
| `aliasDirect` | bool | Also export each direct key as `<envPrefix>_<KEY>`, and `unset` the alias of a key not found. |
| `namespaced` | `{ "EXPORTED": "SOURCE_KEY" }` | Exported ONLY under the namespaced name — database URLs. |
| `machineWide` | keys | May fall back to the ambient shell (per-machine tokens such as `NODE_AUTH_TOKEN`). |
| `githubToken` | bool | Export `GITHUB_TOKEN` from `gh auth token`. |
| `railway.service` | string | Railway service holding the deployed server's env. Also used by `ops.railwayKeys`. |
| `railway.environment` | string | Default `production`. |
| `railway.projectId` | string | Enables the GraphQL route with a project `RAILWAY_TOKEN`; without it only the CLI's login is used. |
| `railway.fallback` | keys | Source keys read from Railway when no local source defines them. Fetched once, only when one is missing. |

## `ops` — `bin/ops-pull.sh`

| Field | Type | Meaning |
|---|---|---|
| `vercelEnvironment` | string | Environment pulled; default `production`. The first argument overrides it. |
| `channel` | bool | Pull the `OPS_*` channel into `<stateDir>/ops.env`, sourced from `~/.bashrc`. |
| `unsetAlways` | keys | Refused on the channel and `unset` in `ops.env`, so an inherited export dies too. |
| `fileSecrets` | list of name or `{ name, path?, mustContain? }` | `OPS_<name>` values that are files: never exported; with `path`, base64-decoded to `<stateDir>/<path>` (mode 600). `{VAR}` in `path` is filled from `OPS_VAR`. A decoded file lacking `mustContain` is deleted. |
| `vercelKeys` | keys | Plain Vercel variables written to `<stateDir>/cloud.env` (never sourced). |
| `railwayKeys` | `{ "RAILWAY_NAME": "WRITTEN_NAME" }` | Railway variables (service from `credentials.railway`) written to `cloud.env` under the mapped name. `RAILWAY_SERVICE`/`RAILWAY_ENV` in the environment override the service and environment. |

## `worktree` — `bin/setup-worktree.sh`

| Field | Type | Meaning |
|---|---|---|
| `strategy` | `install` \| `mirror` | `install`: run `install` in the worktree. `mirror`: no install; copy nested workspace deps from the main checkout and resolve the rest upward. Default `install`. |
| `envFiles` | paths | Copied from the main checkout when absent. Never the root `.env`. |
| `install` | command | `install` strategy; run under `with-check-lock.sh --writer`. Default `npm ci`. |
| `requireScopes` | scopes | Package scopes that must exist in `node_modules` after install (an auth-gated scope npm can silently omit). |
| `workspaceDirs` | dirs | Where workspace packages live. Default `["apps", "packages"]`. |
| `workspaceScope` | scope | `mirror`: link `node_modules/<scope>/*` to THIS worktree's packages. `install`: the link farm cleared before install. |
| `linkRootBin` | bool | `mirror`: per-binary links for the main checkout's `node_modules/.bin`. |
| `lockWorktree` | string | `git worktree lock` reason, so generic sweeps cannot remove a live tree. |
| `prismaGenerate` | command | Run after dependencies, e.g. `npx prisma generate`. |
| `graphify` | bool | Build `graphify-out/` best-effort. |
| `postSteps` | commands | Run last, in the worktree, with the step environment below exported. |
| `checkSteps` | commands | Run by `--check`, with the same environment. |

The step environment, for a repo's own mirror step (MuscleBuddy's
`bin/worktree-tailwind-sources.sh`):

| Variable | Meaning |
|---|---|
| `WORKTREE`, `MAIN_TREE` | The worktree and the main checkout. |
| `SETUP_WORKTREE_STALE` | `1` when the main tree's install moved since the last copy. Read before this run's copy, so a step can refresh its own copy too. |
| `SETUP_WORKTREE_COPIED_STAMP` | Non-empty when this bootstrap had already copied into the worktree before this run. A step judges completeness only for copies it made; an unstamped tree is the branch's own install. |
| `SETUP_WORKTREE_EXEMPT` | Packages the branch's lockfile moved, one per line, or `ALL` when the lockfiles cannot be compared. The main tree's copy is the wrong one for those. |
| `SETUP_WORKTREE_LOCK` | The check-lock wrapper. Read the main tree's `node_modules` under `--light --no-drift`. |

The `mirror` copy stamp lives in the worktree's git dir as
`<envprefix>-nested-deps-stamp` (`nested-deps-stamp` without an `envPrefix`).
`<PREFIX>_SETUP_WORKTREE_STABLE_SECS` or `SETUP_WORKTREE_STABLE_SECS` (default 300)
sets how long a source must be quiet before a copy that timed out on the lock retries unlocked.

## `supabase` — `bin/staging-db-url.sh`

| Field | Type | Meaning |
|---|---|---|
| `projectName` | string | The Supabase project, resolved by name. |
| `stagingBranch` | string | Its staging branch; default `staging`. |

## `doctor` — `bin/doctor.sh`

| Field | Type | Meaning |
|---|---|---|
| `resolves` | module | A module the root must resolve, proving dependencies are installed. |
| `nestedDeps` | `workspace:module` | Modules each workspace must resolve (npm nests some). |
| `prismaClient` | paths | Any existing path proves a generated client. Default `node_modules/.prisma/client/index.d.ts`. |
| `envFiles` | `[{ path, fix }]` | Env files to report, each with the command that produces it. |
| `checks` | `[{ name, run, fix, severity }]` | Repo checks run with `sh` in the repo root; `severity` `block` (default) or `warn`. |

## Example — a mirror-strategy repo with the OPS channel

MuscleBuddy's manifest, verbatim.

```json
{
  "name": "MuscleBuddy",
  "envPrefix": "MB",
  "stateDir": "~/.musclebuddy",
  "credentials": {
    "sources": ["apps/server/.env.local", "apps/server/.env", ".env"],
    "direct": [
      "SUPABASE_URL",
      "SUPABASE_ANON_KEY",
      "SUPABASE_SERVICE_KEY",
      "VAPID_PUBLIC_KEY",
      "VAPID_PRIVATE_KEY",
      "ANTHROPIC_API_KEY",
      "STRIPE_SECRET_KEY",
      "STRIPE_WEBHOOK_SECRET",
      "STRIPE_PRO_PRICE_ID",
      "STRIPE_COACH_PRICE_ID",
      "GOOGLE_PLACES_API_KEY",
      "RESEND_API_KEY",
      "FDC_API_KEY"
    ],
    "aliasDirect": true,
    "namespaced": {
      "MB_PROD_DATABASE_URL": "DATABASE_URL",
      "MB_PROD_DIRECT_URL": "DIRECT_URL"
    },
    "githubToken": true,
    "railway": {
      "service": "@musclebuddy/server",
      "environment": "production",
      "fallback": [
        "SUPABASE_URL",
        "SUPABASE_ANON_KEY",
        "SUPABASE_SERVICE_KEY",
        "VAPID_PUBLIC_KEY",
        "VAPID_PRIVATE_KEY",
        "DATABASE_URL",
        "DIRECT_URL"
      ]
    }
  },
  "ops": {
    "channel": true,
    "unsetAlways": [
      "RAILWAY_TOKEN",
      "RAILWAY_API_TOKEN",
      "MB_RAILWAY_TOKEN",
      "MB_RAILWAY_API_TOKEN"
    ],
    "fileSecrets": [
      "SERVER_ENV_LOCAL_B64",
      {
        "name": "ASC_API_KEY_P8_B64",
        "path": "signing/AuthKey_{ASC_KEY_ID}.p8",
        "mustContain": "BEGIN PRIVATE KEY"
      }
    ]
  },
  "worktree": {
    "strategy": "mirror",
    "envFiles": ["apps/web/.env.local", "apps/server/.env.local"],
    "linkRootBin": true,
    "lockWorktree": "agent session worktree — remove via bin/worktree-reap.sh (#4238)",
    "prismaGenerate": "bin/prisma-client-fresh.sh",
    "postSteps": ["bin/worktree-tailwind-sources.sh"],
    "checkSteps": ["bin/worktree-tailwind-sources.sh --check"]
  },
  "supabase": {
    "projectName": "MuscleBuddy",
    "stagingBranch": "staging"
  },
  "doctor": {
    "resolves": "vitest",
    "nestedDeps": ["apps/web:lucide-react", "apps/server:fastify", "packages/engine:zod"],
    "prismaClient": ["prisma/generated/client/client.ts", "prisma/generated/client/index.js"],
    "envFiles": [
      {
        "path": ".env",
        "fix": "~/.claude/bin/agent-env-build.sh reads the DB and Supabase values from Railway; .env.example lists the rest"
      },
      {
        "path": "apps/web/.env.local",
        "fix": "npx vercel env pull apps/web/.env.local"
      },
      {
        "path": "apps/server/.env.local",
        "fix": "bin/server-env-sync.sh pull"
      },
      {
        "path": ".env.test",
        "fix": "bin/e2e-env.sh (mints the E2E sandbox from the Supabase PAT; e2e cannot provision its fixtures without it)"
      }
    ],
    "checks": [
      {
        "name": "npm is the pinned one, not a hoisted package's bin",
        "run": "case \"$(command -v npm)\" in */node_modules/.bin/npm) exit 1 ;; esac",
        "fix": "npm run unshadow-npm",
        "severity": "warn"
      },
      {
        "name": "a Playwright browser is installed",
        "run": "ls -d \"$HOME\"/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell >/dev/null 2>&1",
        "fix": "npx playwright install chromium (e2e cannot run without it)",
        "severity": "warn"
      },
      {
        "name": "the Playwright browser starts (system libraries present)",
        "run": "b=$(ls -d \"$HOME\"/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell 2>/dev/null | tail -1); [ -z \"$b\" ] || \"$b\" --version",
        "fix": "export LD_LIBRARY_PATH=$HOME/.local/lib/wsl-playwright-libs:$HOME/.local/pwlibs/usr/lib/x86_64-linux-gnu",
        "severity": "warn"
      }
    ]
  }
}
```

## Example — a repo whose secrets live only in the cloud

```json
{
  "name": "NetWorthy",
  "envPrefix": "NW",
  "stateDir": "~/.networthy",
  "credentials": {
    "sources": ["apps/web/.env.local", "apps/server/.env.local", ".env.local"],
    "direct": ["VITE_SUPABASE_URL", "VITE_SUPABASE_ANON_KEY", "SUPABASE_URL", "GMI_PACKAGES_TOKEN"],
    "namespaced": { "NW_DATABASE_URL": "DATABASE_URL" },
    "railway": { "service": "server-v2", "environment": "production", "projectId": "<railway-project-id>" }
  },
  "ops": {
    "vercelEnvironment": "development",
    "vercelKeys": ["VITE_SUPABASE_URL", "VITE_SUPABASE_ANON_KEY"],
    "railwayKeys": { "DATABASE_URL": "DATABASE_URL", "SUPABASE_URL": "SUPABASE_URL", "NODE_AUTH_TOKEN": "GMI_PACKAGES_TOKEN" }
  },
  "worktree": { "strategy": "mirror", "envFiles": ["apps/web/.env.local", "apps/server/.env.local"], "workspaceScope": "@networthy" }
}
```
