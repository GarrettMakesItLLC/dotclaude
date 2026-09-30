#!/usr/bin/env bash
# Self-test for graphify-skill.sh with a stub `graphify` CLI: installs the skill
# from a scratch project install, replaces an older copy whole, never touches a
# CLAUDE.md outside the scratch dir, and --check reports missing/stale/current.
#   bash bin/graphify-skill.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GS="$HERE/graphify-skill.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }
unset BASH_ENV
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME/.claude" "$TMP/bin"
echo "# my global CLAUDE.md" >"$HOME/.claude/CLAUDE.md"

# The stub mimics `graphify install --project`: skill + references + version
# stamp under ./.claude/skills/graphify, plus a project CLAUDE.md.
cat >"$TMP/bin/graphify" <<'S'
#!/usr/bin/env bash
if [ "$1" = --version ]; then echo "graphify ${STUB_VERSION:-0.9.40}"; exit 0; fi
if [ "$1" = install ]; then
  mkdir -p .claude/skills/graphify/references
  echo "# graphify skill" > .claude/skills/graphify/SKILL.md
  echo "q" > .claude/skills/graphify/references/query.md
  printf '%s' "${STUB_VERSION:-0.9.40}" > .claude/skills/graphify/.graphify_version
  echo "## graphify" >> CLAUDE.md
  exit 0
fi
exit 2
S
chmod +x "$TMP/bin/graphify"
export PATH="$TMP/bin:$PATH"
D="$HOME/.claude/skills/graphify"

echo "graphify-skill: --check on a machine without the skill"
"$GS" --check >/dev/null 2>&1 && bad "--check passed with no skill" || ok "missing reported"

echo "graphify-skill: install"
out="$("$GS" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -f "$D/SKILL.md" ] && [ -f "$D/references/query.md" ] && ok "skill and references installed" || bad "rc=$rc $out"
[ "$(cat "$D/.graphify_version")" = 0.9.40 ] && ok "version stamp kept" || bad "stamp $(cat "$D/.graphify_version")"
[ "$(cat "$HOME/.claude/CLAUDE.md")" = "# my global CLAUDE.md" ] && ok "the global CLAUDE.md is untouched" || bad "CLAUDE.md modified"
"$GS" --check >/dev/null 2>&1 && ok "--check passes when current" || bad "--check failed when current"

echo "graphify-skill: a newer CLI makes the skill stale, and a refresh replaces it whole"
echo stale >"$D/references/dropped.md"
STUB_VERSION=0.9.41 "$GS" --check >/dev/null 2>&1 && bad "--check passed on a stale skill" || ok "stale reported"
STUB_VERSION=0.9.41 "$GS" >/dev/null 2>&1
[ "$(cat "$D/.graphify_version")" = 0.9.41 ] && [ ! -e "$D/references/dropped.md" ] && ok "refreshed, dropped file gone" || bad "refresh: $(ls "$D/references")"

exit "$fail"
