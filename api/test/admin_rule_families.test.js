const test = require('node:test');
const assert = require('node:assert/strict');
const { validateField } = require('../src/admin_rule_families');

test('validateField: required field missing fails', () => {
  const err = validateField({ name: 'label', type: 'string', required: true }, undefined);
  assert.match(err, /label is required/);
});

test('validateField: optional field missing passes (null)', () => {
  const err = validateField({ name: 'notes', type: 'string' }, undefined);
  assert.equal(err, null);
});

test('validateField: string type rejects a number', () => {
  const err = validateField({ name: 'label', type: 'string' }, 5);
  assert.match(err, /must be a string/);
});

test('validateField: required string rejects empty/whitespace', () => {
  const err = validateField({ name: 'label', type: 'string', required: true }, '   ');
  assert.match(err, /must not be empty/);
});

test('validateField: number enforces min/max', () => {
  const spec = { name: 'capValue', type: 'number', min: 0, max: 100 };
  assert.match(validateField(spec, -1), /must be >= 0/);
  assert.match(validateField(spec, 101), /must be <= 100/);
  assert.equal(validateField(spec, 50), null);
});

test('validateField: number rejects NaN/non-finite', () => {
  const err = validateField({ name: 'rate', type: 'number' }, NaN);
  assert.match(err, /must be a number/);
});

test('validateField: integer rejects a float', () => {
  const err = validateField({ name: 'resetsOnDay', type: 'integer' }, 1.5);
  assert.match(err, /must be an integer/);
});

test('validateField: integer enforces min/max range (day-of-month)', () => {
  const spec = { name: 'resetsOnDay', type: 'integer', min: 1, max: 31 };
  assert.match(validateField(spec, 32), /must be <= 31/);
  assert.equal(validateField(spec, 15), null);
});

test('validateField: boolean rejects a truthy non-boolean', () => {
  const err = validateField({ name: 'isRepeatable', type: 'boolean' }, 1);
  assert.match(err, /must be a boolean/);
});

test('validateField: enum rejects a value outside the allowed set', () => {
  const spec = { name: 'period', type: 'enum', values: ['annual', 'lifetime'] };
  assert.match(validateField(spec, 'quarterly'), /must be one of annual\/lifetime/);
  assert.equal(validateField(spec, 'annual'), null);
});

test('validateField: jsonb rejects an array (must be a plain object)', () => {
  const err = validateField({ name: 'conditions', type: 'jsonb' }, [1, 2]);
  assert.match(err, /must be an object/);
});

test('validateField: jsonb accepts a plain object', () => {
  const err = validateField({ name: 'conditions', type: 'jsonb' }, { foo: 'bar' });
  assert.equal(err, null);
});
