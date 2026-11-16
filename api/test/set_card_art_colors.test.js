'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { parseColorMap, setOne } = require('../scripts/set_card_art_colors');

test('parseColorMap upper-cases valid colours and keeps their slugs', () => {
  const { colors, errors } = parseColorMap({ 'sbi-aurum': '#231f20', 'axis-atlas': ' #0a1b2c ' });
  assert.deepEqual(errors, []);
  assert.equal(colors.get('sbi-aurum'), '#231F20');
  assert.equal(colors.get('axis-atlas'), '#0A1B2C');
});

test('parseColorMap rejects shorthand, names, rgb() and bad slugs', () => {
  const { colors, errors } = parseColorMap({
    ok: '#112233',
    short: '#123',
    named: 'red',
    rgb: 'rgb(1,2,3)',
    'Bad Slug': '#112233',
    empty: '',
  });
  assert.deepEqual([...colors.keys()], ['ok']);
  assert.equal(errors.length, 5);
});

test('parseColorMap rejects a non-object input', () => {
  assert.equal(parseColorMap([]).errors.length, 1);
  assert.equal(parseColorMap(null).errors.length, 1);
});

function fakeClient(row) {
  const calls = [];
  return {
    calls,
    async query(sql, params) {
      calls.push({ sql, params });
      if (/^\s*SELECT/i.test(sql)) return { rows: row ? [row] : [] };
      return { rows: [] };
    },
  };
}

test('setOne reports a missing slug without writing', async () => {
  const client = fakeClient(null);
  const result = await setOne(client, 'admin-1', 'nope', '#112233');
  assert.equal(result.action, 'missing');
  assert.equal(client.calls.length, 1);
});

test('setOne leaves an identical colour alone', async () => {
  const client = fakeClient({ id: 'c1', art_primary_color: '#112233' });
  const result = await setOne(client, 'admin-1', 'x', '#112233');
  assert.equal(result.action, 'unchanged');
  assert.equal(client.calls.length, 1);
});

test('setOne updates the colour, bumps data_version and writes an audit row', async () => {
  const client = fakeClient({ id: 'c1', art_primary_color: null });
  const result = await setOne(client, 'admin-1', 'x', '#112233');
  assert.equal(result.action, 'updated');
  const update = client.calls.find((c) => /UPDATE card_products/.test(c.sql));
  assert.match(update.sql, /data_version = data_version \+ 1/);
  assert.deepEqual(update.params, ['c1', '#112233']);
  const audit = client.calls.find((c) => /admin_audit_log/.test(c.sql));
  assert.equal(audit.params[0], 'admin-1');
  assert.equal(JSON.parse(audit.params[3]).art_primary_color, '#112233');
});

test('setOne in dry-run mode throws the rollback marker carrying the result', async () => {
  const client = fakeClient({ id: 'c1', art_primary_color: '#000000' });
  await assert.rejects(
    () => setOne(client, 'admin-1', 'x', '#112233', { dryRun: true }),
    (error) => error.message === '__DRY_RUN_ROLLBACK__' && error.result.action === 'updated'
  );
});
