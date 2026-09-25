#!/usr/bin/env bash
# Rotates the GitHub Packages read token (NODE_AUTH_TOKEN / GMI_PACKAGES_TOKEN)
# across every known location, for dotclaude#396: the fleet ran on a classic
# PAT with org-admin/repo-delete scopes when every consumer only ever needed
# read:packages.
#
# GitHub Packages' npm registry accepts only a classic PAT — fine-grained
# tokens aren't supported there (docs.github.com, "Working with the npm
# registry"). So the owner mints a classic PAT scoped to read:packages ONLY,
# with an expiry, and this script takes it from there.
#
# Usage:
#   printf '%s' "$NEW_TOKEN" | bin/rotate-packages-token.sh          # dry run
#   printf '%s' "$NEW_TOKEN" | bin/rotate-packages-token.sh --apply  # writes
#
# The token is read from STDIN ONLY — never argv, never an env var — so it
# never shows up in `ps`, shell history, or this process's own argv. Nothing
# is written anywhere until --apply is passed; the default is a dry run that
# only verifies the token and reports what it would change.
#
# What it touches, once --apply is passed:
#   - the local secrets env files that currently set NODE_AUTH_TOKEN directly
#     (in place, preserving every other line)
#   - every Railway service/environment inventoried below, via the `railway`
#     CLI if it's on PATH, else it prints the exact command
#   - every Vercel project/environment inventoried below, via the `vercel`
#     CLI if it's on PATH, else it prints the exact command
#   - the GMI_PACKAGES_TOKEN org Actions secret, via `gh secret set`
#
# It refuses to touch anything unless the token verifies first: scopes must
# be exactly `read:packages` (measured live from api.github.com/user's
# x-oauth-scopes header — an empty or wrong-scoped token does not 401 on
# `npm ci`, it silently omits every @gmi/* package, so scope-checking here is
# the only place that catches it before it reaches a build), and the token
# must actually resolve a package against npm.pkg.github.com.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: printf '%s' "$NEW_TOKEN" | rotate-packages-token.sh [--apply] [--skip-verify]

  --apply         Write the new token to every inventoried location.
                   Without it, verifies the token and prints a plan only.
  --skip-verify   Skip the live scope/registry checks (tests only).
EOF
}

APPLY=0
SKIP_VERIFY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --skip-verify) SKIP_VERIFY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -t 0 ]; then
  echo "error: pipe the new token on stdin — never as an argument. Example:" >&2
  echo "  printf '%s' \"\$NEW_TOKEN\" | $0 --apply" >&2
  exit 2
fi

TOKEN="$(cat -)"
# strip a single trailing newline, tolerate none
TOKEN="${TOKEN%$'\n'}"
TOKEN="${TOKEN%$'\r'}"
if [ -z "$TOKEN" ]; then
  echo "error: empty token on stdin" >&2
  exit 2
fi

EXPECTED_SCOPES="read:packages"
GITHUB_API_URL="${GITHUB_API_URL_OVERRIDE:-https://api.github.com}"
REGISTRY_PACKAGE="${REGISTRY_PACKAGE_OVERRIDE:-@garrettmakesitllc/patterns}"

# --- 1. Verify the token before touching anything -------------------------

if [ "$SKIP_VERIFY" -ne 1 ]; then
  echo "==> verifying token scopes against $GITHUB_API_URL/user"
  headers="$(curl -fsS -D - -o /dev/null -H "Authorization: Bearer $TOKEN" "$GITHUB_API_URL/user")" \
    || { echo "error: could not reach $GITHUB_API_URL/user with this token" >&2; exit 1; }
  scopes_line="$(printf '%s' "$headers" | tr -d '\r' | grep -i '^x-oauth-scopes:' || true)"
  if [ -z "$scopes_line" ]; then
    echo "error: no x-oauth-scopes header came back — is this really a classic PAT?" >&2
    exit 1
  fi
  scopes="$(printf '%s' "$scopes_line" | cut -d: -f2- | tr -d ' \t')"
  if [ "$scopes" != "$EXPECTED_SCOPES" ]; then
    echo "error: token scopes are '$scopes', expected exactly '$EXPECTED_SCOPES'." >&2
    echo "       Refusing to rotate to a token that is not read:packages-only —" >&2
    echo "       that is the whole point of this rotation (dotclaude#396)." >&2
    exit 1
  fi
  echo "    scopes OK: $scopes"

  echo "==> verifying registry access: npm view $REGISTRY_PACKAGE version"
  npmrc_tmp="$(mktemp)"
  trap 'rm -f "$npmrc_tmp"' RETURN 2>/dev/null || true
  cat > "$npmrc_tmp" <<EOF
@garrettmakesitllc:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${TOKEN}
EOF
  if ! version="$(npm view "$REGISTRY_PACKAGE" version --userconfig "$npmrc_tmp" 2>&1)"; then
    rm -f "$npmrc_tmp"
    echo "error: npm view $REGISTRY_PACKAGE failed against npm.pkg.github.com:" >&2
    echo "$version" >&2
    exit 1
  fi
  rm -f "$npmrc_tmp"
  echo "    registry access OK (resolved version $version)"
else
  echo "==> --skip-verify: not checking scopes or registry access"
fi

MODE="dry run"
[ "$APPLY" -eq 1 ] && MODE="apply"
echo "==> mode: $MODE"

# --- 2. Inventory --------------------------------------------------------
# Local secrets env files known to set NODE_AUTH_TOKEN directly (checked live
# below — a file that no longer sets it, or never did, is skipped and
# reported, not assumed).
SECRET_ENV_FILES=(
  "$HOME/.config/secrets/gmi.env"
  "$HOME/.musclebuddy/agent.env"
  "$HOME/.musclebuddy/ops.env"
  "$HOME/.networthy/agent.env"
  "$HOME/.networthy/ops.env"
  "$HOME/.adventureos/agent.env"
  "$HOME/.redthread/agent.env"
)

# Railway: projectId:serviceId:environmentId:label
RAILWAY_TARGETS=(
  "d4839f4b-63ed-4dd6-a1e6-58cea7eba8ea:7d4e72b8-bfe3-41d3-ba05-6e82399bd1f5:99b2cf8c-cf3b-435f-bd23-ca7a7bcd03e0:sidequest/server (production)"
  "2e903006-f3ea-4df3-b668-8def44031d1e:f38d30ad-d16c-4688-a45c-95d919b1180a:45e02372-bd25-4dfc-a6e8-7185e9991e29:adventureos-server/server (production)"
  "2e903006-f3ea-4df3-b668-8def44031d1e:f38d30ad-d16c-4688-a45c-95d919b1180a:4aef1894-5b4b-4467-b183-c09b88aeac0b:adventureos-server/server (staging)"
  "95548a10-abec-495a-8f3b-f3f31f5cf403:97b61198-1e0f-4515-a171-88125331076d:5ef9a644-3b69-4032-9463-aa2631e985d7:networthy/server-QOzy (production)"
  "95548a10-abec-495a-8f3b-f3f31f5cf403:7f6aa3e3-8d5e-4d74-a25f-2b1302c14a9c:5ef9a644-3b69-4032-9463-aa2631e985d7:networthy/server-v2 (production)"
  "27db0fce-866f-4ebf-aaa4-cf0b92479859:15d76f3a-54a7-4e00-849a-44d411b80cad:cb0781b9-8f4f-45f3-a7c3-85ca9c25fb78:precious-victory/@musclebuddy/server (production)"
  "27db0fce-866f-4ebf-aaa4-cf0b92479859:15d76f3a-54a7-4e00-849a-44d411b80cad:f92caf58-0050-4541-af80-ec5cfadfc6dc:precious-victory/@musclebuddy/server (staging)"
  "b8918dae-a674-43ab-b643-6ff312b7ee0c:7998e33c-635a-466d-b36b-d29031feee52:94018006-44da-452f-bb90-ae3aced9a414:observant-ambition/redthread-worker (production)"
  "b8918dae-a674-43ab-b643-6ff312b7ee0c:303ca329-4706-4c32-803c-b32512203233:94018006-44da-452f-bb90-ae3aced9a414:observant-ambition/@redthread/server (production)"
)

# Vercel: projectId:environmentTarget:label — one call per target, since the
# Vercel CLI sets one environment at a time.
VERCEL_TARGETS=(
  "prj_kOr3DbAGYPk5sRNOcXugDG8YHFQV:production:musclebuddy-docs"
  "prj_PSTcfZoVVf18SAHneHrAC7sIgV8s:development:muscle-buddy"
  "prj_PSTcfZoVVf18SAHneHrAC7sIgV8s:preview:muscle-buddy"
  "prj_PSTcfZoVVf18SAHneHrAC7sIgV8s:production:muscle-buddy"
  "prj_oC1J2i2Nt2UsQBlZcxZ0igc5dm91:preview:muscle-buddy-demo"
  "prj_oC1J2i2Nt2UsQBlZcxZ0igc5dm91:production:muscle-buddy-demo"
  "prj_IAPKOOo1eFhBGGDYLvNNi73OT22u:preview:sidequest"
  "prj_IAPKOOo1eFhBGGDYLvNNi73OT22u:production:sidequest"
  "prj_fQwpmfGqhq1oFbuT8mWmCTtGY3x5:preview:adventureos-web-vite"
  "prj_fQwpmfGqhq1oFbuT8mWmCTtGY3x5:production:adventureos-web-vite"
  "prj_X5E28w6xFTOdD8BCTXGkWLcAEn3c:development:networthy-web"
  "prj_X5E28w6xFTOdD8BCTXGkWLcAEn3c:preview:networthy-web"
  "prj_X5E28w6xFTOdD8BCTXGkWLcAEn3c:production:networthy-web"
  "prj_mhHreQh3gSMa9PCuk3ChljOex4uS:preview:adventureos"
  "prj_mhHreQh3gSMa9PCuk3ChljOex4uS:production:adventureos"
)

ORG="GarrettMakesItLLC"
ORG_SECRET="GMI_PACKAGES_TOKEN"

failures=()

# --- 3. Secrets env files --------------------------------------------------

echo
echo "==> secrets env files"
for f in "${SECRET_ENV_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "    skip (missing): $f"
    continue
  fi
  if ! grep -qE '^[[:space:]]*export[[:space:]]+NODE_AUTH_TOKEN=' "$f"; then
    echo "    skip (no direct NODE_AUTH_TOKEN assignment): $f"
    continue
  fi
  if [ "$APPLY" -eq 0 ]; then
    echo "    would update: $f"
    continue
  fi
  tmp="$(mktemp)"
  # Preserve every other line; replace only the export line's value.
  awk -v tok="$TOKEN" '
    /^[[:space:]]*export[[:space:]]+NODE_AUTH_TOKEN=/ { print "export NODE_AUTH_TOKEN=" tok; next }
    { print }
  ' "$f" > "$tmp"
  chmod --reference="$f" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv "$tmp" "$f"
  echo "    updated: $f"
done

# --- 4. Railway -------------------------------------------------------------

echo
echo "==> Railway services"
# railway's own `variables --set KEY=VALUE` CLI has no stdin form, so the
# token necessarily passes through this process's argv for the duration of
# each call — unlike the vercel and gh steps below, which take it on stdin.
if command -v railway >/dev/null 2>&1; then
  for entry in "${RAILWAY_TARGETS[@]}"; do
    IFS=':' read -r proj svc env label <<<"$entry"
    if [ "$APPLY" -eq 0 ]; then
      echo "    would set NODE_AUTH_TOKEN on $label"
      continue
    fi
    if RAILWAY_PROJECT_ID="$proj" RAILWAY_SERVICE_ID="$svc" RAILWAY_ENVIRONMENT_ID="$env" \
        railway variables --set "NODE_AUTH_TOKEN=$TOKEN" --skip-deploys >/dev/null 2>&1; then
      echo "    updated: $label"
    else
      echo "    FAILED: $label" >&2
      failures+=("railway:$label")
    fi
  done
else
  echo "    railway CLI not found on PATH — run these once NEW_TOKEN is exported:"
  for entry in "${RAILWAY_TARGETS[@]}"; do
    IFS=':' read -r proj svc env label <<<"$entry"
    echo "      # $label"
    echo "      RAILWAY_PROJECT_ID=$proj RAILWAY_SERVICE_ID=$svc RAILWAY_ENVIRONMENT_ID=$env \\"
    echo "        railway variables --set \"NODE_AUTH_TOKEN=\$NEW_TOKEN\" --skip-deploys"
  done
fi

# --- 5. Vercel ---------------------------------------------------------------

echo
echo "==> Vercel projects"
if command -v vercel >/dev/null 2>&1; then
  for entry in "${VERCEL_TARGETS[@]}"; do
    IFS=':' read -r proj target label <<<"$entry"
    if [ "$APPLY" -eq 0 ]; then
      echo "    would set NODE_AUTH_TOKEN ($target) on $label"
      continue
    fi
    VERCEL_PROJECT_ID="$proj" vercel env rm NODE_AUTH_TOKEN "$target" -y >/dev/null 2>&1 || true
    if printf '%s' "$TOKEN" | VERCEL_PROJECT_ID="$proj" vercel env add NODE_AUTH_TOKEN "$target" >/dev/null 2>&1; then
      echo "    updated: $label ($target)"
    else
      echo "    FAILED: $label ($target)" >&2
      failures+=("vercel:$label:$target")
    fi
  done
else
  echo "    vercel CLI not found on PATH — run these once NEW_TOKEN is exported:"
  for entry in "${VERCEL_TARGETS[@]}"; do
    IFS=':' read -r proj target label <<<"$entry"
    echo "      # $label ($target)"
    echo "      VERCEL_PROJECT_ID=$proj vercel env rm NODE_AUTH_TOKEN $target -y"
    echo "      printf '%s' \"\$NEW_TOKEN\" | VERCEL_PROJECT_ID=$proj vercel env add NODE_AUTH_TOKEN $target"
  done
fi

# --- 6. Org Actions secret ---------------------------------------------------

echo
echo "==> org Actions secret $ORG_SECRET"
if [ "$APPLY" -eq 0 ]; then
  echo "    would set: gh secret set $ORG_SECRET --org $ORG"
elif command -v gh >/dev/null 2>&1; then
  if printf '%s' "$TOKEN" | gh secret set "$ORG_SECRET" --org "$ORG" >/dev/null 2>&1; then
    echo "    updated: $ORG_SECRET"
  else
    echo "    FAILED: $ORG_SECRET" >&2
    failures+=("gh:$ORG_SECRET")
  fi
else
  echo "    gh CLI not found on PATH — run once NEW_TOKEN is exported:"
  echo "      printf '%s' \"\$NEW_TOKEN\" | gh secret set $ORG_SECRET --org $ORG"
fi

echo
if [ "${#failures[@]}" -gt 0 ]; then
  echo "==> DONE WITH FAILURES: ${failures[*]}" >&2
  exit 1
fi
echo "==> done ($MODE)"
