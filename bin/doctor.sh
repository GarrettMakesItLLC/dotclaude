#!/usr/bin/env bash
# Report whether this machine is set up to work on the product repo you are in.
#
#   ~/.claude/bin/doctor.sh                 # from anywhere in the repo (npm run doctor)
#   ~/.claude/bin/doctor.sh --classify-npm-ls <package-lock.json> < npm-ls.json
#
# Each line is one fact with its fix attached, so "is this box right?" is
# answered in a minute rather than by a confusing failure an hour later: a wrong
# Node fails `npm ci` with an error that names the lockfile, a stale Prisma
# client throws type errors on files the branch never touched.
#
# Exit status is non-zero only for what WILL break a normal session (wrong Node,
# dependencies that do not resolve, no Prisma client, no git hooks). Everything
# else is a warning: plenty of work needs neither staging credentials nor a
# browser.
#
# Generic checks run everywhere. The repo-specific ones come from the `doctor`
# block of `.claude/repo.json` (docs/repo-manifest.md): `resolves` (a module the
# root must resolve), `nestedDeps` (`workspace:module` pairs), `prismaClient`
# (paths, any of which proves a generated client), `envFiles`
# ([{path, fix}]) and `checks` ([{name, run, fix, severity}], each run with sh in
# the repo root; severity "block" or "warn").
#
# Inside a linked worktree the checks ask the resolver, not the filesystem: a
# worktree resolves upward into the main checkout's install, and its root `.env`
# is withheld on purpose.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=bin/lib/repo-manifest.sh
. "$HERE/lib/repo-manifest.sh"

# npm's own install leaves `optional: true` packages for other platforms marked
# `extraneous` on every box. Counting those as a blocker made doctor exit 1 on a
# correct checkout and prescribe an `npm ci` that cannot clear them. So an
# extraneous package recorded optional in the lockfile is a warning; any other
# extraneous and every `invalid` still blocks. One `block|warn <name> <reason>`
# line per problem.
classify_npm_ls() {
  local program
  # Read into a variable rather than `python3 -` on a heredoc: `-` would read the
  # program from stdin, which is the `npm ls --json` being classified.
  program="$(cat <<'PY'
import json, sys
try:
    report = json.load(sys.stdin)
except Exception:
    sys.exit(0)
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        packages = json.load(fh).get("packages", {})
except Exception:
    packages = {}
for name, entry in sorted((report.get("dependencies") or {}).items()):
    if not isinstance(entry, dict):
        continue
    if entry.get("invalid"):
        print(f"block {name} invalid")
        continue
    if not entry.get("extraneous"):
        continue
    record = packages.get(f"node_modules/{name}")
    optional = bool(record.get("optional")) if isinstance(record, dict) else False
    print(f"{'warn' if optional else 'block'} {name} extraneous")
PY
  )"
  python3 -c "$program" "$1"
}

if [ "${1:-}" = --classify-npm-ls ]; then
  classify_npm_ls "${2:?usage: doctor.sh --classify-npm-ls <package-lock.json>}"
  exit 0
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "doctor: not inside a git repository" >&2; exit 1; }
cd "$ROOT" || exit 1
# shellcheck disable=SC2034 # read by the manifest_get calls below
manifest_find "$ROOT" >/dev/null 2>&1 || MANIFEST=""
main_tree="$(main_tree_of "$ROOT" || echo "$ROOT")"
in_worktree=0
[ "$main_tree" = "$ROOT" ] || in_worktree=1
where="$([ "$in_worktree" = 1 ] && echo 'main checkout' || echo 'this checkout')"

fails=0
warns=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n     → %s\n' "$1" "$2"; fails=$((fails + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n     → %s\n' "$1" "$2"; warns=$((warns + 1)); }
note() { printf '  \033[2m·\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
resolves() { node -e "require.resolve('$1')" >/dev/null 2>&1; }

# ── Toolchain ────────────────────────────────────────────────────────────────
head_ 'Toolchain'

if [ -f package.json ]; then
  want_node="$(tr -d 'v \n' <.nvmrc 2>/dev/null || true)"
  have_node="$(node -v 2>/dev/null | tr -d 'v')"
  if [ -z "$have_node" ]; then
    bad 'node is not on PATH' 'install Node via nvm, then `nvm use`'
  elif [ -z "$want_node" ]; then
    ok "node v$have_node (no .nvmrc pin)"
  elif [ "${have_node%%.*}" = "${want_node%%.*}" ]; then
    ok "node v$have_node (.nvmrc wants $want_node)"
  else
    bad "node v$have_node, but .nvmrc wants $want_node" 'run `nvm use` — an older Node fails `npm ci` with a misleading *lockfile* error'
  fi

  have_npm="$(npm -v 2>/dev/null)"
  npm_path="$(command -v npm 2>/dev/null || true)"
  # Inside `npm run`, every node_modules/.bin on the ancestor chain precedes
  # corepack's shim, so a dependency that hoists an `npm` package answers here.
  case "$npm_path" in
    */node_modules/.bin/npm) bad "npm v$have_npm resolves to $npm_path, shadowing the real npm" 'a dependency hoisted an `npm` package; its bin wins inside every `npm run`' ;;
  esac
  pin="$(node -p "((require('./package.json').packageManager)||'').startsWith('npm@') ? require('./package.json').packageManager.slice(4) : ''" 2>/dev/null)"
  if [ -z "$have_npm" ]; then
    bad 'npm is not on PATH' 'it ships with Node — check the nvm install'
  elif [ -n "$pin" ] && [ "${have_npm%%.*}" != "${pin%%.*}" ]; then
    warn "npm v$have_npm, but packageManager pins npm@$pin" "fine for everything except the lockfile — regenerate it ONLY with \`corepack npm@$pin install\` (\`npx npm@…\` silently runs a different npm)"
  else
    ok "npm v$have_npm${pin:+ (packageManager pins $pin)}"
  fi
fi

for tool in git gh python3; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool present"; else bad "$tool is not installed" "install $tool — the workflow assumes it"; fi
done
if command -v gitleaks >/dev/null 2>&1; then
  ok 'gitleaks present (pre-commit secret scan active)'
else
  warn 'gitleaks is not installed — commits are scanned only once they reach CI' 'install gitleaks; the hook is what stops the commit'
fi

# Three states, not two: a Node shim (`@railway/cli`) whose postinstall never
# fetched the real binary is on PATH and exits 127, which is worse than absent
# because presence is what routes an agent to it. So each tool is asked for its
# version. None is required — the MCP or fallback is the preferred route anyway.
for tool in jq psql shellcheck railway vercel corepack; do
  case "$tool" in
    jq) alt='use `node -e` or `python3 -m json.tool`'; repair='install jq' ;;
    psql) alt='use the Supabase MCP, or `node` with the repo'"'"'s `pg`'; repair='install postgresql-client' ;;
    shellcheck) alt='read the script'; repair='install shellcheck' ;;
    railway) alt='use the Railway MCP'; repair='run `npm install -g @railway/cli --foreground-scripts` — the postinstall that fetches the binary did not run' ;;
    vercel) alt='use `npx vercel …` or the Vercel MCP'; repair='use `npx vercel …`, which resolves its own copy' ;;
    corepack) alt='it ships with Node'; repair='re-run the nvm install' ;;
  esac
  if ! command -v "$tool" >/dev/null 2>&1; then
    note "$tool absent — $alt"
  elif timeout 30 "$tool" --version >/dev/null 2>&1; then
    note "$tool present"
  else
    warn "$tool present on PATH but NOT RUNNABLE (\`$tool --version\` fails)" "$repair; until then, $alt"
  fi
done

# ── Dependencies ─────────────────────────────────────────────────────────────
head_ 'Dependencies'

probe="$(manifest_get doctor.resolves || true)"
if [ -n "$probe" ]; then
  if resolves "$probe"; then
    ok "dependencies resolvable$([ "$in_worktree" = 1 ] && echo ' (a worktree may resolve through the main checkout)')"
  else
    bad 'dependencies do not resolve' 'in a worktree: `~/.claude/bin/setup-worktree.sh`; in the main checkout: `~/.claude/bin/with-check-lock.sh --writer npm ci`'
  fi
fi

missing_nested=''
while IFS= read -r pair; do
  [ -n "$pair" ] || continue
  ws="${pair%%:*}"; dep="${pair##*:}"
  if [ -d "$ws" ] && ! (cd "$ws" && node -e "require.resolve('$dep')" >/dev/null 2>&1); then
    missing_nested="$missing_nested $ws/$dep"
  fi
done < <(manifest_get doctor.nestedDeps || true)
if [ -n "$missing_nested" ]; then
  bad "missing workspace deps:$missing_nested" 'TS2307 on files the branch never touched — run `~/.claude/bin/setup-worktree.sh` in a worktree, or `npm ci` in the main checkout'
elif manifest_has doctor.nestedDeps; then
  ok 'workspace deps resolvable'
fi

# Both checks read the MAIN checkout even from a worktree: every worktree
# resolves upward through its install, so either fault breaks them all at once
# and is invisible from the one it breaks.
if [ -f "$main_tree/package-lock.json" ]; then
  if git -C "$main_tree" diff --quiet -- package-lock.json 2>/dev/null; then
    ok "$where package-lock.json is clean"
  else
    bad "$where has uncommitted package-lock.json changes" "its install matches no commit — inspect with \`(cd $main_tree && git diff --stat -- package-lock.json)\`"
  fi
fi
if [ -d "$main_tree/node_modules" ] && [ -f "$main_tree/package-lock.json" ] && command -v npm >/dev/null 2>&1; then
  classified="$( (cd "$main_tree" && npm ls --depth=0 --json 2>/dev/null) | classify_npm_ls "$main_tree/package-lock.json")"
  blocking="$(grep -c '^block ' <<<"$classified" || true)"
  residue="$(grep -c '^warn ' <<<"$classified" || true)"
  if [ "${blocking:-0}" -eq 0 ] && [ "${residue:-0}" -eq 0 ]; then
    ok "$where install matches its lockfile"
  elif [ "${blocking:-0}" -eq 0 ]; then
    warn "$where carries $residue extraneous OPTIONAL package(s): $(sed -n 's/^warn \([^ ]*\) .*/\1/p' <<<"$classified" | paste -sd' ' -)" 'nothing to do — npm places other platforms'"'"' optional fallbacks and `npm ci` leaves them'
  else
    bad "$where install has $blocking extraneous/invalid package(s): $(sed -n 's/^block \([^ ]*\) .*/\1/p' <<<"$classified" | paste -sd' ' -)" "run \`(cd $main_tree && ~/.claude/bin/with-check-lock.sh --writer npm ci)\`"
  fi
fi

if [ -f prisma/schema.prisma ] || [ -d prisma/schema ]; then
  client=""
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if [ -e "$c" ]; then client="$c"; break; fi
  done < <(manifest_get doctor.prismaClient || printf 'node_modules/.prisma/client/index.d.ts\n%s\n' "$main_tree/node_modules/.prisma/client/index.d.ts")
  if [ -z "$client" ]; then
    bad 'no generated Prisma client' 'run `npx prisma generate` (also after merging any schema change)'
  elif [ -n "$(find prisma -name '*.prisma' -newer "$client" 2>/dev/null | head -1)" ]; then
    warn 'the generated Prisma client is older than the schema' 'run `npx prisma generate` — a stale client produces type and lint errors that read as code bugs'
  else
    ok 'Prisma client generated and current'
  fi
fi

# ── Environment ──────────────────────────────────────────────────────────────
head_ 'Environment'

while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  f="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["path"])' "$spec" 2>/dev/null)" || continue
  fix="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("fix","see the repo docs"))' "$spec" 2>/dev/null)"
  if [ -f "$f" ]; then
    ok "$f present"
  elif [ "$f" = .env ] && [ "$in_worktree" = 1 ]; then
    note 'no root .env — correct in a worktree, it is withheld on purpose'
  else
    warn "$f missing" "$fix"
  fi
done < <(manifest_get doctor.envFiles || true)

if [ -n "${DATABASE_URL:-}" ]; then
  warn 'DATABASE_URL is exported in this shell' 'a bare DATABASE_URL pins every dotenv-based seed or migration to it — export it namespaced and opt in per command'
else
  ok 'DATABASE_URL not exported (opt in per command)'
fi

if [ -f .npmrc ] && grep -q NODE_AUTH_TOKEN .npmrc; then
  if [ -n "${NODE_AUTH_TOKEN:-}" ]; then
    ok 'NODE_AUTH_TOKEN set (GitHub Packages installs can authenticate)'
  else
    warn 'NODE_AUTH_TOKEN is unset — `npm ci` exits 0 having silently omitted every auth-gated package' 'source ~/.config/secrets/gmi.env (the PAT with read:packages) — never `gh auth token`'
  fi
fi

state_dir="$(manifest_get stateDir || true)"
if [ -n "$state_dir" ]; then
  state_dir="$(manifest_path_expand "$state_dir")"
  if [ -f "$state_dir/agent.env" ]; then
    ok "agent shell credentials built ($state_dir/agent.env)"
  else
    warn 'agent shell credentials not built' '`~/.claude/bin/agent-env-build.sh` (and `~/.claude/bin/ops-pull.sh` first, if the repo uses the OPS channel)'
  fi
fi

# ── Machine ──────────────────────────────────────────────────────────────────
head_ 'Machine'

mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_gb=$((mem_kb / 1024 / 1024))
if [ "$mem_gb" -ge 16 ]; then
  ok "${mem_gb} GB RAM visible"
elif [ "$mem_gb" -gt 0 ]; then
  warn "${mem_gb} GB RAM visible — checks are memory-bound" 'on WSL2 this is half the host RAM unless ~/.wslconfig sets memory='
fi
if command -v flock >/dev/null 2>&1; then
  ok 'flock present (~/.claude/bin/with-check-lock.sh can bound concurrent checks)'
else
  warn 'no flock — with-check-lock.sh runs every check UNBOUNDED' 'install util-linux; concurrent checks OOM-kill each other'
fi

hooks_path="$(git config core.hooksPath 2>/dev/null || true)"
if [ -n "$hooks_path" ]; then
  if [ -d "$ROOT/$hooks_path" ] || [ -d "$hooks_path" ]; then
    ok "git hooks active ($hooks_path)"
  else
    bad "git hooks are not installed ($hooks_path is missing) — commits skip every hook" 'run `npm run prepare` (in a worktree: `~/.claude/bin/setup-worktree.sh`)'
  fi
fi

if grep -qs 'graphify hook-guard' .claude/settings.json; then
  if [ -f graphify-out/graph.json ]; then
    ok 'graphify-out/graph.json present'
  else
    warn 'no graphify-out/graph.json — the repo points agents at a graph that does not exist here' 'run `graphify update .`'
  fi
fi

# ── Repo checks ──────────────────────────────────────────────────────────────
checks="$(manifest_get doctor.checks || true)"
if [ -n "$checks" ]; then
  head_ 'Repo checks'
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    fields="$(python3 -c '
import json, sys
c = json.loads(sys.argv[1])
print(c.get("name", c.get("run", "")))
print(c.get("run", "false"))
print(c.get("fix", "see the repo docs"))
print(c.get("severity", "block"))' "$spec" 2>/dev/null)" || continue
    cname="$(sed -n 1p <<<"$fields")"; crun="$(sed -n 2p <<<"$fields")"
    cfix="$(sed -n 3p <<<"$fields")"; csev="$(sed -n 4p <<<"$fields")"
    if sh -c "$crun" >/dev/null 2>&1; then
      ok "$cname"
    elif [ "$csev" = warn ]; then
      warn "$cname" "$cfix"
    else
      bad "$cname" "$cfix"
    fi
  done <<<"$checks"
fi

# ── Verdict ──────────────────────────────────────────────────────────────────
printf '\n'
if [ "$fails" -eq 0 ] && [ "$warns" -eq 0 ]; then
  printf '\033[32mThis box is set up.\033[0m\n'
elif [ "$fails" -eq 0 ]; then
  printf '\033[33m%s warning(s), nothing blocking.\033[0m You can work; read the arrows above.\n' "$warns"
else
  printf '\033[31m%s blocking problem(s)\033[0m and %s warning(s). Fix the ✗ lines first.\n' "$fails" "$warns"
fi
[ "$fails" -eq 0 ]
