#!/usr/bin/env bash
# bin/migration-lock-check.py and GarrettMakesItLLC/ci's
# actions/check-migration-locks/migration-lock-check.py are the same checker:
# the write-time hook (hooks/migration-guard.sh) runs this copy, CI runs that
# one, and a migration the hook accepts must not fail in CI. This compares the
# two as Python ASTs with the module docstring dropped, so each copy may say
# where it lives while the code itself cannot drift.
#   bash bin/migration-lock-check-drift.test.sh
#
# Offline, a local run reports SKIP and exits 0. Under CI (`CI` set) an
# unreachable upstream fails: a drift check that could not fetch has checked
# nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL="$HERE/migration-lock-check.py"
URL="${MIGRATION_CHECK_UPSTREAM_URL:-https://raw.githubusercontent.com/GarrettMakesItLLC/ci/main/actions/check-migration-locks/migration-lock-check.py}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! curl -fsSL --max-time 20 "$URL" -o "$TMP/upstream.py"; then
  if [ -n "${CI:-}" ]; then
    echo "FAIL: could not fetch $URL — the drift check measured nothing"
    exit 1
  fi
  echo "SKIP: migration-lock-check drift (offline: $URL unreachable)"
  exit 0
fi

python3 - "$LOCAL" "$TMP/upstream.py" <<'PY'
import ast, sys

def body(path):
    tree = ast.parse(open(path, encoding="utf-8").read())
    if tree.body and isinstance(tree.body[0], ast.Expr) and isinstance(getattr(tree.body[0], "value", None), ast.Constant) and isinstance(tree.body[0].value.value, str):
        tree.body = tree.body[1:]
    return ast.dump(tree, include_attributes=False)

local, upstream = sys.argv[1], sys.argv[2]
if body(local) != body(upstream):
    print("FAIL: bin/migration-lock-check.py has drifted from ci's actions/check-migration-locks/migration-lock-check.py")
    print("      change both together (the hook and CI must accept the same migrations)")
    sys.exit(1)
print("migration-lock-check drift: in step with ci")
PY
