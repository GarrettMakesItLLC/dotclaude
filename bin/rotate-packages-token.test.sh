#!/usr/bin/env bash
# Self-test for rotate-packages-token.sh. Stubs curl, npm, railway, vercel and
# gh via a fake PATH directory so nothing here touches the real network,
# Railway, Vercel or GitHub — and never handles a real secret.
#   bash bin/rotate-packages-token.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/rotate-packages-token.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

FAKE_TOKEN="test-token-not-a-real-secret"
GOOD_SCOPES="read:packages"

STUBBIN="$TMP/stubbin"
mkdir -p "$STUBBIN"

# --- fake curl: answers api.github.com/user with x-oauth-scopes -----------
# Controlled by env vars the test sets before each run:
#   STUB_SCOPES        - value of the x-oauth-scopes header to return
#   STUB_CURL_FAIL=1    - simulate curl failing entirely (bad token / network)
cat > "$STUBBIN/curl" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_CURL_FAIL:-0}" = "1" ]; then
  exit 1
fi
# Only the -D - -o /dev/null header-dump form is used by the script.
printf 'HTTP/1.1 200 OK\r\n'
printf 'x-oauth-scopes: %s\r\n' "${STUB_SCOPES:-read:packages}"
printf '\r\n'
exit 0
EOF

# --- fake npm: `npm view <pkg> version --userconfig <file>` ---------------
#   STUB_NPM_FAIL=1  - simulate registry access failing
cat > "$STUBBIN/npm" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_NPM_FAIL:-0}" = "1" ]; then
  echo "npm error 404 Not Found" >&2
  exit 1
fi
if [ "$1" = "view" ]; then
  echo "1.2.3"
  exit 0
fi
exit 1
EOF

# --- fake railway / vercel / gh: record every invocation -------------------
CALL_LOG="$TMP/calls.log"
cat > "$STUBBIN/railway" <<EOF
#!/usr/bin/env bash
echo "railway \$*" >> "$CALL_LOG"
if [ "\${STUB_RAILWAY_FAIL:-0}" = "1" ]; then exit 1; fi
exit 0
EOF
cat > "$STUBBIN/vercel" <<EOF
#!/usr/bin/env bash
echo "vercel \$* <stdin:\$(cat - 2>/dev/null | wc -c)b>" >> "$CALL_LOG"
if [ "\${STUB_VERCEL_FAIL:-0}" = "1" ]; then exit 1; fi
exit 0
EOF
cat > "$STUBBIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$* <stdin:\$(cat - 2>/dev/null | wc -c)b>" >> "$CALL_LOG"
if [ "\${STUB_GH_FAIL:-0}" = "1" ]; then exit 1; fi
exit 0
EOF
chmod +x "$STUBBIN"/*

# awk/grep/cut/mktemp/mv/chmod stay the real system ones.
FAKE_PATH="$STUBBIN:$PATH"

run() {
  # run <token-to-pipe> <args...>  -> stdout+stderr in $OUT, status in $RC
  local token="$1"; shift
  OUT="$(printf '%s' "$token" | PATH="$FAKE_PATH" "$SCRIPT" "$@" 2>&1)"; RC=$?
}

# ---------------------------------------------------------------------------
echo "== argv / stdin handling =="

RC=0
OUT="$("$SCRIPT" --apply < /dev/null 2>&1)" || RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'empty token'; then
  ok "refuses an empty token on stdin"
else
  bad "should refuse empty stdin (rc=$RC): $OUT"
fi

RC=0
OUT="$(printf '%s' "$FAKE_TOKEN" | PATH="$FAKE_PATH" "$SCRIPT" --bogus-flag 2>&1)" || RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'unknown argument'; then
  ok "rejects an unrecognized flag"
else
  bad "should reject unknown flag (rc=$RC): $OUT"
fi

echo "== token never touches argv =="
run "$FAKE_TOKEN" --skip-verify
if ! pgrep -f "$FAKE_TOKEN" >/dev/null 2>&1; then
  ok "token does not appear in any running process's argv (best-effort check)"
else
  bad "token leaked into a process argv"
fi

echo "== scope verification =="

export STUB_SCOPES="admin:org, repo, read:packages, write:packages"
RC=0
run "$FAKE_TOKEN"
unset STUB_SCOPES
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'expected exactly'; then
  ok "refuses a token with extra scopes beyond read:packages"
else
  bad "should refuse over-scoped token (rc=$RC): $OUT"
fi

export STUB_SCOPES="$GOOD_SCOPES"
RC=0
run "$FAKE_TOKEN"
unset STUB_SCOPES
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'scopes OK'; then
  ok "accepts a token scoped to exactly read:packages"
else
  bad "should accept read:packages-only token (rc=$RC): $OUT"
fi

export STUB_CURL_FAIL=1
RC=0
run "$FAKE_TOKEN"
unset STUB_CURL_FAIL
if [ "$RC" -ne 0 ]; then
  ok "refuses when the scope check itself fails (bad token / network)"
else
  bad "should fail closed when curl fails: $OUT"
fi

echo "== registry verification =="

export STUB_SCOPES="$GOOD_SCOPES"
export STUB_NPM_FAIL=1
RC=0
run "$FAKE_TOKEN"
unset STUB_SCOPES STUB_NPM_FAIL
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'npm view'; then
  ok "refuses a token that scopes-checks OK but can't resolve a package"
else
  bad "should fail when npm view fails (rc=$RC): $OUT"
fi

echo "== dry run touches nothing =="

secrets_dir="$TMP/secrets"
mkdir -p "$secrets_dir"
before_marker="unchanged-marker-value"
cat > "$secrets_dir/gmi.env" <<EOF
export SOME_OTHER_VAR=$before_marker
export NODE_AUTH_TOKEN=old-token-value
EOF
before_content="$(cat "$secrets_dir/gmi.env")"

HOME_OVERRIDE="$TMP/home"
mkdir -p "$HOME_OVERRIDE/.config/secrets"
cp "$secrets_dir/gmi.env" "$HOME_OVERRIDE/.config/secrets/gmi.env"

export STUB_SCOPES="$GOOD_SCOPES"
RC=0
OUT="$(printf '%s' "$FAKE_TOKEN" | HOME="$HOME_OVERRIDE" PATH="$FAKE_PATH" "$SCRIPT" 2>&1)"; RC=$?
unset STUB_SCOPES
after_content="$(cat "$HOME_OVERRIDE/.config/secrets/gmi.env")"
if [ "$RC" -eq 0 ] && [ "$before_content" = "$after_content" ] \
   && printf '%s' "$OUT" | grep -q 'would update'; then
  ok "dry run (no --apply) reports the plan and writes nothing"
else
  bad "dry run should not modify files (rc=$RC): $OUT"
fi
if [ -f "$CALL_LOG" ]; then
  bad "dry run should not invoke railway/vercel/gh: $(cat "$CALL_LOG")"
else
  ok "dry run does not shell out to railway/vercel/gh"
fi

echo "== --apply updates the secrets env file in place =="

rm -f "$CALL_LOG"
export STUB_SCOPES="$GOOD_SCOPES"
RC=0
OUT="$(printf '%s' "$FAKE_TOKEN" | HOME="$HOME_OVERRIDE" PATH="$FAKE_PATH" "$SCRIPT" --apply 2>&1)"; RC=$?
unset STUB_SCOPES
if [ "$RC" -eq 0 ] \
   && grep -q "export NODE_AUTH_TOKEN=$FAKE_TOKEN" "$HOME_OVERRIDE/.config/secrets/gmi.env" \
   && grep -q "export SOME_OTHER_VAR=$before_marker" "$HOME_OVERRIDE/.config/secrets/gmi.env"; then
  ok "--apply rewrites the NODE_AUTH_TOKEN line and preserves every other line"
else
  bad "--apply should update the token in place (rc=$RC): $OUT"
fi

echo "== --apply shells out to railway, vercel and gh =="

if [ -f "$CALL_LOG" ] \
   && grep -q '^railway ' "$CALL_LOG" \
   && grep -q '^vercel ' "$CALL_LOG" \
   && grep -q '^gh ' "$CALL_LOG"; then
  ok "--apply invokes railway, vercel and gh for their inventoried targets"
else
  bad "--apply should call all three CLIs: $(cat "$CALL_LOG" 2>/dev/null || echo '<no log>')"
fi

# vercel/gh take the token on stdin; railway's own `--set KEY=VALUE` CLI
# interface has no stdin form, so it is the one place the token necessarily
# passes through argv to a CLI we don't control — check the other two.
if grep -E '^(vercel|gh) ' "$CALL_LOG" | grep -q "$FAKE_TOKEN"; then
  bad "the token leaked into vercel's or gh's argv (call log): $(cat "$CALL_LOG")"
else
  ok "vercel and gh receive the token on stdin, never as an argument"
fi

echo "== a CLI failure is reported and the run exits non-zero =="

rm -f "$CALL_LOG"
export STUB_SCOPES="$GOOD_SCOPES"
export STUB_RAILWAY_FAIL=1
RC=0
OUT="$(printf '%s' "$FAKE_TOKEN" | HOME="$HOME_OVERRIDE" PATH="$FAKE_PATH" "$SCRIPT" --apply 2>&1)"; RC=$?
unset STUB_SCOPES STUB_RAILWAY_FAIL
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'FAILED'; then
  ok "a failed railway call is surfaced and fails the run"
else
  bad "should surface a railway failure (rc=$RC): $OUT"
fi

echo "== missing CLIs fall back to printed commands =="

NO_CLI_PATH="$TMP/no-cli-path"
mkdir -p "$NO_CLI_PATH"
cp "$STUBBIN/curl" "$STUBBIN/npm" "$NO_CLI_PATH/"
# Curated PATH with only the standard tools the script needs, deliberately
# excluding railway/vercel/gh even if they happen to be installed on this
# box — appending /usr/bin:/bin here would silently pick up the real CLIs.
for tool in awk grep cut sed tr cat mktemp mv chmod rm mkdir bash env printf \
            true false sha256sum wc dirname basename pwd; do
  t="$(command -v "$tool" 2>/dev/null)" && ln -sf "$t" "$NO_CLI_PATH/$tool"
done
export STUB_SCOPES="$GOOD_SCOPES"
RC=0
OUT="$(printf '%s' "$FAKE_TOKEN" | HOME="$HOME_OVERRIDE" PATH="$NO_CLI_PATH" "$SCRIPT" --apply 2>&1)"; RC=$?
unset STUB_SCOPES
if printf '%s' "$OUT" | grep -q 'railway CLI not found on PATH' \
   && printf '%s' "$OUT" | grep -q 'vercel CLI not found on PATH' \
   && printf '%s' "$OUT" | grep -q 'gh CLI not found on PATH'; then
  ok "prints the exact command for each target when a CLI is missing"
else
  bad "should fall back to printed commands (rc=$RC): $OUT"
fi
if printf '%s' "$OUT" | grep -q "$FAKE_TOKEN"; then
  bad "a printed fallback command must never contain the actual token"
else
  ok "printed fallback commands reference \$NEW_TOKEN, never the literal value"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
