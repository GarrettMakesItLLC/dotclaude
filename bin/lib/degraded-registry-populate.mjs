#!/usr/bin/env node
// degraded-registry-populate.mjs — fill the degraded mirror's store with every
// @garrettmakesitllc/* version any consumer lockfile pins, and check lockfiles
// against it. Run through bin/degraded-registry.sh (populate | verify | pins).
//
//   pins     [--root DIR]... [--lockfile FILE]...        TSV of every pin found
//   populate [--root DIR]... [--lockfile FILE]... [--rebuild] [--cache DIR]...
//   verify   --lockfile FILE...                          exit 1 on any gap
//
// Where pins come from: every git repo directly under each --root (default
// ~/workspace, plus one level deeper for grouping dirs like Tools/), at three
// refs: the working tree, origin/dev and origin/main. A fresh worktree is cut
// from one of the remote refs, so the mirror has to cover them as well as
// whatever a checkout currently holds.
//
// Where tarballs come from, in order:
//   1. already in the store, with a matching integrity: nothing to do;
//   2. an npm cache (cacache content is addressed by the sha512 the lockfile
//      already names, so it is the exact published bytes);
//   3. --rebuild: built and packed from the platform repo at the version's
//      release tag. Kept ONLY if its integrity equals the lockfile's. A rebuild
//      that differs goes to <state>/mismatch/ and is reported, never served:
//      serving it would make a regenerated lockfile pin bytes that GitHub
//      Packages does not hold, and that lockfile would break the day billing
//      comes back.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const SCOPE = '@garrettmakesitllc/';
const HOME = os.homedir();
const STORE = process.env.GMI_REGISTRY_STORE;
const STATE = process.env.GMI_REGISTRY_STATE || path.join(HOME, '.local/state/gmi-registry');
const PORT = process.env.GMI_REGISTRY_PORT || '4873';
const PLATFORM = process.env.GMI_PLATFORM_DIR || path.join(HOME, 'workspace/platform');

function die(msg) {
  console.error(`degraded-registry: ${msg}`);
  process.exit(1);
}

// --- arguments ---------------------------------------------------------------

const [cmd, ...rest] = process.argv.slice(2);
const opts = { roots: [], lockfiles: [], caches: [], rebuild: false };
for (let i = 0; i < rest.length; i++) {
  const a = rest[i];
  if (a === '--root') opts.roots.push(rest[++i]);
  else if (a === '--lockfile') opts.lockfiles.push(rest[++i]);
  else if (a === '--cache') opts.caches.push(rest[++i]);
  else if (a === '--rebuild') opts.rebuild = true;
  else die(`unknown argument: ${a}`);
}
if (!['pins', 'populate', 'verify'].includes(cmd)) die('usage: pins|populate|verify [options]');
if (cmd !== 'pins' && !STORE) die('GMI_REGISTRY_STORE is not set');

// --- pin discovery -------------------------------------------------------------

function git(dir, args) {
  return execFileSync('git', ['-C', dir, ...args], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 256 << 20,
  });
}

function repoDirs(root) {
  const out = [];
  const visit = (dir, depth) => {
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (!e.isDirectory() || e.name.startsWith('.') || e.name === 'node_modules') continue;
      if (/-worktrees$/.test(e.name)) continue;
      const d = path.join(dir, e.name);
      if (existsSync(path.join(d, '.git'))) {
        if (existsSync(path.join(d, 'package-lock.json'))) out.push(d);
      } else if (depth > 0) {
        visit(d, depth - 1);
      }
    }
  };
  visit(root, 1);
  return out;
}

function pinsFromLock(text, source) {
  let lock;
  try { lock = JSON.parse(text); } catch { return []; }
  const pins = [];
  for (const [key, v] of Object.entries(lock.packages || {})) {
    const name = v.name || key.replace(/^.*node_modules\//, '');
    if (!name.startsWith(SCOPE) || !v.integrity || !/^https?:/.test(v.resolved || '')) continue;
    pins.push({ name, version: v.version, integrity: v.integrity, resolved: v.resolved, source });
  }
  return pins;
}

function collectPins() {
  const pins = [];
  for (const f of opts.lockfiles) pins.push(...pinsFromLock(readFileSync(f, 'utf8'), f));
  const roots = opts.roots.length || opts.lockfiles.length ? opts.roots : [path.join(HOME, 'workspace')];
  // Two checkouts of one remote (a second clone parked on an old branch) would
  // otherwise drag in every version that clone's stale refs ever pinned. Keep
  // the checkout whose origin/main is newest; name the others so a caller who
  // does need one can pass its lockfile explicitly.
  const byRemote = new Map();
  for (const root of roots) {
    for (const dir of repoDirs(root)) {
      let remote = dir;
      let stamp = 0;
      try { remote = git(dir, ['remote', 'get-url', 'origin']).trim()
        .replace(/\.git$/, '').replace(/^.*github\.com[:/]/, '').toLowerCase(); } catch { /* no origin */ }
      try { stamp = Number(git(dir, ['log', '-1', '--format=%ct', 'origin/main']).trim()) || 0; } catch { /* no origin/main */ }
      const prev = byRemote.get(remote);
      if (!prev || stamp > prev.stamp) {
        if (prev) console.error(`skipping ${prev.dir}: ${dir} is a fresher checkout of ${remote}`);
        byRemote.set(remote, { dir, root, stamp });
      } else {
        console.error(`skipping ${dir}: ${prev.dir} is a fresher checkout of ${remote}`);
      }
    }
  }
  for (const { dir, root } of byRemote.values()) {
    {
      const label = path.relative(root, dir);
      pins.push(...pinsFromLock(readFileSync(path.join(dir, 'package-lock.json'), 'utf8'), `${label}@worktree`));
      for (const ref of ['origin/dev', 'origin/main']) {
        let text = '';
        try { text = git(dir, ['show', `${ref}:package-lock.json`]); } catch { continue; }
        pins.push(...pinsFromLock(text, `${label}@${ref}`));
      }
    }
  }
  return pins;
}

// One entry per name@version. Two different integrities for one version means
// the same version number was published twice with different bytes — not
// something a mirror can resolve, so it is reported rather than picked.
function unique(pins) {
  const by = new Map();
  for (const p of pins) {
    const k = `${p.name}@${p.version}`;
    if (!by.has(k)) by.set(k, { ...p, sources: new Set(), integrities: new Set() });
    by.get(k).sources.add(p.source);
    by.get(k).integrities.add(p.integrity);
  }
  return [...by.values()].sort((a, b) => (a.name + a.version).localeCompare(b.name + b.version));
}

// --- store and caches ------------------------------------------------------------

const short = (name) => name.slice(SCOPE.length);
const storePath = (p) => path.join(STORE, 'packages', short(p.name), `${short(p.name)}-${p.version}.tgz`);

function integrityOf(file, alg = 'sha512') {
  return `${alg}-${createHash(alg).update(readFileSync(file)).digest('base64')}`;
}

function cacheDirs() {
  const dirs = [...opts.caches];
  try {
    dirs.push(path.join(execFileSync('npm', ['config', 'get', 'cache'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(), '_cacache'));
  } catch { /* npm absent: the defaults below still apply */ }
  dirs.push(path.join(HOME, '.npm/_cacache'), '/tmp/npm-cache/_cacache');
  for (const extra of (process.env.GMI_REGISTRY_CACHES || '').split(':')) if (extra) dirs.push(extra);
  return [...new Set(dirs.map((d) => (d.endsWith('_cacache') || existsSync(path.join(d, 'content-v2')) ? d : path.join(d, '_cacache'))))]
    .filter((d) => existsSync(path.join(d, 'content-v2')));
}

function fromCache(integrity, caches) {
  const [alg, b64] = integrity.split('-', 2);
  const hex = Buffer.from(b64, 'base64').toString('hex');
  for (const c of caches) {
    const f = path.join(c, 'content-v2', alg, hex.slice(0, 2), hex.slice(2, 4), hex.slice(4));
    if (existsSync(f)) return f;
  }
  return null;
}

// --- rebuild from platform -------------------------------------------------------------

function sh(cwd, cmdline, env = {}) {
  execFileSync('bash', ['-c', cmdline], {
    cwd, stdio: ['ignore', 'inherit', 'inherit'], env: { ...process.env, HUSKY: '0', ...env },
  });
}

function rebuild(p) {
  const tag = `@gmi/${short(p.name)}@${p.version}`;
  try { git(PLATFORM, ['rev-parse', '--verify', `refs/tags/${tag}`]); } catch {
    return { ok: false, why: `no tag ${tag} in ${PLATFORM}` };
  }
  const work = path.join(STATE, 'rebuild', tag.replace(/[@/]/g, '_'));
  rmSync(work, { recursive: true, force: true });
  mkdirSync(path.dirname(work), { recursive: true });
  try { git(PLATFORM, ['worktree', 'prune']); } catch { /* best effort */ }
  execFileSync('git', ['-C', PLATFORM, 'worktree', 'add', '--detach', work, `refs/tags/${tag}`], { stdio: 'ignore' });
  const out = path.join(work, '.degraded-pack');
  mkdirSync(out, { recursive: true });
  try {
    // The mirror serves platform's own @gmi/* pins, so the switch need not be
    // on for a rebuild — only the server has to be up.
    const reg = `--registry=http://127.0.0.1:${PORT}/ --replace-registry-host=npm.pkg.github.com`;
    sh(work, `npm ci --no-audit --no-fund ${reg}`);
    sh(work, 'npm run build');
    sh(work, `npm pack -w ${p.name} --pack-destination ${JSON.stringify(out)}`);
    const tgz = readdirSync(out).find((f) => f.endsWith('.tgz'));
    if (!tgz) return { ok: false, why: 'npm pack produced no tarball' };
    const built = path.join(out, tgz);
    const got = integrityOf(built, p.integrity.split('-')[0]);
    if (got === p.integrity) {
      mkdirSync(path.dirname(storePath(p)), { recursive: true });
      copyFileSync(built, storePath(p));
      return { ok: true };
    }
    const keep = path.join(STATE, 'mismatch', `${short(p.name)}-${p.version}.tgz`);
    mkdirSync(path.dirname(keep), { recursive: true });
    copyFileSync(built, keep);
    return { ok: false, why: `rebuilt from ${tag} but integrity differs (kept at ${keep}, NOT served)`, mismatch: true, rebuiltIntegrity: got };
  } catch (e) {
    return { ok: false, why: `rebuild of ${tag} failed: ${e.message.split('\n')[0]}` };
  } finally {
    try { execFileSync('git', ['-C', PLATFORM, 'worktree', 'remove', '--force', work], { stdio: 'ignore' }); } catch { /* left for prune */ }
  }
}

// --- commands -------------------------------------------------------------------------

const pins = unique(collectPins());

if (cmd === 'pins') {
  for (const p of pins) console.log([p.name, p.version, [...p.integrities].join(','), [...p.sources].join(',')].join('\t'));
  process.exit(0);
}

if (cmd === 'verify') {
  let gaps = 0;
  for (const p of pins) {
    const f = storePath(p);
    const have = existsSync(f) ? integrityOf(f, p.integrity.split('-')[0]) : null;
    if (have !== p.integrity) {
      gaps++;
      console.log(`MISSING ${p.name}@${p.version} ${have ? '(store holds different bytes)' : ''} <- ${[...p.sources].join(', ')}`);
    }
  }
  console.log(`${pins.length - gaps}/${pins.length} pinned versions served by the mirror`);
  process.exit(gaps ? 1 : 0);
}

// populate
const caches = cacheDirs();
const report = { present: 0, copied: 0, rebuilt: 0, conflict: [], missing: [], mismatch: [] };
for (const p of pins) {
  const label = `${p.name}@${p.version}`;
  if (p.integrities.size > 1) {
    report.conflict.push(`${label}: lockfiles disagree on integrity (${[...p.integrities].join(' vs ')})`);
    continue;
  }
  const dest = storePath(p);
  if (existsSync(dest)) {
    if (integrityOf(dest, p.integrity.split('-')[0]) === p.integrity) { report.present++; continue; }
    report.conflict.push(`${label}: the store holds different bytes than ${[...p.sources].join(', ')} pins`);
    continue;
  }
  const cached = fromCache(p.integrity, caches);
  if (cached) {
    mkdirSync(path.dirname(dest), { recursive: true });
    copyFileSync(cached, dest);
    if (integrityOf(dest, p.integrity.split('-')[0]) !== p.integrity) {
      rmSync(dest);
      report.missing.push(`${label}: cache entry ${cached} failed its integrity check`);
      continue;
    }
    report.copied++;
    continue;
  }
  if (opts.rebuild) {
    console.error(`rebuilding ${label} from platform...`);
    const r = rebuild(p);
    if (r.ok) { report.rebuilt++; continue; }
    (r.mismatch ? report.mismatch : report.missing).push(`${label}: ${r.why} <- ${[...p.sources].join(', ')}`);
    continue;
  }
  report.missing.push(`${label}: not in any npm cache (${caches.join(', ')}); re-run with --rebuild <- ${[...p.sources].join(', ')}`);
}

let files = 0;
const pkgRoot = path.join(STORE, 'packages');
if (existsSync(pkgRoot)) {
  for (const d of readdirSync(pkgRoot)) {
    if (statSync(path.join(pkgRoot, d)).isDirectory()) files += readdirSync(path.join(pkgRoot, d)).filter((f) => f.endsWith('.tgz')).length;
  }
}
console.log(`pinned versions: ${pins.length}  already in store: ${report.present}  copied from cache: ${report.copied}  rebuilt: ${report.rebuilt}  store total: ${files} tarballs`);
for (const [k, list] of [['CONFLICT', report.conflict], ['MISMATCH', report.mismatch], ['MISSING', report.missing]]) {
  for (const line of list) console.log(`${k} ${line}`);
}
process.exit(report.conflict.length || report.mismatch.length || report.missing.length ? 2 : 0);
