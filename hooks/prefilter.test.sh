#!/usr/bin/env bash
# Self-test for the raw-input prefilters (and claim-guard's fast parse) that let a
# hook exit before it starts python. A prefilter must never cause a miss, so for
# every prefiltered hook this runs a corpus through the hook twice, with the
# prefilter on and with DOTCLAUDE_NO_PREFILTER=1, and asserts the exit code,
# stdout and stderr are identical. The corpus has, per hook, one input for each
# keyword its prefilter keys on (quoting, case and encoding variants included),
# and each of those must still FIRE (block, or emit its report): a prefilter that
# skipped it would turn a firing case quiet and fail here.
#   bash hooks/prefilter.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

export HOME="$TMP/home" TMPDIR="$TMP" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$TMP/bin"
unset DOTCLAUDE_NO_PREFILTER WORKTREE_GUARD_OFF CLAIM_GUARD_OFF NODE_AUTH_TOKEN GITHUB_TOKEN

# --- fixtures ---------------------------------------------------------------
# REPO: a main checkout that uses .worktrees/, with tracked work uncommitted, an
# untracked file, and a linked worktree holding branch `held`.
REPO="$TMP/repo"
git init -q -b main "$REPO"
printf 'tracked\n' >"$REPO/f"
printf '.worktrees/\n' >"$REPO/.gitignore"
git -C "$REPO" add . && git -C "$REPO" commit -q -m init
git -C "$REPO" worktree add -q "$REPO/.worktrees/held" -b held
printf 'dirty\n' >"$REPO/f"
printf 'x\n' >"$REPO/untracked"

# TWO: a two-tier repo (origin/dev exists) on a feature branch, for pr-base-guard.
TWO="$TMP/two"
git init -q -b main "$TWO"
git -C "$TWO" commit -q --allow-empty -m init
git -C "$TWO" remote add origin git@github.com:Org/Two.git
git -C "$TWO" update-ref refs/remotes/origin/main HEAD
git -C "$TWO" update-ref refs/remotes/origin/dev HEAD
git -C "$TWO" checkout -q -b feat/x

# PINNED: npm pinned to a major the stub npm does not match, with an empty token.
printf '#!/bin/sh\n[ "$1" = --version ] && echo 11.4.0\n' >"$TMP/bin/npm"
chmod +x "$TMP/bin/npm"
PINNED="$TMP/pinned"; mkdir -p "$PINNED"
echo '{ "name": "p", "packageManager": "npm@10.8.2" }' >"$PINNED/package.json"
echo '//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}' >"$PINNED/.npmrc"
export PATH="$TMP/bin:$PATH"

# --- harness ----------------------------------------------------------------
# payload <tool> <cwd> <command>  (Bash)  /  jpayload <json>
bash_payload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"session_id":"s","tool_input":{"command":sys.argv[1]}}))' "$1" "$2"
}

# run <hook> <cwd> <json> [off]  ->  "rc<TAB>stdout<TAB>stderr" in $RESULT
run_hook() {
  local hook="$1" cwd="$2" json="$3" off="${4:-}" so se rc
  so="$TMP/so"; se="$TMP/se"
  if [ -n "$off" ]; then
    (cd "$cwd" && printf '%s' "$json" | DOTCLAUDE_NO_PREFILTER=1 "$HERE/$hook.sh" >"$so" 2>"$se"); rc=$?
  else
    (cd "$cwd" && printf '%s' "$json" | "$HERE/$hook.sh" >"$so" 2>"$se"); rc=$?
  fi
  RESULT="$rc|$(cat "$so")|$(cat "$se")"
}

# check <fires|quiet> <hook> <label> <cwd> <json>
check() {
  local want="$1" hook="$2" label="$3" cwd="$4" json="$5" on off rc out
  run_hook "$hook" "$cwd" "$json"; on="$RESULT"
  run_hook "$hook" "$cwd" "$json" off; off="$RESULT"
  if [ "$on" != "$off" ]; then
    echo "FAIL ($hook / $label): prefilter changed the result"
    echo "  prefilter on : $on"
    echo "  prefilter off: $off"
    fail=1
    return
  fi
  rc="${on%%|*}"; out="${on#*|}"; out="${out%%|*}"
  case "$want" in
    fires) { [ "$rc" != 0 ] || [ -n "$out" ]; } || { echo "FAIL ($hook / $label): expected the hook to fire, it was silent"; fail=1; } ;;
    quiet) { [ "$rc" = 0 ] && [ -z "$out" ]; } || { echo "FAIL ($hook / $label): expected silence, got rc=$rc out=$out"; fail=1; } ;;
  esac
}

b() { bash_payload "$1" "${2:-$REPO}"; }

# --- pooler-readonly-guard: keyword read[_ -]only | read%5fonly, any case ----
H=pooler-readonly-guard
DB='postgres://u:p@db.x.supabase.co:6543/postgres'
check fires $H 'read_only'        "$REPO" "$(b "psql '$DB' -c 'SET default_transaction_read_only = on'")"
check fires $H 'READ_ONLY upper'  "$REPO" "$(b "psql '$DB' -c 'SET DEFAULT_TRANSACTION_READ_ONLY = ON'")"
check fires $H 'read-only'        "$REPO" "$(b "psql '$DB' -c 'SET default_transaction_read-only = on'")"
check fires $H 'read only'        "$REPO" "$(b "psql '$DB' -c 'SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY'")"
check fires $H 'read%5fonly'      "$REPO" "$(b "psql '$DB' -c 'SET default_transaction_read%5fonly = on'")"
check quiet $H 'unrelated'        "$REPO" "$(b "ls -la")"
check quiet $H 'mentions it, sets nothing' "$REPO" "$(b "echo read_only")"

# --- db-push-guard: prisma ... push, through quotes and wrappers -------------
H=db-push-guard
check fires $H 'plain'            "$REPO" "$(b 'npx prisma db push')"
check fires $H 'pnpm exec'        "$REPO" "$(b 'pnpm exec prisma db push --accept-data-loss')"
check fires $H 'quoted prisma'    "$REPO" "$(b 'npx "prisma" db push')"
check fires $H 'quote-split push' "$REPO" "$(b "npx prisma db pu''sh")"
check quiet $H 'backslash split (the guard itself does not read it)' "$REPO" "$(b 'npx pri\sma db push')"
check fires $H 'after a separator' "$REPO" "$(b 'cd x; npx prisma db push')"
check quiet $H 'unrelated'        "$REPO" "$(b 'git push origin main')"
check quiet $H 'prisma, no push'  "$REPO" "$(b 'npx prisma generate')"

# --- npm-install-guard: keyword npm ------------------------------------------
H=npm-install-guard
check fires $H 'npm ci, empty token' "$PINNED" "$(b 'NODE_AUTH_TOKEN="" npm ci' "$PINNED")"
check fires $H 'npm install, wrong major' "$PINNED" "$(b 'npm install left-pad' "$PINNED")"
check quiet $H 'unrelated'        "$PINNED" "$(b 'ls' "$PINNED")"

# --- verify-reminder and pr-base-guard: gh pr create | pr_create -------------
for H in verify-reminder pr-base-guard; do
  check fires $H 'gh pr create (base main from feature)' "$TWO" "$(b 'gh pr create --base main --title x' "$TWO")"
  check quiet $H 'gh pr list'       "$TWO" "$(b 'gh pr list --base main' "$TWO")"
  check quiet $H 'unrelated'        "$TWO" "$(b 'ls' "$TWO")"
done
H=verify-reminder
check fires $H 'chained'          "$TWO" "$(b 'git push origin HEAD && gh pr create --fill' "$TWO")"
check fires $H 'mcp pr_create'    "$TWO" '{"tool_name":"mcp__github-rest__pr_create","tool_input":{}}'
H=pr-base-guard
check fires $H 'mcp pr_create'    "$TWO" '{"tool_name":"mcp__github-rest__pr_create","tool_input":{"title":"x","head":"feat/x","base":"main"}}'
check fires $H 'quoted words'     "$TWO" "$(b 'gh "pr" create --base main' "$TWO")"
check fires $H 'backslash words'  "$TWO" "$(b 'gh p\r create --base main' "$TWO")"
check fires $H '--base=main'      "$TWO" "$(b 'gh pr create --base=main --fill' "$TWO")"

# --- tool-gap-reporter: keyword rror (isError, is_error, error, Error:) ------
H=tool-gap-reporter
gap() { # label response-json: two failures of one tool fire the report
  local label="$1" resp="$2" json mode out
  json="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","tool_name":"mcp__x__t","session_id":"s","tool_response":json.loads(sys.argv[1])}))' "$resp")"
  for mode in on off; do
    rm -rf "$TMP/gaps-$mode"
    export TOOL_GAP_STATE_DIR="$TMP/gaps-$mode"
    if [ "$mode" = off ]; then export DOTCLAUDE_NO_PREFILTER=1; else unset DOTCLAUDE_NO_PREFILTER; fi
    printf '%s' "$json" | "$HERE/$H.sh" >/dev/null 2>&1
    out="$(printf '%s' "$json" | "$HERE/$H.sh" 2>&1)"
    if [ "$mode" = on ]; then ON_OUT="$out"; else OFF_OUT="$out"; fi
  done
  unset DOTCLAUDE_NO_PREFILTER
  if [ "$ON_OUT" != "$OFF_OUT" ]; then echo "FAIL ($H / $label): prefilter changed the result"; fail=1; return; fi
  case "$ON_OUT" in *mcp__x__t*) ;; *) echo "FAIL ($H / $label): the second failure did not fire"; fail=1 ;; esac
}
gap 'isError'       '{"isError":true,"content":[{"type":"text","text":"boom"}]}'
gap 'is_error'      '{"is_error":true}'
gap 'error key'     '{"error":"timed out"}'
gap 'MCP error'     '"MCP error -32602: bad"'
gap 'Error: string' '"Error: nope"'
gap 'InputValidationError' '"InputValidationError: x"'
check quiet $H 'success, no error text' "$REPO" '{"hook_event_name":"PostToolUse","tool_name":"mcp__x__t","tool_response":"ok"}'

# --- git-guard: git + discard verbs; git + steal verbs -----------------------
H=git-guard
check fires $H 'reset --hard'          "$REPO" "$(b 'git reset --hard')"
check fires $H 'checkout -- path'      "$REPO" "$(b 'git checkout -- f')"
check fires $H 'restore path'          "$REPO" "$(b 'git restore f')"
check fires $H 'forced switch'         "$REPO" "$(b 'git switch -f main')"
check fires $H 'clean -f'              "$REPO" "$(b 'git clean -f')"
check fires $H 'read-tree --reset -u'  "$REPO" "$(b 'git read-tree --reset -u HEAD')"
check fires $H 'checkout-index -f'     "$REPO" "$(b 'git checkout-index -f -a')"
check fires $H 'quote-split verb'      "$REPO" "$(b "git res''et --hard")"
check fires $H 'quote-split git'       "$REPO" "$(b 'g"i"t reset --hard')"
check fires $H 'wrapped in bash -c'    "$REPO" "$(b "bash -c 'git reset --hard'")"
check fires $H 'checkout -B held'      "$REPO" "$(b 'git checkout -B held')"
check fires $H 'branch -f held'        "$REPO" "$(b 'git branch -f held HEAD')"
check fires $H 'update-ref held'       "$REPO" "$(b 'git update-ref refs/heads/held HEAD')"
check fires $H 'switch -C held'        "$REPO" "$(b 'git switch -C held')"
check quiet $H 'unrelated'             "$REPO" "$(b 'ls -la')"
check quiet $H 'git status'            "$REPO" "$(b 'git status')"

# --- worktree-guard: node_modules link, and the write shapes -----------------
H=worktree-guard
T="$REPO/new.txt"
check fires $H 'ln -s node_modules'    "$REPO" "$(b "ln -s /other/node_modules $REPO/node_modules")"
check fires $H 'cp -sl node_modules'   "$REPO" "$(b "cp -al /other/node_modules $REPO/node_modules")"
check fires $H 'redirect >'            "$REPO" "$(b "echo x > $T")"
check fires $H 'redirect >>'           "$REPO" "$(b "echo x >> $T")"
check fires $H 'tee'                   "$REPO" "$(b "echo x | tee $T")"
check fires $H 'cp'                    "$REPO" "$(b "cp /etc/hostname $T")"
check fires $H 'mv'                    "$REPO" "$(b "mv /tmp/a $T")"
check fires $H 'install'               "$REPO" "$(b "install -m 644 /etc/hostname $T")"
check fires $H 'sed -i'                "$REPO" "$(b "sed -i s/a/b/ $REPO/f")"
check fires $H 'quote-split cp'        "$REPO" "$(b "c\"p\" /etc/hostname $T")"
check fires $H 'python heredoc open'   "$REPO" "$(b "python3 - <<'EOF'
open('$T', 'w').write('x')
EOF")"
check fires $H 'Edit tool'             "$REPO" "{\"tool_name\":\"Edit\",\"cwd\":\"$REPO\",\"tool_input\":{\"file_path\":\"$T\"}}"
check fires $H 'Write tool, "Bash" in text' "$REPO" "{\"tool_name\":\"Write\",\"cwd\":\"$REPO\",\"tool_input\":{\"file_path\":\"$T\",\"content\":\"\\\"tool_name\\\":\\\"Bash\\\"\"}}"
check quiet $H 'ls'                    "$REPO" "$(b 'ls -la')"
check quiet $H 'git status'            "$REPO" "$(b 'git status')"
check quiet $H 'write inside .worktrees' "$REPO" "$(b "echo x > $REPO/.worktrees/held/n.txt")"

# --- worktree-bootstrap: git worktree add -------------------------------------
H=worktree-bootstrap
PROJ="$TMP/proj"; mkdir -p "$PROJ/bin" "$PROJ/.worktrees/wt"
cat >"$PROJ/bin/setup-worktree.sh" <<EOF
#!/usr/bin/env bash
printf '%s' "\$1" > "$TMP/bootstrap-record"
EOF
chmod +x "$PROJ/bin/setup-worktree.sh"
for mode in on off; do
  rm -f "$TMP/bootstrap-record"
  if [ $mode = off ]; then export DOTCLAUDE_NO_PREFILTER=1; else unset DOTCLAUDE_NO_PREFILTER; fi
  b "git worktree add $PROJ/.worktrees/wt" "$PROJ" | CLAUDE_PROJECT_DIR="$PROJ" "$HERE/$H.sh" >/dev/null 2>&1
  for _ in $(seq 1 100); do [ -f "$TMP/bootstrap-record" ] && break; sleep 0.05; done
  [ -f "$TMP/bootstrap-record" ] || { echo "FAIL ($H / prefilter $mode): git worktree add did not run the setup script"; fail=1; }
done
unset DOTCLAUDE_NO_PREFILTER
rm -f "$TMP/bootstrap-record"
b 'ls' "$PROJ" | CLAUDE_PROJECT_DIR="$PROJ" "$HERE/$H.sh" >/dev/null 2>&1
sleep 0.2
[ ! -f "$TMP/bootstrap-record" ] || { echo "FAIL ($H): ls ran the setup script"; fail=1; }

# --- claim-guard: the fast parse must read what python reads -----------------
# An unclaimed issue branch is blocked via a stub API; an Edit whose text holds
# backslashes and quotes (the python path) and a plain one (the regex path) must
# agree, and so must a NotebookEdit's notebook_path.
H=claim-guard
CG="$TMP/cg"; git init -q -b issue-7-x "$CG"
git -C "$CG" remote add origin git@github.com:Org/Repo.git
printf '#!/bin/sh\necho tok\n' >"$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
cat >"$TMP/api.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = b'{"assignees":[],"labels":[]}'
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
srv = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$TMP/api.py" "$TMP/api-port" & API=$!
trap 'kill "$API" 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do [ -s "$TMP/api-port" ] && break; sleep 0.1; done
api_port="$(cat "$TMP/api-port")"
export CLAIM_GUARD_API="http://127.0.0.1:$api_port" CLAIM_GUARD_CACHE_DIR="$TMP/cg-cache" NO_PROXY=127.0.0.1 no_proxy=127.0.0.1
check fires $H 'Edit, plain payload'    "$CG" "{\"session_id\":\"s\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$CG/a.txt\",\"old_string\":\"a\",\"new_string\":\"b\"}}"
check fires $H 'Edit, escaped payload'  "$CG" "{\"session_id\":\"s\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$CG/a.txt\",\"old_string\":\"a\\\\\\\"b\",\"new_string\":\"b\"}}"
check fires $H 'NotebookEdit'           "$CG" "{\"session_id\":\"s\",\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"$CG/n.ipynb\",\"new_source\":\"x\"}}"
check fires $H 'no session_id'          "$CG" "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$CG/a.txt\"}}"
check quiet $H 'no path'                "$CG" '{"session_id":"s","tool_name":"Edit","tool_input":{}}'

if [ "$fail" = 0 ]; then echo "prefilter: all cases passed"; fi
exit "$fail"
