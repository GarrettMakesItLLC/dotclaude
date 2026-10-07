#!/usr/bin/env bash
# degraded-registry.sh — serve @garrettmakesitllc/* from a local mirror while
# GitHub Packages refuses downloads, and switch npm onto it with one line.
#
#   degraded-registry.sh on                 start the mirror and route npm to it
#   degraded-registry.sh off                route npm back to GitHub Packages, stop the mirror
#   degraded-registry.sh status [--quiet]   say which mode npm is in; --quiet exits 0 only when ON and serving
#   degraded-registry.sh start | stop       the mirror process alone, leaving ~/.npmrc as it is
#   degraded-registry.sh populate [--rebuild] [--root DIR]... [--lockfile FILE]...
#                                           copy every pinned version into the store (cache, then platform rebuild)
#   degraded-registry.sh verify [LOCKFILE]...   exit 1 unless the mirror serves every pin (default ./package-lock.json)
#   degraded-registry.sh pins [--root DIR]...   list every pin across the workspace's lockfiles
#   degraded-registry.sh publish <pkg-dir|tarball>
#                                           pack (if a dir) and add one version to the store
#   degraded-registry.sh sync               commit the store and exchange it with the shared remote
#   degraded-registry.sh banner             the SessionStart line; silent when off
#
# skills/operating-a-fleet/references/degraded-registry.md has the design. In short:
#
# THE SWITCH. Each consumer repo's committed .npmrc pins
# `@garrettmakesitllc:registry=https://npm.pkg.github.com`, and a project .npmrc
# outranks the user one, so the scope cannot be re-pointed from ~/.npmrc. It does
# not need to be. `npm ci` fetches each tarball from the lockfile's `resolved`
# URL, and `replace-registry-host=always` rewrites that host to the DEFAULT
# registry, which no repo sets. So `on` writes these keys to ~/.npmrc
# (`allow-remote=all` is for npm 12 only; npm 10 ignores it):
#
#   registry=http://127.0.0.1:4873/
#   replace-registry-host=always
#   allow-remote=all
#
# The mirror answers GitHub's own download paths and 307-redirects everything
# else to registry.npmjs.org. Nothing is committed to any repo, and `off`
# deletes exactly the block `on` wrote.
#
# THE STORE is a git checkout ($GMI_REGISTRY_HOME, default
# ~/.local/share/gmi-registry) holding packages/<name>/<name>-<version>.tgz.
# `sync` exchanges it with $GMI_REGISTRY_REMOTE, which is how the other machine
# gets the same bytes. Bytes matter: a rebuilt tarball almost never hashes the
# same as the original, so tarballs are shared rather than rebuilt per machine.
set -uo pipefail

PROG="$(basename "$0")"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SERVER="$HERE/lib/gmi-registry-server.mjs"
POPULATE="$HERE/lib/degraded-registry-populate.mjs"

PORT="${GMI_REGISTRY_PORT:-4873}"
URL="http://127.0.0.1:${PORT}/"
STORE="${GMI_REGISTRY_HOME:-$HOME/.local/share/gmi-registry}"
STATE="${GMI_REGISTRY_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/gmi-registry}"
REMOTE="${GMI_REGISTRY_REMOTE:-https://github.com/GarrettMakesItLLC/gmi-registry-store.git}"
NPMRC="${DEGRADED_REGISTRY_NPMRC:-${NPM_CONFIG_USERCONFIG:-$HOME/.npmrc}}"
PIDFILE="$STATE/server.pid"
LOG="$STATE/server.log"
BEGIN='# >>> dotclaude degraded-registry (bin/degraded-registry.sh off removes this) >>>'
END='# <<< dotclaude degraded-registry <<<'

export GMI_REGISTRY_STORE="$STORE" GMI_REGISTRY_STATE="$STATE" GMI_REGISTRY_PORT="$PORT"

die() { echo "$PROG: $*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

# --- state probes ---------------------------------------------------------------

is_on() { [ -f "$NPMRC" ] && grep -qF "$BEGIN" "$NPMRC"; }

serving() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -s --max-time 2 "${URL}-/gmi-registry/health" 2>/dev/null | grep -q '"ok":true'
}

tarball_count() {
  find "$STORE/packages" -name '*.tgz' 2>/dev/null | wc -l | tr -d ' '
}

# --- server lifecycle -----------------------------------------------------------------

start_server() {
  serving && return 0
  command -v node >/dev/null 2>&1 || die "node is not on PATH"
  mkdir -p "$STATE" "$STORE/packages"
  (
    cd "$STATE" || exit 1
    nohup setsid node "$SERVER" >>"$LOG" 2>&1 </dev/null &
    echo $! >"$PIDFILE"
  )
  for _ in $(seq 1 25); do
    serving && return 0
    sleep 0.2
  done
  die "the mirror did not come up on $URL (log: $LOG)"
}

stop_server() {
  # Only the PID this script recorded. Never a pattern match: another session's
  # node processes share this box.
  [ -f "$PIDFILE" ] || return 0
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null)"
  # The basename, not the full path: a mirror started from a worktree checkout
  # is still this script's to stop once that worktree is gone.
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] \
     && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -qF "$(basename "$SERVER")"; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
}

# --- ~/.npmrc block ------------------------------------------------------------------------

strip_block() {
  [ -f "$NPMRC" ] || return 0
  local tmp
  tmp="$(mktemp "${NPMRC}.XXXXXX")" || die "cannot write next to $NPMRC"
  awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$NPMRC" >"$tmp"
  if [ -s "$tmp" ] && grep -q '[^[:space:]]' "$tmp"; then
    mv "$tmp" "$NPMRC"
  else
    # The block was all there was: leave no empty file behind.
    rm -f "$tmp" "$NPMRC"
  fi
}

write_block() {
  strip_block
  # A user-level `registry=` or `replace-registry-host=` outside the block would
  # silently win or lose depending on order, so refuse rather than guess.
  if [ -f "$NPMRC" ] && grep -qE '^[[:space:]]*(registry|replace-registry-host|allow-remote)[[:space:]]*=' "$NPMRC"; then
    die "$NPMRC already sets registry=, replace-registry-host= or allow-remote= outside the managed block; remove it first"
  fi
  {
    echo "$BEGIN"
    echo "registry=${URL}"
    # `always`, not just npm.pkg.github.com: npm 12 classifies a tarball whose
    # URL is not on the configured registry as "remote" and refuses it under
    # allow-remote=none|root (platform commits root). Rewriting every pin onto
    # the mirror keeps npmjs tarballs registry-typed; the mirror 307s them on.
    echo "replace-registry-host=always"
    # The rewritten @garrettmakesitllc pins are still off their SCOPE's registry
    # (GitHub, from the project .npmrc), so npm 12 needs this too. npm 10 ignores it.
    echo "allow-remote=all"
    # `npm publish` refuses to run with no credential for the target registry.
    # The mirror ignores it; this is a placeholder, not a secret.
    echo "//127.0.0.1:${PORT}/:_authToken=degraded-local"
    echo "$END"
  } >>"$NPMRC"
}

# --- commands ---------------------------------------------------------------------------------

cmd_status() {
  local quiet=0
  [ "${1:-}" = "--quiet" ] && quiet=1
  if is_on && serving; then
    ((quiet)) || echo "ON: npm is routed to the degraded mirror at $URL ($(tarball_count) tarballs in $STORE)"
    return 0
  fi
  ((quiet)) && return 1
  if is_on; then
    echo "ON but NOT SERVING: $NPMRC routes npm to $URL and nothing answers there. Every npm install will fail. Run: $PROG start"
  else
    echo "OFF: npm uses each repo's committed registry (GitHub Packages for @garrettmakesitllc/*)$(serving && echo "; the mirror process is running")"
  fi
  return 0
}

cmd_publish() {
  local src="${1:-}"
  [ -n "$src" ] || die "publish needs a package directory or a .tgz"
  local tgz tmp=""
  if [ -d "$src" ]; then
    tmp="$(mktemp -d)"
    (cd "$src" && npm pack --pack-destination "$tmp" >/dev/null) || die "npm pack failed in $src"
    tgz="$(find "$tmp" -name '*.tgz' | head -1)"
  else
    tgz="$src"
  fi
  [ -f "$tgz" ] || die "no tarball at $tgz"
  local manifest name version short dest
  manifest="$(tar -xzOf "$tgz" package/package.json 2>/dev/null)" || die "$tgz has no package/package.json"
  name="$(printf '%s' "$manifest" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).name))')"
  version="$(printf '%s' "$manifest" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).version))')"
  case "$name" in
    @garrettmakesitllc/*) short="${name#@garrettmakesitllc/}" ;;
    *) die "$name is not an @garrettmakesitllc package" ;;
  esac
  dest="$STORE/packages/$short/$short-$version.tgz"
  if [ -f "$dest" ]; then
    if cmp -s "$tgz" "$dest"; then
      echo "$name@$version is already in the mirror (identical bytes)"
      [ -n "$tmp" ] && rm -rf "$tmp"
      return 0
    fi
    [ -n "$tmp" ] && rm -rf "$tmp"
    die "$name@$version is already in the mirror with DIFFERENT bytes. A published version is immutable: bump the version."
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$tgz" "$dest"
  [ -n "$tmp" ] && rm -rf "$tmp"
  echo "added $name@$version ($(sha1sum "$dest" | cut -c1-40))"
  echo "share it with the other machine: $PROG sync"
}

cmd_sync() {
  command -v git >/dev/null 2>&1 || die "git is not on PATH"
  if [ ! -d "$STORE/.git" ]; then
    if [ -d "$STORE/packages" ] && [ -n "$(ls -A "$STORE/packages" 2>/dev/null)" ]; then
      git -C "$STORE" init -q -b main || die "git init failed in $STORE"
      git -C "$STORE" remote add origin "$REMOTE"
      git -C "$STORE" fetch -q origin 2>/dev/null && git -C "$STORE" reset -q --soft origin/main 2>/dev/null
    else
      mkdir -p "$(dirname "$STORE")"
      rm -rf "$STORE"
      git clone -q "$REMOTE" "$STORE" || die "cannot clone $REMOTE"
      echo "cloned the store: $(tarball_count) tarballs"
      return 0
    fi
  fi
  git -C "$STORE" add -A packages
  if ! git -C "$STORE" diff --cached --quiet; then
    git -C "$STORE" commit -q -m "store: $(git -C "$STORE" diff --cached --name-only | wc -l | tr -d ' ') tarball(s) from $(hostname)" \
      || die "commit failed in $STORE"
  fi
  if git -C "$STORE" ls-remote --exit-code origin main >/dev/null 2>&1; then
    git -C "$STORE" pull -q --rebase origin main || die "pull failed in $STORE; resolve it there"
  fi
  git -C "$STORE" push -q origin HEAD:main || die "push failed from $STORE"
  echo "store in sync with $REMOTE: $(tarball_count) tarballs"
}

cmd_banner() {
  is_on || return 0
  if ! serving; then
    # A reboot kills the mirror while ~/.npmrc still points at it. Bring it
    # back rather than letting every install in the session fail.
    ( start_server ) >/dev/null 2>&1 || true
  fi
  if serving; then
    echo "DEGRADED REGISTRY ON: npm fetches @garrettmakesitllc/* from the local mirror at $URL ($(tarball_count) tarballs), because GitHub Packages refuses downloads. Installs need no NODE_AUTH_TOKEN. A version missing from the mirror fails loudly: check with \`degraded-registry.sh verify\`. New platform versions: build, then \`degraded-registry.sh publish packages/<name>\` and \`degraded-registry.sh sync\`. Do not substitute versions or use --offline. Back to normal: \`degraded-registry.sh off\`."
  else
    echo "DEGRADED REGISTRY BROKEN: ~/.npmrc routes npm to $URL but the mirror would not start (log: $LOG). Every npm install will fail until \`degraded-registry.sh start\` succeeds or \`degraded-registry.sh off\` restores normal mode."
  fi
}

[ $# -ge 1 ] || usage 1
ACTION="$1"; shift
case "$ACTION" in
  on)
    # A machine with no store yet starts from the shared one when it can.
    [ -d "$STORE/packages" ] || [ -d "$STORE/.git" ] || ( cmd_sync ) >/dev/null 2>&1 || true
    start_server
    write_block
    echo "ON: npm now fetches @garrettmakesitllc/* from $URL ($(tarball_count) tarballs). Undo: $PROG off"
    ;;
  off)
    strip_block
    stop_server
    echo "OFF: npm uses each repo's committed registry again."
    ;;
  status) cmd_status "$@" ;;
  start) start_server; echo "mirror up on $URL" ;;
  stop) stop_server; echo "mirror stopped" ;;
  populate | verify | pins)
    if [ "$ACTION" = verify ]; then
      args=()
      [ $# -gt 0 ] || set -- package-lock.json
      for f in "$@"; do args+=(--lockfile "$f"); done
      set -- "${args[@]}"
    fi
    if [ "$ACTION" = populate ] && printf '%s\n' "$@" | grep -qx -- '--rebuild'; then
      start_server
    fi
    node "$POPULATE" "$ACTION" "$@"
    ;;
  publish) cmd_publish "$@" ;;
  sync) cmd_sync ;;
  banner) cmd_banner ;;
  -h | --help | help) usage 0 ;;
  *) usage 1 ;;
esac
