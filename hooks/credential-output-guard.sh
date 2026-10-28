#!/usr/bin/env bash
# dotclaude credential-output-guard — PostToolUse hook (matcher: Bash).
#
# secret-read-guard.sh refuses the commands KNOWN to print a credential before
# they run. This is the net under it: after any shell call, the result is
# scanned for credential-shaped text, and when it holds some the hook
#   - REDACTS it, so Claude never sees the value (`updatedToolOutput` for Bash's
#     `{stdout, stderr}`); and
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
#     redis/amqp `scheme://user:pass@host`, unless the host is reserved for
#     testing (example.com/.net/.org, *.test, *.example, *.invalid) and the
#     password is not a live value;
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
# The judgement is on the VALUE's shape, not only the name's. A value that is a
# URL path (`/oauth/token`, `design/tokens`), a URL with no userinfo, query or
# secret-looking path segment (a public token endpoint), or a lowercase
# identifier (`admin:manage`, `authenticated`, `fcm-token-1`) is not a
# credential unless it equals a live one; a name that says what a credential
# DESCRIBES (…_PATH, …_AUDIENCE, …_PERMISSION, …_SCOPE) is likewise exempt for
# a non-live value. Names that cannot hold anything but a secret (…SECRET,
# …PASSWORD, …PASS, PRIVATE_KEY) are redacted at 6+ characters in any quoting
# (plain, escaped-in-a-string JSON, or an unquoted `name: value` line).
#
# Any 10+ character base64-alphabet run in the output that is a substring of a
# live credential's value or of one of its lines (a PEM body fragment a
# name-extractor emitted) is redacted too.
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
if tool != "Bash":
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
    r"(SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE|_PASS\b|API_?KEY|PRIVATE_KEY|SERVICE_ROLE|"
    r"ACCESS_KEY|DATABASE_URL|DB_URL|DIRECT_URL|CONNECTION_STRING|DSN|CREDENTIAL)",
    re.I,
)
KV_LINE = re.compile(r"(?m)^([ \t]*(?:export[ \t]+)?)([A-Za-z_][A-Za-z0-9_]*)=([^\n]*)$")
# A quoted value after `:` or `=`, its key bare or quoted in either style. The
# closing quote may be missing: `curl … | cut -c1-200` cuts a JSON response
# mid-value, and the secret's prefix is still printed (#479).
KV_PAIR = re.compile(r"""(?<![A-Za-z0-9_])(["']?)([A-Za-z_][A-Za-z0-9_]*)\1\s*[:=]\s*(["'])((?:(?!\3)[^\\\n]|\\.)*)(?:\3|(?=\n)|\Z)""")
KV_ESCAPED = re.compile(r'''\\"([A-Za-z_][A-Za-z0-9_]*)\\"\s*:\s*\\"((?:(?!\\")[^\\\n])*)''')
KV_YAML = re.compile(r"(?m)^([ \t]*(?:-[ \t]+)?)([A-Za-z_][A-Za-z0-9_]*):[ \t]+([^\s\"'<][^\n]*?)[ \t]*$")
PLACEHOLDER = re.compile(r"redacted|\*\*\*|xxxx|changeme|change-me|your[_-]|placeholder|example|\.\.\.|…", re.I)


def placeholder(v):
    return (not v or v.startswith(("$", "<", "%", "{", "[")) or PLACEHOLDER.search(v)
            or len(set(v)) == 1)


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    return v


def name_shaped(v):
    """A bare UPPER_SNAKE identifier with an underscore is a variable NAME
    (`"MB_PROD_DATABASE_URL": "DATABASE_URL"` in a repo.json name map), never a
    credential value, even when some secret-named variable happens to hold it."""
    return re.fullmatch(r"[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+", v) is not None


def live_values():
    """Values of live credentials: secret-named env vars and the secrets files."""
    vals = set()
    for k, v in os.environ.items():
        if SECRET_NAME.search(k) and len(v) >= 8 and not name_shaped(v):
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
                            if len(v) >= 8 and not name_shaped(v):
                                vals.add(v)
            except OSError:
                continue
    return vals


LIVE = live_values()


# A word: lowercase letters, at most three trailing digits (`fcm`, `token1`).
_WORD = r"[a-z]+\d{0,3}"
KNOWN_AUTH_HOSTS = {
    "oauth2.googleapis.com", "accounts.google.com", "www.googleapis.com",
    "login.microsoftonline.com", "appleid.apple.com", "fcm.googleapis.com",
    "api.sandbox.push.apple.com", "api.push.apple.com",
}


def fixture_shaped(v):
    if re.fullmatch(r"(?:gh[pousr]_|github_pat_|sbp_|sk-ant-|sk_live_|rk_live_|AIza)[A-Za-z0-9_\-]{0,19}", v):
        return True
    if len(v) > 40:
        return False
    # Lowercase words joined by `-`/`_`/`:`/`.` (`inline-expansion`, `admin:manage`,
    # `fcm-token-1`) or one lowercase word with no digit (`authenticated`): an
    # identifier, not a generated secret. A live credential is matched before this.
    if re.fullmatch(_WORD + r"(?:[-_:.](?:" + _WORD + r"|\d{1,3}))+", v):
        return True
    return bool(re.fullmatch(r"[a-z]+", v))


def path_shaped(v):
    """A URL path or module specifier (`/oauth/token`, `./tokens`, `design/tokens`,
    `@scope/pkg`): slash-separated segments of lowercase words. Mixed-case
    segments count only when short and digit-free, so a base64 secret that
    happens to hold a `/` does not."""
    if "/" not in v or len(v) > 64 or re.search(r"[+=\s]", v):
        return False
    body = re.sub(r"^(?:\.{1,2}/|/|@)", "", v)
    segs = body.split("/")
    if not all(segs):
        return False
    lower = all(re.fullmatch(r"[a-z0-9][a-z0-9._~-]{0,23}", g) for g in segs)
    mixed = len(v) <= 24 and all(re.fullmatch(r"[A-Za-z][A-Za-z._-]{0,23}", g) for g in segs)
    return bool(lower or mixed)


def public_url(v):
    """An http(s) URL that carries no secret: no userinfo, query or fragment, and
    either a known public auth host or a path of plain lowercase words. A webhook
    URL (its path holds an id and a token) is not."""
    m = re.fullmatch(r"https?://([A-Za-z0-9.-]+)(?::\d+)?((?:/[^\s?#@]*)?)", v)
    if not m:
        return False
    if m.group(1).lower() in KNOWN_AUTH_HOSTS:
        return True
    segs = [g for g in m.group(2).split("/") if g]
    return all(re.fullmatch(r"[a-z][a-z0-9._~-]{0,23}|v?\d{1,3}(?:\.\d+)?", g) for g in segs)


# A name that says what a credential is FOR or HOW it is carried, not the credential.
DESCRIPTOR_NAME = re.compile(
    r"(?:[_-](?:path|endpoint|audience|permissions?|scopes?|issuer|ttl|header|prefix|algorithm)"
    r"|(?:Path|Endpoint|Audience|Permissions?|Scopes?|Issuer|Header|Prefix|Algorithm))$",
    re.I,
)
# Names that can hold nothing but a secret: the value is redacted at a lower floor.
HARD_NAME = re.compile(r"(secret|passw(?:or)?d|passphrase|(?:^|_)pass$|private_?key)", re.I)


def fixture_host(host):
    """An RFC 2606 / 6761 reserved host — example.com/.net/.org, or a .test,
    .example, .invalid or .localhost name — or a loopback address, which no
    shared or production database answers on, so a URL to it is a test fixture
    rather than a leak."""
    h = (host or "").lower().rstrip(".")
    if h == "localhost" or re.fullmatch(r"127(?:\.\d{1,3}){3}", h):
        return True
    if re.search(r"\$\{|\[|\]|<|>|%s", h):  # a template or placeholder host, not a real name
        return True
    return bool(re.search(r"(?:^|\.)example\.(?:com|net|org)$|\.(?:test|example|invalid|localhost)$", h))


def real_value(v, name=""):
    v = unquote(v)
    if v in LIVE:
        return True
    if name and DESCRIPTOR_NAME.search(name):
        return False
    if fixture_shaped(v) or path_shaped(v) or public_url(v):
        return False
    # A short lowercase-hex string is a digest's fingerprint (the Supabase
    # Management API prints `external_apple_secret` as a hash prefix), not a
    # secret: every credential shape this guard protects is longer (#479).
    if re.fullmatch(r"[0-9a-f]{8,16}", v):
        return False
    floor = 6 if name and HARD_NAME.search(name) else 8
    if len(v) < floor or re.search(r"\s", v) or re.search(r"[()\[\]{}$`]", v):
        return False
    # A bare UPPER_SNAKE identifier is a variable NAME (`"RT_DATABASE_URL":
    # "DATABASE_URL"` in a name-mapping file), never a credential value.
    if re.fullmatch(r"[A-Z_][A-Z0-9_]*", v):
        return False
    return not placeholder(v)


# Lines of every live value of 10+ characters: a name-extractor over a multi-line
# PEM prints a fragment of one line, which is no PEM block and no known prefix.
LIVE_LINES = {ln for v in LIVE for ln in v.splitlines() if len(ln) >= 10}
FRAGMENT = re.compile(r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{10,}={0,2}")


def fragments(text, found):
    if not LIVE_LINES:
        return text

    def frag(m):
        s = m.group(0).rstrip("=")
        if s.islower() or s.isdigit():  # a word or a number, not key material
            return m.group(0)
        if any(s in ln for ln in LIVE_LINES):
            found.append("a fragment of a stored secret")
            return "<redacted>"
        return m.group(0)
    return FRAGMENT.sub(frag, text)


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
    text = fragments(text, found)

    def url(m):
        if placeholder(m.group(3)):
            return m.group(0)
        pw = unquote(m.group(3))
        if pw not in LIVE and (fixture_host(m.group(4)) or re.fullmatch(r"[a-z]{1,12}", pw)):
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
        if not SECRET_NAME.search(name) or not real_value(val, name):
            return m.group(0)
        found.append("the value of %s" % name)
        return "%s%s=<redacted>" % (lead, name)
    text = KV_LINE.sub(kv, text)

    def kp(m):
        name, val = m.group(2), m.group(4)
        if not SECRET_NAME.search(name) or not real_value(val, name):
            return m.group(0)
        found.append("the value of %s" % name)
        whole, at = m.group(0), m.start(0)
        return whole[:m.start(4) - at] + "<redacted>" + whole[m.end(4) - at:]
    text = KV_PAIR.sub(kp, text)

    # JSON escaped inside a string (`{\\"name\\":\\"value\\"}`), as a log line or a
    # nested response prints it.
    def ke(m):
        name, val = m.group(1), m.group(2)
        if not HARD_NAME.search(name) or not real_value(val, name):
            return m.group(0)
        found.append("the value of %s" % name)
        return m.group(0).replace(val, "<redacted>")
    text = KV_ESCAPED.sub(ke, text)

    # An unquoted `name: value` line (YAML, `jq -r 'to_entries[]'`) under a name
    # that can hold nothing but a secret.
    def ky(m):
        name, val = m.group(2), m.group(3)
        if not HARD_NAME.search(name) or not real_value(val, name):
            return m.group(0)
        found.append("the value of %s" % name)
        return "%s%s: <redacted>" % (m.group(1), name)
    text = KV_YAML.sub(ky, text)
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
        "⚠ CREDENTIAL LEAK: a %s result carried %s. It was redacted before Claude saw it, "
        "but the command already printed it — treat it as leaked and rotate it. Command: %s"
        % ("Bash", what, cmd_line)
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
