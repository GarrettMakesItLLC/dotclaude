#!/usr/bin/env bash
# Assemble <stateDir>/agent.env — the credentials a product repo's agent shells see.
#
#   ~/.claude/bin/agent-env-build.sh          # run from anywhere in the repo
#
# Agents run ad-hoc CLI (a curl, a `tsx` script, a psql one-liner), and an app's
# secrets live in `.env` files only the app's own dotenv loader reads — so a
# plain shell sees none of them, and agents conclude "I can't" when they simply
# could not SEE the key. This file is sourced from ~/.bashrc, so every shell and
# every worktree inherits it with no per-worktree setup. It is regenerated from
# its sources, never hand-edited, never committed. Re-run after any `.env` edit;
# the SessionStart hook `agent-creds-sync.sh` runs it every session.
#
# Everything it reads comes from the repo's `.claude/repo.json`
# (docs/repo-manifest.md), `credentials` block:
#
#   sources      .env files, relative to the MAIN checkout (a worktree holds only
#                what setup-worktree copied), highest priority first. The repo's
#                <stateDir>/cloud.env from ops-pull.sh is always appended last.
#   direct       keys exported under their real names, so an app script reading
#                process.env works from a shell too.
#   aliasDirect  also export each direct key as <envPrefix>_<KEY>, and `unset`
#                the alias of any key not found. A bare name is a shared
#                namespace: ~/.bashrc sources several repos' bundles and the last
#                one wins, so a bare SUPABASE_URL can answer with another
#                product's project. The alias is this repo's value or nothing.
#   namespaced   { "<EXPORTED_NAME>": "<SOURCE_KEY>" } — exported ONLY under the
#                namespaced name. For database URLs above all: dotenv never
#                overrides an already-set variable, so a bare DATABASE_URL in a
#                shell silently pins every dotenv-based script on the machine to
#                this repo's database. Opt in per command:
#                    export DATABASE_URL=$<EXPORTED_NAME>
#   machineWide  keys that are per-machine rather than per-repo (NODE_AUTH_TOKEN
#                from ~/.config/secrets/gmi.env), so falling back to the ambient
#                shell is correct. Never widened to other keys: a repo-shaped
#                name in the ambient shell is probably another project's value.
#   githubToken  true: export GITHUB_TOKEN from `gh auth token`. This never
#                writes NODE_AUTH_TOKEN; that is a separate credential that
#                doctor.sh verifies against the registry.
#   railway      { service, environment, projectId?, fallback: [keys] } — a key
#                in `fallback` missing from every local source is read from that
#                Railway service (bin/lib/railway.sh: GraphQL with a project
#                token, else the CLI's interactive login). Fetched once, and only
#                when something is missing, so a machine with a complete `.env`
#                builds offline.
#
# Empty keys are skipped, never exported as "". The run prints what it emitted,
# what came from Railway, and what is absent — that output is the authority on
# what a shell has, not any doc.
#
# Idempotent. chmod 600.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=bin/lib/repo-manifest.sh
. "$HERE/lib/repo-manifest.sh"
# shellcheck source=bin/lib/railway.sh
. "$HERE/lib/railway.sh"

die() { echo "agent-env-build: $*" >&2; exit 1; }

manifest_find >/dev/null || die "no .claude/repo.json governs $PWD — this repo has not opted in (docs/repo-manifest.md)."
REPO_ROOT="$(main_tree_of "$PWD")" || die "not inside a git repository"
cd "$REPO_ROOT"

name="$(manifest_get name || basename "$REPO_ROOT")"
prefix="$(manifest_get envPrefix || true)"
state_dir_raw="$(manifest_get stateDir)" || die "manifest has no stateDir"
STATE_DIR="$(manifest_path_expand "$state_dir_raw")"
OUT="$STATE_DIR/agent.env"

SOURCES=()
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in
    /* | \~*) SOURCES+=("$(manifest_path_expand "$rel")") ;;
    *) SOURCES+=("$REPO_ROOT/$rel") ;;
  esac
done < <(manifest_get credentials.sources || true)
SOURCES+=("$STATE_DIR/cloud.env")

mapfile -t DIRECT < <(manifest_get credentials.direct || true)
mapfile -t MACHINE_WIDE < <(manifest_get credentials.machineWide || true)
mapfile -t RW_FALLBACK < <(manifest_get credentials.railway.fallback || true)
NS_NAMES=(); NS_SRC=()
while IFS=$'\t' read -r k v; do
  [ -n "$k" ] || continue
  NS_NAMES+=("$k"); NS_SRC+=("$v")
done < <(manifest_get credentials.namespaced || true)
alias_direct="$(manifest_get credentials.aliasDirect || echo false)"
github_token="$(manifest_get credentials.githubToken || echo false)"

if [ "$alias_direct" = true ] && [ -z "$prefix" ]; then
  die "credentials.aliasDirect needs envPrefix in the manifest"
fi

in_list() { # needle, haystack...
  local n="$1" x; shift
  for x in "$@"; do [ "$x" = "$n" ] && return 0; done
  return 1
}

# First non-empty value for KEY across SOURCES, quotes stripped. `if`, not
# `[[ ]] && …`, as the loop body's last command: under `set -e` a false test
# there aborts the whole script silently, and a key present with an EMPTY value
# in an earlier source is exactly that case.
lookup() {
  local key="$1" f line val
  for f in "${SOURCES[@]}"; do
    [ -f "$f" ] || continue
    line="$(grep -E "^(export )?${key}=" "$f" | tail -1 || true)"
    [ -n "$line" ] || continue
    val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    if [ -n "$val" ]; then
      printf '%s' "$val"
      return 0
    fi
  done
  if [ "${#MACHINE_WIDE[@]}" -gt 0 ] && in_list "$key" "${MACHINE_WIDE[@]}" && [ -n "${!key:-}" ]; then
    printf '%s' "${!key}"
    return 0
  fi
  return 1
}

# Railway, fetched once into this shell (a cache set inside a command
# substitution would die with the subshell), and only when a fallback key is
# actually missing locally.
railway_kv_cache=""
if [ -n "${RW_FALLBACK[0]:-}" ]; then
  for key in "${RW_FALLBACK[@]}"; do
    if ! lookup "$key" >/dev/null; then
      rw_service="$(manifest_get credentials.railway.service || true)"
      rw_env="$(manifest_get credentials.railway.environment || echo production)"
      rw_project="$(manifest_get credentials.railway.projectId || true)"
      if [ -n "$rw_service" ]; then
        railway_kv_cache="$(railway_kv "$rw_service" "$rw_env" "$rw_project" || true)"
      fi
      break
    fi
  done
fi

from_railway=()
# KEY's value from the local sources, else from Railway when KEY is a fallback.
# Runs in a command substitution, so provenance is re-derived by the caller
# (`lookup` failing means Railway answered).
resolve() {
  if lookup "$1"; then return 0; fi
  if [ -n "${RW_FALLBACK[0]:-}" ] && in_list "$1" "${RW_FALLBACK[@]}" && railway_value "$1" "$railway_kv_cache"; then
    return 0
  fi
  return 1
}

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
{
  printf '# %s agent shell credentials — GENERATED by ~/.claude/bin/agent-env-build.sh. Do not edit.\n' "$name"
  printf '# Sourced from ~/.bashrc so every agent shell and worktree inherits it. chmod 600.\n\n'
} >"$TMP"

# Never exported bare, whatever a manifest lists: Claude Code bills a bare
# ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN in its environment to that key
# instead of the subscription, so a product's API key in an agent shell charges
# every session on the box to it. The prefix alias, which Claude Code ignores,
# is still emitted. The bundle also unsets both, so it scrubs an older bundle
# sourced before it.
NEVER_BARE=(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN)

emitted=(); skipped=()
for key in "${DIRECT[@]}"; do
  [ -n "$key" ] || continue
  if val="$(resolve "$key")"; then
    lookup "$key" >/dev/null || from_railway+=("$key")
    if in_list "$key" "${NEVER_BARE[@]}"; then
      if [ "$alias_direct" = true ]; then
        printf 'export %s_%s=%q\n' "$prefix" "$key" "$val" >>"$TMP"
        emitted+=("${prefix}_$key")
      fi
      continue
    fi
    printf 'export %s=%q\n' "$key" "$val" >>"$TMP"
    [ "$alias_direct" = true ] && printf 'export %s_%s=%q\n' "$prefix" "$key" "$val" >>"$TMP"
    emitted+=("$key")
  else
    skipped+=("$key")
  fi
done

printf '\n# Claude Code bills a bare Anthropic key instead of the subscription.\nunset %s\n' "${NEVER_BARE[*]}" >>"$TMP"

if [ "$alias_direct" = true ] && [ "${#skipped[@]}" -gt 0 ]; then
  {
    printf '\n# Not available — the %s_ alias is unset so a sibling repo'"'"'s bare export\n' "$prefix"
    printf '# cannot be mistaken for this repo'"'"'s value.\n'
    for key in "${skipped[@]}"; do printf 'unset %s_%s\n' "$prefix" "$key"; done
  } >>"$TMP"
fi

if [ "$github_token" = true ]; then
  gh_token=""
  if command -v gh >/dev/null 2>&1; then
    gh_token="$(timeout 15 gh auth token 2>/dev/null || true)"
  fi
  [ -n "$gh_token" ] || gh_token="${GITHUB_TOKEN:-}"
  gh_token="${gh_token%%$'\n'*}"
  if [ -n "$gh_token" ]; then
    printf '\n# GitHub API token for scripts that read GITHUB_TOKEN. NOT the GitHub Packages\n# token: that is NODE_AUTH_TOKEN (bin/doctor.sh verifies it).\nexport GITHUB_TOKEN=%q\n' "$gh_token" >>"$TMP"
    emitted+=(GITHUB_TOKEN)
  else
    skipped+=(GITHUB_TOKEN)
  fi
fi

if [ "${#NS_NAMES[@]}" -gt 0 ]; then
  printf '\n# Namespaced, never bare — opt in per command, e.g. export %s=$%s\n' "${NS_SRC[0]}" "${NS_NAMES[0]}" >>"$TMP"
  for i in "${!NS_NAMES[@]}"; do
    ns="${NS_NAMES[$i]}"; src="${NS_SRC[$i]}"
    if val="$(resolve "$src")"; then
      lookup "$src" >/dev/null || from_railway+=("$ns")
      printf 'export %s=%q\n' "$ns" "$val" >>"$TMP"
      emitted+=("$ns")
    else
      printf '# %s: no source defines %s. Read it on demand from where the server reads it.\n' "$ns" "$src" >>"$TMP"
      skipped+=("$ns")
    fi
  done
fi

install -m 600 "$TMP" "$OUT"
rm -f "$TMP"; trap - EXIT

bashrc_ensure_sourced "$OUT" "$name agent shell credentials"

echo "agent-env-build: wrote ${#emitted[@]} cred(s) to $OUT: ${emitted[*]}"
if [ "${#from_railway[@]}" -gt 0 ]; then
  echo "agent-env-build: read from Railway (no local source defines them): ${from_railway[*]}"
fi
if [ "${#skipped[@]}" -gt 0 ]; then
  echo "agent-env-build: absent (fetch on demand, or run ~/.claude/bin/ops-pull.sh): ${skipped[*]}"
fi
