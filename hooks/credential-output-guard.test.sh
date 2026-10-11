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
printf 'NODE_AUTH_TOKEN=%s\nALIAS_DATABASE_URL=DATABASE_URL\n' "$FAKE_LIVE" >"$FAKE_HOME/.config/secrets/fake.env"
# A live secret-named variable whose value is itself a variable NAME (#484, #494).
export ALIAS_DIRECT_URL=DIRECT_URL
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

# A dict repr / object literal pairs a quoted value with its key anywhere on a
# line (#478): an App Store Connect attributes dict printed with `print(a)`.
must_redact "Python dict repr" "{'contactEmail': 'r@example.org', 'demoAccountName': 'reviewer', 'demoAccountPassword': '$FAKE_VAL', 'demoAccountRequired': True}" "$FAKE_VAL" "the value of demoAccountPassword"
must_redact "JS object literal" "const login = { user: 'r', password: \"$FAKE_VAL\" };" "$FAKE_VAL" "the value of password"
must_pass "dict repr, non-secret keys" "{'contactEmail': 'r@example.org', 'demoAccountRequired': True}"
must_pass "dict repr, placeholder" "{'demoAccountPassword': 'your-password-here'}"
# #478's false positive: a name mapping in a repo manifest.
must_pass "repo.json name mapping" '{"MB_PROD_DATABASE_URL": "DATABASE_URL", "MB_PROD_DIRECT_URL": "DIRECT_URL"}'
# A JSON response cut mid-value still prints the secret's prefix (#479).
must_redact "truncated jwt_secret" "{\"db_schema\":\"public\",\"jwt_secret\":\"$FAKE_VAL" "$FAKE_VAL" "the value of jwt_secret"
must_redact "smtp_pass" "{\"smtp_pass\":\"$FAKE_VAL\",\"smtp_port\":\"587\"}" "$FAKE_VAL" "the value of smtp_pass"
# A short hex digest fingerprint is not a secret (#479).
must_pass "hex fingerprint" '{"external_apple_secret":"3f9a1c2b7d4e"}'
must_pass "pass-through name" '{"bypass_cache":"enabled-for-all-routes"}'
# The same map when a live variable or a secrets-file entry holds that name as
# its value: a name is never a credential (#481, #483, #484, #487, #494).
must_pass "name mapping vs live names" '{"ADVOS_DATABASE_URL": "DATABASE_URL", "ADVOS_DIRECT_URL": "DIRECT_URL"}'
must_pass "name mapping env vs live names" "$(printf 'X_DATABASE_URL=DATABASE_URL\nX_DIRECT_URL=DIRECT_URL')"

# A URL to a host reserved for testing is a fixture (#481), unless its password
# is a live credential.
must_pass "example.com fixture URL" "postgresql://postgres.sandboxref:${FAKE_PW}@pooler.example.com:6543/postgres"
must_pass ".test fixture URL" "redis://default:${FAKE_PW}@cache.test:6379"
must_pass ".invalid fixture URL" "postgres://u:${FAKE_PW}@db.internal.invalid/x"
must_redact "live password on a fixture host" "postgresql://u:${FAKE_LIVE}@db.example.com/x" "$FAKE_LIVE" "postgresql password"
must_redact "example-ish real host" "postgresql://u:${FAKE_PW}@example.com.attacker.net/x" "$FAKE_PW" "postgresql password"

# Private-key bodies. FAKE_* bodies are a key's fixed DER prefix (structure, not
# key material) followed by filler.
B64LINE="$(rep A 64)"
FAKE_EC_BODY="MIGTAgEAMBMGByqGSM49$(rep B 44)"
FAKE_RSA_BODY="MIIEvQIBADANBgkqhkiG9w0BAQEFAASC$(rep C 32)"
must_redact "PEM block" "$(printf 'APPLE_KEY=-----BEGIN PRIVATE KEY-----\n%s\n%s\nQUJD\n-----END PRIVATE KEY-----\nnext' "$FAKE_RSA_BODY" "$B64LINE")" "$B64LINE" "a private key"
out="$(run "$(printf -- '-----BEGIN EC PRIVATE KEY-----\n%s\nQUJDRA==\n-----END EC PRIVATE KEY-----\nafter the key' "$B64LINE")")"
so="$(field 'd["hookSpecificOutput"]["updatedToolOutput"]["stdout"]' <<<"$out")"
grep -q 'QUJDRA==' <<<"$so" && fail "a key's short last line survived"
grep -q '^after the key$' <<<"$so" || fail "the line after the key was lost: $so"
# The header was grep'd away (#478): bare body lines, the first with the prefix.
must_redact "header-less EC body" "$(printf '%s\n%s\n%s' "$FAKE_EC_BODY" "$B64LINE" "$B64LINE")" "$B64LINE" "a private key"
must_redact "header-less RSA body" "$FAKE_RSA_BODY" "$FAKE_RSA_BODY" "a private key"
must_redact "SEC1 P-384 body" "MIGkAgEBBDB$(rep G 53)" "$(rep G 53)" "a private key"
must_redact "openssh body" "b3BlbnNzaC1rZXktdjE$(rep D 50)" "$(rep D 50)" "a private key"
# A sourced `railway variables --kv` dump (#509): bash echoes each line of a
# multi-line PEM value as a command it could not find.
must_redact "sourced PEM value" "$(printf '/tmp/kv.env: line 7: PRIVATE: command not found\n/tmp/kv.env: line 8: %s: command not found\n/tmp/kv.env: line 9: %s: command not found\n/tmp/kv.env: line 10: -----END: command not found' "$FAKE_EC_BODY" "$B64LINE")" "$B64LINE" "a private key"
out="$(run "" "$(printf '/tmp/kv.env: line 8: %s: command not found\n/tmp/kv.env: line 9: %s: No such file or directory' "$FAKE_EC_BODY" "$B64LINE")")"
se="$(field 'd["hookSpecificOutput"]["updatedToolOutput"]["stderr"]' <<<"$out" 2>/dev/null)"
[ -n "$se" ] && ! grep -qF "$B64LINE" <<<"$se" || fail "a sourced PEM value on stderr was not redacted: ${se:-no report}"
# A JSON one-liner with escaped newlines (a service-account file).
must_redact "PEM in JSON" "{\"private_key\": \"-----BEGIN PRIVATE KEY-----\\\\n${B64LINE}\\\\n-----END PRIVATE KEY-----\\\\n\"}" "$B64LINE" "a private key"
# A header alone is prose, not a key; certificates and public keys are public.
must_pass "PEM header in prose" "detect the \`-----BEGIN PRIVATE KEY-----\` header, then the body"
must_pass "certificate body" "$(printf -- '-----BEGIN CERTIFICATE-----\nMIIC+TCCAeGgAwIBAgIU%s\n-----END CERTIFICATE-----' "$(rep E 40)")"
must_pass "public key body" "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB$(rep F 40)"
must_pass "long hash" "sha256 $(rep 0 64) package.tgz"

# Value shape, not name (#547, #548, #552, #554, #555): source constants that
# NAME a credential but hold a path, a public endpoint or an identifier.
must_pass "TOKEN_PATH url path (#547)" "export const ADVENTUREOS_TOKEN_PATH = '/oauth/token';"
must_pass "TOKEN_PATH in a diff (#547)" "+export const ADVENTUREOS_TOKEN_PATH = '/api/v1/partner/oauth/token'"
must_pass "FCM_TOKEN_URL public endpoint (#548)" "const FCM_TOKEN_URL = 'https://oauth2.googleapis.com/token';"
must_pass "token_uri in a service account shape (#548)" "const TOKEN_URL = 'https://login.microsoftonline.com/common/oauth2/v2.0/token';"
must_pass "tokens option with a short path (#552)" "      tokens: 'design/tokens',"
must_pass "tokens option, relative module (#552)" "tokens: './tokens',"
must_pass "API_KEY_MINT_PERMISSION (#554)" "export const API_KEY_MINT_PERMISSION = 'admin:manage';"
must_pass "ACCESS_TOKEN_AUDIENCE (#555)" "const ACCESS_TOKEN_AUDIENCE = 'authenticated';"
must_pass "FCM_TOKEN test constant (#555)" "const FCM_TOKEN = 'fcm-token-1';"
must_pass "descriptor name, non-word value" "const TOKEN_PATH = 'Ab3dE9fGh2Jk8LmN0pQr'"
must_pass "pooler fixture, short lowercase password (#555)" "postgres://postgres.short:short@x.pooler.supabase.com:5432/postgres"
# ...and the same shapes with a secret in them still redact.
must_redact "token with a webhook-shaped URL" "SLACK_TOKEN_URL=https://hooks.slack.com/services/T0123ABCD/B0456EFGH/${FAKE_VAL}" "$FAKE_VAL" "SLACK_TOKEN_URL"
must_redact "URL value with a secret query" "const TOKEN_URL = 'https://api.partner.io/cb?token=${FAKE_VAL}'" "$FAKE_VAL" "TOKEN_URL"
must_redact "URL value with userinfo" "ACCESS_TOKEN_URL=https://user:${FAKE_VAL}@host.org/x" "$FAKE_VAL" "ACCESS_TOKEN_URL"
must_redact "path-looking base64 secret" "const API_TOKEN = '${FAKE_VAL}/${FAKE_VAL}'" "$FAKE_VAL" "API_TOKEN"
must_redact "tokens key, high-entropy value" "tokens: '$FAKE_VAL'," "$FAKE_VAL" "tokens"
must_redact "descriptor name holding a live value" "export const TOKEN_PATH = '$FAKE_LIVE'" "$FAKE_LIVE" "TOKEN_PATH"
must_redact "mixed-case password on the pooler" "postgres://postgres.abc:${FAKE_PW}@x.pooler.supabase.com:5432/postgres" "$FAKE_PW" "postgres password"

# Supabase Management API config/auth (#557): any *_secret / *_pass, any quoting.
CAPTCHA="0x4AAAAAAA$(rep Z 30)"
must_redact "security_captcha_secret JSON" "{\"security_captcha_secret\":\"$CAPTCHA\",\"site_url\":\"https://x.org\"}" "$CAPTCHA" "security_captcha_secret"
must_redact "security_captcha_secret escaped JSON" '{\"security_captcha_secret\":\"'"$CAPTCHA"'\",\"smtp_port\":\"587\"}' "$CAPTCHA" "security_captcha_secret"
must_redact "security_captcha_secret YAML" "$(printf 'site_url: https://x.org\nsecurity_captcha_secret: %s' "$CAPTCHA")" "$CAPTCHA" "security_captcha_secret"
must_redact "short smtp_pass" '{"smtp_pass":"p4ss!9"}' 'p4ss!9' "smtp_pass"
must_redact "hook secrets" '{"hook_send_sms_secrets":"v1,whsec_'"$(rep h 20)"'"}' "whsec_$(rep h 20)" "hook_send_sms_secrets"
must_redact "external client secret" "{\"external_github_secret\":\"$(rep K 3)$(rep m 20)\"}" "$(rep m 20)" "external_github_secret"
must_pass "null secret" '{"security_captcha_secret":null,"smtp_pass":""}'
must_pass "escaped placeholder" '{\"smtp_pass\":\"<redacted>\"}'
must_pass "yaml, no value" "security_captcha_secret:"

# A PEM body fragment printed by a name-extractor (#550): the guard sees no
# header and no DER prefix, only a run that is part of a stored private key.
export FAKE_PEM_PRIVATE_KEY="$(printf -- '-----BEGIN PRIVATE KEY-----\nZQXWVUTSRQPONMLKJIHGFEDCBA9876\nMNBVCXZLKJHGFDSAPOIUYTREWQ0123\n-----END PRIVATE KEY-----')"
must_redact "uppercase PEM fragment" "$(printf 'NAMES\nZQXWVUTSRQPONM\nMNBVCXZLKJHG')" "ZQXWVUTSRQPONM" "a fragment of a stored secret"
must_pass "short run is not a fragment" "ZQXWVUT"
must_pass "unrelated uppercase run" "ABCDEFGHIJKLMNOP"
unset FAKE_PEM_PRIVATE_KEY

# Serena's execute_shell_command (#519): the result is an MCP payload, replaced
# through updatedMCPToolOutput. Serena's text is the JSON of
# {stdout, return_code, cwd, stderr}; the harness hands it over either as that
# string or as a list of text content blocks.
SERENA_TEXT="$(python3 -c 'import json,sys; print(json.dumps({"stdout": sys.argv[1], "return_code": 0, "cwd": "/w", "stderr": None}))' \
  "$(printf 'line one\nDATABASE: postgresql://u:%s@db.example.internal:6543/postgres' "$FAKE_PW")")"
for shape in blocks string; do
  for tool in mcp__plugin_serena_serena__execute_shell_command mcp__serena__execute_shell_command; do
    out="$(python3 -c '
import json, sys
text = sys.argv[3]
resp = [{"type": "text", "text": text}] if sys.argv[2] == "blocks" else text
print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"command": "env | grep URL"}, "tool_response": resp}))
' "$tool" "$shape" "$SERENA_TEXT" | "$GUARD")"
    [ -n "$out" ] || { fail "$tool ($shape): no report"; continue; }
    got="$(python3 -c '
import json, sys
d = json.load(sys.stdin)["hookSpecificOutput"]
assert "updatedToolOutput" not in d, "an MCP result was replaced through the Bash field"
r = d["updatedMCPToolOutput"]
text = r[0]["text"] if isinstance(r, list) else r
assert (isinstance(r, list) and r[0]["type"] == "text") or isinstance(r, str), "shape changed"
print(json.loads(text)["stdout"])
' <<<"$out" 2>&1)" || { fail "$tool ($shape): $got"; continue; }
    grep -qF "$FAKE_PW" <<<"$got" && fail "$tool ($shape): value survived redaction"
    grep -qF 'postgresql://u:<redacted>@db.example.internal' <<<"$got" || fail "$tool ($shape): not redacted in place: $got"
    grep -q '^line one$' <<<"$got" || fail "$tool ($shape): other output lost: $got"
    grep -q 'Serena shell result' <<<"$out" || fail "$tool ($shape): warning does not name the tool"
  done
done
out="$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__serena__execute_shell_command", "tool_input": {"command": "ls"}, "tool_response": [{"type": "text", "text": "{\"stdout\": \"a.txt\", \"return_code\": 0}"}]}))' | "$GUARD")"
[ -z "$out" ] || fail "clean Serena output was flagged: $out"
out="$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__serena__read_file", "tool_response": "postgresql://u:secretvalue1@h/db"}))' | "$GUARD")"
[ -z "$out" ] || fail "a Serena tool other than the shell was scanned"

# Fail open on garbage and on other tools.
printf 'not json' | "$GUARD" >/dev/null 2>&1 || fail "garbage input did not fail open"
out="$(printf '%s' '{"tool_name":"Read","tool_response":"x"}' | "$GUARD")"
[ -z "$out" ] || fail "a non-Bash tool was scanned"

if [ -s "$FAIL_MARKER" ]; then
  echo "credential-output-guard: $(wc -l <"$FAIL_MARKER") case(s) FAILED"
  exit 1
fi
echo "credential-output-guard: all cases passed"
