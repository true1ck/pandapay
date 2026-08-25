const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { collect } = require('../scripts/collect_card_pipeline');
const {
  deriveCardEconomics,
  IMPORT_TRANSFORM_VERSION,
  importCapRules,
  mapCategory,
  sourceHash,
  upsertCardProduct,
} = require('../scripts/import_card_pipeline');

function report() {
  return {
    unusualBlockSizes: {},
    warnings: [],
    unmappedCategories: {},
    skippedCategories: [],
  };
}

test('sourceHash ignores object key order but preserves array order', () => {
  const first = { card: { name: 'A', fees: { annual: 500, joining: 0 } }, rules: [1, 2] };
  const reordered = { rules: [1, 2], card: { fees: { joining: 0, annual: 500 }, name: 'A' } };
  const changed = { ...reordered, rules: [2, 1] };

  assert.equal(sourceHash(first), sourceHash(reordered));
  assert.notEqual(sourceHash(first), sourceHash(changed));
  assert.match(sourceHash(first), /^[0-9a-f]{64}$/);
});

test('deriveCardEconomics maps points, valuation, and base exclusions', () => {
  const result = deriveCardEconomics(
    {
      card_product: {
        point_value_inr_baseline: 0.25,
        point_value_baseline_basis: '4 points = ₹1',
      },
      accrual_engine: { base_points_per_block: 2, base_block_inr: 150 },
      reward_rules: [
        {
          category_id: 'all_retail',
          conditions: { excluded_categories: ['fuel', 'wallet_load', 'unknown_source_category'] },
        },
      ],
    },
    report()
  );

  assert.deepEqual(result, {
    baseRewardUnit: 'points_per_150',
    baseRewardRate: 2,
    pointValueInr: 0.25,
    pointValueBasis: '4 points = ₹1',
    excludedCategorySlugs: ['fuel', 'wallet'],
  });
});

test('deriveCardEconomics normalizes unusual point blocks without changing value', () => {
  const r = report();
  const result = deriveCardEconomics(
    {
      card_product: {},
      accrual_engine: { base_points_per_block: 5, base_block_inr: 500 },
      reward_rules: [],
    },
    r
  );

  assert.equal(result.baseRewardUnit, 'points_per_100');
  assert.equal(result.baseRewardRate, 1);
  assert.equal(r.unusualBlockSizes[500], 1);
});

test('unknown source categories are skipped rather than broadened to other', () => {
  const r = report();
  assert.deepEqual(mapCategory('flipkart_partner_only', r, 'rule x'), {
    skip: true,
    categoryId: null,
  });
  assert.equal(r.unmappedCategories.flipkart_partner_only, 1);
});

test('upsertCardProduct performs no writes when the source hash is unchanged', async () => {
  const queries = [];
  const client = {
    async query(sql, params) {
      queries.push({ sql, params });
      return {
        rows: [
          {
            id: 'card-id',
            status: 'published',
            import_source_hash: 'same-hash',
            import_transform_version: IMPORT_TRANSFORM_VERSION,
          },
        ],
      };
    },
  };

  const result = await upsertCardProduct(
    client,
    'issuer-id',
    { slug: 'test-card', name: 'Test Card', network: 'visa', card_type: 'credit' },
    {},
    {
      baseRewardUnit: 'cashback_percent',
      baseRewardRate: 1,
      pointValueInr: null,
      pointValueBasis: null,
      excludedCategorySlugs: [],
    },
    false,
    'same-hash',
    'run-1'
  );

  assert.equal(result.action, 'unchanged');
  assert.equal(queries.length, 1);
  assert.match(queries[0].sql, /^SELECT id, status, import_source_hash/);
});

test('legacy cap_reference links a points cap to its reward rule and converts it to rupees', async () => {
  const queries = [];
  const client = {
    async query(sql, params) {
      queries.push({ sql, params });
      return { rows: [] };
    },
  };
  const r = {
    skippedCapRules: [],
    aggregateScopeCaps: [],
    unmappedPeriods: {},
    unusualBlockSizes: {},
    warnings: [],
  };

  await importCapRules(
    client,
    'card-id',
    [
      {
        id: 'monthly-points-cap',
        category_id: 'online',
        metric: 'total_reward_points',
        period: 'calendar_month',
        limit_value: 2000,
        post_limit_behavior: { action: 'downgrade_to_base_rate', points_per_block: 2 },
      },
    ],
    {},
    { 'monthly-points-cap': ['reward-rule-uuid'] },
    {},
    0.25,
    100,
    r
  );

  assert.equal(queries.length, 1);
  assert.equal(queries[0].params[1], 'reward-rule-uuid');
  assert.equal(queries[0].params[6], 500);
  assert.equal(queries[0].params[7], null);
  assert.equal(queries[0].params[8], null);
  assert.equal(r.aggregateScopeCaps.length, 0);
});

test('collector follows the checklist-selected run and preserves expected name in its index', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pandapay-card-collector-'));
  const out = path.join(root, 'out');
  try {
    const itemDir = path.join(root, 'results', 'run-selected', 'items');
    fs.mkdirSync(path.join(root, 'data'), { recursive: true });
    fs.mkdirSync(itemDir, { recursive: true });
    fs.writeFileSync(
      path.join(root, 'data', 'checklist.json'),
      JSON.stringify({
        rows: [
          {
            id: 'expected-id',
            card_name: 'Expected Product Name',
            issuer: 'Example Bank',
            status: 'done',
            run_id: 'run-selected',
          },
        ],
      })
    );
    fs.writeFileSync(
      path.join(itemDir, 'expected-id.json'),
      JSON.stringify({
        id: 'expected-id',
        ok: true,
        final: { card_product: { slug: 'extracted-slug', name: 'Extracted Product Name' } },
      })
    );

    const result = collect({ pipeline: root, out, includeUnlisted: false });
    const records = JSON.parse(fs.readFileSync(result.collectedPath, 'utf8'));
    const index = JSON.parse(fs.readFileSync(result.indexPath, 'utf8'));

    assert.equal(records[0].card_product.slug, 'extracted-slug');
    assert.equal(index[0].card_name, 'Expected Product Name');
    assert.equal(index[0].runId, 'run-selected');
    assert.equal(result.report.collected, 1);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
