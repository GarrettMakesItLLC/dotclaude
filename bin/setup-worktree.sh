#!/usr/bin/env bash
# Bootstrap a freshly created git worktree of a product repo so its first
# typecheck / lint / test fails on code, never on environment.
#
#   ~/.claude/bin/setup-worktree.sh [--check] [<worktree-dir>]
#
# <worktree-dir> defaults to the cwd. The dotclaude PostToolUse hook
# `worktree-bootstrap.sh` runs this, detached, after every `git worktree add` in
# a repo with a `.claude/repo.json`; run it by hand if the hook did not fire.
# What it does is read from that manifest's `worktree` block
# (docs/repo-manifest.md) — this file holds the behaviour, the manifest the
# per-repo values.
#
# `git worktree add` copies tracked files only. The failures that follow all read
# as code bugs, which is why each is fixed here rather than debugged later:
#
#   * Git hooks silently no-op. `core.hooksPath` is the RELATIVE `.husky/_`, and
#     husky's shim directory is gitignored, so it exists only where an install
#     ran. Commits then skip gitleaks and lint-staged with no error. The shims
#     are copied from the main checkout.
#   * No per-app env files (`worktree.envFiles`), copied from the main checkout
#     when absent. The root `.env` is never in that list by convention: it can
#     hold live database URLs, and an agent worktree should not inherit them.
#   * No dependencies. Two strategies, per repo:
#       install — run `worktree.install` in the worktree, under the check lock's
#                 WRITER mode (an install rewrites what every concurrent check
#                 reads), retry once from an empty tree, then verify each
#                 `worktree.requireScopes` package scope actually landed: npm
#                 exits 0 on an install that silently omitted an auth-gated scope.
#       mirror  — no install. Node resolution walks up into the main checkout's
#                 hoisted `node_modules`, so only what it cannot reach is
#                 provided: workspace deps npm installed NESTED under
#                 `<workspaceDirs>/*/node_modules` (real copies, verified
#                 name@version and file-for-file against the source, refreshed
#                 when the source install moves), the root `node_modules/.bin`
#                 (per-binary symlinks into a real directory, re-pointed at the
#                 worktree's own package once it has one), and optionally
#                 `node_modules/<workspaceScope>/*` links to THIS worktree's own
#                 packages, without which a worktree typechecks against the main
#                 tree's copy of a package it edited. `node_modules` itself is
#                 never symlinked across trees: that escapes the worktree under
#                 realpath and breaks type-aware ESLint's project resolution.
#   * No generated Prisma client (`worktree.prismaGenerate`).
#   * No graph for graphify (`worktree.graphify`), built best-effort.
#
# `worktree.postSteps` run last, in the worktree, with WORKTREE, MAIN_TREE and
# the SETUP_WORKTREE_* state exported (docs/repo-manifest.md) — the place for a
# repo's own extra step. `--check` writes nothing: it
# answers "would a build here fail on the bootstrap rather than the code?", runs
# `worktree.checkSteps`, and exits non-zero naming the repair. A pre-push hook
# can call it, since the bootstrap runs once and a later dependency change in
# the main checkout leaves a mirrored worktree behind.
#
# `worktree.lockWorktree` (a reason string) locks the worktree against sweeps:
# `git worktree remove` then needs --force twice and `git worktree prune` skips
# it, so a generic cleanup cannot delete a live tree mid-build.
#
# Idempotent. Exits non-zero, naming the fix, when the tree cannot build.
set -euo pipefail

# A pre-push hook runs this with GIT_DIR exported for the tree being pushed; left
# set, every `git -C "$main_tree"` below would answer about that tree instead.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=bin/lib/repo-manifest.sh
. "$HERE/lib/repo-manifest.sh"
# SETUP_WORKTREE_LOCK overrides the wrapper (the self-test injects a lock that
# times out); it is exported to postSteps either way.
LOCK="${SETUP_WORKTREE_LOCK:-$HERE/with-check-lock.sh}"

say() { echo "[setup-worktree] $*"; }
warn() { echo "[setup-worktree] $*" >&2; }

check_only=0
if [ "${1:-}" = "--check" ]; then
  check_only=1
  shift
fi

target="$(cd "${1:-$PWD}" && pwd)"
cd "$target"

manifest_find "$target" >/dev/null || { warn "no .claude/repo.json in $target — this repo has not opted in; run its own bin/setup-worktree.sh if it has one."; exit 1; }
main_tree="$(main_tree_of "$target")" || { warn "$target is not inside a git repository"; exit 1; }

if [ "$main_tree" = "$target" ]; then
  ((check_only)) || say "$target is the main checkout, nothing to bootstrap." >&2
  exit 0
fi

strategy="$(manifest_get worktree.strategy || echo install)"
case "$strategy" in install | mirror) ;; *) warn "unknown worktree.strategy '$strategy' (install | mirror)"; exit 1 ;; esac
state_dir="$(manifest_path_expand "$(manifest_get stateDir || echo "")")"
env_prefix="$(manifest_get envPrefix || true)"
case "$env_prefix" in *[!A-Za-z0-9_]*) env_prefix="" ;; esac
mapfile -t workspace_dirs < <(manifest_get worktree.workspaceDirs || printf 'apps\npackages\n')
scope="$(manifest_get worktree.workspaceScope || true)"
# What postSteps/checkSteps may read (docs/repo-manifest.md). The SETUP_WORKTREE_*
# values are filled in by the mirror strategy below; under `install` they stay
# empty, which reads as "nothing copied, nothing exempt, nothing stale".
export WORKTREE="$target" MAIN_TREE="$main_tree" SETUP_WORKTREE_LOCK="$LOCK"
export SETUP_WORKTREE_STALE=0 SETUP_WORKTREE_COPIED_STAMP="" SETUP_WORKTREE_EXEMPT=""

# One bootstrap of a given worktree at a time: the hook and a hand-run can both
# fire on one `git worktree add`, and the loser of a race leaves a PARTIAL copy.
# Keyed on the target, so different worktrees still bootstrap in parallel.
if ((check_only == 0)) && command -v flock >/dev/null 2>&1; then
  exec 9>"${TMPDIR:-/tmp}/setup-worktree.$(printf '%s' "$target" | cksum | cut -d' ' -f1).lock"
  flock -w 300 9 || warn "another bootstrap of $target is still running; proceeding"
fi

run_steps() { # label, manifest key
  local label="$1" key="$2" step
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    if ! (cd "$target" && sh -c "$step"); then
      warn "$label step failed: $step — fix it, then re-run: ~/.claude/bin/setup-worktree.sh $target"
      exit 1
    fi
  done < <(manifest_get "$key" || true)
}

# ---------------------------------------------------------------------------
# Fresh-worktree setup (skipped by --check)
# ---------------------------------------------------------------------------
if ((check_only == 0)); then
  reason="$(manifest_get worktree.lockWorktree || true)"
  if [ -n "$reason" ] && ! git -C "$target" worktree list --porcelain \
    | awk -v t="$target" '/^worktree /{c=substr($0,10)} /^locked/{if(c==t) f=1} END{exit(f?0:1)}'; then
    git -C "$target" worktree lock --reason "$reason" "$target" 2>/dev/null \
      && say "locked this worktree against sweeps"
  fi

  if [ -d "$main_tree/.husky/_" ] && [ ! -d "$target/.husky/_" ]; then
    mkdir -p "$target/.husky"
    cp -r "$main_tree/.husky/_" "$target/.husky/_"
    say "installed husky hook shims (.husky/_)"
  fi

  copied=()
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -f "$main_tree/$rel" ] && [ ! -f "$target/$rel" ]; then
      mkdir -p "$(dirname "$target/$rel")"
      cp "$main_tree/$rel" "$target/$rel"
      copied+=("$rel")
    fi
  done < <(manifest_get worktree.envFiles || true)
  [ "${#copied[@]}" -eq 0 ] || say "copied env: ${copied[*]}"
fi

# ---------------------------------------------------------------------------
# install strategy
# ---------------------------------------------------------------------------
verify_scopes() {
  local s missing=()
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    [ -d "$target/node_modules/$s" ] || missing+=("$s")
  done < <(manifest_get worktree.requireScopes || true)
  [ "${#missing[@]}" -eq 0 ] && return 0
  warn "node_modules is missing ${missing[*]} after install — an auth-gated scope did not resolve. npm reports success on that."
  warn "NODE_AUTH_TOKEN must be non-empty and able to read the scope's packages; \`~/.claude/bin/doctor.sh\` checks it with a registry GET."
  return 1
}

if [ "$strategy" = install ]; then
  if ((check_only)); then
    if [ ! -d "$target/node_modules" ] || ! verify_scopes; then
      warn "dependencies are not installed here. Repair:  ~/.claude/bin/setup-worktree.sh $target"
      exit 1
    fi
    run_steps check worktree.checkSteps
    exit 0
  fi

  install_cmd="$(manifest_get worktree.install || echo "npm ci")"

  # A hook's non-login shell has no profile, so the GitHub Packages token is
  # absent and the auth-gated scope alone 401s while everything else installs.
  # Read ONLY that variable, in a subshell, rather than sourcing a credentials
  # bundle into every package's install script.
  if [ -z "${NODE_AUTH_TOKEN:-}" ]; then
    for f in "$HOME/.config/secrets/gmi.env" ${state_dir:+"$state_dir/agent.env"}; do
      [ -f "$f" ] || continue
      tok="$(
        # shellcheck disable=SC1090  # a per-machine secrets file chosen at runtime; there is nothing to follow statically
        . "$f" >/dev/null 2>&1
        printf '%s' "${NODE_AUTH_TOKEN:-}"
      )"
      if [ -n "$tok" ]; then export NODE_AUTH_TOKEN="$tok"; break; fi
    done
  fi

  # A leftover workspace link farm makes npm abort with EEXIST on its own links.
  [ -z "$scope" ] || rm -rf "${target:?}/node_modules/$scope"

  do_install() {
    if [ -x "$LOCK" ]; then
      (cd "$target" && "$LOCK" --writer sh -c "$install_cmd")
    else
      (cd "$target" && sh -c "$install_cmd")
    fi
  }
  # An install command that is not `npm ci` (a pinned `npx npm@11 install`, say)
  # can rewrite a tracked lockfile in a different npm's shape, which dirties a
  # tree that must stay clean — a validator's frozen-SHA worktree (#493). Note
  # which lockfiles are clean now, and put back any the install rewrites.
  clean_locks=()
  for lf in package-lock.json npm-shrinkwrap.json; do
    if [ -f "$target/$lf" ] && git -C "$target" ls-files --error-unmatch -- "$lf" >/dev/null 2>&1 \
       && git -C "$target" diff --quiet -- "$lf" 2>/dev/null; then
      clean_locks+=("$lf")
    fi
  done
  restore_locks() {
    local lf
    for lf in ${clean_locks[@]+"${clean_locks[@]}"}; do
      if ! git -C "$target" diff --quiet -- "$lf" 2>/dev/null; then
        git -C "$target" checkout -- "$lf" 2>/dev/null \
          && say "restored $lf: '$install_cmd' rewrote it, and it was clean before the install"
      fi
    done
  }
  say "installing dependencies: $install_cmd"
  trap restore_locks EXIT
  if ! do_install; then
    warn "first install failed — clearing node_modules and retrying once…"
    find "$target" -type d -name node_modules -prune -exec rm -rf {} +
    if ! do_install; then
      warn "install failed — resolve it, then re-run: ~/.claude/bin/setup-worktree.sh $target"
      [ -n "${NODE_AUTH_TOKEN:-}" ] || warn "NODE_AUTH_TOKEN is unset — auth-gated packages need it."
      exit 1
    fi
  fi
  restore_locks
  trap - EXIT
  verify_scopes || exit 1
fi

# ---------------------------------------------------------------------------
# mirror strategy
# ---------------------------------------------------------------------------
if [ "$strategy" = mirror ]; then
  # The main tree is the source of truth for every copy below, which it is not
  # when its own install predates its lockfile.
  if [ -f "$main_tree/package-lock.json" ] && [ -f "$main_tree/node_modules/.package-lock.json" ] \
    && (($(stat -c %Y "$main_tree/node_modules/.package-lock.json") < $(stat -c %Y "$main_tree/package-lock.json"))); then
    warn "the MAIN checkout ($main_tree) installed packages that predate its own package-lock.json, so it is"
    warn "not a trustworthy source to copy from. This is churn from another session's merged lockfile"
    warn "change, not this branch. Re-install there first, then retry:"
    warn "  (cd $main_tree && ~/.claude/bin/with-check-lock.sh --writer npm ci)"
    exit 1
  fi
  # The same staleness in a root install of the worktree's own, which nothing
  # refreshes once it exists and which node then resolves against instead.
  if [ -f "$target/package-lock.json" ] && [ -f "$target/node_modules/.package-lock.json" ] \
    && (($(stat -c %Y "$target/node_modules/.package-lock.json") < $(stat -c %Y "$target/package-lock.json"))); then
    warn "this worktree has its OWN root install, older than this branch's package-lock.json. Re-install it:"
    warn "  (cd $target && ~/.claude/bin/with-check-lock.sh --writer npm ci)   or remove it: rm -rf $target/node_modules"
    exit 1
  fi

  # Root node_modules/.bin: a literal `node_modules/.bin/<x>` path does not walk
  # upward the way an import does. Per-binary links to RESOLVED paths, in a real
  # directory, never a link of `.bin` itself (npm would write through it).
  if ((check_only == 0)) && [ "$(manifest_get worktree.linkRootBin || echo false)" = true ] \
    && [ ! -e "$target/node_modules/.bin" ] && [ -d "$main_tree/node_modules/.bin" ]; then
    mkdir -p "$target/node_modules/.bin"
    n=0
    while IFS= read -r -d '' bin_path; do
      resolved="$(readlink -f "$bin_path" 2>/dev/null || true)"
      [ -n "$resolved" ] || continue
      ln -s "$resolved" "$target/node_modules/.bin/$(basename "$bin_path")"
      n=$((n + 1))
    done < <(find "$main_tree/node_modules/.bin" -maxdepth 1 -type l -print0)
    [ "$n" -eq 0 ] || say "linked $n root bin(s) into node_modules/.bin"
  fi

  # A root `.bin` link into the main tree is right only while this worktree has
  # no package of that name of its own. Once it does (a root install here, which
  # the never-overwrite rule above leaves the old links beside), the link runs
  # the MAIN tree's binary against THIS tree's packages: `npx vitest` starts
  # main's vitest while the setup file extends this tree's `expect`, and every
  # matcher fails as "Invalid Chai property". Such a link is re-pointed at the
  # worktree's own package, relative — the shape npm leaves.
  split_bins=()
  if [ -d "$target/node_modules/.bin" ] && [ ! -L "$target/node_modules/.bin" ]; then
    while IFS= read -r -d '' bin_link; do
      bin_dest="$(readlink "$bin_link")"
      case "$bin_dest" in "$main_tree/node_modules/"*) ;; *) continue ;; esac
      bin_rel="${bin_dest#"$main_tree/node_modules/"}"
      bin_pkg="${bin_rel%%/*}"
      case "$bin_pkg" in @*) bin_pkg="$bin_pkg/$(cut -d/ -f2 <<<"$bin_rel")" ;; esac
      [ -d "$target/node_modules/$bin_pkg" ] && [ ! -L "$target/node_modules/$bin_pkg" ] || continue
      [ -e "$target/node_modules/$bin_rel" ] || continue
      split_bins+=("$(basename "$bin_link")")
      ((check_only)) || ln -sfn "../$bin_rel" "$bin_link"
    done < <(find "$target/node_modules/.bin" -maxdepth 1 -type l -print0)
  fi
  if [ "${#split_bins[@]}" -gt 0 ]; then
    if ((check_only)); then
      warn "node_modules/.bin runs the main tree's copy of a package this worktree has itself: ${split_bins[*]}"
      warn "Two copies of one tool meet at runtime (vitest shows it as \"Invalid Chai property\"). Repair:"
      warn "  ~/.claude/bin/setup-worktree.sh $target"
      exit 1
    fi
    say "re-pointed ${#split_bins[@]} root bin(s) at this worktree's own packages"
  fi

  # A branch whose lockfile moved a package needs its own install for THAT
  # package, so the main tree's copy is exempt per package, not per tree. The
  # comparison is against the main tree's COMMITTED lockfile: an install there
  # rewrites the working copy, and every worktree would then "differ".
  main_head_lock="$(mktemp)"
  trap 'rm -f "$main_head_lock"' EXIT
  compare_lock="$main_tree/package-lock.json"
  git -C "$main_tree" show HEAD:package-lock.json >"$main_head_lock" 2>/dev/null && compare_lock="$main_head_lock"
  if ! git -C "$main_tree" diff --quiet -- package-lock.json 2>/dev/null; then
    warn "the MAIN checkout ($main_tree) has UNCOMMITTED package-lock.json changes; this worktree is compared against its HEAD. Check with: (cd $main_tree && git diff --stat -- package-lock.json)"
  fi

  branch_owns_deps=0
  exempt_pkgs=""
  if [ -f "$target/package-lock.json" ] && ! cmp -s "$compare_lock" "$target/package-lock.json"; then
    branch_owns_deps=1
    exempt_pkgs="$(node -e '
      const fs = require("fs");
      const load = (p) => {
        const parsed = JSON.parse(fs.readFileSync(p, "utf8"));
        if (!parsed.packages) throw new Error("no packages map");
        const out = new Map();
        for (const [key, entry] of Object.entries(parsed.packages)) {
          const at = key.lastIndexOf("node_modules/");
          if (at === -1) continue;
          out.set(key.slice(at + "node_modules/".length), entry.version ?? "");
        }
        return out;
      };
      let a, b;
      try { a = load(process.argv[1]); b = load(process.argv[2]); } catch { console.log("ALL"); process.exit(0); }
      for (const name of [...new Set([...a.keys(), ...b.keys()])].sort()) if (a.get(name) !== b.get(name)) console.log(name);
    ' "$compare_lock" "$target/package-lock.json" 2>/dev/null || echo ALL)"
    warn "this branch's package-lock.json differs from the main tree's; the packages it moved need an install here:"
    warn "  (cd $target && ~/.claude/bin/with-check-lock.sh --writer npm ci)"
  fi

  is_exempt() {
    [ "$branch_owns_deps" = 1 ] || return 1
    [ "$exempt_pkgs" = ALL ] && return 0
    grep -qxF -- "$1" <<<"$exempt_pkgs"
  }
  pkg_version() {
    node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version ?? "")' "$1" 2>/dev/null
  }
  # A branch that ran its own install may hoist a package to its own root;
  # resolution through that root is identical, so it is not a gap.
  resolves_from_worktree_root() {
    ((branch_owns_deps)) || return 1
    [ -f "$target/node_modules/$1/package.json" ] || return 1
    [ -n "$2" ] && [ "$(pkg_version "$target/node_modules/$1/package.json")" = "$2" ]
  }
  # name@version of every package in a node_modules (a directory holding a
  # package.json; a scope counts its members).
  pkg_list() {
    node -e '
      const fs = require("fs"), path = require("path"), root = process.argv[1], out = [];
      const rec = (n) => { try { out.push(`${n}@${JSON.parse(fs.readFileSync(path.join(root, n, "package.json"), "utf8")).version ?? ""}`); } catch {} };
      let es; try { es = fs.readdirSync(root, { withFileTypes: true }); } catch { process.exit(0); }
      for (const e of es) {
        if (!e.isDirectory()) continue;
        if (!e.name.startsWith("@")) { rec(e.name); continue; }
        for (const s of fs.readdirSync(path.join(root, e.name), { withFileTypes: true })) if (s.isDirectory()) rec(`${e.name}/${s.name}`);
      }
      console.log(out.join("\n"));
    ' "$1" 2>/dev/null | sed '/^$/d' | LC_ALL=C sort -u
  }
  drifted() { # packages in src that dst lacks at that exact version
    LC_ALL=C comm -23 <(pkg_list "$1") <(pkg_list "$2") | while IFS= read -r entry; do
      name="${entry%@*}"; ver="${entry##*@}"
      is_exempt "$name" && continue
      resolves_from_worktree_root "$name" "$ver" && continue
      printf '%s\n' "$name"
    done
  }
  # Same version, missing files: a copy that raced a concurrent install. Only
  # real packages count, so npm's own caches (.vite, .cache) never fail a tree.
  incomplete_packages() {
    local src="$1" dst="$2"
    [ -d "$src" ] && [ -d "$dst" ] || return 0
    LC_ALL=C comm -23 <(cd "$src" && find . -type f 2>/dev/null | sort) <(cd "$dst" && find . -type f 2>/dev/null | sort) \
      | while IFS= read -r relf; do
          p="${relf#./}"
          if [[ "$p" == @*/* ]]; then name="$(cut -d/ -f1-2 <<<"$p")"; else name="${p%%/*}"; fi
          [ -f "$src/$name/package.json" ] || continue
          is_exempt "$name" && continue
          resolves_from_worktree_root "$name" "$(pkg_version "$src/$name/package.json")" && continue
          printf '%s\n' "$name"
        done | LC_ALL=C sort -u
  }

  # npm rewrites node_modules/.package-lock.json at the end of every install,
  # so its mtime stamps the source install; the stamp a copy was taken from is
  # kept in the worktree's private git dir.
  source_stamp=""
  [ -f "$main_tree/node_modules/.package-lock.json" ] && source_stamp="$(stat -c %Y "$main_tree/node_modules/.package-lock.json")"
  # Named from envPrefix (`mb-nested-deps-stamp`), so a worktree bootstrapped by
  # a repo's own older copy of this script keeps its stamp instead of reading as
  # stale and being re-copied from scratch.
  stamp_prefix="$(printf '%s' "$env_prefix" | tr '[:upper:]' '[:lower:]')"
  stamp_file="$(git -C "$target" rev-parse --path-format=absolute --git-dir)/${stamp_prefix:+$stamp_prefix-}nested-deps-stamp"
  copied_stamp=""
  [ -f "$stamp_file" ] && copied_stamp="$(cat "$stamp_file")"
  stale=0
  if [ "$branch_owns_deps" = 0 ] && [ -n "$source_stamp" ] && [ "$copied_stamp" != "$source_stamp" ]; then stale=1; fi
  # The state BEFORE this run, for a repo's own mirror step: the stamp written
  # below would otherwise tell it the copy is current even when this run just
  # refreshed it.
  SETUP_WORKTREE_STALE="$stale" SETUP_WORKTREE_COPIED_STAMP="$copied_stamp"
  SETUP_WORKTREE_EXEMPT=""
  [ "$branch_owns_deps" = 0 ] || SETUP_WORKTREE_EXEMPT="$exempt_pkgs"

  # Copies READ the main tree's node_modules, which a concurrent `--writer npm ci`
  # rewrites; `cp` copies whatever bytes are there. So a copy holds the check
  # lock in light mode (excludes the writer, takes no slot) without drift
  # bookkeeping. A lock timeout (75) is reported as that, not as a short source;
  # a source quiet for SETUP_WORKTREE_STABLE_SECS has no writer to race, so a
  # timed-out copy retries once unlocked.
  stable_knob="${env_prefix:+${env_prefix}_SETUP_WORKTREE_STABLE_SECS}"
  stable_secs="${SETUP_WORKTREE_STABLE_SECS:-${stable_knob:+${!stable_knob:-}}}"
  stable_secs="${stable_secs:-300}"
  lock_gave_up=(); lock_retried=()
  copy_guarded() {
    local label="$1" status=0
    shift
    if [ ! -x "$LOCK" ]; then cp "$@" || true; return 0; fi
    "$LOCK" --light --no-drift cp "$@" || status=$?
    if [ "$status" -eq 75 ]; then
      if [ -n "$source_stamp" ] && (($(date +%s) - source_stamp >= stable_secs)); then
        cp "$@" || true
        lock_retried+=("$label")
      else
        lock_gave_up+=("$label")
      fi
    fi
    return 0
  }

  nested=(); refreshed=(); short=(); outdated=()
  find_roots=()
  for d in "${workspace_dirs[@]}"; do [ -n "$d" ] && [ -d "$main_tree/$d" ] && find_roots+=("$main_tree/$d"); done
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    rel="${src#"$main_tree"/}"
    dst="$target/$rel"
    workspace="${rel%/node_modules}"
    if ((check_only)); then
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ -d "$dst/$name" ]; then outdated+=("$workspace/$name"); else short+=("$workspace/$name"); fi
      done < <(drifted "$src" "$dst")
      while IFS= read -r name; do [ -n "$name" ] && short+=("$workspace/$name"); done < <(incomplete_packages "$src" "$dst")
      continue
    fi
    was_stale=0
    if [ "$stale" = 1 ] && [ -d "$dst" ]; then rm -rf "$dst"; was_stale=1; fi
    mkdir -p "$dst"
    while IFS= read -r name; do
      [ -n "$name" ] && [ -d "$dst/$name" ] || continue
      rm -rf "${dst:?}/$name"
      refreshed+=("$workspace/$name")
    done < <(drifted "$src" "$dst")
    # A package the branch's lockfile moved is its own install's to place, and
    # `cp -rn` fills whatever gap it finds: a branch that hoisted a package out
    # of this nest leaves exactly such a gap, and the main tree's nested copy at
    # the OLD version would land in it and shadow the branch's hoisted one. Note
    # which moved packages the copy would introduce, and take them back out.
    introduced_exempt=()
    if ((branch_owns_deps)); then
      while IFS= read -r entry; do
        name="${entry%@*}"
        [ -n "$name" ] && [ ! -e "$dst/$name" ] || continue
        if is_exempt "$name"; then introduced_exempt+=("$name"); fi
      done < <(pkg_list "$src")
    fi
    before=$(find "$dst" -mindepth 1 -maxdepth 1 | wc -l)
    copy_guarded "$workspace" -rn "$src/." "$dst/"
    for name in ${introduced_exempt[@]+"${introduced_exempt[@]}"}; do
      rm -rf "${dst:?}/$name"
      case "$name" in @*/*) rmdir "$dst/${name%%/*}" 2>/dev/null || true ;; esac
    done
    # Their `.bin` links came along too, now dangling; left in place they would
    # shadow the branch's own root binaries on an npm script's PATH.
    if [ "${#introduced_exempt[@]}" -gt 0 ] && [ -d "$dst/.bin" ]; then
      find "$dst/.bin" -maxdepth 1 -xtype l -delete
      rmdir "$dst/.bin" 2>/dev/null || true
    fi
    after=$(find "$dst" -mindepth 1 -maxdepth 1 | wc -l)
    if ((after > before)); then
      if ((was_stale)); then refreshed+=("$workspace"); else nested+=("$workspace"); fi
    fi
    [ -z "$(drifted "$src" "$dst")" ] || short+=("$workspace")
    while IFS= read -r name; do [ -n "$name" ] && short+=("$workspace/$name"); done < <(incomplete_packages "$src" "$dst")
  done < <([ "${#find_roots[@]}" -eq 0 ] || find "${find_roots[@]}" -mindepth 2 -maxdepth 2 -type d -name node_modules 2>/dev/null | sort)
  # A package absent from the copy is both drifted and incomplete; name it once.
  if [ "${#short[@]}" -gt 0 ]; then mapfile -t short < <(printf '%s\n' "${short[@]}" | awk '!seen[$0]++'); fi

  # Workspace packages resolve to THIS worktree's source, not the main tree's.
  if [ -n "$scope" ] && ((check_only == 0)); then
    linked=()
    mkdir -p "$target/node_modules/$scope"
    for d in "${workspace_dirs[@]}"; do
      [ -n "$d" ] && [ -d "$target/$d" ] || continue
      for pkg_dir in "$target/$d"/*/; do
        pkg_dir="${pkg_dir%/}"
        [ -f "$pkg_dir/package.json" ] || continue
        pname="$(node -p "require('$pkg_dir/package.json').name" 2>/dev/null)" || continue
        case "$pname" in "$scope"/*) ;; *) continue ;; esac
        link="$target/node_modules/$pname"
        dest="../../${pkg_dir#"$target"/}"
        if [ -L "$link" ] && [ "$(readlink "$link")" != "$dest" ]; then rm "$link"; fi
        if [ -e "$link" ] && [ ! -L "$link" ]; then warn "$link exists and is not a symlink — leaving it alone."; continue; fi
        if [ ! -e "$link" ]; then ln -s "$dest" "$link"; linked+=("$pname"); fi
      done
    done
    [ "${#linked[@]}" -eq 0 ] || say "linked workspace packages: ${linked[*]}"
  fi

  if ((check_only)); then
    if [ "$((${#short[@]} + ${#outdated[@]}))" -gt 0 ]; then
      warn "this worktree's nested deps no longer match $main_tree."
      [ "${#outdated[@]}" -eq 0 ] || warn "held at a version the main tree has moved off: ${outdated[*]}"
      [ "${#short[@]}" -eq 0 ] || warn "missing or incomplete: ${short[*]}"
      warn "Nothing is wrong with the branch: the copy runs once, at \`git worktree add\`. Repair:"
      warn "  ~/.claude/bin/setup-worktree.sh $target"
      warn "If the same packages are reported afterwards, the MAIN checkout is stale:"
      warn "  (cd $main_tree && ~/.claude/bin/with-check-lock.sh --writer npm ci)"
      exit 1
    fi
    run_steps check worktree.checkSteps
    exit 0
  fi

  [ "${#lock_retried[@]}" -eq 0 ] || say "the check lock gave up waiting to copy: ${lock_retried[*]} — retried unlocked, since the source has been quiet for at least ${stable_secs}s and no writer can be racing it."
  if [ "${#lock_gave_up[@]}" -gt 0 ]; then
    warn "the check lock timed out before copying: ${lock_gave_up[*]} — nothing was copied for them (exit 75, the box is"
    warn "contended; the source is not short). Retry: ~/.claude/bin/setup-worktree.sh $target  (CHECK_TIMEOUT=0 waits indefinitely)"
    exit 1
  fi
  [ "${#refreshed[@]}" -eq 0 ] || say "refreshed stale nested workspace deps: ${refreshed[*]}"
  [ "${#nested[@]}" -eq 0 ] || say "copied nested workspace deps: ${nested[*]}"
  if [ "${#short[@]}" -gt 0 ]; then
    warn "nested deps are INCOMPLETE for: ${short[*]} — typecheck would report TS2307 on files this branch never"
    warn "touched. Re-run this script; if it persists the source is mid-install, so wait and run:"
    warn "  (cd $target && ~/.claude/bin/with-check-lock.sh --writer npm ci)"
    exit 1
  elif [ -n "$source_stamp" ] && [ "$branch_owns_deps" = 0 ]; then
    printf '%s' "$source_stamp" >"$stamp_file"
  fi
fi

# ---------------------------------------------------------------------------
# Both strategies: Prisma client, graph, repo steps, credential nudges
# ---------------------------------------------------------------------------
prisma_cmd="$(manifest_get worktree.prismaGenerate || true)"
if [ -n "$prisma_cmd" ]; then
  say "generating the Prisma client: $prisma_cmd"
  if ! (cd "$target" && sh -c "$prisma_cmd" >/dev/null 2>&1); then
    # A CLI that does not resolve is a dependency problem, not a schema one, and
    # wants a different repair.
    if ! (cd "$target" && npx --no-install prisma --version >/dev/null 2>&1); then
      warn "the prisma CLI does not resolve here, so the client could not be generated. Install first:"
      warn "  (cd $target && ~/.claude/bin/with-check-lock.sh --writer npm ci)   then re-run: ~/.claude/bin/setup-worktree.sh $target"
    else
      warn "Prisma client generation failed — run it by hand: (cd $target && $prisma_cmd)"
    fi
    exit 1
  fi
fi

if [ "$(manifest_get worktree.graphify || echo false)" = true ]; then
  if command -v graphify >/dev/null 2>&1; then
    (cd "$target" && graphify update . >/dev/null 2>&1) && say "graphify-out ready." \
      || warn "graphify update failed — run by hand: (cd $target && graphify update .)"
  else
    warn "graphify CLI not on PATH — skipping the knowledge graph (bootstrap.sh installs it)."
  fi
fi

run_steps post worktree.postSteps

# Credentials are per machine, in the state dir and sourced from ~/.bashrc, so a
# worktree inherits them; a fresh machine has to build them once. Nudged, not
# pulled: a pull needs the network and a linked cloud project.
if [ -n "$state_dir" ]; then
  if [ "$(manifest_get ops.channel || echo false)" = true ] && [ ! -f "$state_dir/ops.env" ]; then
    warn "ops secrets not found — on a new machine run: (cd $main_tree && ~/.claude/bin/ops-pull.sh)"
  fi
  if [ ! -f "$state_dir/agent.env" ]; then
    warn "agent shell creds not found — build them once: (cd $main_tree && ~/.claude/bin/agent-env-build.sh)"
  fi
fi
# The next thing a worktree is likely to run is an install, and npm exits 0 on
# one that silently omitted every auth-gated package when the token is empty.
if [ -z "${NODE_AUTH_TOKEN:-}" ] && [ "$strategy" = mirror ] \
  && ! grep -qs '^export NODE_AUTH_TOKEN=.' "$HOME/.config/secrets/gmi.env" ${state_dir:+"$state_dir/agent.env"}; then
  warn "no GitHub Packages token in this shell or in ~/.config/secrets/gmi.env — an \`npm ci\` here would silently omit"
  warn "every auth-gated package. Export a NODE_AUTH_TOKEN that can read packages (e.g. in ~/.config/secrets/gmi.env), then start a new shell."
fi

say "$target ready ($strategy)."
