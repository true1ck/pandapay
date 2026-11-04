const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const {
  normalize,
  loadDirectory,
  resolveMerchant,
  ancestors,
} = require('../src/merchant_directory');

/**
 * Engine v2 (plan C3) and the merchant directory resolver (plan C5).
 *
 * The scenario files in db/fixtures/reward_v2_scenarios/ are the contract
 * the Dart engine (packages/pandapay_domain) is held to as well; this file
 * loads every one of them. The unit tests below pin the JS-side details the
 * scenarios can't reach (resolver tie-breaks, legacy cap conversion, the v1
 * delegation switch).
 */

const FIXTURES = path.join(__dirname, '..', '..', 'db', 'fixtures');

// ---------------------------------------------------------------------------
// Merchant directory (C5)
// ---------------------------------------------------------------------------

const DIR_JSON = {
  version: 1,
  merchants: [
    { slug: 'swiggy', name: 'Swiggy', parent_slug: null, aliases: ['swiggy', 'bundl technologies'], vpa_prefixes: ['swiggy'] },
    { slug: 'instamart', name: 'Swiggy Instamart', parent_slug: 'swiggy', aliases: ['swiggy instamart', 'instamart'], vpa_prefixes: [] },
    { slug: 'zomato', name: 'Zomato', parent_slug: null, aliases: ['zomato'], vpa_prefixes: ['zomato', 'zomatoorder'] },
    { slug: 'blinkit', name: 'Blinkit', parent_slug: 'zomato', aliases: ['blinkit', 'grofers'], vpa_prefixes: [] },
    { slug: 'beta_mart', name: 'Beta Mart', parent_slug: null, aliases: ['mart one'], vpa_prefixes: [] },
    { slug: 'alpha_mart', name: 'Alpha Mart', parent_slug: null, aliases: ['mart one'], vpa_prefixes: [] },
    { slug: 'retired', name: 'Retired Brand', parent_slug: null, aliases: ['retired brand'], vpa_prefixes: ['retired'], is_active: false },
  ],
  platforms: [{ slug: 'phonepe_app', name: 'PhonePe app', kind: 'payment_app', aliases: ['phonepe'] }],
};

test('normalize: lowercases, collapses non-alphanumeric runs to one space, trims', () => {
  assert.strictEqual(normalize('  BUNDL-Technologies*Pvt.  Ltd '), 'bundl technologies pvt ltd');
  assert.strictEqual(normalize('Swiggy__Instamart'), 'swiggy instamart');
  assert.strictEqual(normalize(null), '');
  assert.strictEqual(normalize(''), '');
});

test('resolveMerchant: an alias matches on word boundaries only', () => {
  const dir = loadDirectory(DIR_JSON);
  assert.deepStrictEqual(resolveMerchant(dir, 'BUNDL TECHNOLOGIES BLR', null)?.slug, 'swiggy');
  assert.strictEqual(resolveMerchant(dir, 'Swiggywala Store', null), null);
  assert.strictEqual(resolveMerchant(dir, 'myswiggy', null), null);
  assert.strictEqual(resolveMerchant(dir, 'POS*SWIGGY*ORDER', null)?.slug, 'swiggy');
});

test('resolveMerchant: the longest matching alias wins', () => {
  const dir = loadDirectory(DIR_JSON);
  const r = resolveMerchant(dir, 'SWIGGY INSTAMART BANGALORE', null);
  assert.strictEqual(r.slug, 'instamart');
  assert.strictEqual(r.via, 'alias');
});

test('resolveMerchant: equal-length aliases tie-break to the slug that sorts first', () => {
  const dir = loadDirectory(DIR_JSON);
  assert.strictEqual(resolveMerchant(dir, 'MART ONE STORE', null).slug, 'alpha_mart');
});

test('resolveMerchant: a VPA prefix match wins over an alias in the name', () => {
  const dir = loadDirectory(DIR_JSON);
  const r = resolveMerchant(dir, 'Swiggy', 'zomato.order@okaxis');
  assert.strictEqual(r.slug, 'zomato');
  assert.strictEqual(r.via, 'vpa');
  // "starts with": the normalized VPA user part is "zomatoorder pay".
  assert.strictEqual(resolveMerchant(dir, null, 'ZomatoOrder.pay@ybl').slug, 'zomato');
});

test('resolveMerchant: a VPA that matches nothing falls back to the alias', () => {
  const dir = loadDirectory(DIR_JSON);
  const r = resolveMerchant(dir, 'Blinkit Commerce', 'someone@okhdfc');
  assert.strictEqual(r.slug, 'blinkit');
  assert.strictEqual(r.via, 'alias');
});

test('resolveMerchant: inactive merchants are never resolved', () => {
  const dir = loadDirectory(DIR_JSON);
  assert.strictEqual(resolveMerchant(dir, 'Retired Brand', null), null);
  assert.strictEqual(resolveMerchant(dir, null, 'retired@upi'), null);
});

test('resolveMerchant: no name and no VPA, or no directory, resolves to null', () => {
  const dir = loadDirectory(DIR_JSON);
  assert.strictEqual(resolveMerchant(dir, null, null), null);
  assert.strictEqual(resolveMerchant(dir, '   ', ''), null);
  assert.strictEqual(resolveMerchant(null, 'Swiggy', null), null);
});

test('ancestors: follows parent_slug, excludes the slug itself', () => {
  const dir = loadDirectory(DIR_JSON);
  assert.deepStrictEqual(ancestors(dir, 'instamart'), ['swiggy']);
  assert.deepStrictEqual(ancestors(dir, 'swiggy'), []);
  assert.deepStrictEqual(ancestors(dir, 'unknown_slug'), []);
  assert.deepStrictEqual(ancestors(null, 'instamart'), []);
});

test('ancestors: depth is limited to 5 and cycles are safe', () => {
  const chain = [];
  for (let i = 0; i < 8; i += 1) chain.push({ slug: `m${i}`, name: `M${i}`, parent_slug: i < 7 ? `m${i + 1}` : null, aliases: [] });
  const deep = loadDirectory({ merchants: chain, platforms: [] });
  assert.deepStrictEqual(ancestors(deep, 'm0'), ['m1', 'm2', 'm3', 'm4', 'm5']);

  const cyclic = loadDirectory({
    merchants: [
      { slug: 'a', name: 'A', parent_slug: 'b', aliases: [] },
      { slug: 'b', name: 'B', parent_slug: 'c', aliases: [] },
      { slug: 'c', name: 'C', parent_slug: 'a', aliases: [] },
    ],
    platforms: [],
  });
  assert.deepStrictEqual(ancestors(cyclic, 'a'), ['b', 'c']);
  const self = loadDirectory({ merchants: [{ slug: 's', name: 'S', parent_slug: 's', aliases: [] }], platforms: [] });
  assert.deepStrictEqual(ancestors(self, 's'), []);
});

test('loadDirectory: accepts an already-loaded directory and the checked-in fixture', () => {
  const dir = loadDirectory(DIR_JSON);
  assert.strictEqual(loadDirectory(dir), dir);
  const real = loadDirectory(JSON.parse(fs.readFileSync(path.join(FIXTURES, 'merchant_directory.json'), 'utf8')));
  assert.strictEqual(resolveMerchant(real, 'INSTAMART BLR', null).slug, 'instamart');
  assert.deepStrictEqual(ancestors(real, 'instamart'), ['swiggy']);
});
