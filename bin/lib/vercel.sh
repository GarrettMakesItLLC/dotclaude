# shellcheck shell=bash
# Resolve a working Vercel CLI invocation into the $VERCEL array. Sourced, never run.
# Call it as "${VERCEL[@]}" env pull ... — never a bare `vercel`.
#
# On an agent box the CLI is often installed (`npm i -g vercel`) with its bin dir
# off PATH, so `command -v vercel` fails while the tool is right there. Tried in
# order: `vercel` on PATH, the npm-global bin, the active node's bin dir, an
# already-cached `npx --no-install vercel`, and last `npx --yes vercel`, which
# fetches it and reuses the existing `vercel login` session.
resolve_vercel() {
  if command -v vercel >/dev/null 2>&1; then
    VERCEL=(vercel)
    return 0
  fi
  local prefix nodebin cand
  prefix="$(npm config get prefix 2>/dev/null || true)"
  nodebin="$(command -v node 2>/dev/null || true)"
  nodebin="${nodebin%/*}"
  for cand in "${prefix:+$prefix/bin/vercel}" "${nodebin:+$nodebin/vercel}"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then
      VERCEL=("$cand")
      return 0
    fi
  done
  command -v npx >/dev/null 2>&1 || return 1
  if npx --no-install vercel --version >/dev/null 2>&1; then
    VERCEL=(npx --no-install vercel)
  else
    # shellcheck disable=SC2034 # read by the scripts that source this file
    VERCEL=(npx --yes vercel)
  fi
  return 0
}
