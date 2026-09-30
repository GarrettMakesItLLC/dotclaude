#!/usr/bin/env bash
# dotclaude credential-output-guard — PostToolUse hook (matcher: Bash).
#
# secret-read-guard.sh refuses the commands KNOWN to print a credential before
# they run. This is the net under it: after any Bash call, the result is scanned
# for credential-shaped text, and when it holds some the hook
#   - REDACTS it (`updatedToolOutput`), so Claude never sees the value, and
#   - says so LOUDLY: a `systemMessage` to the user and `additionalContext`
#     telling Claude to report the leak at once, naming what leaked (never the
#     value), so the credential is rotated rather than quietly carried on past.
#
# Redaction only changes what Claude sees. The command already ran, and the
# harness's own telemetry captured the raw output first — which is why the
# warning says to treat the credential as leaked.
#
# Credential-shaped means:
#   - a URL with a non-empty password: postgres(ql)/mysql/mariadb/mongodb/
#     redis/amqp `scheme://user:pass@host`;
#   - a token with a known prefix: sk-ant-, sk_live_/rk_live_, AIza, ghp_/gho_/
#     ghs_/ghu_/ghr_, github_pat_, sbp_, AKIA, or a PEM private-key header;
#   - `NAME=value` (env-file / `railway variables --kv` shape) or
#     `"NAME": "value"` (JSON) where NAME is a credential name (…TOKEN, …SECRET,
#     …PASSWORD, …API_KEY, DATABASE_URL, …) and the value looks real: at least
#     8 characters, no whitespace, not an expansion, not a placeholder.
#
# Fail-open: anything it cannot parse passes through unchanged.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"
INPUT_JSON="$input" python3 - <<'PY' 2>/dev/null
import json, os, re, sys

try:
    obj = json.loads(os.environ.get("INPUT_JSON", ""))
except Exception:
    sys.exit(0)
if obj.get("tool_name") != "Bash":
    sys.exit(0)
resp = obj.get("tool_response")
if resp is None:
    sys.exit(0)

URL = re.compile(
    r"\b((?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|rediss?|amqps?)://)"
    r"([^:/?#@\s]+):([^@\s/]+)@([^/\s:?#]*)"
)
TOKENS = [
    ("an Anthropic API key", re.compile(r"sk-ant-[A-Za-z0-9_\-]{20,}")),
    ("a Stripe live key", re.compile(r"\b[sr]k_live_[A-Za-z0-9]{16,}")),
    ("a Google API key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}")),
    ("a GitHub token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}")),
    ("a GitHub fine-grained token", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{22,}")),
    ("a Supabase access token", re.compile(r"\bsbp_[a-f0-9]{40}")),
    ("an AWS access key id", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("a private key", re.compile(r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----")),
]
SECRET_NAME = re.compile(
    r"(SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|PRIVATE_KEY|SERVICE_ROLE|"
    r"ACCESS_KEY|DATABASE_URL|DB_URL|DIRECT_URL|CONNECTION_STRING|DSN|CREDENTIAL)",
    re.I,
)
KV_LINE = re.compile(r"(?m)^([ \t]*(?:export[ \t]+)?)([A-Za-z_][A-Za-z0-9_]*)=([^\n]*)$")
KV_JSON = re.compile(r"\"([A-Za-z_][A-Za-z0-9_]*)\"\s*:\s*\"((?:[^\"\\]|\\.)*)\"")
PLACEHOLDER = re.compile(r"redacted|\*\*\*|xxxx|changeme|change-me|your[_-]|placeholder|example|\.\.\.|…", re.I)


def placeholder(v):
    return (not v or v.startswith(("$", "<", "%", "{")) or PLACEHOLDER.search(v)
            or len(set(v)) == 1)


def real_value(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    if len(v) < 8 or re.search(r"\s", v) or re.search(r"[()\[\]{}$`]", v):
        return False
    return not placeholder(v)


def scan(text, found):
    def url(m):
        if placeholder(m.group(3)):
            return m.group(0)
        found.append("a %s password for %s@%s" % (m.group(1).rstrip(":/"), m.group(2), m.group(4) or "?"))
        return "%s%s:<redacted>@%s" % (m.group(1), m.group(2), m.group(4))
    text = URL.sub(url, text)

    for label, pat in TOKENS:
        def tok(m, label=label):
            found.append(label)
            return "<redacted>"
        text = pat.sub(tok, text)

    def kv(m):
        lead, name, val = m.group(1), m.group(2), m.group(3)
        if not SECRET_NAME.search(name) or not real_value(val):
            return m.group(0)
        found.append("the value of %s" % name)
        return "%s%s=<redacted>" % (lead, name)
    text = KV_LINE.sub(kv, text)

    def kj(m):
        name, val = m.group(1), m.group(2)
        if not SECRET_NAME.search(name) or not real_value(val):
            return m.group(0)
        found.append("the value of %s" % name)
        return "\"%s\": \"<redacted>\"" % name
    text = KV_JSON.sub(kj, text)
    return text


found = []
if isinstance(resp, dict):
    updated = dict(resp)
    for key in ("stdout", "stderr"):
        if isinstance(resp.get(key), str):
            updated[key] = scan(resp[key], found)
elif isinstance(resp, str):
    updated = scan(resp, found)
else:
    sys.exit(0)

if not found:
    sys.exit(0)

what = "; ".join(dict.fromkeys(found))
cmd = (obj.get("tool_input") or {}).get("command", "") or ""
cmd_line = cmd.strip().splitlines()[0][:160] if cmd.strip() else "(unknown)"
print(json.dumps({
    "systemMessage": (
        "⚠ CREDENTIAL LEAK: a Bash result carried %s. It was redacted before Claude saw it, "
        "but the command already printed it — treat it as leaked and rotate it. Command: %s"
        % (what, cmd_line)
    ),
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": (
            "⚠ CREDENTIAL LEAK (dotclaude credential-output-guard): this command's output contained %s. "
            "The value was redacted from the result you see, but it was printed and captured before "
            "redaction, so it must be treated as leaked. Tell the user NOW, in your next message, which "
            "credential leaked and that it needs rotating — do not wait for the end of the task. Do not "
            "re-run the command to look at the value. Capture a credential with $(...) or redirect it to a "
            "file, and inspect it with sed 's/:[^:@]*@/:<redacted>@/' or sed 's/=.*/=<redacted>/'."
            % what
        ),
        "updatedToolOutput": updated,
    },
}))
PY
exit 0
