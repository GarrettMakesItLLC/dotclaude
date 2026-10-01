#!/usr/bin/env bash
# Self-test for heredoc-guard.sh: an unquoted heredoc whose body would expand is
# refused; quoted delimiters, escaped spans, here-strings and the opt-in pass.
#   bash hooks/heredoc-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/heredoc-guard.sh"
fail=0

check() {
  local want="$1" cmd="$2" got
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd" \
    | "$GUARD" >/dev/null 2>&1
  got=$?
  [ "$got" = "$want" ] || { echo "FAIL: want $want got $got for: $cmd"; fail=1; }
}

BT='`'
# Should BLOCK — the reported shape: a markdown code span in an unquoted body.
check 2 "python3 - <<EOF
doc = 'run ${BT}npx prisma migrate deploy${BT} first'
EOF"
check 2 "cat > notes.md <<-END
	see \$(date)
	END"
# A second, unquoted heredoc after a quoted one is still judged.
check 2 "cat <<'A' > a.txt
${BT}safe${BT}
A
cat <<B > b.txt
${BT}ran${BT}
B"

# Should ALLOW — quoted delimiters pass the body through untouched.
check 0 "python3 - <<'EOF'
doc = 'run ${BT}npx prisma migrate deploy${BT} first'
EOF"
check 0 "cat <<\"EOF\"
\$(date)
EOF"
check 0 "cat <<\\EOF
${BT}x${BT}
EOF"
# Should ALLOW — an unquoted body that only interpolates a variable.
check 0 "python3 - <<EOF
print('\$HOME')
EOF"
# Should ALLOW — escaped spans are literal in an unquoted body.
check 0 "cat <<EOF
\\${BT}x\\${BT} and \\\$(y)
EOF"
# Should ALLOW — a here-string, and a << inside quotes, are not heredocs.
check 0 "grep -c x <<< \"\$(date)\""
check 0 "echo 'use <<EOF here' && echo \$(date)"
# Should ALLOW — the explicit opt-in.
check 0 "HEREDOC_EXPAND_OK=1 cat <<EOF
built \$(date)
EOF"
# Not Bash, and not JSON: fail open.
python3 -c 'import json; print(json.dumps({"tool_name":"Write","tool_input":{"content":"<<EOF"}}))' | "$GUARD" >/dev/null 2>&1 \
  || { echo "FAIL: non-Bash tool was judged"; fail=1; }
printf 'not json' | "$GUARD" >/dev/null 2>&1 || { echo "FAIL: garbage input did not fail open"; fail=1; }

[ "$fail" = 0 ] && echo "heredoc-guard: all cases passed"
exit "$fail"
