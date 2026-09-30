#!/usr/bin/env bash
# Pull a product repo's cloud-held agent secrets onto this machine.
#
#   ~/.claude/bin/ops-pull.sh [<vercel-environment>]     # run from anywhere in the repo
#
# Reads the repo's `.claude/repo.json` (docs/repo-manifest.md) and writes into
# its `stateDir` (e.g. ~/.musclebuddy/). Two independent halves, each opt-in:
#
# 1. THE OPS CHANNEL (`ops.channel: true`) -> <stateDir>/ops.env, sourced from
#    ~/.bashrc. Every Vercel env var named `OPS_<NAME>` is pulled, the prefix is
#    stripped, and each lands as `export <NAME>=...`. This is the route for a
#    secret an AGENT needs that the app does not (a monitoring key, an ad-platform
#    token, an MCP's API key): Vercel is the single copy and every machine pulls
#    it, so "the key isn't set" means "pull it", never "ask the owner". App
#    runtime secrets do not go here — they live where the server reads them, and a
#    second copy only widens the leak surface.
#
#    Add one with `--no-sensitive`:
#        vercel env add OPS_MY_SECRET production --no-sensitive
#    `vercel env add` marks a variable sensitive by default, and a sensitive
#    variable cannot be read back: the pull returns the literal `[SENSITIVE]`,
#    eleven characters that authenticate as garbage rather than failing as
#    missing. Such a line is dropped, and the run fails naming it.
#
#    Refused outright: an OPS_ var that would export a bare RAILWAY_TOKEN,
#    RAILWAY_API_TOKEN or VERCEL_TOKEN. A CLI checks its token variable before
#    its own login, so a bare export shadows the interactive session, and a
#    project-scoped or stale token then denies every call while blaming the
#    login. Name such a secret `OPS_<PREFIX>_<NAME>` so tooling reads it
#    deliberately. Names in `ops.unsetAlways` are refused too, and the generated
#    file `unset`s them, so an export inherited from a long-lived parent shell
#    dies at the next shell rather than outliving every correction.
#
#    `ops.fileSecrets` are values that are FILES (a base64 env bundle, a signing
#    key). They are never exported — a PEM in an environment variable is one `env`
#    away from a log — and a secret with a `path` is decoded to
#    <stateDir>/<path> (mode 600), with `{VAR}` in the path filled from the
#    channel's own OPS_VAR. `mustContain` is checked after decoding, and a file
#    that fails it is deleted rather than left half-valid.
#
# 2. CLOUD VALUES (`ops.vercelKeys`, `ops.railwayKeys`) -> <stateDir>/cloud.env,
#    plain KEY=value lines, NOT sourced by any shell. For a repo with no local
#    `.env` at all, where the cloud is the only source of the values
#    `agent-env-build.sh` exports. That script reads cloud.env as its
#    lowest-priority source and applies its own namespacing, so a production
#    DATABASE_URL here never lands bare in a shell. `railwayKeys` maps a Railway
#    variable name to the name written here, so a Railway `NODE_AUTH_TOKEN` can
#    arrive as `GMI_PACKAGES_TOKEN` instead of colliding with the shell's own.
#
# Runs from the MAIN working tree whatever the cwd: `vercel env pull` resolves
# the project from `.vercel/` in its cwd, which a linked worktree does not have.
#
# Exit 0 when every configured half succeeded; 1 otherwise, with the reason.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=bin/lib/repo-manifest.sh
. "$HERE/lib/repo-manifest.sh"
# shellcheck source=bin/lib/vercel.sh
. "$HERE/lib/vercel.sh"
# shellcheck source=bin/lib/railway.sh
. "$HERE/lib/railway.sh"

die() { echo "ops-pull: $*" >&2; exit 1; }

manifest_find >/dev/null || die "no .claude/repo.json governs $PWD — this repo has not opted in (docs/repo-manifest.md)."
main_tree="$(main_tree_of "$PWD")" || die "not inside a git repository"
cd "$main_tree"

name="$(manifest_get name || basename "$main_tree")"
prefix="$(manifest_get envPrefix || true)"
state_dir_raw="$(manifest_get stateDir)" || die "manifest has no stateDir"
STATE_DIR="$(manifest_path_expand "$state_dir_raw")"
ENVIRONMENT="${1:-$(manifest_get ops.vercelEnvironment || echo production)}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

failed=0
did_anything=0

# The one source line ~/.bashrc needs per sourced file. Inserted ABOVE the
# ~/.config/secrets/gmi.env line when there is one, so gmi.env keeps winning on
# NODE_AUTH_TOKEN: it holds the PAT with `read:packages`, and anything sourced
# after it that exports a `gh` OAuth token would silently downgrade npm auth.
ensure_sourced() {
  local file="$1" label="$2" bashrc="$HOME/.bashrc" line gmi tmp
  line="[ -f \"$file\" ] && . \"$file\""
  grep -qF "$line" "$bashrc" 2>/dev/null && return 0
  gmi='[ -f "$HOME/.config/secrets/gmi.env" ] && . "$HOME/.config/secrets/gmi.env"'
  if grep -qF "$gmi" "$bashrc" 2>/dev/null; then
    tmp="$(mktemp)"
    awk -v src="$line" -v gmi="$gmi" -v label="# $label" '
      !done && $0 == gmi { print label; print src; print ""; done = 1 }
      { print }
    ' "$bashrc" >"$tmp" && cat "$tmp" >"$bashrc"
    rm -f "$tmp"
  else
    printf '\n# %s\n%s\n' "$label" "$line" >>"$bashrc"
  fi
  echo "ops-pull: added the source line for $file to ~/.bashrc — open a new shell to load it."
}

vercel_pull() {
  local env="$1" out="$2"
  if [ ! -f "$main_tree/.vercel/project.json" ]; then
    echo "ops-pull: $main_tree/.vercel/project.json is missing — run 'vercel link' in the main checkout first." >&2
    return 1
  fi
  resolve_vercel || { echo "ops-pull: no vercel CLI and no npx — install one, then 'vercel login'." >&2; return 1; }
  if ! "${VERCEL[@]}" env pull "$out" --environment="$env" --yes >/dev/null 2>&1; then
    echo "ops-pull: 'vercel env pull --environment=$env' failed — run 'vercel login' and 'vercel link' in $main_tree." >&2
    return 1
  fi
}

value_of() { # KEY FILE -> value with surrounding quotes stripped
  local line
  line="$(grep -E "^$1=" "$2" | tail -1 || true)"
  [ -n "$line" ] || return 1
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  printf '%s' "$line"
}

TMP="$(mktemp)"
CLOUD_TMP="$(mktemp)"
trap 'rm -f "$TMP" "$CLOUD_TMP"' EXIT

# ---------------------------------------------------------------------------
# 1. The OPS_ channel
# ---------------------------------------------------------------------------
if [ "$(manifest_get ops.channel || echo false)" = true ]; then
  did_anything=1
  if vercel_pull "$ENVIRONMENT" "$TMP"; then
    mapfile -t unset_always < <(manifest_get ops.unsetAlways || true)
    mapfile -t file_secret_json < <(manifest_get ops.fileSecrets || true)
    file_secret_names=()
    for fs in "${file_secret_json[@]}"; do
      [ -n "$fs" ] || continue
      file_secret_names+=("$(python3 -c '
import json, sys
try:
    v = json.loads(sys.argv[1])
except ValueError:
    v = sys.argv[1]
print(v if isinstance(v, str) else v["name"])' "$fs")")
    done

    refused=0
    for shadow in RAILWAY_TOKEN RAILWAY_API_TOKEN VERCEL_TOKEN; do
      if grep -qE "^OPS_${shadow}=" "$TMP"; then
        echo "ops-pull: OPS_${shadow} would export a bare ${shadow}, which overrides this machine's" >&2
        echo "  interactive CLI login and reports the failure as a broken login. Rename it:" >&2
        echo "    vercel env rm OPS_${shadow} ${ENVIRONMENT} && vercel env add OPS_${prefix:+${prefix}_}${shadow} ${ENVIRONMENT} --no-sensitive" >&2
        refused=1
      fi
    done
    for n in "${unset_always[@]}"; do
      [ -n "$n" ] || continue
      if grep -qE "^OPS_${n}=" "$TMP"; then
        echo "ops-pull: OPS_${n} is on this repo's ops.unsetAlways list — it must not be a shell variable" >&2
        echo "  here at all. Remove it from Vercel:  vercel env rm OPS_${n} ${ENVIRONMENT}" >&2
        refused=1
      fi
    done

    if [ "$refused" = 1 ]; then
      failed=1
    else
      unreadable="$(grep -E '^OPS_[A-Za-z0-9_]+="?\[SENSITIVE\]"?$' "$TMP" | sed -E 's/^OPS_([A-Za-z0-9_]+)=.*/\1/' || true)"
      dropped_re='^$'
      if [ "${#file_secret_names[@]}" -gt 0 ]; then
        dropped_re="^OPS_($(IFS='|'; echo "${file_secret_names[*]}"))="
      fi
      OPS_FILE="$STATE_DIR/ops.env"
      {
        printf '# %s ops secrets — GENERATED by ~/.claude/bin/ops-pull.sh from Vercel OPS_* vars.\n' "$name"
        printf '# Vercel is the source of truth; regenerate with: ~/.claude/bin/ops-pull.sh\n'
        printf '# Sourced from ~/.bashrc. chmod 600. Do not edit.\n\n'
        grep -E '^OPS_[A-Za-z0-9_]+=' "$TMP" \
          | grep -vE '^OPS_[A-Za-z0-9_]+="?\[SENSITIVE\]"?$' \
          | grep -vE "$dropped_re" \
          | sed -E 's/^OPS_//; s/^([A-Za-z0-9_]+)=/export \1=/' || true
        if [ "${#file_secret_names[@]}" -gt 0 ]; then
          printf '\n# File-shaped secrets: materialised under %s, never exported.\n' "$STATE_DIR"
          echo "unset ${file_secret_names[*]}"
        fi
        if [ "${#unset_always[@]}" -gt 0 ] && [ -n "${unset_always[0]}" ]; then
          printf '\n# Never a shell variable here (ops.unsetAlways); cleared so an inherited export dies too.\n'
          echo "unset ${unset_always[*]}"
        fi
      } >"$OPS_FILE"
      chmod 600 "$OPS_FILE"

      # File secrets with a path are decoded next to ops.env.
      for fs in "${file_secret_json[@]}"; do
        [ -n "$fs" ] || continue
        spec="$(python3 -c '
import json, sys
try:
    v = json.loads(sys.argv[1])
except ValueError:
    v = sys.argv[1]
if isinstance(v, str):
    v = {"name": v}
print(v["name"]); print(v.get("path", "")); print(v.get("mustContain", ""))
' "$fs")"
        fs_name="$(sed -n 1p <<<"$spec")"
        fs_path="$(sed -n 2p <<<"$spec")"
        fs_must="$(sed -n 3p <<<"$spec")"
        [ -n "$fs_path" ] || continue
        blob="$(value_of "OPS_${fs_name}" "$TMP" || true)"
        [ -n "$blob" ] && [ "$blob" != "[SENSITIVE]" ] || continue
        # Fill {VAR} placeholders from the channel's own OPS_VAR.
        missing_var=""
        while read -r var; do
          [ -n "$var" ] || continue
          val="$(value_of "OPS_${var}" "$TMP" || true)"
          if [ -z "$val" ] || [ "$val" = "[SENSITIVE]" ]; then missing_var="$var"; break; fi
          fs_path="${fs_path//\{$var\}/$val}"
        done < <(grep -oE '\{[A-Za-z0-9_]+\}' <<<"$fs_path" | tr -d '{}' | sort -u)
        if [ -n "$missing_var" ]; then
          echo "ops-pull: OPS_${fs_name} names its file by OPS_${missing_var}, which is not on the channel — add it:" >&2
          echo "    vercel env add OPS_${missing_var} ${ENVIRONMENT} --no-sensitive" >&2
          failed=1
          continue
        fi
        dest="$STATE_DIR/$fs_path"
        mkdir -p "$(dirname "$dest")"
        chmod 700 "$(dirname "$dest")"
        (umask 077; printf '%s' "$blob" | base64 -d >"$dest" 2>/dev/null) || true
        chmod 600 "$dest" 2>/dev/null || true
        if [ -n "$fs_must" ] && ! grep -qF -- "$fs_must" "$dest" 2>/dev/null; then
          rm -f "$dest"
          echo "ops-pull: OPS_${fs_name} did not decode to a file containing '$fs_must' — re-encode it:" >&2
          echo "    base64 -w0 <file> | vercel env add OPS_${fs_name} ${ENVIRONMENT} --no-sensitive --force" >&2
          failed=1
        else
          echo "ops-pull: wrote $dest"
        fi
      done

      ensure_sourced "$OPS_FILE" "$name ops secrets"
      count="$(grep -c '^export ' "$OPS_FILE" || true)"
      echo "ops-pull: wrote ${count} ops secret(s) to $OPS_FILE from Vercel [$ENVIRONMENT]."

      if [ -n "$unreadable" ]; then
        echo "ops-pull: these are marked SENSITIVE in Vercel and cannot be read back, so they were left out" >&2
        echo "  rather than written as the literal '[SENSITIVE]'. Re-add each from a machine that has the value:" >&2
        for n in $unreadable; do
          echo "    vercel env add OPS_${n} ${ENVIRONMENT} --no-sensitive --force" >&2
        done
        failed=1
      fi
    fi
  else
    failed=1
  fi
fi

# ---------------------------------------------------------------------------
# 2. Cloud values -> cloud.env (not sourced)
# ---------------------------------------------------------------------------
mapfile -t vercel_keys < <(manifest_get ops.vercelKeys || true)
mapfile -t railway_map < <(manifest_get ops.railwayKeys || true)
if [ -n "${vercel_keys[0]:-}" ] || [ -n "${railway_map[0]:-}" ]; then
  did_anything=1
  cloud_ok=0
  {
    printf '# %s cloud values — GENERATED by ~/.claude/bin/ops-pull.sh. Do not edit.\n' "$name"
    printf '# Plain KEY=value, deliberately NOT sourced by any shell: it can hold a production\n'
    printf '# connection string. ~/.claude/bin/agent-env-build.sh reads it and namespaces it.\n\n'
  } >"$CLOUD_TMP"

  if [ -n "${vercel_keys[0]:-}" ]; then
    vtmp="$(mktemp)"
    if vercel_pull "$ENVIRONMENT" "$vtmp"; then
      n=0
      for key in "${vercel_keys[@]}"; do
        if val="$(value_of "$key" "$vtmp")" && [ -n "$val" ] && [ "$val" != "[SENSITIVE]" ]; then
          printf '%s=%s\n' "$key" "$val" >>"$CLOUD_TMP"
          n=$((n + 1))
        fi
      done
      echo "ops-pull: pulled $n of ${#vercel_keys[@]} key(s) from Vercel [$ENVIRONMENT]."
      [ "$n" -gt 0 ] && cloud_ok=1
    fi
    rm -f "$vtmp"
  fi

  if [ -n "${railway_map[0]:-}" ]; then
    rw_service="${RAILWAY_SERVICE:-$(manifest_get credentials.railway.service || true)}"
    rw_env="${RAILWAY_ENV:-$(manifest_get credentials.railway.environment || echo production)}"
    rw_project="$(manifest_get credentials.railway.projectId || true)"
    if [ -z "$rw_service" ]; then
      echo "ops-pull: ops.railwayKeys is set but credentials.railway.service is not — cannot pick a service." >&2
      failed=1
    elif kv="$(railway_kv "$rw_service" "$rw_env" "$rw_project")"; then
      n=0
      for pair in "${railway_map[@]}"; do
        src="${pair%%$'\t'*}"
        dst="${pair#*$'\t'}"
        if val="$(railway_value "$src" "$kv")"; then
          printf '%s=%s\n' "$dst" "$val" >>"$CLOUD_TMP"
          n=$((n + 1))
        fi
      done
      echo "ops-pull: pulled $n of ${#railway_map[@]} key(s) from Railway [$rw_service/$rw_env]."
      [ "$n" -gt 0 ] && cloud_ok=1
    else
      echo "ops-pull: Railway did not answer for $rw_service/$rw_env — set RAILWAY_TOKEN (a project token works) or run 'railway login'." >&2
    fi
  fi

  if [ "$cloud_ok" = 1 ]; then
    install -m 600 "$CLOUD_TMP" "$STATE_DIR/cloud.env"
    echo "ops-pull: wrote $STATE_DIR/cloud.env — run ~/.claude/bin/agent-env-build.sh to fold it into agent shells."
  else
    echo "ops-pull: nothing was pulled for cloud.env; the previous copy (if any) is left as it was." >&2
    failed=1
  fi
fi

[ "$did_anything" = 1 ] || die "the manifest configures neither ops.channel nor ops.vercelKeys/railwayKeys — nothing to pull."
exit "$failed"
