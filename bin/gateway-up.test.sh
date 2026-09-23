#!/usr/bin/env bash
# Self-test for bin/gateway-{up,down,status,common}.sh.
#
# The property under test is the one the whole design turns on: a class whose
# credential is missing is NEVER quietly served by a cheaper class. It is a
# hard stop, and dropping it takes saying so by name. Everything else here —
# composition, fallback pruning, double-start refusal — protects that.
#
# No proxy is started and no network call is made to a provider: `--dry-run`
# composes and validates, and `litellm` is stubbed so this runs on a box (or a
# CI runner) that has never installed it.
#
# Run:  bash bin/gateway-up.test.sh
# The scripts under test are bash, and BASH_ENV (set to ~/.bashrc on agent boxes) makes every
# bash child re-source it and re-export the real keys this suite unsets. Without this the
# suite measures the caller's shell, not the script.
unset BASH_ENV
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UP="$HERE/gateway-up.sh"
DOWN="$HERE/gateway-down.sh"
STATUS="$HERE/gateway-status.sh"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/secrets" "$TMP/home"
cat > "$TMP/bin/litellm" <<'STUB'
#!/usr/bin/env bash
echo "stub litellm: $*"
sleep 300
STUB
chmod +x "$TMP/bin/litellm"

export PATH="$TMP/bin:$PATH"
export CLAUDE_GATEWAY_HOME="$TMP/home"
export GATEWAY_SECRETS_DIR="$TMP/secrets"
# A port nothing on a dev box or a runner is plausibly holding. The pre-start
# probe would otherwise read a stranger's service as "ours is already up".
export GATEWAY_PORT=45917
# The real env must not leak in: the whole point is deciding liveness from the
# secrets dir this test controls.
unset ANTHROPIC_API_KEY GEMINI_API_KEY

CONFIG="$TMP/home/runtime-config.yaml"

check() { # check <description> <expected-substring> <actual>
  case "$3" in *"$2"*) return 0 ;; esac
  echo "FAIL ($1): expected '$2' in:"; echo "$3" | sed 's/^/    /'; fail=1
}
absent() { # absent <description> <forbidden-substring> <actual>
  case "$3" in *"$2"*) echo "FAIL ($1): '$2' should NOT appear in:"; echo "$3" | sed 's/^/    /'; fail=1 ;; esac
}

# --- No credentials at all: refuse, and name every class and its blocker. ---
out="$("$UP" --dry-run 2>&1)"; rc=$?
[ "$rc" != 0 ] || { echo "FAIL (no keys): exited 0, must refuse"; fail=1; }
check "no keys" "refusing to start" "$out"
check "no keys names frontier's blocker" '$ANTHROPIC_API_KEY is not set' "$out"
check "no keys names cheap's blocker" '$GEMINI_API_KEY is not set' "$out"
check "no keys names the local probe" "no server answering at" "$out"
check "no keys explains the escape hatch" "--allow-missing" "$out"
[ -f "$CONFIG" ] && { echo "FAIL (no keys): composed a config anyway"; fail=1; }

# --- One key present, the rest waived by name: compose exactly that class. ---
echo 'export GEMINI_API_KEY=test-cheap-key' > "$TMP/secrets/cheap.env"
out="$("$UP" --dry-run --allow-missing frontier --allow-missing frontier-light --allow-missing local 2>&1)"; rc=$?
[ "$rc" = 0 ] || { echo "FAIL (cheap only): exit $rc"; echo "$out"; fail=1; }
check "cheap only" "classes: cheap" "$out"
check "cheap only reports the waivers" "skipped: frontier:" "$out"
body="$(cat "$CONFIG" 2>/dev/null)"
check "composed config has the cheap class" "model_name: cheap" "$body"
absent "composed config" "model_name: frontier" "$body"
absent "composed config" "model_name: local" "$body"
check "composed config keeps the budget cap" "max_budget" "$body"

# --- THE INVARIANT: a waived class is gone, not re-pointed at a cheaper one.
#     A fallback that survived into a dead class would turn a loud 400 into a
#     flash model answering a code review. ---
absent "waived class must not appear as a fallback target" '"local"' "$body"
absent "waived class must not appear as a fallback source" '"frontier"' "$body"

# --- state.env must SOURCE cleanly. A blocker string carries the literal
#     `$ANTHROPIC_API_KEY` of the variable that was missing; written
#     double-quoted, sourcing it under `set -u` kills gateway-status on the
#     very variable whose absence it is reporting. ---
( set -u; # shellcheck source=/dev/null
  . "$TMP/home/state.env" ) >/dev/null 2>&1 \
  || { echo "FAIL (state.env): does not source cleanly under set -u"; fail=1; }
state="$(set -u; . "$TMP/home/state.env" >/dev/null 2>&1; echo "$GATEWAY_SKIPPED")"
check "state.env keeps the blocker verbatim" 'ANTHROPIC_API_KEY is not set' "$state"


# --- Both Anthropic classes live: the in-class fallback appears, and still
#     nothing points down into `cheap`. ---
echo 'export ANTHROPIC_API_KEY=test-frontier-key' > "$TMP/secrets/anthropic.env"
out="$("$UP" --dry-run --allow-missing local 2>&1)"; rc=$?
[ "$rc" = 0 ] || { echo "FAIL (frontier+cheap): exit $rc"; echo "$out"; fail=1; }
body="$(cat "$CONFIG")"
check "frontier composed" "model_name: frontier" "$body"
check "frontier falls back within its own class" '{"frontier": ["frontier-light"]}' "$body"
absent "frontier must never fall back to cheap" '{"frontier": ["cheap"]}' "$body"
absent "cheap has no live fallback target here" '{"cheap": ["local"]}' "$body"

# --- The composed document is valid YAML with a model_list. ---
python3 - "$CONFIG" <<'PY' || { echo "FAIL: composed config is not valid YAML"; fail=1; }
import sys
try:
    import yaml
except ImportError:
    print("  (pyyaml absent — skipped the parse assertion)")
    sys.exit(0)
doc = yaml.safe_load(open(sys.argv[1]))
assert [m["model_name"] for m in doc["model_list"]], doc
assert doc["general_settings"]["master_key"] == "os.environ/LITELLM_MASTER_KEY", doc
PY

# --- The master key is minted 0600 and never lands in the repo. ---
mode="$(stat -c %a "$TMP/home/master.key" 2>/dev/null || stat -f %Lp "$TMP/home/master.key")"
[ "$mode" = "600" ] || { echo "FAIL (master key): mode $mode, want 600"; fail=1; }

# --- `--allow-missing` takes a comma list too. ---
out="$("$UP" --dry-run --allow-missing=local 2>&1)"; rc=$?
[ "$rc" = 0 ] || { echo "FAIL (--allow-missing=): exit $rc"; echo "$out"; fail=1; }

# --- An unknown argument is refused rather than ignored. ---
rc=0; "$UP" --wat >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL (unknown arg): exit $rc, want 2"; fail=1; }

# --- litellm absent: say how to install it, don't fail obscurely. ---
out="$(PATH="/usr/bin:/bin" "$UP" --dry-run 2>&1)"; rc=$?
[ "$rc" != 0 ] || { echo "FAIL (no litellm): exited 0"; fail=1; }
check "no litellm" "uv tool install" "$out"

# --- down/status with nothing running. ---
check "down when stopped" "not running" "$("$DOWN" 2>&1)"
out="$("$STATUS" 2>&1)"; rc=$?
[ "$rc" != 0 ] || { echo "FAIL (status when down): exited 0"; fail=1; }
check "status when down" "gateway: DOWN" "$out"
check "status lists per-class readiness" "✓ cheap" "$out"
check "status names what blocks a class" "no server answering at" "$out"
rc=0; "$STATUS" --quiet >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || { echo "FAIL (status --quiet when down): exit $rc, want 1"; fail=1; }

# --- A stale PID file must not wedge a restart, and must never name a
#     recycled PID as the gateway (or gateway-down would kill a stranger). ---
sleep 300 &
stranger=$!
echo "$stranger" > "$TMP/home/gateway.pid"
check "stale pid belonging to another process" "not running" "$("$DOWN" 2>&1)"
kill -0 "$stranger" 2>/dev/null || { echo "FAIL (stale pid): gateway-down killed an unrelated process"; fail=1; }
kill "$stranger" 2>/dev/null || true
[ -e "$TMP/home/gateway.pid" ] && { echo "FAIL (stale pid): file not cleared"; fail=1; }

echo '99999999' > "$TMP/home/gateway.pid"
out="$("$UP" --dry-run --allow-missing local 2>&1)"; rc=$?
[ "$rc" = 0 ] || { echo "FAIL (stale pid blocks restart): exit $rc"; echo "$out"; fail=1; }

# --- Double-start refusal, against a process that really is ours. ---
"$TMP/bin/litellm" --config x >/dev/null 2>&1 &
ours=$!
echo "$ours" > "$TMP/home/gateway.pid"
out="$("$UP" --allow-missing local 2>&1)"; rc=$?
check "double start" "already running" "$out"
[ "$rc" = 0 ] || { echo "FAIL (double start): exit $rc, want 0"; fail=1; }
kill -0 "$ours" 2>/dev/null || { echo "FAIL (double start): the running proxy was disturbed"; fail=1; }
check "down stops our own process" "stopped (pid $ours)" "$("$DOWN" 2>&1)"
sleep 0.5
kill -0 "$ours" 2>/dev/null && { echo "FAIL (down): process survived"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "gateway: all cases passed"
fi
exit "$fail"
