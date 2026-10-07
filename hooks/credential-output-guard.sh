#!/usr/bin/env bash
# dotclaude credential-output-guard — PostToolUse hook (matcher: Bash, and
# Serena's execute_shell_command).
#
# secret-read-guard.sh refuses the commands KNOWN to print a credential before
# they run. This is the net under it: after any shell call, the result is
# scanned for credential-shaped text, and when it holds some the hook
#   - REDACTS it, so Claude never sees the value: `updatedToolOutput` for Bash's
#     `{stdout, stderr}`, `updatedMCPToolOutput` for Serena's MCP result (a
#     string, or a list of `{type: text, text}` blocks, whose text is itself the
#     JSON `{stdout, stderr, return_code, cwd}`; every string in it is scanned,
#     and JSON text is scanned field by field and re-serialised); and
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
#     ghs_/ghu_/ghr_, github_pat_, sbp_, AKIA;
#   - a private-key BODY: the base64 lines under a `-----BEGIN … PRIVATE
#     KEY-----` header, or, with no header in sight (a `grep -v =` that dropped
#     the `NAME=-----BEGIN…` line, or bash echoing each line of a sourced
#     multi-line value back as `line N: <base64>: command not found`), a run
#     that opens with a private key's fixed DER prefix (PKCS#8 RSA/EC/Ed25519,
#     PKCS#1 RSA, SEC1 EC, openssh-key-v1) and the base64 lines that follow it.
#     A header alone is not a key: prose and docs name it all the time;
#   - `NAME=value` (env-file / `railway variables --kv` shape) or a quoted
#     `"NAME": "value"` / `'name': 'value'` / `name: 'value'` pair anywhere on a
#     line (JSON, a Python dict repr, a JS object literal) where NAME is a
#     credential name (…TOKEN, …SECRET,
#     …PASSWORD, …API_KEY, DATABASE_URL, …) and the value looks real: at least
#     8 characters, no whitespace, not an expansion, not a placeholder, not a
#     bare UPPER_SNAKE variable name, and not fixture-shaped (below).
#
# A `NAME=value` match is a LEAK when the value equals a live credential: a
# secret-named environment variable, or a value in ~/.config/secrets/*.env,
# ~/.musclebuddy/*.env or ~/.redthread/*.env (read here, never printed). When it
# matches no live value it is still reported unless it is fixture-shaped: a
# known-prefix token shorter than a real one (`ghp_good`) or all-lowercase words
# joined by `-`/`_` with no digit (`inline-expansion`). Source code and test
# fixtures hold those, and a false leak report sends the owner to rotate a
# credential for nothing.
#
# Fail-open: anything it cannot parse passes through unchanged.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "⚠️  dotclaude credential-output-guard: DISABLED — python3 is not installed, so nothing was checked (bin/doctor.sh lists the prerequisites)." >&2; exit 0; }

input="$(cat)"
INPUT_JSON="$input" python3 - <<'PY' 2>/dev/null
import glob, json, os, re, sys

try:
    obj = json.loads(os.environ.get("INPUT_JSON", ""))
except Exception:
    sys.exit(0)
tool = obj.get("tool_name") or ""
is_mcp = re.fullmatch(r"mcp__(?:plugin_serena_)?serena__execute_shell_command", tool) is not None
if tool != "Bash" and not is_mcp:
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
]
PEM_BEGIN = re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")
PEM_END = re.compile(r"-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----")
# The fixed DER prefix of a private key, base64-encoded from offset 0, then
# more key: RSA PKCS#8 and PKCS#1, EC PKCS#8 (P-256/384/521), EC SEC1, the
# Ed25519/Ed448/X25519 PKCS#8 form, and openssh-key-v1. Certificates (MIIC…
# then `CCA`) and public keys (`MIIBIjANBgkq…AAOC`, `MFkwEwYH…`) differ in the
# bytes these pin, so they never match.
KEY_BODY = re.compile(
    r"(?:MII[A-Za-z0-9+/]{3}IBADANBgkqhkiG9w0BAQEFAAS|MII[A-Za-z0-9+/]{3}IBAAKC"
    r"|MI[GH][A-Za-z0-9+/]AgEAMB[A-Za-z0-9+/]GByqGSM49|MHcCAQEEI|MIGkAgEBBD|MIHcAgEBBEI"
    r"|M[CE][A-Za-z0-9+/]CAQAwBQYDK2V[uvwx]|b3BlbnNzaC1rZXktdjE)[A-Za-z0-9+/]{16,}"
)
# A maximal base64 run long enough to be key material, not a word or a path.
B64_RUN = re.compile(r"(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/]{16,}={0,2}(?![A-Za-z0-9+/=_.-])")
SECRET_NAME = re.compile(
    r"(SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|PRIVATE_KEY|SERVICE_ROLE|"
    r"ACCESS_KEY|DATABASE_URL|DB_URL|DIRECT_URL|CONNECTION_STRING|DSN|CREDENTIAL)",
    re.I,
)
KV_LINE = re.compile(r"(?m)^([ \t]*(?:export[ \t]+)?)([A-Za-z_][A-Za-z0-9_]*)=([^\n]*)$")
# A quoted value after `:` or `=`, its key bare or quoted in either style.
KV_PAIR = re.compile(r"""(?<![A-Za-z0-9_])(["']?)([A-Za-z_][A-Za-z0-9_]*)\1\s*[:=]\s*(["'])((?:(?!\3)[^\\\n]|\\.)*)\3""")
PLACEHOLDER = re.compile(r"redacted|\*\*\*|xxxx|changeme|change-me|your[_-]|placeholder|example|\.\.\.|…", re.I)


def placeholder(v):
    return (not v or v.startswith(("$", "<", "%", "{")) or PLACEHOLDER.search(v)
            or len(set(v)) == 1)


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    return v


def live_values():
    """Values of live credentials: secret-named env vars and the secrets files."""
    vals = set()
    for k, v in os.environ.items():
        if SECRET_NAME.search(k) and len(v) >= 8:
            vals.add(v)
    home = os.path.expanduser("~")
    pats = [".config/secrets/*.env", ".musclebuddy/*.env", ".redthread/*.env"]
    for pat in pats:
        for path in glob.glob(os.path.join(home, pat)):
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line.rstrip("\n"))
                        if m and SECRET_NAME.search(m.group(1)):
                            v = unquote(m.group(2))
                            if len(v) >= 8:
                                vals.add(v)
            except OSError:
                continue
    return vals


LIVE = live_values()


def fixture_shaped(v):
    if re.fullmatch(r"(?:gh[pousr]_|github_pat_|sbp_|sk-ant-|sk_live_|rk_live_|AIza)[A-Za-z0-9_\-]{0,19}", v):
        return True
    return bool(re.fullmatch(r"[a-z]+(?:[-_][a-z]+)+", v))


def real_value(v):
    v = unquote(v)
    if v in LIVE:
        return True
    if fixture_shaped(v):
        return False
    if len(v) < 8 or re.search(r"\s", v) or re.search(r"[()\[\]{}$`]", v):
        return False
    # A bare UPPER_SNAKE identifier is a variable NAME (`"RT_DATABASE_URL":
    # "DATABASE_URL"` in a name-mapping file), never a credential value.
    if re.fullmatch(r"[A-Z_][A-Z0-9_]*", v):
        return False
    return not placeholder(v)


def pem(text, found):
    """Redact private-key bodies: the base64 after a PEM header, or a run that
    opens with a key's DER prefix, and each base64 line that continues it."""
    out, in_key, hit = [], False, False
    for line in text.split("\n"):
        begin = PEM_BEGIN.search(line)
        if begin:
            start = begin.end()
        elif KEY_BODY.search(line) or in_key:
            start = 0
        else:
            out.append(line)
            continue
        end = PEM_END.search(line, start)
        stop = end.start() if end else len(line)
        seg, n = B64_RUN.subn("<redacted>", line[start:stop])
        if n == 0 and in_key and not begin and re.fullmatch(r"\s*[A-Za-z0-9+/]+={0,2}\s*", seg):
            seg, n = "<redacted>", 1  # a key's short last line
        if n:
            hit = True
        in_key = not end and (bool(begin) or n > 0)
        out.append(line[:start] + seg + line[stop:])
    if hit:
        found.append("a private key")
    return "\n".join(out)


def scan(text, found):
    text = pem(text, found)

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

    def kp(m):
        name, val = m.group(2), m.group(4)
        if not SECRET_NAME.search(name) or not real_value(val):
            return m.group(0)
        found.append("the value of %s" % name)
        whole, at = m.group(0), m.start(0)
        return whole[:m.start(4) - at] + "<redacted>" + whole[m.end(4) - at:]
    text = KV_PAIR.sub(kp, text)
    return text


def walk(v, found):
    """An MCP result: every string in it, and JSON text field by field."""
    if isinstance(v, list):
        return [walk(x, found) for x in v]
    if isinstance(v, dict):
        return {k: walk(x, found) for k, x in v.items()}
    if not isinstance(v, str):
        return v
    if v.lstrip().startswith(("{", "[")):
        try:
            inner = json.loads(v)
        except ValueError:
            inner = None
        if isinstance(inner, (dict, list)):
            mark = len(found)
            redone = walk(inner, found)
            return json.dumps(redone) if len(found) > mark else v
    return scan(v, found)


found = []
if is_mcp:
    updated = walk(resp, found)
elif isinstance(resp, dict):
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
        "⚠ CREDENTIAL LEAK: a %s result carried %s. It was redacted before Claude saw it, "
        "but the command already printed it — treat it as leaked and rotate it. Command: %s"
        % ("Serena shell" if is_mcp else "Bash", what, cmd_line)
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
        # The MCP field is the one every harness version applies to an MCP
        # tool; Bash's result is replaced through updatedToolOutput.
        ("updatedMCPToolOutput" if is_mcp else "updatedToolOutput"): updated,
    },
}))
PY
exit 0
