#!/usr/bin/env node
// gmi-registry-server.mjs — the degraded-mode npm registry for @garrettmakesitllc/*.
//
// Run through bin/degraded-registry.sh, never directly.
// skills/operating-a-fleet/references/degraded-registry.md
// has the design. The constraints this file enforces:
//
// * The store is a directory of tarballs and nothing else:
//   <store>/packages/<name>/<name>-<version>.tgz. Packuments are derived from
//   the tarballs on each request, so adding a version is copying a file, and a
//   `git pull` of the store is visible immediately without a restart.
// * dist.tarball is GitHub Packages' own URL form,
//   https://npm.pkg.github.com/download/@garrettmakesitllc/<name>/<version>/<sha1>.
//   npm records that URL in package-lock.json, so a lockfile written in degraded
//   mode is byte-identical to one written in normal mode. When the same tarball
//   bytes are later published to GitHub, that URL resolves there too. With
//   `replace-registry-host=always` in ~/.npmrc, npm sends the fetch
//   here instead, to the same path, which this server answers.
// * A tarball is served only when its sha1 matches the URL. A rebuilt tarball
//   that differs from the original is never passed off as it.
// * Anything outside the scope gets a 307 to registry.npmjs.org. A 307 keeps
//   the method and body, so `npm audit`'s POST still works.
//
// Binds 127.0.0.1 only. Publishing goes through `degraded-registry.sh publish`,
// which copies a packed tarball into the store. There is no PUT endpoint.

import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { createReadStream, readFileSync, readdirSync, realpathSync, statSync, existsSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { gunzipSync } from 'node:zlib';
import path from 'node:path';

const SCOPE = '@garrettmakesitllc';
const GH_DOWNLOAD = 'https://npm.pkg.github.com/download';
const UPSTREAM = process.env.GMI_REGISTRY_UPSTREAM || 'https://registry.npmjs.org';
const STORE = process.env.GMI_REGISTRY_STORE;
const PORT = Number(process.env.GMI_REGISTRY_PORT || 4873);
const HOST = process.env.GMI_REGISTRY_BIND || '127.0.0.1';

if (!STORE) {
  console.error('gmi-registry-server: GMI_REGISTRY_STORE is not set');
  process.exit(1);
}
const PKG_ROOT = path.join(STORE, 'packages');

// --- tarball reading ---------------------------------------------------------

// Memoised per path+mtime+size: hashing and gunzipping happens once per tarball.
const meta = new Map();

function readTarEntry(buf, wanted) {
  // Minimal ustar reader: enough for `npm pack` output, which is plain ustar
  // with `package/` prefixed names (plus pax headers for long ones).
  let off = 0;
  let paxPath = null;
  while (off + 512 <= buf.length) {
    const hdr = buf.subarray(off, off + 512);
    if (hdr.every((b) => b === 0)) break;
    const str = (a, b) => hdr.subarray(a, b).toString('utf8').replace(/\0.*$/s, '');
    let name = str(0, 100);
    const prefix = str(345, 500);
    if (prefix) name = `${prefix}/${name}`;
    const size = parseInt(str(124, 136).trim() || '0', 8);
    const type = String.fromCharCode(hdr[156] || 48);
    const body = buf.subarray(off + 512, off + 512 + size);
    off += 512 + Math.ceil(size / 512) * 512;
    if (type === 'x') {
      const m = /\d+ path=([^\n]*)\n/.exec(body.toString('utf8'));
      paxPath = m ? m[1] : null;
      continue;
    }
    if (paxPath) {
      name = paxPath;
      paxPath = null;
    }
    if (name === wanted) return body;
  }
  return null;
}

function tarballMeta(file) {
  const st = statSync(file);
  const key = `${file}:${st.mtimeMs}:${st.size}`;
  const hit = meta.get(file);
  if (hit && hit.key === key) return hit;
  const buf = readFileSync(file);
  const sha1 = createHash('sha1').update(buf).digest('hex');
  const integrity = `sha512-${createHash('sha512').update(buf).digest('base64')}`;
  let manifest = null;
  try {
    const pj = readTarEntry(gunzipSync(buf), 'package/package.json');
    manifest = pj ? JSON.parse(pj.toString('utf8')) : null;
  } catch {
    manifest = null;
  }
  const entry = { key, sha1, integrity, manifest, mtime: st.mtime };
  meta.set(file, entry);
  return entry;
}

function versionsOf(name) {
  const dir = path.join(PKG_ROOT, name);
  if (!existsSync(dir)) return [];
  const re = new RegExp(`^${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-(.+)\\.tgz$`);
  return readdirSync(dir)
    .map((f) => {
      const m = re.exec(f);
      return m ? { version: m[1], file: path.join(dir, f) } : null;
    })
    .filter(Boolean);
}

// --- semver ordering for dist-tags.latest ------------------------------------

function cmpSemver(a, b) {
  const parse = (v) => {
    const [core, pre] = v.split('-', 2);
    return { nums: core.split('.').map((n) => Number(n) || 0), pre: pre ?? null };
  };
  const x = parse(a);
  const y = parse(b);
  for (let i = 0; i < 3; i++) {
    if ((x.nums[i] ?? 0) !== (y.nums[i] ?? 0)) return (x.nums[i] ?? 0) - (y.nums[i] ?? 0);
  }
  if (x.pre === y.pre) return 0;
  if (x.pre === null) return 1;
  if (y.pre === null) return -1;
  return x.pre < y.pre ? -1 : 1;
}

function packument(name) {
  const vs = versionsOf(name);
  if (vs.length === 0) return null;
  const full = `${SCOPE}/${name}`;
  const versions = {};
  const time = {};
  for (const { version, file } of vs) {
    const m = tarballMeta(file);
    if (!m.manifest || m.manifest.version !== version || m.manifest.name !== full) continue;
    versions[version] = {
      ...m.manifest,
      _id: `${full}@${version}`,
      dist: {
        tarball: `${GH_DOWNLOAD}/${full}/${version}/${m.sha1}`,
        shasum: m.sha1,
        integrity: m.integrity,
      },
    };
    time[version] = m.mtime.toISOString();
  }
  const sorted = Object.keys(versions).sort(cmpSemver);
  if (sorted.length === 0) return null;
  const stable = sorted.filter((v) => !v.includes('-'));
  return {
    _id: full,
    name: full,
    'dist-tags': { latest: (stable.length ? stable : sorted).at(-1) },
    versions,
    time,
  };
}

// --- http --------------------------------------------------------------------

function send(res, status, body, type = 'application/json') {
  const data = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(status, { 'content-type': type, 'content-length': Buffer.byteLength(data) });
  res.end(data);
}

function sendTarball(res, file, method) {
  const st = statSync(file);
  res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': st.size });
  if (method === 'HEAD') return res.end();
  createReadStream(file).pipe(res);
}

const NAME = '([a-z0-9][a-z0-9._-]*)';
const ROUTES = {
  // GitHub Packages' download form, which is what lockfiles carry.
  download: new RegExp(`^/download/${SCOPE}/${NAME}/([^/]+)/([0-9a-f]{40})$`),
  // The conventional registry form.
  tarball: new RegExp(`^/${SCOPE}/${NAME}/-/${NAME}-([^/]+)\\.tgz$`),
  packument: new RegExp(`^/${SCOPE}(?:%2[fF]|/)${NAME}$`),
};

export function handle(req, res) {
  const url = new URL(req.url, 'http://local');
  const p = decodeURIComponent(url.pathname).replace(/\/+$/, '') || '/';
  const pEncoded = url.pathname.replace(/\/+$/, '');

  if (p === '/-/ping') return send(res, 200, {});
  if (p === '/-/gmi-registry/health') {
    return send(res, 200, { ok: true, store: STORE, packages: existsSync(PKG_ROOT) ? readdirSync(PKG_ROOT).length : 0 });
  }

  let m = ROUTES.download.exec(p);
  if (m) {
    const [, name, version, sha1] = m;
    const file = path.join(PKG_ROOT, name, `${name}-${version}.tgz`);
    if (!existsSync(file)) return send(res, 404, { error: `${SCOPE}/${name}@${version} is not in the degraded mirror` });
    const got = tarballMeta(file).sha1;
    if (got !== sha1) {
      return send(res, 404, {
        error: `${SCOPE}/${name}@${version}: the mirror holds sha1 ${got}, the request asks for ${sha1}. ` +
          'The mirrored tarball is not the one this lockfile pinned.',
      });
    }
    return sendTarball(res, file, req.method);
  }

  m = ROUTES.tarball.exec(p);
  if (m && m[1] === m[2]) {
    const file = path.join(PKG_ROOT, m[1], `${m[1]}-${m[3]}.tgz`);
    if (!existsSync(file)) return send(res, 404, { error: 'not found' });
    return sendTarball(res, file, req.method);
  }

  m = ROUTES.packument.exec(p) || ROUTES.packument.exec(pEncoded);
  if (m && (req.method === 'GET' || req.method === 'HEAD')) {
    const doc = packument(m[1]);
    if (!doc) return send(res, 404, { error: `${SCOPE}/${m[1]} is not in the degraded mirror` });
    return send(res, 200, doc);
  }

  if (p.startsWith(`/${SCOPE}`) || p.startsWith('/download/')) {
    return send(res, 404, { error: `not served by the degraded mirror: ${p}` });
  }

  res.writeHead(307, { location: `${UPSTREAM}${req.url}` });
  return res.end();
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  createServer(handle).listen(PORT, HOST, () => {
    console.log(`gmi-registry: ${HOST}:${PORT} store=${STORE}`);
  });
}
