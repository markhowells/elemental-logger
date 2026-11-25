#!/usr/bin/env node
'use strict';
/**
 * merge-settings: apply the MANAGED keys of a rendered settings file onto the
 * live SignalK settings.json, leaving every other key untouched.
 *
 * SignalK rewrites settings.json at runtime (interfaces, resourcesApi,
 * courseApi, UI changes), so the file cannot simply be overwritten.
 *
 * Usage: merge-settings <managed.json> <live.json>
 *
 * - live.json missing -> it is created as a copy of managed.json.
 * - Managed keys (dotted paths) are set from managed.json.
 * - A managed key absent from managed.json is REMOVED from live.json
 *   (e.g. security.allow_readonly), so the live file cannot keep a stale value.
 * - Prints one line per changed key; exits 0 on success.
 */
const fs = require('fs');

const MANAGED = [
  'vessel.name',
  'vessel.mmsi',
  'pipedProviders',
  'port',
  'sslport',
  'security.strategy',
  'security.allow_readonly',
];

function get(obj, path) {
  return path.split('.').reduce((o, k) => (o && typeof o === 'object' ? o[k] : undefined), obj);
}

function set(obj, path, value) {
  const keys = path.split('.');
  const last = keys.pop();
  let o = obj;
  for (const k of keys) {
    if (typeof o[k] !== 'object' || o[k] === null) o[k] = {};
    o = o[k];
  }
  o[last] = value;
}

function del(obj, path) {
  const keys = path.split('.');
  const last = keys.pop();
  let o = obj;
  for (const k of keys) {
    if (!o || typeof o[k] !== 'object') return;
    o = o[k];
  }
  delete o[last];
}

const [managedPath, livePath] = process.argv.slice(2);
if (!managedPath || !livePath) {
  console.error('usage: merge-settings <managed.json> <live.json>');
  process.exit(2);
}

const managed = JSON.parse(fs.readFileSync(managedPath, 'utf8'));

if (!fs.existsSync(livePath)) {
  fs.writeFileSync(livePath, JSON.stringify(managed, null, 2) + '\n');
  console.log('settings: created from managed template');
  process.exit(0);
}

const live = JSON.parse(fs.readFileSync(livePath, 'utf8'));
let changed = 0;

for (const path of MANAGED) {
  const want = get(managed, path);
  const have = get(live, path);
  if (want === undefined) {
    if (have !== undefined) {
      del(live, path);
      console.log(`settings: removed ${path}`);
      changed++;
    }
  } else if (JSON.stringify(want) !== JSON.stringify(have)) {
    set(live, path, want);
    console.log(`settings: set ${path}`);
    changed++;
  }
}

if (changed) {
  fs.writeFileSync(livePath + '.tmp', JSON.stringify(live, null, 2) + '\n');
  fs.renameSync(livePath + '.tmp', livePath);
} else {
  console.log('settings: managed keys already in sync');
}
