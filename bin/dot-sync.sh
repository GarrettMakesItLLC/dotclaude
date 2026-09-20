#!/usr/bin/env bash
# dot-sync — bring this machine fully up to date with dotclaude + dotfiles
# and everything they now install. The one thing to type instead of
# remembering to pull two repos, rebuild a gitignored MCP dist, and re-check
# links by hand.
#
# The SessionStart hook (hooks/dotrepo-sync.sh) already does the fast,
# silent, every-session part of this — a clean fast-forward of both repos
# plus a rebuild of the github MCP when its sources changed. This script
# SOURCES that hook (DOTREPO_SYNC_SOURCED=1) to reuse the exact same
# sync_repo/rebuild_artifacts logic rather than a second copy of it, then
# does the slower or more consequential things a session start must not pay
# for on every launch:
#
#   1. pull dotclaude + dotfiles (via the sourced hook, verbosely)
#   2. `bootstrap.sh --check` for dotclaude, dotfiles' own installer for
#      dotfiles — report drift with the fix command, never apply it silently
#   3. flag (and, with --build-mcp, rebuild) a stale github MCP dist
#   4. fast-forward the rest of the repo fleet (bin/repo-sweep.sh), which
#      is where drift actually hides — the dot repos are pulled every
#      session, the repos everything BUILDS against are not
#   5. refresh the Obsidian vault, only with --kb (bin/kb-sync.sh; several
#      seconds, a copy of multiple trees)
#   6. report the agent gateway / Claude account ledger state, if those
#      files exist on this machine — never create or edit them, another
#      agent owns them
#   7. report what the machine is still missing: an un-run install, an
#      absent credential file the roster expects, a tool the sync itself
#      needed and didn't find
#
# Usage:
#   bin/dot-sync.sh                 # pull + check + report (fast when current)
#   bin/dot-sync.sh --fix           # also apply `bootstrap.sh` for reported link drift
#   bin/dot-sync.sh --build-mcp     # also rebuild a stale github MCP dist outright
#   bin/dot-sync.sh --kb            # also refresh the Obsidian vault (bin/kb-sync.sh)
#   bin/dot-sync.sh --deps          # also install deps in a fleet repo that moved
#   bin/dot-sync.sh --no-repos      # skip the fleet sweep (dot repos only)
#   bin/dot-sync.sh --skip-checks   # pull only — skip bootstrap --check and reports
#
# Every step reports what it did or found; nothing here is silent about a
# step it skipped. Exit 0 unless a pull genuinely needs a human (dirty tree,
# diverged history) or --fix/--build-mcp itself fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_self_repo="$(cd "$HERE/.." && pwd)"

# Same redirect bootstrap.sh does: ~/.claude always tracks the MAIN checkout,
# never a linked worktree, so a worktree's own `.git` is a file (not a dir)
# and would otherwise make sync_repo below wrongly report dotclaude as "not
# found". Honors DOTCLAUDE_DIR if the caller set one (tests, another machine
# layout) rather than second-guessing it.
if [ -z "${DOTCLAUDE_DIR:-}" ]; then
  DOTCLAUDE_DIR="$_self_repo"
  if git -C "$_self_repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    main_tree="$(git -C "$_self_repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    main_tree="${main_tree%/.git}"
    if [ -n "$main_tree" ] && [ "$main_tree" != "$_self_repo" ] && [ -f "$main_tree/bootstrap.sh" ]; then
      DOTCLAUDE_DIR="$main_tree"
    fi
  fi
fi
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"

FIX=0
BUILD_MCP=0
DO_KB=0
DO_REPOS=1
DO_DEPS=0
SKIP_CHECKS=0
for arg in "$@"; do
  case "$arg" in
    --fix)         FIX=1 ;;
    --build-mcp)   BUILD_MCP=1 ;;
    --kb)          DO_KB=1 ;;
    --no-repos)    DO_REPOS=0 ;;
    --deps)        DO_DEPS=1 ;;
    --skip-checks) SKIP_CHECKS=1 ;;
    -h|--help)
      sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "dot-sync: unknown option '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

status=0
say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
note() { printf '  \033[36m·\033[0m     %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m     %s\n' "$*"; status=1; }

# --------------------------------------------------------------------------
# 1. Pull both repos — reuse the SessionStart hook's engine verbatim.
# --------------------------------------------------------------------------
say "1. Pulling dotclaude + dotfiles"

# shellcheck disable=SC2034  # read by the sourced hooks/dotrepo-sync.sh below
DOTREPO_SYNC_SOURCED=1
# shellcheck disable=SC2034  # read by the sourced hooks/dotrepo-sync.sh below
DOTSYNC_VERBOSE=1
# Sourced from THIS checkout (not $DOTCLAUDE_DIR, which may be a different,
# not-yet-pulled main checkout when run from a worktree) — dot-sync.sh and
# its pull engine ship together in the same commit, so they must always be
# the same pair of files.
# shellcheck source=hooks/dotrepo-sync.sh
source "$_self_repo/hooks/dotrepo-sync.sh"

sync_repo "$DOTCLAUDE_DIR" "dotclaude"
sync_repo "$DOTFILES_DIR" "dotfiles"

# shellcheck disable=SC2154  # `notes` is declared and populated by the sourced hook
if [ "${#notes[@]}" -eq 0 ]; then
  ok "nothing to pull"
else
  for n in "${notes[@]}"; do
    case "$n" in
      *"resolve by hand"*|*"Nothing was overwritten"*) bad "$n" ;;
      *) note "$n" ;;
    esac
  done
fi

if [ "$SKIP_CHECKS" = 1 ]; then
  echo
  echo "dot-sync: --skip-checks — pull only, done."
  exit "$status"
fi

# --------------------------------------------------------------------------
# 2. bootstrap.sh --check for dotclaude; dotfiles' own installer for dotfiles.
# --------------------------------------------------------------------------
say "2. Config drift"

if [ -f "$DOTCLAUDE_DIR/bootstrap.sh" ]; then
  if bootstrap_out="$(bash "$DOTCLAUDE_DIR/bootstrap.sh" --check 2>&1)"; then
    ok "dotclaude: bootstrap.sh --check is clean"
  elif [ "$FIX" = 1 ]; then
    note "dotclaude: bootstrap.sh --check found drift — --fix passed, running bootstrap.sh"
    echo "$bootstrap_out" | sed 's/^/      /'
    if bash "$DOTCLAUDE_DIR/bootstrap.sh" 2>&1 | sed 's/^/      /'; then
      ok "dotclaude: bootstrap.sh applied"
    else
      bad "dotclaude: bootstrap.sh failed to apply — run it by hand"
    fi
  else
    bad "dotclaude: bootstrap.sh --check found drift"
    echo "$bootstrap_out" | sed 's/^/      /'
    note "fix: bash $DOTCLAUDE_DIR/bootstrap.sh   (re-run dot-sync.sh --fix to apply)"
  fi
else
  note "dotclaude: no bootstrap.sh found at $DOTCLAUDE_DIR — skipped"
fi

# dotfiles has no separate --check mode: install.sh IS the check — it reports
# "already wired" for anything already in place and only appends/adds what's
# missing (a marker line in ~/.bashrc, a git include.path entry). Idempotent
# and side-effect-free on an already-current machine, so it is always safe to
# run rather than gated behind --fix, unlike dotclaude's bootstrap.sh (which
# moves real files to a timestamped backup dir and so needs consent first).
if [ -f "$DOTFILES_DIR/install.sh" ]; then
  install_out="$(bash "$DOTFILES_DIR/install.sh" 2>&1)"
  if printf '%s' "$install_out" | grep -q "already wired\|already including"; then
    ok "dotfiles: install.sh — already wired"
  else
    note "dotfiles: install.sh made changes:"
    echo "$install_out" | sed 's/^/      /'
  fi
else
  note "dotfiles: no install.sh found at $DOTFILES_DIR — skipped"
fi

# --------------------------------------------------------------------------
# 3. github MCP dist staleness (the #325 incident this whole thing exists
#    for) — bootstrap.sh --check above already flags it; --build-mcp forces
#    a rebuild here even when the hook's pull didn't just touch it (e.g. the
#    dist was never built, or went stale by some path other than a pull).
# --------------------------------------------------------------------------
say "3. github MCP build"

mcp_dir="$DOTCLAUDE_DIR/mcp/github"
if [ -f "$mcp_dir/package.json" ]; then
  if [ ! -f "$mcp_dir/dist/index.js" ]; then
    mcp_state="missing"
  elif [ -n "$(find "$mcp_dir/src" -newer "$mcp_dir/dist/index.js" -type f 2>/dev/null)" ]; then
    mcp_state="stale"
  else
    mcp_state="current"
  fi

  case "$mcp_state" in
    current) ok "github MCP dist is current" ;;
    missing|stale)
      if [ "$BUILD_MCP" = 1 ]; then
        note "github MCP dist is $mcp_state — --build-mcp passed, running npm ci && npm run build in $mcp_dir"
        if ( cd "$mcp_dir" && npm ci >/dev/null 2>&1 && npm run build >/dev/null 2>&1 ); then
          ok "github MCP rebuilt — restart the session to pick it up"
        else
          bad "github MCP build failed — run it by hand: (cd $mcp_dir && npm ci && npm run build)"
        fi
      else
        bad "github MCP dist is $mcp_state"
        note "fix: (cd $mcp_dir && npm ci && npm run build)   (re-run dot-sync.sh --build-mcp to apply)"
      fi
      ;;
  esac
else
  note "github MCP not vendored in this checkout — skipped"
fi

# --------------------------------------------------------------------------
# 4. The rest of the repo fleet. The two dot repos are pulled every session;
#    the repos everything BUILDS against are not, and that is where drift
#    actually hides — one machine's `platform` sat 52 commits behind for three
#    weeks with nothing broken enough to notice. Delegated to bin/repo-sweep.sh
#    so dotfiles' bootstrap/device.sh runs the same code rather than a second
#    copy of it. Fast-forward only; every skip is reported with its reason.
# --------------------------------------------------------------------------
say "4. Repo fleet"

sweep="$DOTCLAUDE_DIR/bin/repo-sweep.sh"
if [ "$DO_REPOS" != 1 ]; then
  note "skipped (--no-repos)"
elif [ ! -x "$sweep" ]; then
  note "bin/repo-sweep.sh not found or not executable — may be mid-merge on another machine"
else
  sweep_args=()
  [ "$DO_DEPS" = 1 ] && sweep_args+=(--deps)
  if bash "$sweep" "${sweep_args[@]+"${sweep_args[@]}"}" 2>&1 | sed 's/^/      /'; then
    ok "fleet swept"
  else
    bad "repo-sweep.sh failed — see output above"
  fi
fi

# --------------------------------------------------------------------------
# 5. Obsidian vault refresh — only with --kb (docs/knowledge-base.md: a copy
#    of several trees, seconds of cost, not something every sync should pay).
# --------------------------------------------------------------------------
say "5. Knowledge base (Obsidian vault)"

kb_sync="$DOTCLAUDE_DIR/bin/kb-sync.sh"
if [ "$DO_KB" != 1 ]; then
  note "skipped (pass --kb to refresh the vault)"
elif [ ! -f "$kb_sync" ]; then
  note "bin/kb-sync.sh not found — may be mid-merge on another machine, tolerating absence"
else
  if bash "$kb_sync" 2>&1 | sed 's/^/      /'; then
    ok "vault refreshed"
  else
    bad "kb-sync.sh failed — see output above"
  fi
fi

# --------------------------------------------------------------------------
# 6. Agent gateway / Claude account ledger — report only. Another agent owns
#    these files; this script must never create or edit them.
# --------------------------------------------------------------------------
say "6. Agent gateway / account ledger"

gateway_found=0
shopt -s nullglob
for f in "$DOTCLAUDE_DIR"/bin/gateway-*.sh "$DOTCLAUDE_DIR"/bin/claude-accounts*.sh; do
  gateway_found=1
  if [ -x "$f" ]; then
    ok "found: $(basename "$f") (executable)"
  elif head -5 "$f" 2>/dev/null | grep -qi 'sourced, never run'; then
    # A library that is sourced is CORRECTLY non-executable — the missing bit
    # is the signal, not a defect. Same predicate bootstrap.sh's doctor uses,
    # so the two agree instead of one flagging what the other exempts.
    ok "found: $(basename "$f") (sourced library)"
  else
    bad "found: $(basename "$f") — NOT executable, so it will silently never run"
  fi
done
shopt -u nullglob
if [ -f "$DOTCLAUDE_DIR/docs/agent-gateway.md" ]; then
  gateway_found=1
  ok "docs/agent-gateway.md present"
fi
[ "$gateway_found" = 1 ] || note "no gateway/ledger tooling on this checkout yet — not this script's to create"

# --------------------------------------------------------------------------
# 7. What the machine still needs.
# --------------------------------------------------------------------------
say "7. What this machine still needs"

missing=()
command -v git    >/dev/null 2>&1 || missing+=("git")
command -v python3 >/dev/null 2>&1 || missing+=("python3 (hook JSON payloads)")
command -v node   >/dev/null 2>&1 || missing+=("node (github MCP build)")
command -v npm    >/dev/null 2>&1 || missing+=("npm (github MCP build)")
[ "$DO_KB" = 1 ] && { command -v rsync >/dev/null 2>&1 || missing+=("rsync (bin/kb-sync.sh)"); }
command -v gh     >/dev/null 2>&1 || missing+=("gh (https://cli.github.com)")
if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then
  missing+=("gh auth login (gh is installed but not authenticated)")
fi

# The credential roster this repo documents (integrations.md's "Per-machine
# secrets" table) — currently just the upload-post API key, checked via the
# file it's supposed to live in rather than an env var, since that file is
# gitignored and per-machine by design.
settings_local="$HOME/.claude/settings.local.json"
if [ -f "$settings_local" ]; then
  if command -v python3 >/dev/null 2>&1 && \
     ! python3 -c "import json,sys; sys.exit(0 if json.load(open('$settings_local')).get('env',{}).get('UPLOAD_POST_API_KEY') else 1)" 2>/dev/null; then
    missing+=("UPLOAD_POST_API_KEY in $settings_local (see integrations.md#per-machine-secrets)")
  fi
else
  missing+=("$settings_local (per-machine secrets — see integrations.md#per-machine-secrets)")
fi

if [ "${#missing[@]}" -eq 0 ]; then
  ok "nothing outstanding"
else
  for m in "${missing[@]}"; do note "$m"; done
fi

echo
if [ "$status" = 0 ]; then
  echo "dot-sync: done, nothing needs a human."
else
  echo "dot-sync: done — see the ✗ items above."
fi
exit "$status"
