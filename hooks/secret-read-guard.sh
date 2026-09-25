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
    print(hit)
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

[ -n "$verdict" ] && block "$verdict"

exit 0
