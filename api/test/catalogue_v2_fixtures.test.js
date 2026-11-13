// Loader v2 (plan C7) on real CardPipeline records (api/test/fixtures/cardpipeline).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const { transformCardRecordV2 } = require('../scripts/catalogue_v2/transform');
const { loadDirectory } = require('../scripts/catalogue_v2/directory');
const { applyOverrides, DEFAULT_OVERRIDES_DIR } = require('../scripts/catalogue_v2/overrides');
const { aggregateReport, renderMarkdown } = require('../scripts/catalogue_v2/coverage');
const { unwrapItem, loadDoneRecords } = require('../scripts/catalogue_v2/source');

const FIXTURES = path.join(__dirname, 'fixtures', 'cardpipeline');
const directory = loadDirectory();

function fixture(slug) {
  return JSON.parse(fs.readFileSync(path.join(FIXTURES, `${slug}.json`), 'utf8'));
}
function transform(slug, overrides = null) {
  const { record } = unwrapItem(fixture(slug));
  return transformCardRecordV2(record, { directory, overrides, sourceSlug: slug });
}
function rows(t, sourceId) {
  return t.rewardRules.filter((r) => r.source_local_id === sourceId);
}
function cap(t, key) {
  return t.capRules.find((c) => c.key === key);
}
function flagCodes(t) {
  return t.card.model_coverage.flags.map((f) => f.code);
}

test('fixture records unwrap from final, falling back to original', () => {
  assert.equal(unwrapItem({ ok: true, final: { a: 1 }, original: { a: 2 } }).record.a, 1);
  const fallback = unwrapItem({ ok: true, original: { a: 2 } });
  assert.equal(fallback.record.a, 2);
  assert.equal(fallback.from, 'original');
  assert.equal(unwrapItem({ ok: false }).record, null);
  assert.equal(unwrapItem({ card_product: { slug: 'x' } }).from, 'bare');
});

test('co-brand card (Swiggy HDFC): the swiggy_app token becomes a Swiggy merchant rule with its ₹249 floor', () => {
  const t = transform('swiggy-hdfc-bank-credit-card');
  const [swiggy] = rows(t, 'swiggy_10pct');
  assert.equal(swiggy.rule_role, 'earn');
  assert.deepEqual(swiggy.merchant_slugs, ['swiggy']);
  assert.equal(swiggy.merchant_pattern, 'swiggy');
  assert.equal(swiggy.min_txn_inr, 249);
  assert.equal(swiggy.rate, 10);
  assert.equal(swiggy.min_engine_version, 1);
  // The 5% online rule is narrowed by a merchant/MCC list we can't express: info, not widened.
  assert.equal(rows(t, 'online_5pct')[0].rule_role, 'info');
  // "Swiggy Liquor" / "Swiggy Minis" are their own directory brands now, so on
  // the RAW record (no override) their exclusions load as real exclusions. The
  // raw swiggy_app channel still expands to the whole Swiggy group, which is
  // broader than the issuer's text (it can only under-state); the committed
  // override narrows it with channel_type "all" (see the snapshot examples).
  for (const id of ['swiggy_liquor_exclusion', 'swiggy_minis_exclusion']) {
    const [row] = rows(t, id);
    assert.equal(row.rule_role, 'exclusion', id);
    assert.ok(row.merchant_slugs.includes(id.replace('_exclusion', '')), id);
  }
  // The spend-vs-cashback mix-up (R5) is flagged, not silently fixed.
  assert.ok(cap(t, 'swiggy_cashback_cap').flags.includes('suspect_cap_unit'));
  assert.equal(cap(t, 'swiggy_cashback_cap').cap_kind, 'eligible_spend');
  assert.equal(t.card.base_reward_unit, 'cashback_percent');
  assert.equal(t.card.model_status, 'partial');
});

test('co-brand card with the issuer-verified override: caps become ₹ cashback caps', () => {
  // Same paths and values WP6a uses for this card (C7.2).
  const overrides = {
    source_slug: 'swiggy-hdfc-bank-credit-card',
    changes: [
      ['swiggy_cashback_cap', 1500], ['online_5pct_cashback_cap', 1500], ['other_1pct_cashback_cap', 500],
    ].flatMap(([id, amount]) => [
      { path: `cap_rules[id=${id}].metric`, value: 'total_reward_points' },
      { path: `cap_rules[id=${id}].limit_value`, value: amount },
      { path: `cap_rules[id=${id}].limit_value_inr`, value: null },
    ]),
  };
  const t = transform('swiggy-hdfc-bank-credit-card', overrides);
  const swiggyCap = cap(t, 'swiggy_cashback_cap');
  assert.equal(swiggyCap.cap_kind, 'total_cashback');
  assert.equal(swiggyCap.cap_amount, 1500);
  assert.equal(swiggyCap.measure, 'reward_value');
  assert.equal(swiggyCap.cap_value, 1500);
  assert.equal(swiggyCap.post_cap_rate, 0);
  assert.deepEqual(swiggyCap.target_keys, ['swiggy_10pct']);
  assert.equal(swiggyCap.min_engine_version, 1);
  assert.ok(!swiggyCap.flags.includes('suspect_cap_unit'));
  assert.equal(t.card.model_coverage.overrides_applied.length, 9);
});

test('app-platform card (PhonePe SBI SELECT BLACK): platform parts, nested caps, MCC exclusions', () => {
  const t = transform('phonepe-sbi-select-black');
  const app = rows(t, 'phonepe-10x');
  assert.deepEqual(app.map((r) => r.category_slug).sort(), ['bills', 'insurance', 'travel']);
  assert.ok(app.every((r) => r.platform_slugs.join() === 'phonepe_app' && r.rate === 10 && r.min_engine_version === 2));
  assert.equal(rows(t, 'online-5x')[0].rail, 'online');
  assert.equal(rows(t, 'base-1x')[0].rule_role, 'base');
  assert.deepEqual(rows(t, 'phonepe-scanpay-1x').map((r) => [r.platform_slugs.join(), r.rail]), [['phonepe_app', 'upi_qr']]);
  // "UPI outside PhonePe" (D16): an exclusion on UPI with PhonePe as the exception.
  assert.deepEqual(rows(t, 'upi-outside-phonepe').map((r) => [r.rule_role, r.rail, r.except_platform_slugs.join()]),
    [['exclusion', 'upi_qr', 'phonepe_app']]);
  assert.deepEqual(rows(t, 'utilities-outside-phonepe-base').map((r) => [r.rule_role, r.except_platform_slugs.join(), r.min_engine_version]),
    [['earn', 'phonepe_app', 2]]);
  // Exclusions (D19c/D20a): v1-only category row + v2 category-and-MCC row + v2 MCC-only row.
  assert.deepEqual(rows(t, 'fuel-exclusion').map((r) => [r.category_slug, r.mcc_include.join(), r.min_engine_version, r.max_engine_version]),
    [['fuel', '', 1, 1], ['fuel', '5172,5541,5542,5983', 2, null], [null, '5172,5541,5542,5983', 2, null]]);
  // Nested caps: the insurance sub-cap targets only the insurance part and keeps its parent.
  const insurance = cap(t, 'phonepe-insurance-monthly');
  assert.equal(insurance.parent_key, 'phonepe-other-monthly');
  assert.deepEqual(insurance.target_keys, [app.find((r) => r.category_slug === 'insurance').key]);
  assert.equal(insurance.min_engine_version, 2, 'its target is a platform rule (D3)');
  assert.equal(cap(t, 'phonepe-other-monthly').cap_kind, 'bonus_points');
  assert.equal(cap(t, 'online-monthly').min_engine_version, 1);
  assert.equal(t.card.accrual_rounding, 'floor');
  assert.equal(t.card.points_expiry_months, 24);
});

test('app-platform card with its override: total caps, un-nested insurance cap', () => {
  const t = transform('phonepe-sbi-select-black', {
    changes: [
      { path: 'cap_rules[id=phonepe-other-monthly].metric', value: 'total_reward_points' },
      { path: 'cap_rules[id=phonepe-insurance-monthly].metric', value: 'total_reward_points' },
      { path: 'cap_rules[id=online-monthly].metric', value: 'total_reward_points' },
      { path: 'cap_rules[id=phonepe-insurance-monthly].parent_cap_id', value: null },
    ],
  });
  assert.equal(cap(t, 'phonepe-insurance-monthly').parent_key, null);
  assert.equal(cap(t, 'phonepe-insurance-monthly').cap_kind, 'total_points');
  assert.equal(cap(t, 'online-monthly').post_cap_rate, 0);
});

test('brand-portal card (Amex Platinum Travel): Reward Multiplier is a platform rule, not every spend', () => {
  const t = transform('american-express-platinum-travel-credit-card-india');
  const [rm] = rows(t, 'reward_multiplier_online_brands');
  assert.equal(rm.rule_role, 'earn');
  assert.deepEqual(rm.platform_slugs, ['amex_reward_multiplier']);
  assert.equal(rm.block_inr, 50);
  assert.equal(rm.rate, 3);
  assert.equal(rm.rail, null, 'a portal is online by definition; an online rail would miss unknown-rail spends');
  assert.ok(!rm.flags.includes('unrestricted_accelerator'));
  const [base] = rows(t, 'base_all_retail');
  assert.equal(base.rule_role, 'base');
  assert.equal(base.block_inr, 50);
  assert.equal(t.card.accrual_block_inr, 50);
  // Milestones on the card-membership year, rewards parsed, welcome window.
  const welcome = t.milestones.find((m) => m.key === 'welcome_15k_90d');
  assert.equal(welcome.window_days, 90);
  assert.equal(welcome.reward_points, 10000);
  const m4 = t.milestones.find((m) => m.key === 'milestone_4l');
  assert.deepEqual([m4.period, m4.anchor, m4.reward_kind, m4.reward_points], ['annual', 'card_anniversary', 'points', 10000]);
  // Redemption options by channel (R11).
  assert.ok(t.redemptionOptions.length >= 3);
  assert.ok(t.redemptionOptions.every((o) => o.value_per_point_inr > 0));
});

test('app-bonus card with an unknown cap (PNB Kiwi): missing cap value flagged; Kiwi Neon unlocks structured', () => {
  const t = transform('pnb-kiwi-credit-card');
  assert.deepEqual(rows(t, 'upi-scan-pay-kiwi').map((r) => [r.platform_slugs.join(), r.rail, r.rate]), [['kiwi_app', 'upi_qr', 6]]);
  assert.equal(t.capRules.length, 0);
  assert.ok(t.card.model_coverage.flags.some((f) => f.code === 'missing_cap_value' && f.source_local_id === 'monthly-kiwi-cap'));
  assert.equal(t.card.model_coverage.caps_total, 1);
  assert.equal(t.card.model_coverage.caps_enforced, 0);
  const lounge = t.unlockRules.filter((u) => u.benefit_key === 'kiwi-neon-lounge');
  assert.deepEqual(lounge.map((u) => u.spend_threshold_inr), [50000, 100000, 150000]);
  assert.ok(lounge.every((u) => u.unlocks_quota === 1 && u.kind === 'lounge_domestic'));
  // MCC-only exclusions with odd labels are v2 exclusions on their MCCs.
  const [agri] = rows(t, 'exclude-agricultural-services');
  assert.equal(agri.rule_role, 'exclusion');
  assert.ok(agri.mcc_include.includes('0763'));
  assert.equal(agri.min_engine_version, 2);
});

test('premium card with many caps (HDFC Infinia): "up to 10X" is info; redemption caps skipped; card-wide cap', () => {
  const t = transform('hdfc-infinia-metal');
  assert.equal(rows(t, 'smartbuy-up-to-10x')[0].rule_role, 'info');
  assert.ok(rows(t, 'smartbuy-up-to-10x')[0].info_reasons.includes('up_to_rate'));
  assert.equal(cap(t, 'statement-cycle-rp-cap').scope, 'card');
  assert.equal(cap(t, 'statement-cycle-rp-cap').cap_kind, 'total_points');
  assert.equal(cap(t, 'insurance-rp-monthly-cap').category_slug, 'insurance');
  assert.equal(cap(t, 'smartbuy-brand-voucher-rp-subcap').parent_key, 'smartbuy-accelerated-rp');
  assert.ok(cap(t, 'smartbuy-brand-voucher-rp-subcap').flags.includes('orphan_cap'));
  for (const id of ['tanishq-redemption-quarterly', 'apple-redemption-quarterly', 'flight-hotel-redemption-monthly', 'statement-credit-redemption-monthly']) {
    assert.equal(cap(t, id), undefined, id);
  }
  assert.equal(t.card.base_reward_unit, 'points_per_150');
  assert.equal(t.card.model_status, 'partial');
  assert.equal(t.card.model_coverage.caps_total, 11);
});

test('tiered-lounge card (Axis Atlas): tier unlock rows; travel alternatives become one MCC rule', () => {
  const t = transform('axis-atlas');
  const tiers = t.unlockRules.filter((u) => u.kind === 'tier');
  assert.deepEqual(
    tiers.map((u) => [u.tier_label, u.spend_threshold_inr, u.spend_window, u.unlocks_quota]).sort(),
    [['Gold', 750000, 'card_year', 12], ['Gold', 750000, 'card_year', 6], ['Platinum', 1500000, 'card_year', 12], ['Platinum', 1500000, 'card_year', 18]].sort()
  );
  const [travel] = rows(t, 'travel-accelerated');
  assert.equal(travel.rule_role, 'earn');
  assert.equal(travel.category_slug, null, 'narrow token: MCC-only, never all of travel (D17a)');
  assert.equal(travel.min_engine_version, 2);
  assert.ok(travel.mcc_include.includes('4511') && travel.mcc_include.includes('7011') && travel.mcc_include.includes('3000'));
  assert.equal(rows(t, 'travel-above-monthly-cap')[0].rule_role, 'info', 'cumulative-spend trigger');
  const spendCap = cap(t, 'travel-accelerated-monthly-spend-cap');
  assert.equal(spendCap.cap_kind, 'eligible_spend');
  // the source states the post-limit rate (2 pts/₹100, the base): custom_rate at that rate
  assert.deepEqual([spendCap.post_cap_behavior, spendCap.post_cap_unit, spendCap.post_cap_rate], ['custom_rate', 'points_per_100', 2]);
  assert.equal(t.milestones.length, 3);
  assert.ok(t.milestones.every((m) => m.anchor === 'card_anniversary'));
});

test('cashback card (SBI Cashback): rails, unreadable caps reported, and fixed by its override', () => {
  const plain = transform('cashback-sbi-card');
  assert.deepEqual(rows(plain, 'online_cashback').map((r) => [r.rule_role, r.rail, r.rate]), [['earn', 'online', 5]]);
  assert.equal(plain.capRules.length, 0);
  assert.ok(flagCodes(plain).includes('unknown_cap_metric'));
  assert.equal(plain.card.accrual_rounding, 'none');

  const fixed = transform('cashback-sbi-card', {
    changes: [
      { path: 'cap_rules[id=cap_online_cashback_cycle].metric', value: 'total_reward_points' },
      { path: 'cap_rules[id=cap_offline_cashback_cycle].metric', value: 'total_reward_points' },
      { path: 'cap_rules[id=cap_online_cashback_cycle].limit_value', value: 2000 },
      { path: 'cap_rules[id=cap_offline_cashback_cycle].limit_value', value: 2000 },
      { path: 'accrual_engine.cashback_rounding', value: 'rupee_floor' },
    ],
  });
  const online = cap(fixed, 'cap_online_cashback_cycle');
  assert.deepEqual([online.cap_kind, online.cap_amount, online.target_keys.join()], ['total_cashback', 2000, 'online_cashback']);
  assert.equal(fixed.card.cashback_rounding, 'rupee_floor');
});

test('every fixture transforms; the report aggregates and renders', () => {
  const cards = fs.readdirSync(FIXTURES).filter((f) => f.endsWith('.json')).map((f) => {
    const slug = f.replace(/\.json$/, '');
    return { sourceSlug: slug, result: transform(slug), legacy: { acceleratorsUnmapped: 0 } };
  });
  for (const c of cards) {
    const t = c.result;
    // Never widen: every source accelerator is modelled or info, never dropped.
    for (const src of t.coverage.perSource) assert.ok(src.keys.length > 0, `${c.sourceSlug}:${src.source_local_id}`);
    // Every role and engine version is in the C1 domain.
    for (const r of t.rewardRules) {
      assert.ok(['base', 'earn', 'exclusion', 'info'].includes(r.rule_role));
      assert.ok([1, 2].includes(r.min_engine_version));
      if (r.rule_role === 'info') assert.equal(r.min_engine_version, 2);
      if (r.min_engine_version === 1) {
        assert.ok(['cashback_percent', 'points_per_100', 'points_per_150', 'points_per_200', 'miles_per_100', 'flat_points', 'discount_percent'].includes(r.unit));
        assert.equal(r.block_inr, null);
        assert.equal(r.platform_slugs.length, 0);
        assert.equal(r.mcc_include.length, 0);
      }
    }
    for (const k of t.capTargets) assert.ok(t.capRules.some((x) => x.key === k.cap_key) && t.rewardRules.some((x) => x.key === k.rule_key));
    assert.ok(['floor', 'round', 'none', 'points_half_up', 'points_floor'].includes(t.card.accrual_rounding), 'D10');
  }
  const report = aggregateReport(cards, { transformVersion: 'test' });
  assert.equal(report.cards_transformed, cards.length);
  assert.equal(report.accelerators.after_dropped, 0);
  assert.match(renderMarkdown(report), /# Catalogue v2 coverage report/);
});

// Every override file checked into api/scripts/catalogue_overrides must apply
// cleanly to its record. Records come from the fixtures, or from a local
// CardPipeline checkout when one exists next to this repo.
//
// A local CardPipeline checkout can be OLDER than the overrides: the overrides
// and the committed snapshots (db/fixtures/catalogue_v2_cards) were written
// against newer records than a checkout last refreshed in August. An override
// that talks about a rule the old record does not have (error carries
// `missing_selector`) says nothing about the override, so it is reported as a
// diagnostic and skipped. Every other error, and every error against a fixture
// record (which is pinned in this repo), still fails the test.
test('every committed override file applies to its CardPipeline record without error', (t) => {
  const files = fs.existsSync(DEFAULT_OVERRIDES_DIR)
    ? fs.readdirSync(DEFAULT_OVERRIDES_DIR).filter((f) => f.endsWith('.json') && f !== 'verified_cards.json')
    : [];
  let pipeline = null;
  const pipelineRoot = path.resolve(__dirname, '../../../CardPipeline');
  if (fs.existsSync(path.join(pipelineRoot, 'data', 'checklist.json'))) {
    pipeline = new Map(loadDoneRecords(pipelineRoot).records.map((r) => [r.sourceSlug, r.record]));
  }
  for (const file of files) {
    const slug = file.replace(/\.json$/, '');
    const overrides = JSON.parse(fs.readFileSync(path.join(DEFAULT_OVERRIDES_DIR, file), 'utf8'));
    const fromFixture = fs.existsSync(path.join(FIXTURES, file));
    const record = fromFixture ? unwrapItem(fixture(slug)).record : pipeline?.get(slug);
    if (!record) continue; // no source record available in this checkout
    const { errors } = applyOverrides(record, overrides);
    const stale = fromFixture ? [] : errors.filter((e) => e.missing_selector);
    assert.deepEqual(errors.filter((e) => !stale.includes(e)), [], file);
    if (stale.length) {
      t.diagnostic(
        `${file}: the local CardPipeline record is older than this override; skipped ${stale.length} change(s) for rules it does not have (${[...new Set(stale.map((e) => e.missing_selector))].join(', ')})`,
      );
    }
    transformCardRecordV2(record, { directory, overrides, sourceSlug: slug });
  }
});
