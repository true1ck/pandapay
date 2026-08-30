const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { collect } = require('../scripts/collect_card_pipeline');
const {
  deriveCardEconomics,
  extractVerifiedNetworkVariants,
  hasExplicitNoRewardProgram,
  IMPORT_TRANSFORM_VERSION,
  importCapRules,
  importNetworkVariants,
  mapCategory,
  MIN_TXN_KEYS,
  missingSections,
  parseArgs,
  resolveNetwork,
  sanityCheck,
  shadowingZeroRateRules,
  sourceHash,
  unmappedNarrowing,
  upsertCardProduct,
  usableMerchantPattern,
} = require('../scripts/import_card_pipeline');
const {
  parseArgs: parsePublishArgs,
  uniqueRecords,
} = require('../scripts/publish_card_pipeline');

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

test('import CLI accepts repeatable slug filters', () => {
  const args = parseArgs([
    '--input', '/tmp/cards.json',
    '--slug', 'card-one',
    '--slug', 'card-two',
    '--dry-run',
  ]);
  assert.deepEqual(args.slugs, ['card-one', 'card-two']);
  assert.equal(args.dryRun, true);
});

test('publication CLI is dry-run capable and keeps one exact input file', () => {
  assert.deepEqual(
    parsePublishArgs(['--input', '/tmp/cards.json', '--admin-id', 'admin-id', '--dry-run']),
    {
      input: '/tmp/cards.json',
      adminId: 'admin-id',
      reportDir: null,
      dryRun: true,
    }
  );
});

test('publication rejects duplicate or missing slugs before connecting', () => {
  assert.throws(() => uniqueRecords([{}]), /card_product\.slug/);
  assert.throws(
    () => uniqueRecords([
      { card_product: { slug: 'same-card' } },
      { card_product: { slug: 'same-card' } },
    ]),
    /Duplicate input slug/
  );
  assert.equal(uniqueRecords([{ card_product: { slug: 'one-card' } }]).length, 1);
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

// ───────────────────────────────────────────────────────────────────────────
// Regressions for three defects found by running the importer against a real
// 148-record CardPipeline collection and then scoring the result with the
// actual RecommendationEngine.
// ───────────────────────────────────────────────────────────────────────────

test('a card naming several networks resolves to unknown, not to the first one listed', () => {
  // "Visa,Mastercard,RuPay" is a correct reading of a genuinely multi-network
  // product. Picking Visa would render a definite, wrong logo; 'unknown'
  // renders none and, per migration 0042, blocks publishing until a human
  // resolves it.
  for (const raw of ['Visa,Mastercard,RuPay', 'American Express / Mastercard', 'Visa / RuPay']) {
    const r = resolveNetwork(raw);
    assert.equal(r.network, 'unknown');
    assert.equal(r.ambiguous, true);
    assert.ok(r.candidates.length > 1, `${raw} should list its candidates`);
  }
});

test('a missing network resolves to unknown rather than rejecting the card', () => {
  for (const raw of [null, 'N/A', 'null', 'multi_network']) {
    assert.equal(resolveNetwork(raw).network, 'unknown');
  }
  // Real single networks still resolve exactly, including spacing variants.
  assert.equal(resolveNetwork('RuPay').network, 'rupay');
  assert.equal(resolveNetwork('Master Card').network, 'mastercard');
  assert.equal(resolveNetwork('Diners Club').network, 'diners');
});

test('verified network research becomes typed variant rows, but one unverified candidate does not', async () => {
  const record = {
    additional_data: { items: [{
      key: 'verified_network_research',
      value: {
        product_status: 'active',
        candidates: [
          { network: 'Visa', network_tier: 'visa_signature', source_url: 'https://issuer.example/card' },
          { network: 'RuPay', network_tier: 'rupay_select', source_url: 'https://issuer.example/card' },
        ],
      },
    }] },
  };
  assert.deepEqual(
    extractVerifiedNetworkVariants(record).map((v) => [v.network, v.networkTier]),
    [['visa', 'visa_signature'], ['rupay', 'rupay_select']]
  );

  const queries = [];
  const client = { async query(sql, params) { queries.push({ sql, params }); return { rows: [] }; } };
  const r = { networkVariantsImported: 0 };
  await importNetworkVariants(client, 'card-id', record, r);
  assert.equal(queries.length, 2);
  assert.equal(r.networkVariantsImported, 2);

  record.additional_data.items[0].value.candidates.pop();
  assert.deepEqual(extractVerifiedNetworkVariants(record), []);
});

test('official compact and rupee-sign card-name stylings pass the identity guard', () => {
  const base = {
    card_product: { issuer_slug: 'issuer', network: 'visa', card_type: 'credit' },
    reward_rules: [{ id: 'base' }],
    accrual_engine: {},
  };
  const reportShape = () => ({ incompleteRecords: [], unresolvedNetworks: [], networkVariantCards: [] });

  assert.equal(sanityCheck(
    { ...base, card_product: { ...base.card_product, slug: 'dream', name: 'Kotak811 #DreamDifferent Credit Card' } },
    { id: 'dream-id', card_name: 'Dream Different Credit Card' },
    reportShape()
  ), null);
  assert.equal(sanityCheck(
    { ...base, card_product: { ...base.card_product, slug: 'earn', name: 'FIRST EA₹N' } },
    { id: 'earn-id', card_name: 'EARN' },
    reportShape()
  ), null);
});

test('an explicit no-rewards product imports as a valid 0% card', () => {
  const record = {
    card_product: {
      slug: 'no-rewards-prepaid',
      name: 'No Rewards Prepaid Card',
      issuer_slug: 'example-bank',
      network: 'visa',
      card_type: 'prepaid',
    },
    reward_rules: [],
    accrual_engine: {
      base_points_per_block: 'N/A',
      base_cashback_percent: 'N/A',
      effective_base_return_percent: 0,
    },
  };
  const indexEntry = { card_name: record.card_product.name };
  const r = { incompleteRecords: [], unresolvedNetworks: [] };

  assert.equal(hasExplicitNoRewardProgram(record), true);
  assert.equal(sanityCheck(record, indexEntry, r), null);

  const unverified = structuredClone(record);
  unverified.accrual_engine.base_points_per_block = null;
  assert.equal(hasExplicitNoRewardProgram(unverified), false);
  assert.match(sanityCheck(unverified, indexEntry, { incompleteRecords: [], unresolvedNetworks: [] }), /no reward_rules/);
});

test('issuer-audited no-base-program evidence admits a null-rate 0% card, but generic nulls still fail', () => {
  const record = {
    card_product: {
      slug: 'benefit-only-card', name: 'Benefit Only Card', issuer_slug: 'issuer',
      network: 'visa', data_source_tier: 'issuer_mitc_plus_manual_audit',
    },
    reward_rules: [],
    accrual_engine: {
      base_points_per_block: null,
      base_cashback_percent: null,
      effective_base_return_percent: 0,
    },
    additional_data: { items: [{
      key: 'reward_accrual_discontinuation',
      value: 'Automatic base incentive accrual was discontinued.',
    }] },
  };
  assert.equal(hasExplicitNoRewardProgram(record), true);
  const r = { incompleteRecords: [], unresolvedNetworks: [], networkVariantCards: [] };
  assert.equal(sanityCheck(record, { card_name: record.card_product.name }, r), null);

  delete record.additional_data.items[0];
  assert.equal(hasExplicitNoRewardProgram(record), false);
});

test('minimum_transaction_value_inr is recognised as a transaction floor', () => {
  // This exact spelling was missing, so IndiGo 6E Rewards' "no points below
  // ₹100" imported as an unconditional zero-rate rule and the card scored
  // ₹0 at every amount.
  assert.ok(MIN_TXN_KEYS.includes('minimum_transaction_value_inr'));
});

test('a zero-rate rule narrowed by channel_type is unenforceable, a blanket one is not', () => {
  // HDFC Infinia: "education via a third-party app earns nothing" (priority 2)
  // vs "education paid direct earns 5 points" (priority 10). ruleApplies()
  // cannot see channel_type, so both match and the zero always wins.
  const narrowed = unmappedNarrowing(
    { channel_type: 'third_party_aggregator' },
    { aggregators: ['CRED'] },
    null
  );
  assert.ok(narrowed.some((r) => r.includes('channel_type')));

  // A genuine card-wide exclusion carries no narrowing and must be KEPT —
  // dropping it would hand back rewards the issuer does not pay.
  assert.deepEqual(
    unmappedNarrowing({ channel_type: 'all' }, { description: 'Rent never earns.' }, null),
    []
  );
});

test('a transaction floor on a zero-rate rule counts as unmappable, because it inverts', () => {
  // The source means "earns nothing BELOW ₹100". reward_rules.min_txn_inr
  // means "applies AT OR ABOVE ₹100" — storing it would zero out every spend
  // above the floor instead of below it.
  const reasons = unmappedNarrowing(
    { channel_type: 'all' },
    { minimum_transaction_value_inr: 100 },
    null
  );
  assert.equal(reasons.length, 1);
  assert.match(reasons[0], /minimum_transaction_value_inr/);
});

test('prose is not stored as a merchant pattern', () => {
  // merchant_pattern is matched as a substring of a real merchant name, so
  // "Eligible non-Shoppers Stop spends" can never match anything and would
  // silently switch the rule off.
  const report = { unusableMerchantPatterns: [] };
  assert.equal(
    usableMerchantPattern('Eligible non-Shoppers Stop spends', 'card-1', { id: 'r1' }, report),
    null
  );
  assert.equal(report.unusableMerchantPatterns.length, 1);

  // A real merchant name still passes through untouched.
  assert.equal(usableMerchantPattern('Shoppers Stop', 'card-1', { id: 'r2' }, report), 'Shoppers Stop');
  assert.equal(report.unusableMerchantPatterns.length, 1);
});

test('a standalone exclusion is kept; only one that shadows a real rate is dropped', () => {
  // The distinction that matters. An MCC list on a zero-rate rule usually
  // just enumerates the category the rule already targets — redundant, not
  // narrowing — and the rule is the card's genuine exclusion. Gating the drop
  // on narrowing alone removed 537 such rules from a real collection and
  // would have made cards promise rewards their issuers do not pay.
  const rentExclusion = { rate: 0, categoryId: 'rent', rail: null, priority: 1 };
  const baseEarn = { rate: 1, categoryId: null, rail: null, priority: 100 };
  rentExclusion.source = rentExclusion;
  baseEarn.source = baseEarn;
  assert.equal(
    shadowingZeroRateRules([rentExclusion, baseEarn]).size,
    0,
    'a rent exclusion does not collide with an all-spends rule',
  );

  // Same category and rail, zero sorts first: this is the defect.
  const eduZero = { rate: 0, categoryId: 'education', rail: 'online', priority: 2 };
  const eduEarn = { rate: 5, categoryId: 'education', rail: 'online', priority: 10 };
  eduZero.source = eduZero;
  eduEarn.source = eduEarn;
  const shadowing = shadowingZeroRateRules([eduZero, eduEarn]);
  assert.equal(shadowing.size, 1);
  assert.ok(shadowing.has(eduZero), 'the zero-rate rule is the one that shadows');
});

test('a truncated extraction is flagged, not mistaken for a card with no benefits', () => {
  // One real record (hdfc-diners-club-privilege) stopped after 8 of 17
  // sections. It imports fine — its reward rules are real — but the missing
  // sections become blanks in Postgres, and a blank fees_and_surcharges is
  // indistinguishable from "this card has no fees" to whoever reviews it.
  const truncated = {
    card_product: {}, accrual_engine: {}, reward_rules: [], cap_rules: [],
  };
  const gaps = missingSections(truncated);
  assert.ok(gaps.includes('fees_and_surcharges'));
  assert.ok(gaps.includes('lifestyle_and_network_benefits'));
  assert.ok(gaps.includes('redemption_matrix'));

  // A complete record reports nothing.
  const complete = Object.fromEntries(
    ['card_product', 'accrual_engine', 'reward_rules', 'cap_rules',
     'fees_and_surcharges', 'statement_and_late_fees', 'fee_waiver_and_milestones',
     'lifestyle_and_network_benefits', 'insurance_and_protection',
     'addon_card_rules', 'redemption_matrix'].map((k) => [k, {}])
  );
  assert.deepEqual(missingSections(complete), []);
});

test('network arrives as an array on at least one real card and still resolves', () => {
  // hdfc-freedom emits ["Visa","Mastercard","RuPay"] rather than a string.
  const r = resolveNetwork(['Visa', 'Mastercard', 'RuPay']);
  assert.equal(r.network, 'unknown');
  assert.deepEqual(r.candidates, ['visa', 'mastercard', 'rupay']);
  // A single-element array is not ambiguous and resolves normally.
  assert.equal(resolveNetwork(['Visa']).network, 'visa');
});
