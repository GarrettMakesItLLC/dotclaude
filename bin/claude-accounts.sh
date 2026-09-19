#!/usr/bin/env bash
# The fleet's Claude subscription accounts, and what is known about their limits.
#
#   bin/claude-accounts.sh init
#   bin/claude-accounts.sh add work-a --email a@example.com
#   bin/claude-accounts.sh claim work-a            # this machine/session is on it
#   bin/claude-accounts.sh limit work-a --window weekly --until "Sunday 18:00"
#   bin/claude-accounts.sh list
#   bin/claude-accounts.sh suggest                 # which account to switch to
#   bin/claude-accounts.sh report                  # one paragraph, or nothing
#   bin/claude-accounts.sh report --hook-json      # the same, as a SessionStart envelope
#   bin/claude-accounts.sh clear work-a
#   bin/claude-accounts.sh release work-a
#
# WHY THIS IS A LEDGER AND NOT AN API CALL
#   There is no endpoint that reports remaining subscription quota. The only
#   authoritative signal is the limit error itself, which names the reset time,
#   and that error arrives by killing whatever the agent was doing. So this
#   records what was observed, and is only as good as the recording — `limit`
#   is meant to be run the moment a session dies, by whoever saw it.
#
#   It is also why the gateway next door cannot help: Claude Code authenticates
#   against a subscription, not an API key, so subscription capacity cannot be
#   pooled behind a proxy. One account per session, switched with `/login`.
#
# The ledger is per-machine and lives OUTSIDE git — it names accounts and which
# box is on which.
set -euo pipefail

: "${CLAUDE_ACCOUNTS_FILE:=$HOME/.claude/claude-accounts.json}"
: "${CLAUDE_MACHINE:=$(hostname -s 2>/dev/null || hostname)}"
: "${CLAUDE_SESSION_LABEL:=${CLAUDE_SESSION_ID:-pid-$$}}"

command -v python3 >/dev/null 2>&1 || { echo "claude-accounts: python3 is required" >&2; exit 1; }

usage() { sed -n '2,30p' "$0"; }

# Normalise a human time ("Sunday 18:00", "+5 hours", an ISO stamp) to UTC ISO.
# A reset time nobody can parse is a reset time nobody will trust.
to_utc() {
  local raw="$1" out
  out="$(date -u -d "$raw" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  [ -n "$out" ] || { echo "claude-accounts: cannot parse a time from '$raw'" >&2; exit 2; }
  echo "$out"
}

run_py() {
  ACCOUNTS_FILE="$CLAUDE_ACCOUNTS_FILE" \
  ACC_MACHINE="$CLAUDE_MACHINE" \
  ACC_SESSION="$CLAUDE_SESSION_LABEL" \
  ACC_CMD="$1" ACC_LABEL="${2:-}" ACC_A="${3:-}" ACC_B="${4:-}" ACC_C="${5:-}" \
  ACC_HOOK_JSON="${ACC_HOOK_JSON:-}" \
  python3 - <<'PY'
import json, os, sys
from datetime import datetime, timezone

PATH = os.environ["ACCOUNTS_FILE"]
CMD = os.environ["ACC_CMD"]
LABEL = os.environ.get("ACC_LABEL") or ""
A, B, C = os.environ.get("ACC_A", ""), os.environ.get("ACC_B", ""), os.environ.get("ACC_C", "")
MACHINE, SESSION = os.environ["ACC_MACHINE"], os.environ["ACC_SESSION"]

NOW = datetime.now(timezone.utc)


def now_iso():
    return NOW.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse(ts):
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None


def load():
    try:
        with open(PATH) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {"version": 1, "accounts": []}
    data.setdefault("version", 1)
    data.setdefault("accounts", [])
    return data


def save(data):
    os.makedirs(os.path.dirname(PATH) or ".", exist_ok=True)
    tmp = PATH + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, PATH)


def find(data, label):
    for acc in data["accounts"]:
        if acc["label"] == label:
            return acc
    return None


def active_limits(acc):
    """Limit windows whose reset is still in the future. An expired window is
    not an error and not news — it is simply over."""
    out = {}
    for window, info in (acc.get("limits") or {}).items():
        reset = parse(info.get("reset_at", ""))
        if reset and reset > NOW:
            out[window] = info
    return out


def human_until(reset):
    delta = reset - NOW
    mins = int(delta.total_seconds() // 60)
    if mins < 60:
        return f"{mins}m"
    if mins < 60 * 48:
        return f"{mins // 60}h"
    return f"{mins // 1440}d"


def die(msg):
    print(f"claude-accounts: {msg}", file=sys.stderr)
    sys.exit(1)


data = load()

if CMD == "path":
    print(PATH)

elif CMD == "init":
    if not data["accounts"]:
        for label in ("account-a", "account-b", "account-c"):
            data["accounts"].append({"label": label, "email": "", "note": "", "limits": {}, "holder": None})
        save(data)
        print(f"claude-accounts: seeded 3 placeholder accounts in {PATH}")
        print("  rename them with `add <label>` / `rm <label>` once you know which is which")
    else:
        print(f"claude-accounts: {PATH} already has {len(data['accounts'])} account(s); leaving it alone")

elif CMD == "add":
    if not LABEL:
        die("add needs a label")
    acc = find(data, LABEL)
    if acc is None:
        acc = {"label": LABEL, "email": "", "note": "", "limits": {}, "holder": None}
        data["accounts"].append(acc)
    if A:
        acc["email"] = A
    if B:
        acc["note"] = B
    save(data)
    print(f"claude-accounts: recorded {LABEL}")

elif CMD == "rm":
    if find(data, LABEL) is None:
        die(f"no account named {LABEL}")
    data["accounts"] = [a for a in data["accounts"] if a["label"] != LABEL]
    save(data)
    print(f"claude-accounts: removed {LABEL}")

elif CMD == "limit":
    acc = find(data, LABEL)
    if acc is None:
        die(f"no account named {LABEL} (add it first)")
    window = A or "weekly"
    acc.setdefault("limits", {})[window] = {
        "reset_at": B,
        "recorded_at": now_iso(),
        "recorded_by": f"{MACHINE}/{SESSION}",
        "note": C,
    }
    save(data)
    print(f"claude-accounts: {LABEL} is {window}-limited until {B} (recorded by {MACHINE})")
    others = [a["label"] for a in data["accounts"] if a["label"] != LABEL and not active_limits(a)]
    print(f"  clear right now: {', '.join(others) if others else 'none — every account is limited'}")

elif CMD == "clear":
    acc = find(data, LABEL)
    if acc is None:
        die(f"no account named {LABEL}")
    if A:
        (acc.get("limits") or {}).pop(A, None)
    else:
        acc["limits"] = {}
    save(data)
    print(f"claude-accounts: cleared limits on {LABEL}")

elif CMD in ("claim", "release"):
    acc = find(data, LABEL)
    if acc is None:
        die(f"no account named {LABEL}")
    if CMD == "claim":
        held = acc.get("holder")
        if held and held.get("session") != SESSION:
            print(f"claude-accounts: note — {LABEL} was already claimed by "
                  f"{held.get('machine')}/{held.get('session')} since {held.get('since')}")
        acc["holder"] = {"machine": MACHINE, "session": SESSION, "since": now_iso()}
    else:
        acc["holder"] = None
    save(data)
    print(f"claude-accounts: {LABEL} {'claimed by' if CMD == 'claim' else 'released by'} {MACHINE}/{SESSION}")

elif CMD == "list":
    if not data["accounts"]:
        print(f"claude-accounts: no accounts yet — run `claude-accounts.sh init` ({PATH})")
        sys.exit(0)
    print(f"{'ACCOUNT':<16} {'STATE':<26} {'HELD BY':<26} NOTE")
    for acc in data["accounts"]:
        limits = active_limits(acc)
        if limits:
            window, info = sorted(limits.items(), key=lambda kv: kv[1].get("reset_at", ""))[-1]
            reset = parse(info["reset_at"])
            state = f"{window} limit, {human_until(reset)} left"
        else:
            state = "clear"
        holder = acc.get("holder")
        held = f"{holder['machine']}/{holder['session']}" if holder else "-"
        print(f"{acc['label']:<16} {state:<26} {held[:25]:<26} {acc.get('note') or acc.get('email') or ''}")

elif CMD in ("suggest", "report"):
    accounts = data["accounts"]
    if not accounts:
        if CMD == "suggest":
            print(f"claude-accounts: no accounts yet — run `claude-accounts.sh init` ({PATH})")
        sys.exit(0)

    clear_free, clear_held, limited = [], [], []
    for acc in accounts:
        limits = active_limits(acc)
        if limits:
            soonest = min(parse(i["reset_at"]) for i in limits.values())
            limited.append((soonest, acc))
        elif acc.get("holder") and acc["holder"].get("session") != SESSION:
            clear_held.append(acc)
        else:
            clear_free.append(acc)
    limited.sort(key=lambda t: t[0])

    if CMD == "suggest":
        if clear_free:
            acc = clear_free[0]
            print(f"{acc['label']} — no known limit, nobody on it")
        elif clear_held:
            acc = clear_held[0]
            h = acc["holder"]
            print(f"{acc['label']} — no known limit, but {h['machine']}/{h['session']} is on it "
                  f"(two sessions on one account share its quota)")
        else:
            reset, acc = limited[0]
            print(f"none are clear. {acc['label']} frees up soonest, at {reset.strftime('%Y-%m-%dT%H:%MZ')} "
                  f"({human_until(reset)}) — stop dispatching agents until then")
        sys.exit(0)

    # report: what a session needs to know before it starts spending quota.
    parts = []
    if limited:
        for reset, acc in limited:
            parts.append(f"{acc['label']} is limited until {reset.strftime('%a %H:%MZ')} ({human_until(reset)})")
    names = [a["label"] for a in clear_free + clear_held]
    if names:
        parts.append(f"{', '.join(names)} {'is' if len(names) == 1 else 'are'} clear")
    if not limited:
        sys.exit(0)  # nothing limited: say nothing, a clean session needs no banner
    msg = "Claude subscription accounts: " + "; ".join(parts) + "."
    if not clear_free and not clear_held:
        soonest = limited[0][0]
        msg += (" Every account is limited — a dispatched agent will die mid-edit. "
                f"Nothing frees up before {soonest.strftime('%a %H:%MZ')}.")
    msg += "  (bin/claude-accounts.sh list | suggest | limit <label> --until <when>)"
    if os.environ.get("ACC_HOOK_JSON"):
        # Emitted from this same process so the SessionStart hook costs ONE
        # python3 start, not two. A hook measured in seconds gets disabled.
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "SessionStart", "additionalContext": msg}}))
    else:
        print(msg)

else:
    die(f"unknown command: {CMD}")
PY
}

cmd="${1:-}"
[ $# -gt 0 ] && shift || true

case "$cmd" in
  ""|-h|--help|help) usage; exit 0 ;;
  path|init|list|suggest) run_py "$cmd" ;;
  report)
    case "${1:-}" in
      --hook-json) export ACC_HOOK_JSON=1 ;;
      "") ;;
      *) echo "claude-accounts: unknown argument: $1" >&2; exit 2 ;;
    esac
    run_py report
    ;;
  add)
    label="${1:-}"; [ -n "$label" ] || { echo "claude-accounts: add needs a label" >&2; exit 2; }
    shift
    email=""; note=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --email) email="${2:-}"; shift 2 ;;
        --note) note="${2:-}"; shift 2 ;;
        *) echo "claude-accounts: unknown argument: $1" >&2; exit 2 ;;
      esac
    done
    run_py add "$label" "$email" "$note"
    ;;
  rm|claim|release)
    label="${1:-}"; [ -n "$label" ] || { echo "claude-accounts: $cmd needs a label" >&2; exit 2; }
    run_py "$cmd" "$label"
    ;;
  limit)
    label="${1:-}"; [ -n "$label" ] || { echo "claude-accounts: limit needs a label" >&2; exit 2; }
    shift
    window="weekly"; until_raw=""; note=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --window) window="${2:-}"; shift 2 ;;
        --until) until_raw="${2:-}"; shift 2 ;;
        --note) note="${2:-}"; shift 2 ;;
        *) echo "claude-accounts: unknown argument: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$until_raw" ] || { echo "claude-accounts: limit needs --until <when> (the reset time the error named)" >&2; exit 2; }
    # Resolved in its own statement: inside run_py's argument list, a failed
    # command substitution would exit only the subshell and hand the ledger an
    # empty reset time.
    until_utc="$(to_utc "$until_raw")" || exit 2
    run_py limit "$label" "$window" "$until_utc" "$note"
    ;;
  clear)
    label="${1:-}"; [ -n "$label" ] || { echo "claude-accounts: clear needs a label" >&2; exit 2; }
    shift
    window=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --window) window="${2:-}"; shift 2 ;;
        *) echo "claude-accounts: unknown argument: $1" >&2; exit 2 ;;
      esac
    done
    run_py clear "$label" "$window"
    ;;
  *) echo "claude-accounts: unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
