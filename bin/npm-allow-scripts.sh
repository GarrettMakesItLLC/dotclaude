#!/usr/bin/env bash
# npm-allow-scripts — keep npm's install-scripts policy from stranding the
# packages whose postinstall IS the install.
#
# npm 12 blocks dependency lifecycle scripts unless `allow-scripts` covers
# them. `@railway/cli` ships only a JS shim; its postinstall downloads the
# native binary. The CLI updates itself with a global `npm install`, so a
# blocked postinstall leaves a shim with no binary and every `railway` call on
# the box fails (#549). `esbuild` is blocked the same way and breaks vite and
# vitest. This script makes the user-level policy cover both.
#
# Usage:
#   bin/npm-allow-scripts.sh            # report; exit 1 when the policy lacks an entry
#   bin/npm-allow-scripts.sh --apply    # merge the missing entries into the user config
#
# Existing entries are kept. Silent no-op on an npm that has no `allow-scripts`
# option (npm 10 runs every script, so there is nothing to allow).
set -uo pipefail

REQUIRED=(@railway/cli esbuild)

apply=0
case "${1:-}" in
  --apply) apply=1 ;;
  '') ;;
  *) echo "npm-allow-scripts: unknown option '$1'" >&2; exit 2 ;;
esac

command -v npm >/dev/null 2>&1 || { echo "npm-allow-scripts: npm not installed — nothing to do"; exit 0; }

if ! npm config ls -l 2>/dev/null | grep -q '^allow-scripts'; then
  echo "npm-allow-scripts: this npm has no allow-scripts policy — nothing to do"
  exit 0
fi

current="$(npm config get allow-scripts --location=user 2>/dev/null || true)"
case "$current" in undefined|null) current='' ;; esac

missing=()
for pkg in "${REQUIRED[@]}"; do
  case ",${current}," in
    *",${pkg},"*) ;;
    *) missing+=("$pkg") ;;
  esac
done

if [ "${#missing[@]}" -eq 0 ]; then
  echo "npm-allow-scripts: ok — allow-scripts covers ${REQUIRED[*]}"
  exit 0
fi

merged="$current"
for pkg in "${missing[@]}"; do merged="${merged:+$merged,}$pkg"; done

if [ "$apply" = 0 ]; then
  echo "npm-allow-scripts: allow-scripts does not cover ${missing[*]} — their postinstall is blocked (#549)"
  echo "  fix: bin/npm-allow-scripts.sh --apply   (sets allow-scripts=$merged --location=user)"
  exit 1
fi

if npm config set "allow-scripts=$merged" --location=user; then
  echo "npm-allow-scripts: set allow-scripts=$merged"
else
  echo "npm-allow-scripts: could not write the user npm config" >&2
  exit 1
fi
