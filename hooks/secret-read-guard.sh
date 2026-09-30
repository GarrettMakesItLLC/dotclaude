#!/usr/bin/env bash
# dotclaude secret-read-guard — PreToolUse hook for Read | Bash.
#
# Turns "never read a secrets file's VALUES into the transcript" from prose an
# agent follows probabilistically into a hard, deterministic block. Wired in
# settings.json under hooks.PreToolUse. On a policy hit it exits 2, which
# blocks the call and feeds stderr back to Claude.
#
# WHY THIS EXISTS (GarrettMakesItLLC/RedThreadEvents#2419): a subagent told
# "names only, never print values" still ran `cat ~/.redthread/agent.env` and
# printed three live credentials into a session transcript. A prompt limits
# INTENT; only a hook limits CAPABILITY. This is that hook.
#
# WHAT COUNTS AS A SECRETS PATH:
#   - anything under ~/.config/secrets/
#   - any file literally named agent.env, in any directory
#   - ~/.musclebuddy/*.env, ~/.redthread/*.env
#   - generally *.env / .env.* files, EXCEPT *.env.example / *.env.sample /
#     *.env.template — those are checked-in fixtures, not real secrets.
#
# WHAT'S BLOCKED:
#   - `Read` tool on a secrets path.
#   - A `Bash` command that runs a value-printing reader — cat, head, tail,
#     less, more, bat, nl, xxd, od, strings, base64, a printing awk, a sed
#     without a redacting substitution, or a grep/rg without -l/-c/-q/-o — on
#     a secrets path.
#   - A `Bash` command whose JOB is to print a credential, when its stdout
#     reaches the transcript: `*db-url.sh` (staging-db-url.sh), `railway
#     variables`, `vercel env pull /dev/stdout`, `gh auth token`, `supabase …
#     api-keys`, bare `printenv`/`env`/`export -p`/`set`, `printenv <SECRET>`,
#     and `echo`/`printf` of a credential-named variable. Allowed when captured
#     by `$(…)`, redirected to a file or /dev/null, or piped into a sink that
#     prints no value (wc, a checksum, grep -q/-c/-l, `head -c N` with N <= 8,
#     a redacting sed). The PostToolUse `credential-output-guard.sh` redacts
#     whatever still gets through.
#
# WHAT'S ALLOWED (by design — this must not make the file unusable):
#   - `source`/`.` of the file, `set -a; . file` — never PRINTS anything.
#   - `sed 's/=.*/=<redacted>/' <file>` and
#     `grep -oE '^(export )?[A-Za-z_][A-Za-z0-9_]*=' <file>` — the sanctioned
#     name-only / redacted forms, named in the block message below.
#   - `grep`/`rg` with -l/-c/-q/-o (existence/count/name checks, not values).
#   - `test -f`, `ls`, `stat`, `find` — metadata, not content.
#   - Writing TO the file (`>>`, `>`) — this guards reads, not writes.
#   - Anything that doesn't name a secrets path.
#
# Fail-open by design: if the input can't be parsed (no python3, malformed
# JSON), we exit 0 and let the call through. A guard that bricks every Read/
# Bash call is far worse than one that occasionally misses — it is a backstop,
# not a sandbox. Same trade-off git-guard.sh and worktree-guard.sh make.
#
# KNOWN GAPS (by design — don't expand this into a regex arms race):
#   - Not a real shell parse: segments are split on `;`/`&&`/`||`/`|`/newline
#     and tokenized with shlex. A secrets path built at runtime from a
#     variable (`f="$SECRETS_DIR/gmi.env"; cat "$f"`) is invisible to this —
#     same class of gap as worktree-guard's write-target scan.
#   - `cp`/`mv`/`scp` of a secrets file are not blocked — they don't print the
#     VALUES into the transcript, which is the specific hazard this guards.
#   - A reader piped through an intermediate command (`cat file | some-filter`)
#     is still caught, because `cat` itself is flagged the moment it names the
#     path — the pipe destination doesn't matter.

set -uo pipefail

input="$(cat)"

command -v python3 >/dev/null 2>&1 || exit 0

block() {
  echo "⛔ dotclaude secret-read-guard blocked this." >&2
  echo "Reason: $1" >&2
  echo "A prompt limits intent; only a hook limits capability (RedThreadEvents#2419)." >&2
  echo "Sanctioned forms instead:" >&2
  echo "    sed 's/=.*/=<redacted>/' <file>" >&2
  echo "    grep -oE '^(export )?[A-Za-z_][A-Za-z0-9_]*=' <file>" >&2
  echo "Or, to actually USE the values: source the file (it is never printed)." >&2
  echo "False positive? Run it yourself, or edit hooks/secret-read-guard.sh." >&2
  exit 2
}

err="$(mktemp 2>/dev/null || echo /tmp/secret-read-guard-err.$$)"
verdict="$(INPUT_JSON="$input" python3 - <<'PYEOF' 2>"$err"
import json, os, re, shlex, sys

try:
    obj = json.loads(os.environ.get("INPUT_JSON", ""))
except Exception:
    sys.exit(0)

tool = obj.get("tool_name", "")
ti = obj.get("tool_input", {}) or {}

EXCLUDED_SUFFIXES = (".env.example", ".env.sample", ".env.template")

def is_secret_path(tok):
    if not tok:
        return False
    tok = tok.strip("\"'")
    norm = tok.replace("${HOME}", "~").replace("$HOME", "~")
    base = norm.rstrip("/").split("/")[-1]
    if not base:
        return False
    lower = base.lower()
    if lower.endswith(EXCLUDED_SUFFIXES):
        return False
    if "/.config/secrets/" in norm:
        return True
    if lower == "agent.env":
        return True
    if "/.musclebuddy/" in norm and lower.endswith(".env"):
        return True
    if "/.redthread/" in norm and lower.endswith(".env"):
        return True
    if lower == ".env":
        return True
    if lower.endswith(".env"):
        return True
    if lower.startswith(".env."):
        return True
    return False

# ---- Read tool: a straight path check. ----
if tool == "Read":
    path = ti.get("file_path") or ""
    if is_secret_path(path):
        print("Read tool targets a secrets path: " + path)
    sys.exit(0)

if tool != "Bash":
    sys.exit(0)

cmd = ti.get("command") or ""

ALWAYS_BLOCK_READERS = {
    "cat", "head", "tail", "less", "more", "bat", "nl", "xxd", "od",
    "strings", "base64",
}
GREP_LIKE = {"grep", "egrep", "fgrep", "rg"}
SED_LIKE = {"sed", "gsed"}
AWK_LIKE = {"awk", "gawk"}
SAFE_CMDS = {
    "source", ".", "test", "[", "ls", "stat", "file", "find", "true", "echo",
    "tee",
}

ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")


def sed_is_redacting(script):
    if len(script) < 3 or script[0] != "s":
        return False
    delim = script[1]
    if not delim or delim.isalnum():
        return False
    parts = script[2:].split(delim)
    if len(parts) < 2:
        return False
    pattern, replacement = parts[0], parts[1]
    return "=" in pattern and "=" in replacement


def grep_is_allowed(flag_tokens):
    letters = ""
    longs = set()
    for f in flag_tokens:
        if f.startswith("--"):
            longs.add(f.split("=")[0])
        elif f.startswith("-"):
            letters += f[1:]
    if any(c in letters for c in "lcqo"):
        return True
    if longs & {
        "--files-with-matches", "--count", "--quiet", "--only-matching",
        "--silent",
    }:
        return True
    return False


hit = None
for seg in re.split(r"&&|\|\||\||;|\n", cmd):
    seg = seg.strip()
    if not seg:
        continue
    try:
        toks = shlex.split(seg)
    except ValueError:
        toks = seg.split()
    if not toks:
        continue

    # Find the command word, skipping leading VAR=val assignments.
    i = 0
    while i < len(toks) and ASSIGN_RE.match(toks[i]):
        i += 1
    if i >= len(toks):
        continue
    cmd_tok = toks[i]
    cmd_word = cmd_tok.split("/")[-1]
    rest = toks[i + 1:]

    # Collect secrets-path references that are actual READ arguments, not
    # write-redirect targets (`>`, `>>`) and not tee's destination (tee
    # always WRITES its file operands).
    read_refs = []
    write_only = cmd_word == "tee"
    for j, t in enumerate(toks):
        if not is_secret_path(t):
            continue
        prev = toks[j - 1] if j > 0 else ""
        if prev in (">", ">>"):
            continue
        if write_only:
            continue
        read_refs.append(t)

    if not read_refs:
        continue

    if cmd_word in SAFE_CMDS:
        continue

    if cmd_word in ALWAYS_BLOCK_READERS:
        hit = "`%s` prints the file's contents: %s" % (cmd_word, seg)
        break

    if cmd_word in SED_LIKE:
        flag_free = [t for t in rest if not t.startswith("-")]
        has_n = any(
            t == "-n" or (t.startswith("-") and not t.startswith("--") and "n" in t[1:])
            for t in rest
        )
        script = flag_free[0] if flag_free else ""
        if has_n or not sed_is_redacting(script):
            hit = "`sed` on a secrets file without a redacting substitution: %s" % seg
            break
        continue

    if cmd_word in GREP_LIKE:
        flags = [t for t in rest if t.startswith("-")]
        if not grep_is_allowed(flags):
            hit = "`%s` on a secrets file without -l/-c/-q/-o: %s" % (cmd_word, seg)
            break
        continue

    if cmd_word in AWK_LIKE:
        program = " ".join(rest)
        if "redact" not in program.lower():
            hit = "`%s` on a secrets file (prints by default): %s" % (cmd_word, seg)
            break
        continue

    # Unknown command referencing a secrets path (cp, mv, scp, python, ...):
    # doesn't print VALUES into the transcript by itself. Not this guard's
    # job — fail open per the header.

if hit:
    print("READ\t" + hit)
    sys.exit(0)

# ---- Commands whose JOB is to print a credential (#455). ----
#
# A file-read check cannot see `staging-db-url.sh`, `railway variables --kv`,
# `printenv`, `echo $DATABASE_URL` or `gh auth token`: nothing names a secrets
# file, and the value still lands in the transcript. Each is refused when its
# stdout reaches the transcript, and allowed when it does not:
#   - captured by a command substitution (`DB="$(staging-db-url.sh)"`,
#     `psql "$(…)"`) — the value becomes an argument, never output;
#   - redirected to a file or /dev/null (`railway variables --kv > vars.env`);
#   - piped into a sink that prints no value: wc, a checksum, grep -q/-c/-l,
#     `head -c N`/`cut -c-N` with N <= 8 (a prefix), or a redacting sed.
SECRET_NAME = re.compile(
    r"(SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|PRIVATE_KEY|SERVICE_ROLE|"
    r"ACCESS_KEY|DATABASE_URL|DB_URL|DIRECT_URL|CONNECTION_STRING|DSN|CREDENTIAL)",
    re.I,
)
SUBST_MARK = "__SECRET_SUBST__"
WRAPPERS = {"env", "command", "builtin", "time", "nohup", "sudo", "exec", "!"}


def strip_heredocs(c):
    return re.sub(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1.*?^\s*\2\s*$", " ", c, flags=re.S | re.M)


def secret_var_ref(tok):
    """A `$NAME` / `${NAME}` expansion of a credential-named variable that
    prints its value (not its length, and not a short prefix slice)."""
    for m in re.finditer(r"\$\{?(#?)([A-Za-z_][A-Za-z0-9_]*)(:[^}]*)?\}?", tok):
        hashed, name, mod = m.group(1), m.group(2), m.group(3) or ""
        if hashed or not SECRET_NAME.search(name):
            continue
        sl = re.match(r"^:0:(\d+)$", mod)
        if sl and int(sl.group(1)) <= 8:
            continue
        if mod.startswith((":+", ":?")):
            continue
        return name
    return None


def unwrap(toks):
    while toks and (ASSIGN_RE.match(toks[0]) or toks[0] in WRAPPERS):
        if toks[0] == "env" and all(
            ASSIGN_RE.match(t) or t.startswith("-") for t in toks[1:]
        ):
            return toks  # bare `env` dumps the environment: judged below
        toks = toks[1:]
    return toks


def emitter(stage):
    """Why this pipeline stage prints a credential, or None."""
    try:
        toks = shlex.split(stage)
    except ValueError:
        toks = stage.split()
    toks = [t for t in toks if not re.match(r"^\d*[<>]", t)]
    toks = unwrap(toks)
    if not toks:
        return None
    w = toks[0].split("/")[-1]
    args = toks[1:]
    plain = [a for a in args if not a.startswith("-")]
    if re.match(r"^[\w.-]*db-url(\.sh)?$", w):
        return "`%s` prints a database URL with its password" % w
    if w == "railway" and plain[:1] and plain[0] in ("variables", "variable", "vars"):
        if not any(a in ("--set", "-s", "--set-from-stdin") or a.startswith("--set=") for a in args) \
                and not (plain[1:2] and plain[1] in ("set", "delete", "rm")):
            return "`railway variables` prints every variable's value"
    if w == "vercel" and plain[:2] == ["env", "pull"]:
        if any(a in ("/dev/stdout", "/dev/stderr", "/dev/fd/1", "/dev/fd/2", "/proc/self/fd/1", "-") for a in plain[2:]):
            return "`vercel env pull` to stdout prints every variable's value"
    if w == "gh" and plain[:2] == ["auth", "token"]:
        return "`gh auth token` prints a GitHub token"
    if w == "gh" and plain[:2] == ["auth", "status"] and any(a in ("-t", "--show-token") for a in args):
        return "`gh auth status --show-token` prints a GitHub token"
    if w == "supabase" and "api-keys" in plain:
        return "`supabase … api-keys` prints the project's service-role key"
    if w == "printenv":
        if not plain:
            return "bare `printenv` prints every variable, credentials included"
        named = [a for a in plain if SECRET_NAME.search(a)]
        if named:
            return "`printenv %s` prints a credential" % named[0]
    if w == "env" and all(ASSIGN_RE.match(a) or a.startswith("-") for a in args):
        return "bare `env` prints every variable, credentials included"
    if w in ("export", "declare", "typeset") and (not args or all(a in ("-p", "-x", "-px", "-xp") for a in args)):
        return "`%s` with no names prints every exported variable, credentials included" % " ".join(toks)
    if w == "set" and not args:
        return "bare `set` prints every variable, credentials included"
    if w in ("echo", "printf"):
        if any(SUBST_MARK in a for a in args):
            return "`%s` prints the output of a credential-emitting command" % w
        for a in args:
            name = secret_var_ref(a)
            if name:
                return "`%s` prints $%s" % (w, name)
    return None


def stdout_to_file(stage):
    """True when this stage sends its stdout somewhere other than the transcript."""
    for m in re.finditer(r"(?:^|[^0-9<>&])(1?>>?|&>>?)\s*([^\s;&|]+)", stage):
        target = m.group(2)
        if target.startswith("&"):
            continue  # >&2 and friends still reach the transcript
        if target in ("/dev/stdout", "/dev/stderr", "/dev/tty", "/dev/fd/1", "/dev/fd/2"):
            continue
        return True
    return False


def safe_sink(stage):
    try:
        toks = shlex.split(stage)
    except ValueError:
        toks = stage.split()
    toks = unwrap(toks)
    if not toks:
        return False
    w, args = toks[0].split("/")[-1], toks[1:]
    if w in ("wc", "sha256sum", "sha1sum", "md5sum", "shasum", "true", "false"):
        return True
    if w in ("grep", "egrep", "fgrep", "rg"):
        return grep_is_allowed([a for a in args if a.startswith("-")]) and not any(
            a.startswith("-o") or a == "--only-matching" for a in args)
    if w in ("head", "cut"):
        joined = " ".join(args)
        m = re.search(r"-c\s*(?:1?-)?(\d+)", joined) or re.search(r"--bytes[= ](\d+)", joined)
        return bool(m) and int(m.group(1)) <= 8
    if w in ("sed", "gsed"):
        script = " ".join(a for a in args if not a.startswith("-"))
        return "redact" in script.lower() or "***" in script
    return False


def strip_substitutions(c):
    """Replace every $(…) and `…` with a placeholder, innermost first, marking
    the ones whose own contents emit a credential."""
    pat = re.compile(r"\$\(([^()]*)\)|`([^`]*)`")
    for _ in range(20):
        m = pat.search(c)
        if not m:
            break
        inner = m.group(1) if m.group(1) is not None else m.group(2)
        emits = any(emitter(st) for stmt in re.split(r"&&|\|\||;|\n", inner)
                    for st in re.split(r"(?<!\|)\|(?!\|)", stmt))
        c = c[:m.start()] + (SUBST_MARK if emits else "__SUBST__") + c[m.end():]
    return c


def find_emit(c):
    flat = strip_substitutions(strip_heredocs(c).replace("\\\n", " "))
    for stmt in re.split(r"&&|\|\||;|\n", flat):
        stages = [st.strip() for st in re.split(r"(?<!\|)\|(?!\|)", stmt)]
        for i, st in enumerate(stages):
            why = emitter(st)
            if not why:
                continue
            rest = stages[i + 1:]
            if stdout_to_file(st) or any(safe_sink(r) for r in rest) or (rest and stdout_to_file(rest[-1])):
                continue
            return "%s: %s" % (why, stmt.strip())
    return None


# This half is new and heuristic, so a parse it cannot finish lets the call
# through rather than refusing every Bash command.
try:
    emit = find_emit(cmd)
except Exception:
    emit = None
if emit:
    print("EMIT\t" + emit)
PYEOF
)"
status=$?
if [ "$status" -ne 0 ]; then
  echo "⛔ dotclaude secret-read-guard could not inspect this call, so it is refusing it." >&2
  echo "Reason: the extractor exited $status. That is a bug in the guard, not a verdict on your call." >&2
  [ -s "$err" ] && { echo "Check error:" >&2; sed 's/^/    /' "$err" >&2; }
  echo "Fix: repair hooks/secret-read-guard.sh." >&2
  rm -f "$err"
  exit 2
fi
rm -f "$err"

case "$verdict" in
  EMIT$'\t'*)
    reason="${verdict#EMIT$'\t'}"
    echo "⛔ dotclaude secret-read-guard blocked this." >&2
    echo "Reason: $reason" >&2
    echo "Its output would put a live credential in the transcript, where it cannot be taken back (#455)." >&2
    echo "Safe forms instead:" >&2
    echo "    capture it:   DB=\"\$(~/.claude/bin/staging-db-url.sh)\"   (the value becomes an argument, never output)" >&2
    echo "    redirect it:  <command> > /tmp/out.env   then inspect with   sed 's/:[^:@]*@/:<redacted>@/' /tmp/out.env" >&2
    echo "                  or   sed 's/=.*/=<redacted>/' /tmp/out.env" >&2
    echo "    measure it:   printenv NODE_AUTH_TOKEN | head -c 4" >&2
    echo "False positive? Run it yourself, or edit hooks/secret-read-guard.sh." >&2
    exit 2
    ;;
  READ$'\t'*) block "${verdict#READ$'\t'}" ;;
  ?*) block "$verdict" ;;
esac

exit 0
