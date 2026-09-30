#!/usr/bin/env bash
# dotclaude npm-install-guard — PreToolUse hook (matcher: Bash). Guards the two
# ways an npm command produces a broken tree without saying so.
#
# 1. LOCKFILE PIN. A repo that pins "packageManager": "npm@<x>" rejects a
#    lockfile written by another npm major — CI re-resolves under the pin, and a
#    deploy that installs under it fails — so a failure invisible locally
#    surfaces at deploy time. CI pins npm with `corepack enable npm`; this hook
#    is the local equivalent of that pin.
#
#    The pin is read from the TARGET repo's package.json, not assumed. Agent
#    sessions routinely run npm in a sibling checkout with a different pin (or
#    none), and a guard that blocks those has stopped enforcing a constraint and
#    started being an obstacle to work it knows nothing about. No `packageManager` pin, or a pin this box's
#    npm already satisfies, means there is nothing to enforce.
#
#    Allowed: `npm ci` (installs from the lockfile, never rewrites it) and
#    anything under `corepack npm@<pinned>` (the pinned regeneration path).
#    `npx npm@<pinned>` looks equivalent and is not: Node 24's `npx` is itself
#    a corepack shim, and corepack resolves the version to run from its own
#    state rather than the `npx` argument — so it silently runs whatever npm
#    corepack defaults to instead of the pin, with no error (MuscleBuddy#5551).
#    It is REFUSED with that explanation rather than allowed on the strength of
#    the version string it names (MuscleBuddy#5685) — the string was the whole
#    basis of the old allowance, and it is the part that lies.
#    The `npm(@[^[:space:]]+)?` match below is what lets this hook recognize
#    the pinned `corepack npm@<pinned>` form as npm at all — a bare `npm`
#    pattern would miss it, since there's no whitespace between `npm` and
#    `@<pinned>`, and silently skip both checks on the very command this hook
#    recommends.
#
#    `install` is not the only way in: `update`, `uninstall`, `dedupe`, `prune`
#    and `audit fix` all resolve the tree and write the lockfile back out, so
#    blocking `install` alone leaves the same npm-11 lockfile one `npm update`
#    away.
#
# 2. GITHUB PACKAGES TOKEN. A target `.npmrc` that authenticates a registry
#    with `${NODE_AUTH_TOKEN}` makes an EMPTY token worse than a wrong one: npm
#    reports `added N packages`, exits 0, and silently omits every package from
#    that registry, which surfaces hours later as TS2307 on files nobody touched
#    (MuscleBuddy#3964). An EXPIRED token fails the same way, so a GitHub-shaped
#    token is probed against the registry (verdict cached an hour per token
#    fingerprint; NPM_TOKEN_PROBE_URL overrides the probe target). `npm ci` is
#    in scope for this one precisely because it is otherwise always safe.
#
#    The token the install would see is read from the environment, then — since
#    a hook's shell may predate the profile — from ~/.config/secrets/gmi.env
#    (which ~/.bashrc sources last) and the target repo's manifest
#    `<stateDir>/agent.env` (docs/repo-manifest.md).
#
# Fail-open on anything unexpected.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || exit 0
input="$(cat)"

parsed="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""))
    print(d.get("cwd", ""))
except Exception:
    print("")
    print("")
' 2>/dev/null)" || exit 0

command_str="$(printf '%s' "$parsed" | sed -n '1p')"
hook_cwd="$(printf '%s' "$parsed" | sed -n '2p')"

[ -n "$command_str" ] || exit 0

# npm subcommands that re-resolve the tree and write package-lock.json back out,
# including npm's own aliases and typo-aliases. `ci`, `run`, `test`, `ls`, `exec`
# and a bare `npm audit` are absent on purpose — none of them touch the lockfile.
mutating='install|i|in|ins|inst|insta|instal|isnt|isnta|isntal|isntall|add|update|udpate|upgrade|up|uninstall|unlink|remove|rm|r|un|dedupe|ddp|find-dupes|prune'

# The boundaries are "any non-word character" rather than a list of separators,
# so a subshell (`(npm install)`), a pipe, a `;` or an absolute path all still
# match, while `pnpm install` and `npm run install-thing` do not.
lead='(^|[^[:alnum:]_.-])'
trail='([^[:alnum:]_.-]|$)'
# `npm` matches bare or version-pinned (`npm@10.8.2`, `corepack npm@10.8.2 install`)
# — the pinned regeneration path this hook itself recommends names the version on
# the command line, and a pattern that only matched bare `npm` would fail to
# recognize its own suggested command as npm at all, skipping both checks below.
npm_re='npm(@[^[:space:]]+)?'
# A global flag between `npm` and the subcommand (`npm --prefix <dir> install`) used to
# skip both checks below entirely, because the subcommand was required to follow `npm`
# immediately. Absorbs any number of intervening tokens — a flag AND the value it takes
# (`--prefix` and its directory argument are two separate whitespace-delimited tokens,
# neither of which is itself the subcommand) — so a bare `npm audit fix` still matches
# with zero repetitions. Excludes `;&|` from the token class so this cannot cross a shell
# separator and match an unrelated `install` later in a compound command
# (`npm run x && rm -rf install` must never read as `npm install`).
npm_flags='([^[:space:];&|]+[[:space:]]+)*'

writes_lockfile=0
# `npm audit` alone only reports; it is `npm audit fix` that rewrites.
if printf '%s' "$command_str" \
     | grep -qE "${lead}${npm_re}[[:space:]]+${npm_flags}($mutating)${trail}" \
   || printf '%s' "$command_str" \
     | grep -qE "${lead}${npm_re}[[:space:]]+${npm_flags}audit[[:space:]]+fix${trail}"; then
  writes_lockfile=1
fi

# Everything that FETCHES packages, which is the lockfile writers plus `npm ci`.
fetches=$writes_lockfile
if printf '%s' "$command_str" | grep -qE "${lead}${npm_re}[[:space:]]+${npm_flags}ci${trail}"; then
  fetches=1
fi

((writes_lockfile || fetches)) || exit 0

# Which tree would it write? A leading `cd <dir>` wins over the session cwd —
# that is how a command reaches another checkout in the first place.
target="${hook_cwd:-$PWD}"
cd_target="$(printf '%s' "$command_str" \
  | grep -oE "${lead}cd[[:space:]]+[^[:space:];&|]+" \
  | head -1 | sed -E 's/.*cd[[:space:]]+//')"
if [ -n "$cd_target" ]; then
  case "$cd_target" in
    /*) target="$cd_target" ;;
    '~'*) target="${HOME}${cd_target#\~}" ;;
    *) target="${target}/${cd_target}" ;;
  esac
fi

# Walk up for the nearest package.json carrying a packageManager pin, and for the
# nearest .npmrc that authenticates a registry with NODE_AUTH_TOKEN. npm reads
# both from the cwd upwards, so the walk is the same one npm itself does.
pinned=''
pin_dir=''
npmrc=''
dir="$target"
for _ in 1 2 3 4 5 6 7 8; do
  [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ] || break
  if [ -z "$pinned" ] && [ -f "$dir/package.json" ]; then
    pinned="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"npm@\([0-9][0-9.]*\)".*/\1/p' \
      "$dir/package.json" | head -1)"
    [ -n "$pinned" ] && pin_dir="$dir"
  fi
  if [ -z "$npmrc" ] && [ -f "$dir/.npmrc" ] \
     && grep -q 'NODE_AUTH_TOKEN' "$dir/.npmrc"; then
    npmrc="$dir/.npmrc"
  fi
  dir="$(dirname "$dir")"
done

# The value of a variable as the install would see it: this process's
# environment, else the files a login shell would have sourced.
state_env=""
manifest_file="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)/.claude/repo.json"
if [ -f "$manifest_file" ]; then
  state_dir="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("stateDir") or "")' "$manifest_file" 2>/dev/null)"
  case "$state_dir" in \~/*) state_dir="$HOME/${state_dir#\~/}" ;; esac
  [ -n "$state_dir" ] && state_env="$state_dir/agent.env"
fi
env_value() {
  # The name is matched against an identifier before it gets here; `eval` reads
  # a variable by name under `set -u` without tripping on an unset one.
  local name="$1" val='' f
  eval "val=\${$name:-}"
  for f in "$HOME/.config/secrets/gmi.env" ${state_env:+"$state_env"}; do
    [ -z "$val" ] && [ -f "$f" ] || continue
    val="$(sed -n "s/^export ${name}=//p; s/^${name}=//p" "$f" | tail -1)"
    val="${val%\'}"; val="${val#\'}"
    val="${val%\"}"; val="${val#\"}"
  done
  printf '%s' "$val"
}

if ((fetches)) && [ -n "$npmrc" ]; then
  # An inline `NODE_AUTH_TOKEN=…` prefix overrides whatever the shell holds, so
  # it is what decides. A command substitution or a literal carries its own
  # value and is fine; `NODE_AUTH_TOKEN=$GITHUB_TOKEN` is only as good as
  # GITHUB_TOKEN, and an empty one is the exact shape of MuscleBuddy#3964.
  token='' ; source_desc=''
  inline="$(printf '%s' "$command_str" | sed -n 's/.*NODE_AUTH_TOKEN=//p' | head -1)"
  # A leading double quote is quoting, not content: `NODE_AUTH_TOKEN="$(gh auth
  # token)"` and `NODE_AUTH_TOKEN="$GITHUB_TOKEN"` must classify as what they
  # wrap. A single quote suppresses expansion, so it IS a literal.
  inline="${inline#\"}"
  if [ -n "$inline" ]; then
    case "$inline" in
      '$('*|'`'*)
        # `$(gh auth token)` is the one substitution this repo's docs warn about
        # by name — that credential carries no `read:packages`, and GitHub
        # Packages answers it 403 (MuscleBuddy#4017, MuscleBuddy#7449). It is also side-effect-free,
        # so it is EVALUATED rather than waved past as opaque: the whole point
        # of the probe below is to catch a token that exists and does not work,
        # and this is the most common way to acquire one.
        subst="$(printf '%s' "$inline" \
          | sed -E 's/^\$\(([^)]*)\).*/\1/; s/^`([^`]*)`.*/\1/' \
          | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')"
        case "$subst" in
          'gh auth token')
            token="$(gh auth token 2>/dev/null || true)"
            source_desc='$(gh auth token)'
            ;;
          *) token='inline-substitution' ;;
        esac
        ;;
      '$'*)
        var="$(printf '%s' "$inline" | sed -E 's/^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?.*/\1/')"
        # Anything that is not a plain variable name is an expansion this hook
        # cannot evaluate — treat it as opaque and allow, rather than guessing.
        if printf '%s' "$var" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
          token="$(env_value "$var")"
          source_desc="\$$var"
        else
          token='inline-expansion'
        fi
        ;;
      [[:space:]]*|'') token='' ; source_desc='the empty prefix on this command' ;;
      *)
        # A literal token typed on the command line. Keep the VALUE — it is the
        # most probe-able form there is, and discarding it here is what let an
        # invalid inline token through the check below.
        token="$(printf '%s' "$inline" | awk '{print $1}')"
        source_desc='the token on this command line'
        [ -n "$token" ] || token='inline-literal'
        ;;
    esac
  else
    token="$(env_value NODE_AUTH_TOKEN)"
    source_desc='NODE_AUTH_TOKEN'
  fi

  if [ -z "$token" ]; then
    cat >&2 <<EOF
⛔ dotclaude npm-install-guard: this install would authenticate GitHub Packages with an EMPTY token
(${source_desc} is unset or empty; ${npmrc} reads \${NODE_AUTH_TOKEN}).

That does not fail. npm reports "added N packages", exits 0, and omits every
@garrettmakesitllc-scoped package — so the tree builds until something imports
\`@gmi/*\`, then reports TS2307 on files you never touched (MuscleBuddy#3964).

Use the token that actually reads GitHub Packages — the PAT in gmi.env:

  . ~/.config/secrets/gmi.env && <your command>

NOT \`gh auth token\`. That credential carries no \`read:packages\` scope and
npm.pkg.github.com answers it 403, so it lands right back here (MuscleBuddy#4017, MuscleBuddy#7449).
Check which one you actually hold:

  printenv NODE_AUTH_TOKEN | head -c 4   # ghp_ is the PAT; gho_ is gh's
EOF
    exit 2
  fi

  # ...and the same failure with a token that EXISTS but no longer works.
  #
  # Emptiness was the only thing checked above, and an expired token is not
  # empty: it is 40 characters of `ghp_...` that the registry answers 401 to,
  # and npm treats that 401 exactly like the empty case — `added N packages`,
  # exit 0, every @garrettmakesitllc package silently omitted (MuscleBuddy#3976). Because a
  # worktree resolves node_modules upward to the MAIN checkout, one such install
  # breaks typecheck, lint and test for every worktree on the box at once, and
  # it presents as a missing-package error on files nobody touched.
  #
  # So the check has to be "does this token authenticate", not "is this token
  # non-empty" — the weaker question is the one that let MuscleBuddy#3976 happen.
  #
  # Only a token this hook actually resolved is probed. The sentinels stand for
  # values it could not evaluate (a command substitution, an opaque expansion),
  # and guessing at those would block work over a string the hook cannot read.
  #
  # Only something shaped like a GitHub credential is probed. Every token GitHub
  # issues carries one of these prefixes, so a value without one cannot be a live
  # credential this check could usefully validate — it is a stub, a placeholder,
  # or a fixture, and spending a network round trip to tell it that helps nobody.
  # The case MuscleBuddy#3976 is about is a REAL `ghp_` token that stopped working, which
  # this still catches.
  #
  # `inline-literal`, `inline-substitution` and `inline-expansion` are sentinels
  # for values the hook could not evaluate, and none of them match a prefix.
  case "$token" in
    ghp_*|gho_*|ghu_*|ghs_*|ghr_*|github_pat_*) probe="$token" ;;
    *) probe='' ;;
  esac

  if [ -n "$probe" ] && command -v curl >/dev/null 2>&1; then
    # Cache by token fingerprint, never the token itself, so a stale verdict
    # cannot outlive the credential it describes and no secret lands on disk.
    fingerprint="$(printf '%s' "$probe" | sha256sum 2>/dev/null | cut -c1-16)"
    cache="${TMPDIR:-/tmp}/npm-token-probe-${fingerprint:-none}"
    fresh=0
    if [ -n "$fingerprint" ] && [ -f "$cache" ]; then
      age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
      [ "$age" -lt 3600 ] && fresh=1
    fi

    if [ "$fresh" = 1 ]; then
      status="$(cat "$cache" 2>/dev/null)"
    else
      # A HEAD against a package this repo actually depends on. 200 = usable,
      # 401/403 = the failure being guarded. Anything else (000 on timeout, 5xx)
      # is the network's problem, not the token's.
      # Overridable so the sibling test can point this at a local server and
      # assert both verdicts without depending on the network or on the state of
      # a real credential. Nothing outside the test sets it.
      probe_url="${NPM_TOKEN_PROBE_URL:-https://npm.pkg.github.com/@garrettmakesitllc%2fpatterns}"
      status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
        -H "Authorization: Bearer ${probe}" \
        "$probe_url" 2>/dev/null)" || status=''
      [ -n "$fingerprint" ] && [ -n "$status" ] && printf '%s' "$status" >"$cache" 2>/dev/null
    fi

    case "$status" in
      401|403)
        cat >&2 <<EOF
⛔ dotclaude npm-install-guard: this install would authenticate GitHub Packages with an INVALID token
(${source_desc} is set, but npm.pkg.github.com answers it ${status}).

This fails exactly as silently as an empty one: npm reports "added N packages",
exits 0, and omits every @garrettmakesitllc-scoped package. A worktree resolves
node_modules upward, so this corrupts the MAIN checkout and breaks typecheck,
lint and test in EVERY worktree on this box — surfacing later as a missing
\`@gmi/*\` package on files you never touched (MuscleBuddy#3976).

The effective token is the PAT from ~/.config/secrets/gmi.env, which .bashrc
sources last — NOT necessarily \`gh auth token\`. Check what you actually have:

  gh auth status                       # is the ACTIVE account's token the valid one?
  printenv NODE_AUTH_TOKEN | head -c 8 # which credential is really in scope?

A \`gho_\` prefix is the answer on its own: that is \`gh\`'s own token, it carries
no \`read:packages\`, and this registry answers it 403 every time (MuscleBuddy#4017, MuscleBuddy#7449).
Pick up the PAT instead, then re-run:

  . ~/.config/secrets/gmi.env && <your command>

If the PAT itself is what was rejected, it has expired — mint a new one with
\`read:packages\`, and write it to ~/.config/secrets/gmi.env.

This verdict is cached for an hour per token.
EOF
        exit 2
        ;;
    esac
  fi
fi

((writes_lockfile)) || exit 0

# No pin in the target tree — nothing to enforce, and not this hook's business.
[ -n "$pinned" ] || exit 0

# `npx npm@<pinned>` names the pin and does not honour it. Node 24's `npx` is
# itself a corepack shim, and corepack resolves the version to run from its own
# state rather than from the `npx` argument — so this exits 0 having run whatever
# npm corepack defaults to (verified: npm 12.0.1), with no error and no warning
# (MuscleBuddy#5551). It has to be refused BEFORE the "already pinned" allowance below,
# which used to let it straight through on the strength of the string alone.
if printf '%s' "$command_str" | grep -qE "${lead}npx[[:space:]]+(--[^[:space:]]+[[:space:]]+)*npm@"; then
  cat >&2 <<EOF
⛔ dotclaude npm-install-guard: \`npx npm@${pinned}\` looks like the pinned regeneration path and is not.

Node 24's \`npx\` is itself a corepack shim, and corepack resolves the version to
run from its own state rather than from the \`npx\` argument — so this exits 0
having run whatever npm corepack defaults to instead of ${pinned}, with no error
and no warning (MuscleBuddy#5551). The lockfile it writes is then rejected by CI's
\`preflight\` job, which re-resolves it under the pin.

Ask corepack directly:

  corepack npm@${pinned} install
EOF
  exit 2
fi

# Already pinned on the command line? Nothing to do.
case "$command_str" in
  *"npm@${pinned}"*) exit 0 ;;
esac

# The box's npm already satisfies the pin (same major) — no lockfile drift.
box_major="$(npm --version 2>/dev/null | cut -d. -f1)"
pin_major="${pinned%%.*}"
if [ -n "$box_major" ] && [ "$box_major" = "$pin_major" ]; then
  exit 0
fi

cat >&2 <<EOF
⛔ dotclaude npm-install-guard: this npm command would regenerate the package-lock.json under
${pin_dir}, which pins npm@${pinned}, using this box's npm ${box_major:-11}.

A lockfile written by the wrong npm major passes CI and is then rejected by the
pinned version on deploy — the failure is invisible until production. Use one of:

  npm ci                           # install from the lockfile (what you almost always want)
  corepack npm@${pinned} install   # regenerate the lockfile under the pinned version

\`packageManager\` in ${pin_dir}/package.json is the pin; CI enforces it with corepack.
EOF
exit 2
