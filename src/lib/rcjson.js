#!/usr/bin/env node
// rcjson.js - safe edits to Claude config JSON files. Preserves every unknown key.
//   node rcjson.js trust   --file <.claude.json> --path "D:/EW/foo"
//   node rcjson.js untrust --file <.claude.json> --path "D:/EW/foo"
//   node rcjson.js has-trust --file <.claude.json> --path "D:/EW/foo"
'use strict';
const fs = require('fs');

function arg(name) {
  const i = process.argv.indexOf('--' + name);
  return i > 0 ? process.argv[i + 1] : undefined;
}
function sleep(ms) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }

function readJson(file) {
  if (!fs.existsSync(file)) return {};
  let lastErr;
  for (let i = 0; i < 3; i++) {
    try {
      let t = fs.readFileSync(file, 'utf8');
      if (t.charCodeAt(0) === 0xfeff) t = t.slice(1);
      if (!t.trim()) return {};
      return JSON.parse(t);
    } catch (e) { lastErr = e; sleep(200); }
  }
  throw new Error('cannot parse ' + file + ': ' + lastErr.message);
}

function writeJson(file, obj) {
  const tmp = file + '.rc-tmp-' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), 'utf8');
  for (let i = 0; i < 6; i++) {
    try { fs.renameSync(tmp, file); return; } catch (e) {
      if (i === 5) { try { fs.unlinkSync(tmp); } catch (_) {} throw e; }
      sleep(150 * (i + 1));
    }
  }
}

function findKey(projects, p) {
  const lower = p.toLowerCase();
  return Object.keys(projects).find(k => k.toLowerCase() === lower);
}

const cmd = process.argv[2];
const file = arg('file');
const p = arg('path');
try {
  if (!file || !p) throw new Error('usage: rcjson.js trust|untrust|has-trust --file F --path P');
  if (cmd === 'has-trust') {
    const j = readJson(file);
    const k = j.projects ? findKey(j.projects, p) : undefined;
    process.stdout.write(k && j.projects[k].hasTrustDialogAccepted ? 'yes' : 'no');
    process.exit(0);
  }
  for (let attempt = 0; attempt < 3; attempt++) {
    const j = readJson(file);
    if (typeof j !== 'object' || Array.isArray(j)) throw new Error('unexpected JSON root in ' + file);
    if (!j.projects || typeof j.projects !== 'object') j.projects = {};
    const k = findKey(j.projects, p);
    let pre = false;
    if (cmd === 'trust') {
      if (k) { pre = !!j.projects[k].hasTrustDialogAccepted; if (pre) { process.stdout.write('ok preExisting=true'); process.exit(0); } j.projects[k].hasTrustDialogAccepted = true; }
      else j.projects[p] = { allowedTools: [], hasTrustDialogAccepted: true };
    } else if (cmd === 'untrust') {
      if (!k) { process.stdout.write('ok absent'); process.exit(0); }
      delete j.projects[k].hasTrustDialogAccepted;
    } else throw new Error('unknown command ' + cmd);
    writeJson(file, j);
    sleep(300);
    const v = readJson(file);
    const k2 = v.projects ? findKey(v.projects, p) : undefined;
    const ok = cmd === 'trust' ? (k2 && v.projects[k2].hasTrustDialogAccepted === true) : !(k2 && v.projects[k2].hasTrustDialogAccepted);
    if (ok) { process.stdout.write('ok preExisting=' + pre); process.exit(0); }
  }
  throw new Error('value did not persist (file rewritten concurrently)');
} catch (e) {
  process.stderr.write(String(e.message || e));
  process.exit(5);
}
