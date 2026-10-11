#!/usr/bin/env bash
# Self-test for npm-allow-scripts.sh against a stub `npm` and a throwaway user config.
#   bash bin/npm-allow-scripts.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/npm-allow-scripts.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
bad() { echo "FAIL: $1"; fail=1; }

mkdir -p "$TMP/bin"
STORE="$TMP/allow"        # the stub's user-level allow-scripts value
# Stub: `config ls -l` lists the option only when SUPPORTED=1; get/set read and write $STORE.
cat >"$TMP/bin/npm" <<'S'
#!/bin/sh
case "$1 $2" in
  "config ls") [ "$SUPPORTED" = 1 ] && echo "allow-scripts = "; exit 0 ;;
  "config get") cat "$STORE" 2>/dev/null || echo undefined; exit 0 ;;
  "config set") printf '%s' "${3#allow-scripts=}" >"$STORE"; exit 0 ;;
esac
exit 1
S
chmod +x "$TMP/bin/npm"
export PATH="$TMP/bin:$PATH" STORE

SUPPORTED=0 "$SCRIPT" >/dev/null 2>&1; [ $? = 0 ] || bad "an npm without allow-scripts must be a no-op"
[ ! -e "$STORE" ] || bad "an npm without allow-scripts must not be written to"

export SUPPORTED=1
out="$("$SCRIPT" 2>&1)"; rc=$?
[ "$rc" = 1 ] || bad "empty policy: want exit 1, got $rc"
case "$out" in *"fix: bin/npm-allow-scripts.sh --apply"*) ;; *) bad "empty policy: report must name the fix: $out" ;; esac
[ ! -e "$STORE" ] || bad "a report must not write the config"

"$SCRIPT" --apply >/dev/null 2>&1 || bad "--apply failed"
[ "$(cat "$STORE")" = "@railway/cli,esbuild" ] || bad "--apply wrote '$(cat "$STORE")'"
"$SCRIPT" >/dev/null 2>&1 || bad "policy covering both must pass"

printf '%s' 'sharp,esbuild' >"$STORE"
"$SCRIPT" --apply >/dev/null 2>&1
[ "$(cat "$STORE")" = "sharp,esbuild,@railway/cli" ] || bad "existing entries must be kept and only the missing one added, got '$(cat "$STORE")'"

"$SCRIPT" --bogus >/dev/null 2>&1; [ $? = 2 ] || bad "unknown option must exit 2"

[ "$fail" = 0 ] && echo "npm-allow-scripts: all cases passed"
exit "$fail"
