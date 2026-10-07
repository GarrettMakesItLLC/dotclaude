#!/usr/bin/env bash
# Self-test for credential-output-guard.sh. Feeds PostToolUse Bash results
# through the hook and asserts on the JSON it prints: credential-shaped output
# is redacted and reported, everything else passes through with no output.
#
# Every credential below is FAKE: built from repeated filler at runtime, so no
# string in this file is a usable (or scanner-tripping) secret.
#   bash hooks/credential-output-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/credential-output-guard.sh"
FAIL_MARKER="$(mktemp)"
trap 'rm -f "$FAIL_MARKER"' EXIT
fail() { echo "FAIL: $1"; echo x >>"$FAIL_MARKER"; }

rep() { printf "%${2}s" '' | tr ' ' "$1"; }
FAKE_PW="Fake$(rep Q 16)"
FAKE_GH="ghp_$(rep A 36)"
FAKE_ANT="sk-ant-api03-$(rep B 40)"
FAKE_STRIPE="sk_live_$(rep C 24)"
FAKE_GOOGLE="AIza$(rep D 35)"
FAKE_PAT="github_pat_$(rep E 30)"
FAKE_SBP="sbp_$(rep a 40)"
FAKE_AWS="AKIA$(rep F 16)"
FAKE_VAL="fakevalue$(rep G 20)"

# An isolated HOME with a synthetic secrets file, so the guard's live-value
# lookup never touches the real one. FAKE_LIVE is deliberately fixture-shaped
# (all-lowercase words), so only the live-value match can flag it.
FAKE_HOME="$(mktemp -d)"
trap 'rm -f "$FAIL_MARKER"; rm -rf "$FAKE_HOME"' EXIT
FAKE_LIVE="live-secret-words"
mkdir -p "$FAKE_HOME/.config/secrets"
printf 'NODE_AUTH_TOKEN=%s\n' "$FAKE_LIVE" >"$FAKE_HOME/.config/secrets/fake.env"
export HOME="$FAKE_HOME"

# run <stdout> [stderr] — prints the hook's JSON (empty when it passes).
run() {
  python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": "some-command --flag"},
  "tool_response": {"stdout": sys.argv[1], "stderr": sys.argv[2], "interrupted": False, "isImage": False}}))
' "$1" "${2:-}" | "$GUARD"
}
field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

# must_redact <label> <stdout> <leaked-substring> <expected-in-report>
must_redact() {
  local out
  out="$(run "$2")"
  if [ -z "$out" ]; then fail "$1: no report"; return; fi
  local stdout ctx sys
  stdout="$(field 'd["hookSpecificOutput"]["updatedToolOutput"]["stdout"]' <<<"$out")"
  ctx="$(field 'd["hookSpecificOutput"]["additionalContext"]' <<<"$out")"
  sys="$(field 'd["systemMessage"]' <<<"$out")"
  grep -qF -- "$3" <<<"$stdout" && fail "$1: value survived redaction"
  grep -qF -- "$3" <<<"$ctx$sys" && fail "$1: value repeated in the warning"
  grep -qF -- "<redacted>" <<<"$stdout" || fail "$1: no <redacted> marker"
  grep -qF -- "$4" <<<"$ctx" || fail "$1: report does not name '$4': $ctx"
  grep -q 'CREDENTIAL LEAK' <<<"$sys" || fail "$1: no loud systemMessage"
}
must_pass() {
  local out
  out="$(run "$2")"
  [ -z "$out" ] || fail "$1: flagged clean output: $out"
}

must_redact "postgres URL" "postgresql://postgres.abc:${FAKE_PW}@aws-0-us-east-1.pooler.supabase.com:5432/postgres" "$FAKE_PW" "postgresql password for postgres.abc@aws-0-us-east-1.pooler.supabase.com"
must_redact "postgres scheme" "DATABASE: postgres://u:${FAKE_PW}@db.example.internal/x" "$FAKE_PW" "postgres password"
must_redact "GitHub token" "token: $FAKE_GH" "$FAKE_GH" "a GitHub token"
must_redact "Anthropic key" "$FAKE_ANT" "$FAKE_ANT" "an Anthropic API key"
must_redact "Stripe key" "$FAKE_STRIPE" "$FAKE_STRIPE" "a Stripe live key"
must_redact "Google key" "key=$FAKE_GOOGLE" "$FAKE_GOOGLE" "a Google API key"
must_redact "fine-grained PAT" "$FAKE_PAT" "$FAKE_PAT" "fine-grained"
must_redact "Supabase PAT" "$FAKE_SBP" "$FAKE_SBP" "Supabase access token"
must_redact "AWS key id" "$FAKE_AWS" "$FAKE_AWS" "AWS access key id"
must_redact "KEY=value line" "$(printf 'PORT=3000\nNODE_AUTH_TOKEN=%s\nNEXT_PUBLIC_X=1' "$FAKE_VAL")" "$FAKE_VAL" "the value of NODE_AUTH_TOKEN"
must_redact "export line" "export STRIPE_SECRET_KEY='$FAKE_VAL'" "$FAKE_VAL" "the value of STRIPE_SECRET_KEY"
must_redact "railway --kv" "RESEND_API_KEY=$FAKE_VAL" "$FAKE_VAL" "RESEND_API_KEY"
must_redact "JSON pair" "{\"SUPABASE_SERVICE_ROLE_KEY\": \"$FAKE_VAL\", \"PORT\": \"3000\"}" "$FAKE_VAL" "SUPABASE_SERVICE_ROLE_KEY"

# A value equal to a live credential is reported even when fixture-shaped.
must_redact "live value from a secrets file" "NODE_AUTH_TOKEN=$FAKE_LIVE" "$FAKE_LIVE" "the value of NODE_AUTH_TOKEN"

# Other lines and fields survive, and stderr is scanned too.
out="$(run "$(printf 'line one\nNODE_AUTH_TOKEN=%s\nline three' "$FAKE_VAL")" "err: $FAKE_GH")"
so="$(field 'd["hookSpecificOutput"]["updatedToolOutput"]["stdout"]' <<<"$out")"
se="$(field 'd["hookSpecificOutput"]["updatedToolOutput"]["stderr"]' <<<"$out")"
im="$(field 'd["hookSpecificOutput"]["updatedToolOutput"]["isImage"]' <<<"$out")"
grep -q '^line one$' <<<"$so" && grep -q '^line three$' <<<"$so" || fail "surrounding lines lost: $so"
grep -qF "$FAKE_GH" <<<"$se" && fail "stderr not redacted"
[ "$im" = False ] || fail "the tool's other fields were not carried over: isImage=$im"

# Clean output, name-only listings, redacted forms and placeholders pass untouched.
must_pass "plain output" "added 412 packages in 9s"
must_pass "name-only listing" "$(printf 'export NODE_AUTH_TOKEN=\nexport GITHUB_TOKEN=')"
must_pass "sed-redacted env" "$(printf 'NODE_AUTH_TOKEN=<redacted>\nDATABASE_URL=<redacted>')"
must_pass "redacted URL" "postgresql://postgres.abc:<redacted>@host:5432/postgres"
must_pass "URL without password" "postgresql://localhost:5432/dev"
must_pass "expansion in a script" 'NODE_AUTH_TOKEN=$(gh auth token) npm ci'
must_pass "placeholder" "API_KEY=your-api-key-here"
must_pass "short value" "TOKEN_TTL=3600"
must_pass "code" 'GITHUB_TOKEN=process.env.GITHUB_TOKEN ?? ""'
must_pass "non-secret name" "NEXT_PUBLIC_SITE_URL=https://example.org/some/long/path"
must_pass "prefix only" "ghp_"
# Fixtures and sentinels in source code are not credentials (#505).
must_pass "fixture ghp_good" "export NODE_AUTH_TOKEN=ghp_good"
must_pass "fixture ghp_bad" "NODE_AUTH_TOKEN=ghp_bad"
must_pass "sentinel" "token='inline-expansion'"
must_pass "sentinel unquoted" "token=inline-expansion"
# A name-mapping file (a repo config) holds variable NAMES, not values (#496).
must_pass "name mapping JSON" '{"credentials": {"namespaced": {"RT_DATABASE_URL": "DATABASE_URL", "RT_DIRECT_URL": "DIRECT_URL"}}}'
must_pass "name mapping env" "$(printf 'RT_DATABASE_URL=DATABASE_URL\nSERVICE_TOKEN=GITHUB_TOKEN_VALUE')"

# Fail open on garbage and on other tools.
printf 'not json' | "$GUARD" >/dev/null 2>&1 || fail "garbage input did not fail open"
out="$(printf '%s' '{"tool_name":"Read","tool_response":"x"}' | "$GUARD")"
[ -z "$out" ] || fail "a non-Bash tool was scanned"

if [ -s "$FAIL_MARKER" ]; then
  echo "credential-output-guard: $(wc -l <"$FAIL_MARKER") case(s) FAILED"
  exit 1
fi
echo "credential-output-guard: all cases passed"
