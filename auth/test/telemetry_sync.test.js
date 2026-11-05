'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// auth and api ship separate images, so each carries its own copy of the
// telemetry module. The copies must stay identical; api/test/telemetry.test.js
// covers the behaviour.
test('auth telemetry module is identical to the api copy', () => {
  const api = path.join(__dirname, '..', '..', 'api', 'src', 'telemetry.js');
  if (!fs.existsSync(api)) return;
  assert.equal(fs.readFileSync(path.join(__dirname, '..', 'src', 'telemetry.js'), 'utf8'), fs.readFileSync(api, 'utf8'));
});

test('auth observability exports telemetry that is off by default', () => {
  const { telemetry } = require('../src/observability');
  assert.equal(telemetry.reporter.enabled, false);
});
