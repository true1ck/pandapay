const test = require('node:test');
const assert = require('node:assert');
const { buildMonthlyReport, evaluateSingleCard, evaluateOptimal } = require('../src/monthly_report');

/**
 * The monthly report's counterfactuals.
 *
 * `baseline_single_card_inr`, `extra_earned_inr` and `value_missed_inr`
 * were columns that had always been zero — the route wrote an apology into
 * `breakdown` rather than computing them. The reason they are worth
 * computing carefully is that the naive version is badly wrong in a
 * specific direction: evaluating every alternative card as freshly-uncapped
 * makes a capped card look like it would have paid its headline rate on the
 * whole month, which overstates missed value enormously and overstates it
 * most for the cards the app would then go on to recommend.
 */
function card(id, { base = 1, rules = [], caps = [] } = {}) {
  return {
    card: {
      user_card_id: id,
      point_value_inr: 0,
      base_reward_unit: 'cashback_percent',
      base_reward_rate: base,
      excluded_categories: [],
    },
    rewardRules: rules,
    capRules: caps,
  };
}

function txn(id, cardId, amount, isoDate, { categoryId = null, expected = 0 } = {}) {
  return {
    id,
    user_card_id: cardId,
    amount_inr: amount,
    occurred_at: new Date(isoDate),
    merchant_name: `M${id}`,
    category_id: categoryId,
    rail: 'swipe',
    expected_value_inr: expected,
  };
}

test('the baseline is the best SINGLE card across the whole month', () => {
  const cheap = card('c1', { base: 1 });
  const rich = card('c2', { base: 2 });
  const txns = [txn('t1', 'c1', 10000, '2026-08-02'), txn('t2', 'c1', 10000, '2026-08-10')];

  assert.strictEqual(evaluateSingleCard(cheap, txns), 200); // 1% of 20,000
  assert.strictEqual(evaluateSingleCard(rich, txns), 400); // 2% of 20,000
});

test('the baseline respects the single card hitting its own caps', () => {
  // The case the naive version gets badly wrong. A 10% card capped at
  // ₹3,000/month cannot pay 10% on ₹20,000 of spend — it pays 10% on the
  // first ₹3,000 and its 1% base rate on the remaining ₹17,000.
  const capped = card('c1', {
    base: 1,
    rules: [{ id: 'r', unit: 'cashback_percent', rate: 10, priority: 10 }],
    caps: [
      {
        id: 'cap',
        reward_rule_id: 'r',
        measure: 'spend_amount',
        cap_value: 3000,
        post_cap_rate: null,
        post_cap_unit: null,
      },
    ],
  });
  const txns = [txn('t1', 'c1', 10000, '2026-08-02'), txn('t2', 'c1', 10000, '2026-08-10')];

  // 3,000 at 10% = 300, plus 17,000 at 1% = 170.
  assert.strictEqual(evaluateSingleCard(capped, txns), 470);
});

test('the optimal figure carries cap state forward between transactions', () => {
  // Two cards, one capped. The first transaction should take the capped
  // card's high rate; the second must NOT, because the cap is gone.
  const capped = card('c1', {
    base: 1,
    rules: [{ id: 'r', unit: 'cashback_percent', rate: 10, priority: 10 }],
    caps: [
      {
        id: 'cap',
        reward_rule_id: 'r',
        measure: 'spend_amount',
        cap_value: 5000,
        post_cap_rate: null,
        post_cap_unit: null,
      },
    ],
  });
  const flat = card('c2', { base: 3 });
  const txns = [txn('t1', 'c1', 5000, '2026-08-02'), txn('t2', 'c1', 5000, '2026-08-10')];

  const { total } = evaluateOptimal([capped, flat], txns);
  // First: 5,000 at 10% on the capped card = 500. Cap now spent.
  // Second: capped card would pay 1%, flat card pays 3% => 150.
  assert.strictEqual(total, 650);
});

test('missed value is what a perfect month would have added, never negative', () => {
  const weak = card('c1', { base: 1 });
  const strong = card('c2', { base: 5 });
  // Spend went on the weak card and earned 1%.
  const txns = [txn('t1', 'c1', 10000, '2026-08-02', { expected: 100 })];

  const report = buildMonthlyReport({
    cards: [weak, strong],
    txns,
    actualTotal: 100,
    totalSpend: 10000,
  });

  assert.strictEqual(report.optimalInr, 500, 'the strong card would have paid 5%');
  assert.strictEqual(report.valueMissedInr, 400);
  assert.strictEqual(report.baselineSingleCardInr, 500, 'the best single card is the strong one');
});

test('missed value is floored at zero rather than reported as beating perfect', () => {
  // Greedy approximation and float drift can put "optimal" a hair under
  // "actual"; a negative missed value would read as the app claiming the
  // user did better than perfect.
  const only = card('c1', { base: 1 });
  const txns = [txn('t1', 'c1', 10000, '2026-08-02', { expected: 100.0001 })];
  const report = buildMonthlyReport({ cards: [only], txns, actualTotal: 100.0001, totalSpend: 10000 });
  assert.ok(report.valueMissedInr >= 0);
});

test('extra earned is what the wallet beat the single-card baseline by', () => {
  // Two cards, each best in its own category — the multi-card case the
  // whole product exists for.
  const groceries = card('c1', {
    base: 1,
    rules: [{ id: 'rg', category_id: 'groceries', unit: 'cashback_percent', rate: 5, priority: 10 }],
  });
  const dining = card('c2', {
    base: 1,
    rules: [{ id: 'rd', category_id: 'dining', unit: 'cashback_percent', rate: 5, priority: 10 }],
  });
  const txns = [
    txn('t1', 'c1', 10000, '2026-08-02', { categoryId: 'groceries', expected: 500 }),
    txn('t2', 'c2', 10000, '2026-08-05', { categoryId: 'dining', expected: 500 }),
  ];

  const report = buildMonthlyReport({
    cards: [groceries, dining],
    txns,
    actualTotal: 1000,
    totalSpend: 20000,
  });

  // Either single card alone: 5% on its own category (500) + 1% on the
  // other (100) = 600. The wallet earned 1,000, so 400 more.
  assert.strictEqual(report.baselineSingleCardInr, 600);
  assert.strictEqual(report.extraEarnedInr, 400);
  assert.strictEqual(report.valueMissedInr, 0, 'each spend already used the best card');
});

test('the biggest misses are listed, best-first, and capped in number', () => {
  const weak = card('c1', { base: 1 });
  const strong = card('c2', { base: 5 });
  const txns = [
    txn('t1', 'c1', 1000, '2026-08-01', { expected: 10 }),
    txn('t2', 'c1', 50000, '2026-08-02', { expected: 500 }),
    txn('t3', 'c1', 5000, '2026-08-03', { expected: 50 }),
  ];
  const report = buildMonthlyReport({ cards: [weak, strong], txns, actualTotal: 560, totalSpend: 56000 });

  assert.strictEqual(report.topMissed.length, 3);
  assert.strictEqual(report.topMissed[0].transactionId, 't2', 'the biggest miss leads');
  assert.ok(report.topMissed[0].missedInr > report.topMissed[1].missedInr);
  assert.strictEqual(report.topMissed[0].betterCardId, 'c2');
});

test('a month with no spend produces zeroes, not a crash', () => {
  const report = buildMonthlyReport({ cards: [card('c1')], txns: [], actualTotal: 0, totalSpend: 0 });
  assert.strictEqual(report.valueMissedInr, 0);
  assert.strictEqual(report.extraEarnedInr, 0);
  assert.strictEqual(report.topMissed.length, 0);
});

test('spend on a card that has since left the wallet is skipped, not crashed on', () => {
  const remaining = card('c2', { base: 1 });
  const txns = [txn('t1', 'gone-card', 10000, '2026-08-02', { expected: 100 })];
  const report = buildMonthlyReport({ cards: [remaining], txns, actualTotal: 100, totalSpend: 10000 });
  assert.ok(Number.isFinite(report.valueMissedInr));
});
