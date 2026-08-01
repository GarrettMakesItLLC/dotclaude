#!/usr/bin/env bash
# dotclaude subagent-evidence — SubagentStop hook. Blocks a subagent from ending
# its turn when its report CLAIMS completed code work but shows no command
# output, sending it back to run its checks and report them.
#
# Why this exists: CLAUDE.md (Execution) says every dispatched subagent runs the
# checks for its slice and includes the output — "done without evidence is a
# claim, not a fact". That lives as prose, and prose is what a subagent follows
# probabilistically; a report reading "implemented and working" is
# indistinguishable from one that verified nothing. SubagentStop hands over
# `last_assistant_message`, so the report can be judged without touching a
# transcript.
#
# Why the signal is two-sided (claims work AND no evidence): a wrong block costs
# a whole extra subagent round-trip, which is far more expensive than a missed
# one. Either half alone passes — a research subagent claims nothing, and any
# report carrying check output is already compliant. Ambiguity passes.
#
# Why blocking here and NOT nudging (the opposite of verify-reminder.sh): a
# subagent can satisfy this by running its checks and re-reporting, and
# `stop_hook_active` guarantees the retry is never blocked a second time. There
# is no deadlock to design around.
#
# Fail-open by design: no python3, malformed JSON, a different event, an empty
# report -> exit 0 and let the turn end. A judgment call this fuzzy must never be
# the reason work cannot finish.

set -uo pipefail

input="$(cat)"

command -v python3 >/dev/null 2>&1 || exit 0

printf '%s' "$input" | python3 -c '
import json, re, sys

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if d.get("hook_event_name") != "SubagentStop":
    sys.exit(0)

# The retry. Blocking again would loop the subagent against a heuristic it may
# have no way to satisfy.
if d.get("stop_hook_active"):
    sys.exit(0)

# Agents that cannot write code have no checks to run. Their reports are prose by
# definition and must never be gated on command output.
READ_ONLY = {"Explore", "Plan", "claude-code-guide", "statusline-setup"}
if d.get("agent_type", "") in READ_ONLY:
    sys.exit(0)

report = d.get("last_assistant_message") or ""
if not report.strip():
    sys.exit(0)

# Past-tense claims of shipped code. Present/future ("will add", "should fix")
# deliberately does not match — that is a plan, not a claim of completion.
CLAIMS_WORK = re.compile(
    r"\b(implemented|fixed|added|created|updated|refactored|migrated|renamed|"
    r"removed|deleted|wrote|rewrote|patched|introduced|wired up|"
    r"(?:is|are|now) (?:working|passing|done|complete))\b",
    re.I,
)

# Either the invocation of a check, or the shape of its output. Both are strong
# signals that something was actually run rather than asserted.
HAS_EVIDENCE = re.compile(
    r"(\b(npm|pnpm|yarn|npx|bun|tsc|vitest|jest|playwright|pytest|cargo|make|"
    r"ruff|eslint|shellcheck|mypy|gradle|mvn|dotnet)\b|"
    r"\bgo test\b|\bbash .*\.sh\b|"
    r"\b(tests?|checks?|suites?) (passed|passing|failed)\b|"
    r"\b\d+ (passed|failed|passing|failing|errors?|warnings?)\b|"
    r"\bTests?:\s|\bexit (code|status)\b|\bPASS\b|\bFAIL\b|✓|✔)",
    re.I,
)

# The escape the block reason itself offers. A subagent that already stated its
# slice had nothing to run has answered the question — blocking it to make it say
# the same thing twice is pure round-trip.
NO_CHECKS_NEEDED = re.compile(
    r"\b(docs?[- ]only|documentation[- ]only|no code (change|edit)|"
    r"nothing to (run|verify|test)|no (tests?|checks?) to run|"
    r"read[- ]only|comment[- ]only)\b",
    re.I,
)

if (
    CLAIMS_WORK.search(report)
    and not HAS_EVIDENCE.search(report)
    and not NO_CHECKS_NEEDED.search(report)
):
    reason = (
        "This report claims completed work but shows no command output, and "
        "CLAUDE.md (Execution) requires every dispatched subagent to run the checks for its "
        "slice and include the output — \"done without evidence is a claim, not a fact\".\n"
        "Run the check that actually covers what you changed (typecheck — CI runs the rest) "
        "and paste the real output into your report. Do not paraphrase it and do not fabricate it.\n"
        "If your slice genuinely had nothing to run — research, reading, a docs-only edit — "
        "say so in one line and end the turn; that is an accepted answer."
    )
    print(json.dumps({"decision": "block", "reason": reason}))

sys.exit(0)
'

exit 0
