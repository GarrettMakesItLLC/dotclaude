# Degraded registry: installing `@gmi/*` while GitHub Packages refuses downloads

When GitHub Packages hits the org's billing limit, it still answers metadata reads (200) but refuses
every tarball download and every publish with `403 Account has reached its billing limit`.
`npm ci` then fails for any `@garrettmakesitllc/*` version that is not already in the local npm cache.
`--offline` installs and substituted versions do not fix this. The fix is a local mirror, and one
line switches npm onto it.

```bash
bin/degraded-registry.sh on      # start the mirror, route npm to it
bin/degraded-registry.sh off     # back to GitHub Packages, mirror stopped
bin/degraded-registry.sh status  # which mode npm is in
```

While it is on, the SessionStart banner says so in every session, in normal and degraded fleet
mode alike (`hooks/fleet-mode-report.sh`). Asking for the banner also restarts a mirror that a reboot
killed.

## How the switch works

Every consumer repo commits `@garrettmakesitllc:registry=https://npm.pkg.github.com` in its own
`.npmrc`. A project `.npmrc` outranks `~/.npmrc`, so the scope cannot be re-pointed from the user
level, and a `npm_config_@…` environment variable cannot be exported from a shell profile. The
switch does not touch the scope. `npm ci` fetches each tarball from the lockfile's `resolved` URL,
and npm's `replace-registry-host` rewrites a named host to the **default** registry, which no repo
sets. So `on` writes this managed block to `~/.npmrc`, and `off` removes exactly that block:

```ini
registry=http://127.0.0.1:4873/
replace-registry-host=npm.pkg.github.com
//127.0.0.1:4873/:_authToken=degraded-local   # placeholder; `npm publish` wants a credential
```

The mirror (`bin/lib/gmi-registry-server.mjs`, Node, no dependencies, bound to 127.0.0.1) does
three things:

- It answers GitHub's own download path, `/download/@garrettmakesitllc/<name>/<version>/<sha1>`, but
  only when the stored tarball's sha1 matches the URL. That trailing hash is GitHub's sha1 of the
  tarball, so a lockfile URL identifies exact bytes.
- It answers packuments for the scope, with `dist.tarball` in GitHub's URL form. A lockfile written
  in degraded mode is therefore byte-identical to one written in normal mode.
- It sends everything else to `registry.npmjs.org` with a 307. Tarballs pinned at npmjs are not
  rewritten (only `npm.pkg.github.com` is), so they never pass through the mirror at all.

No repo has a committed change, and nothing in CI, Vercel or Railway is affected, because only this
box's `~/.npmrc` changes. With the switch on, `npm ci` needs no `NODE_AUTH_TOKEN`, and
`hooks/npm-install-guard.sh` stops demanding one for `npm ci`. Lockfile writers still read the
scope's packuments from GitHub, so for them the guard still checks the token.

## The store, and how it gets populated

The store is a git checkout at `~/.local/share/gmi-registry` holding
`packages/<name>/<name>-<version>.tgz` and nothing else. Packuments are derived from the tarballs on
each request, so adding a file is the whole publish, and a `git pull` is live without a restart.

```bash
bin/degraded-registry.sh pins                 # every @gmi/* pin across ~/workspace
bin/degraded-registry.sh populate             # fill the store from npm caches
bin/degraded-registry.sh populate --rebuild   # ...then rebuild what is still missing from platform tags
bin/degraded-registry.sh verify [LOCKFILE]    # exit 1 unless the mirror serves every pin
```

Pins are read from every git repo under `~/workspace`, one level of grouping dirs deep (`Tools/`), at
three refs: the working tree, `origin/dev` and `origin/main`. Fresh worktrees are cut from the remote
refs, so the mirror has to cover them too. When two checkouts share a remote, only the one with the
newest `origin/main` counts. A second clone parked on an old branch would otherwise drag in every
version its stale refs ever pinned. Pass its lockfile with `--lockfile` if it really is needed.

Sources, in order:

1. **An npm cache.** cacache stores content under the sha512 that the lockfile already names, so a
   hit is the exact published bytes. `~/.npm/_cacache`, `/tmp/npm-cache/_cacache` (the `cache=`
   RedThreadEvents and SideQuest set), `npm config get cache`, plus `--cache DIR` and
   `GMI_REGISTRY_CACHES`. Read-only: populate never writes to or cleans a cache.
2. **A rebuild from platform** (`--rebuild`), at the release tag `@gmi/<name>@<version>`. It runs
   in a throwaway platform worktree with `npm ci` (through the mirror), `npm run build`, and
   `npm pack`. **The result is kept only if its integrity equals the lockfile's.** A rebuild that
   differs is left in `~/.local/state/gmi-registry/mismatch/` and reported. It is never served:
   serving it would let a regenerated lockfile pin bytes that GitHub Packages does not hold, and
   that lockfile would break the day billing comes back.

A version that nothing on the box has and that cannot be rebuilt byte-for-byte is reported as
`MISSING`/`MISMATCH` together with the lockfiles that pin it. The fix belongs in those repos: move
the pin to a version the mirror holds, through a normal PR. Do not regenerate the lockfile against
rebuilt bytes.

## Publishing a new version in degraded mode

Platform's release workflow cannot publish, and neither can a local `npm publish`. Take
`@garrettmakesitllc/analytics@2.4.0` from platform PR #1233 as the example:

```bash
# in a platform worktree at the merged commit
npm ci && npm run build
~/.claude/bin/degraded-registry.sh publish packages/analytics   # npm pack + add to the store
~/.claude/bin/degraded-registry.sh sync                         # share it with the other machine
```

`publish` refuses to overwrite a version with different bytes, because a published version is
immutable. A consumer then installs it as usual. The one difference is that the scope's packument
has to come from the mirror, because GitHub's metadata does not list the version yet:

```bash
corepack npm@10.8.2 install '@gmi/analytics@npm:@garrettmakesitllc/analytics@2.4.0' \
  --@garrettmakesitllc:registry=http://127.0.0.1:4873/
```

The lockfile records GitHub's URL form, `.../analytics/2.4.0/<sha1>`, exactly as normal mode
would. Once billing is restored, publish **the same tarball file** from the store
(`npm publish ~/.local/share/gmi-registry/packages/analytics/analytics-2.4.0.tgz`) and do not
rebuild it. GitHub then holds those bytes under that URL, and every lockfile written in the
meantime keeps working.

## The other machine

The store is shared through a private git repo, `GarrettMakesItLLC/gmi-registry-store`
(`GMI_REGISTRY_REMOTE` overrides it). Plain git is unaffected by the Packages billing stop, needs no
credential beyond the `gh` login both machines already have, and versions every publish.
Tarballs are shared rather than rebuilt per machine because rebuilds rarely reproduce the original
bytes.

```bash
~/.claude/bin/degraded-registry.sh sync   # first run clones the store; later runs commit, pull --rebase, push
~/.claude/bin/degraded-registry.sh on
```

`on` clones the store by itself on a machine that has none. Run `sync` after every `publish` and
`populate`, on whichever machine did it.

## Leaving degraded mode

When GitHub Packages serves downloads again:

1. Publish every tarball the store holds that GitHub lacks, **from the stored files**.
2. `bin/degraded-registry.sh off` on each machine.

Nothing else changes, because no repo has a committed change to revert.

## Files

| Path | What |
|---|---|
| `bin/degraded-registry.sh` | The CLI: switch, lifecycle, populate/verify, publish, sync, banner |
| `bin/lib/gmi-registry-server.mjs` | The mirror |
| `bin/lib/degraded-registry-populate.mjs` | Pin discovery, cache lookup, platform rebuilds |
| `~/.local/share/gmi-registry/` | The store (`GMI_REGISTRY_HOME`) |
| `~/.local/state/gmi-registry/` | `server.pid`, `server.log`, `mismatch/` (`GMI_REGISTRY_STATE`) |
| `GMI_REGISTRY_PORT` | Default 4873 |
