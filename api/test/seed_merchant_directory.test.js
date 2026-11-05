'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const seed = require('../scripts/seed_merchant_directory');

const DIR = {
  version: 1,
  merchants: [
    { slug: 'instamart', name: 'Swiggy Instamart', parent_slug: 'swiggy', category_slug: 'groceries',
      aliases: ['instamart'], vpa_prefixes: [], mcc: [], notes: 'ignored' },
    { slug: 'swiggy', name: 'Swiggy', parent_slug: null, category_slug: 'dining',
      aliases: ['swiggy'], vpa_prefixes: ['swiggy'], mcc: ['5814'] },
  ],
  platforms: [
    { slug: 'phonepe_app', name: 'PhonePe app', kind: 'payment_app', issuer_slug: null, aliases: ['phonepe'], notes: '' },
  ],
};

// Minimal in-memory stand-in for the two tables, keyed on the seeder's own SQL.
function fakeClient() {
  const merchants = new Map();
  const platforms = new Map();
  const log = [];
  return {
    merchants, platforms, log,
    async query(sql, params) {
      const s = sql.trim();
      log.push(s.split(/\s+/)[0]);
      if (s.startsWith('SELECT slug, name, parent_slug')) return { rows: [...merchants.values()].map((r) => ({ ...r })) };
      if (s.startsWith('SELECT slug, name, kind')) return { rows: [...platforms.values()].map((r) => ({ ...r })) };
      if (s.startsWith('INSERT INTO merchant_brands')) {
        const [slug, name, parent_slug, category_slug, aliases, vpa_prefixes, mcc] = params;
        if (parent_slug && !merchants.has(parent_slug)) throw new Error('fk violation');
        merchants.set(slug, { slug, name, parent_slug, category_slug, aliases, vpa_prefixes, mcc, is_active: true });
      } else if (s.startsWith('INSERT INTO payment_platforms')) {
        const [slug, name, kind, issuer_slug, aliases, notes] = params;
        platforms.set(slug, { slug, name, kind, issuer_slug, aliases, notes, is_active: true });
      } else if (s.startsWith('UPDATE merchant_brands')) {
        for (const slug of params[0]) merchants.get(slug).is_active = false;
      } else if (s.startsWith('UPDATE payment_platforms')) {
        for (const slug of params[0]) platforms.get(slug).is_active = false;
      }
      return { rows: [] };
    },
  };
}

async function runWith(client, args, dir = DIR) {
  const file = path.join(require('node:os').tmpdir(), `dir-${process.pid}-${Math.random().toString(36).slice(2)}.json`);
  fs.writeFileSync(file, JSON.stringify(dir));
  try {
    return await seed.run([...args, '--file', file], { createClient: async () => client, log() {} });
  } finally { fs.unlinkSync(file); }
}

test('dry run reports the plan and writes nothing', async () => {
  const c = fakeClient();
  const plan = await runWith(c, ['--dry-run']);
  assert.equal(plan.merchants.insert.length, 2);
  assert.equal(plan.platforms.insert.length, 1);
  assert.equal(c.merchants.size, 0);
  assert.ok(!c.log.includes('BEGIN'));
});

test('apply inserts parents before children, and a second apply writes nothing', async () => {
  const c = fakeClient();
  await runWith(c, ['--apply']);
  assert.deepEqual([...c.merchants.keys()], ['swiggy', 'instamart']);
  assert.equal(c.merchants.get('instamart').parent_slug, 'swiggy');
  assert.equal(c.platforms.get('phonepe_app').notes, null);
  const writesBefore = c.log.filter((x) => x === 'INSERT').length;
  const plan = await runWith(c, ['--apply']);
  assert.equal(plan.merchants.unchanged, 2);
  assert.equal(plan.merchants.update.length + plan.merchants.insert.length, 0);
  assert.equal(plan.platforms.update.length + plan.platforms.insert.length, 0);
  assert.equal(c.log.filter((x) => x === 'INSERT').length, writesBefore);
});

test('changed fields are updated in place', async () => {
  const c = fakeClient();
  await runWith(c, ['--apply']);
  const changed = JSON.parse(JSON.stringify(DIR));
  changed.merchants[1].aliases.push('swiggy ltd');
  const plan = await runWith(c, ['--apply'], changed);
  assert.deepEqual(plan.merchants.update.map((m) => m.slug), ['swiggy']);
  assert.deepEqual(c.merchants.get('swiggy').aliases, ['swiggy', 'swiggy ltd']);
});

test('slugs missing from the file are kept unless --deactivate-missing', async () => {
  const c = fakeClient();
  await runWith(c, ['--apply']);
  const smaller = { ...DIR, merchants: [DIR.merchants[1]], platforms: [] };
  const plan = await runWith(c, ['--apply'], smaller);
  assert.deepEqual(plan.merchants.missing, ['instamart']);
  assert.equal(c.merchants.get('instamart').is_active, true);
  assert.equal(c.platforms.get('phonepe_app').is_active, true);
  await runWith(c, ['--apply', '--deactivate-missing'], smaller);
  assert.equal(c.merchants.get('instamart').is_active, false);
  assert.equal(c.merchants.get('swiggy').is_active, true);
  assert.equal(c.platforms.get('phonepe_app').is_active, false);
  assert.ok(c.merchants.has('instamart'), 'rows are never deleted');
});

test('a slug that returns to the file is reactivated', async () => {
  const c = fakeClient();
  await runWith(c, ['--apply']);
  c.merchants.get('swiggy').is_active = false;
  const plan = await runWith(c, ['--apply']);
  assert.deepEqual(plan.merchants.update.map((m) => m.slug), ['swiggy']);
  assert.equal(c.merchants.get('swiggy').is_active, true);
});

test('validation rejects bad slugs, duplicates, unknown parents, cycles and kinds', () => {
  const bad = (mut) => { const d = JSON.parse(JSON.stringify(DIR)); mut(d); return () => seed.parseDirectory(d); };
  assert.throws(bad((d) => { d.merchants[0].slug = 'Bad-Slug'; }), /invalid slug/);
  assert.throws(bad((d) => { d.merchants[0].slug = 'swiggy'; }), /duplicate/);
  assert.throws(bad((d) => { d.merchants[0].parent_slug = 'nope'; }), /not in the file/);
  assert.throws(bad((d) => { d.merchants[1].parent_slug = 'instamart'; }), /cycle/);
  assert.throws(bad((d) => { d.platforms[0].kind = 'bogus'; }), /unknown kind/);
  assert.throws(bad((d) => { d.version = 2; }), /version 1/);
});

test('arguments need exactly one of --dry-run / --apply', () => {
  assert.throws(() => seed.parseArgs([]), /exactly one/);
  assert.throws(() => seed.parseArgs(['--dry-run', '--apply']), /exactly one/);
  assert.throws(() => seed.parseArgs(['--wat']), /Unknown/);
  assert.equal(seed.parseArgs(['--apply', '--deactivate-missing']).deactivateMissing, true);
});

test('the committed fixture parses', () => {
  const doc = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../db/fixtures/merchant_directory.json'), 'utf8'));
  const dir = seed.parseDirectory(doc);
  assert.ok(dir.merchants.length > 0 && dir.platforms.length > 0);
});

test('a merchant with a "group" key parses and group is not passed to the upsert', async () => {
  const dir = JSON.parse(JSON.stringify(DIR));
  dir.merchants[1].group = 'zomato';
  const parsed = seed.parseDirectory(dir);
  assert.ok(parsed.merchants.every((m) => !('group' in m)));
  const calls = [];
  const c = fakeClient();
  const q = c.query.bind(c);
  c.query = async (sql, params) => { calls.push(params); return q(sql, params); };
  await runWith(c, ['--apply'], dir);
  assert.ok(calls.filter(Boolean).every((p) => !p.includes('zomato')));
});

test('a missing grandparent gives the "not in the file" error, not a TypeError', () => {
  const dir = JSON.parse(JSON.stringify(DIR));
  dir.merchants = [
    { slug: 'a', name: 'A', parent_slug: 'b' },
    { slug: 'b', name: 'B', parent_slug: 'ghost' },
  ];
  assert.throws(() => seed.parseDirectory(dir), /ghost is not in the file/);
});
