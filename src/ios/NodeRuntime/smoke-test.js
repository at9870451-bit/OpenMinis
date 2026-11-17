'use strict';
// No network and no third-party packages. Used by the App and Linux CI.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
assert.equal(process.arch, 'arm64', 'Wrong runtime architecture');
assert.equal(process.platform, 'linux', 'This is a Linux guest runtime, not iOS native code');
const sample = Buffer.from('Amore offline Node runtime');
assert.deepEqual(zlib.gunzipSync(zlib.gzipSync(sample)), sample);
assert.equal(crypto.createHash('sha256').update('abc').digest('hex'),
  'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
assert.deepEqual(JSON.parse('{"ready":true}'), {ready: true});
console.log(JSON.stringify({ready: true, node: process.version, architecture: process.arch,
  json: true, crypto: true, zlib: true}));
