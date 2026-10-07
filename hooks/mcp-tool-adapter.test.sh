#!/usr/bin/env bash
# Self-test for mcp-tool-adapter.sh and for the hook coverage it exists for.
#   1. Synthetic Serena / Grep payloads, run through the adapter into the REAL
#      guards, are judged as the native call they amount to.
#   2. settings.json registers, for every tool in the table below that can run
#      a shell, read a file or write one, every guard that judges that kind of
#      call. A new shell-, read- or write-capable tool added to the table with
#      no registration turns this red.
#   bash hooks/mcp-tool-adapter.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$HERE/mcp-tool-adapter.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
unset DATABASE_URL DIRECT_URL BASH_ENV GIT_GUARD_HOOK_PROVEN_KILLED WORKTREE_GUARD_OFF CLAIM_GUARD_OFF

# check <want> <guard> <tool_name> <cwd> <tool_input-json>
check() {
  local want="$1" guard="$2" tool="$3" cwd="$4" ti="$5" got
  python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"cwd":sys.argv[2],"tool_input":json.loads(sys.argv[3])}))' \
    "$tool" "$cwd" "$ti" > "$TMP/payload.json"
  "$ADAPTER" "$guard" < "$TMP/payload.json" >/dev/null 2>"$TMP/err"
  got=$?
  [ "$got" = "$want" ] || { echo "FAIL: $guard on $tool $ti: want $want got $got ($(head -c 300 "$TMP/err"))"; fail=1; }
}
S=mcp__plugin_serena_serena__
S2=mcp__serena__

echo "mcp-tool-adapter: Serena's shell is judged as Bash"
check 2 git-guard "${S}execute_shell_command" "$TMP" '{"command":"git push --force origin main"}'
check 2 git-guard "${S2}execute_shell_command" "$TMP" '{"command":"git commit --no-verify -m x"}'
check 0 git-guard "${S}execute_shell_command" "$TMP" '{"command":"git status"}'
check 2 secret-read-guard "${S}execute_shell_command" "$TMP" '{"command":"cat ~/.config/secrets/gmi.env"}'
check 2 db-push-guard "${S}execute_shell_command" "$TMP" '{"command":"DIRECT_URL=postgresql://u:p@db.prodref.example.co:5432/postgres npx prisma db push"}'
check 2 heredoc-guard "${S}execute_shell_command" "$TMP" "$(printf '{"command":%s}' "$(python3 -c 'import json; print(json.dumps("cat > f <<EOF\n$(whoami)\nEOF"))')")"

echo "mcp-tool-adapter: Serena's reads and the Grep tool are judged as reads"
mkdir -p "$TMP/.config/secrets" "$TMP/repo"
check 2 secret-read-guard "${S}read_file" "$TMP" '{"relative_path":".config/secrets/gmi.env"}'
check 2 secret-read-guard "${S}read_file" "$TMP" "{\"relative_path\":\"$TMP/repo/.env.local\"}"
check 0 secret-read-guard "${S}read_file" "$TMP" '{"relative_path":"repo/src/app.ts"}'
check 2 secret-read-guard "${S}search_for_pattern" "$TMP" '{"substring_pattern":".","relative_path":".config/secrets"}'
check 2 secret-read-guard "${S}search_for_pattern" "$TMP" '{"substring_pattern":".","paths_include_glob":"**/*.env"}'
check 0 secret-read-guard "${S}search_for_pattern" "$TMP" '{"substring_pattern":"foo","relative_path":"repo"}'
check 2 secret-read-guard Grep "$TMP" "{\"pattern\":\".\",\"path\":\"$TMP/.config/secrets\"}"
check 2 secret-read-guard Grep "$TMP" "{\"pattern\":\".\",\"path\":\"$TMP/repo/.env\"}"
check 2 secret-read-guard Grep "$TMP" '{"pattern":".","glob":".env*"}'
check 0 secret-read-guard Grep "$TMP" "{\"pattern\":\"foo\",\"path\":\"$TMP/repo\",\"glob\":\"*.ts\"}"
check 0 secret-read-guard Grep "$TMP" '{"pattern":"foo","glob":"*"}'

echo "mcp-tool-adapter: Serena's writes are judged as Write/Edit"
R="$TMP/conv"
git init -q "$R"
printf '.worktrees/\n' > "$R/.gitignore"
git -C "$R" add .gitignore && git -C "$R" -c user.email=t@t -c user.name=t commit -qm init
git -C "$R" worktree add -q "$R/.worktrees/w" -b w 2>/dev/null
check 2 worktree-guard "${S}create_text_file" "$R" '{"relative_path":"src/new.ts","content":"x"}'
check 2 worktree-guard "${S}replace_content" "$R" '{"relative_path":".gitignore","needle":"a","repl":"b","mode":"literal"}'
check 2 worktree-guard "${S2}replace_in_files" "$R" '{"needle":"a","repl":"b","mode":"literal"}'
check 2 worktree-guard "${S}rename_symbol" "$R" '{"name_path":"f","relative_path":"src/a.ts","new_name":"g"}'
check 0 worktree-guard "${S}create_text_file" "$R/.worktrees/w" '{"relative_path":"src/new.ts","content":"x"}'
check 0 worktree-guard "${S}replace_symbol_body" "$R/.worktrees/w" '{"name_path":"f","relative_path":"a.ts","body":"x"}'

echo "mcp-tool-adapter: a native payload reaches the guard unchanged"
check 2 git-guard Bash "$TMP" '{"command":"git push --force origin main"}'
check 2 secret-read-guard Read "$TMP" "{\"file_path\":\"$TMP/.config/secrets/x.env\"}"
check 0 git-guard "mcp__github-rest__pr_view" "$TMP" '{"number":1}'
printf 'not json' | "$ADAPTER" git-guard >/dev/null 2>&1 || { echo "FAIL: garbage input did not fail open"; fail=1; }
printf '{}' | "$ADAPTER" ../evil >/dev/null 2>&1; [ $? = 2 ] || { echo "FAIL: a guard name with a path was accepted"; fail=1; }

echo "mcp-tool-adapter: settings.json registers every guard for every capable tool"
python3 - "$HERE/../settings.json" <<'PY' || fail=1
import json, re, sys
cfg = json.load(open(sys.argv[1]))
SHELL_GUARDS = {"git-guard", "worktree-cd-guard", "npm-install-guard", "heredoc-guard", "db-push-guard",
                "pr-base-guard", "secret-read-guard", "worktree-guard"}
READ_GUARDS = {"secret-read-guard"}
WRITE_GUARDS = {"worktree-guard", "claim-guard", "migration-guard"}
SERENA = ("mcp__plugin_serena_serena__", "mcp__serena__")
# The table. Add a tool here when one appears that can run a shell, read file
# contents, or write a file — and the registration it needs follows.
TABLE = {"Bash": SHELL_GUARDS, "Read": READ_GUARDS, "Grep": READ_GUARDS,
         "Edit": WRITE_GUARDS, "Write": WRITE_GUARDS, "MultiEdit": WRITE_GUARDS, "NotebookEdit": WRITE_GUARDS - {"migration-guard"}}
for p in SERENA:
    TABLE[p + "execute_shell_command"] = SHELL_GUARDS
    for op in ("read_file", "search_for_pattern"):
        TABLE[p + op] = READ_GUARDS
    for op in ("create_text_file", "replace_content", "replace_in_files", "delete_lines", "replace_lines",
               "insert_at_line", "replace_symbol_body", "insert_after_symbol", "insert_before_symbol",
               "rename_symbol", "safe_delete_symbol"):
        TABLE[p + op] = WRITE_GUARDS
NATIVE = {"Bash", "Read", "Grep", "Edit", "Write", "MultiEdit", "NotebookEdit"}

def matches(matcher, tool):
    if matcher in (None, "", "*"):
        return True
    if re.fullmatch(r"[A-Za-z0-9_|-]+", matcher):
        return tool in matcher.split("|")
    return re.fullmatch(matcher, tool) is not None

bad = 0
for tool, need in sorted(TABLE.items()):
    direct, adapted = set(), set()
    for group in cfg["hooks"].get("PreToolUse", []):
        if not matches(group.get("matcher"), tool):
            continue
        for h in group.get("hooks", []):
            cmd = h.get("command", "")
            m = re.search(r"/\.claude/hooks/mcp-tool-adapter\.sh\s+([A-Za-z0-9_-]+)", cmd)
            if m:
                adapted.add(m.group(1)); continue
            m = re.search(r"/\.claude/hooks/([A-Za-z0-9_-]+)\.sh", cmd)
            if m:
                direct.add(m.group(1))
    # A non-native payload means nothing to a guard unless the adapter restates it.
    have = direct | adapted if tool in NATIVE else adapted
    missing = sorted((need - have))
    if missing:
        print(f"FAIL: {tool} reaches no {', '.join(missing)}"); bad = 1
    if tool not in NATIVE and direct & (SHELL_GUARDS | READ_GUARDS | WRITE_GUARDS):
        print(f"FAIL: {tool} is registered directly on {sorted(direct)}, which cannot read its payload"); bad = 1

# PostToolUse: every tool that runs a shell has its output scanned. The guard
# reads Serena's MCP result shape itself, so it is registered directly, not
# through the adapter (which restates PreToolUse INPUT only).
POST_SHELL_GUARDS = {"credential-output-guard"}
for tool in sorted(t for t, need in TABLE.items() if need is SHELL_GUARDS):
    have = set()
    for group in cfg["hooks"].get("PostToolUse", []):
        if matches(group.get("matcher"), tool):
            for h in group.get("hooks", []):
                m = re.search(r"/\.claude/hooks/([A-Za-z0-9_-]+)\.sh", h.get("command", ""))
                if m:
                    have.add(m.group(1))
    missing = sorted(POST_SHELL_GUARDS - have)
    if missing:
        print(f"FAIL: {tool}'s output reaches no PostToolUse {', '.join(missing)}"); bad = 1
sys.exit(bad)
PY

[ "$fail" = 0 ] && echo "mcp-tool-adapter: all cases passed"
exit "$fail"
