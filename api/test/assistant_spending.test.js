const { buildAssistantSpendingSummary } = require('../src/assistant_spending');
const test = require('node:test');
const assert = require('node:assert/strict');

test('returns only the assistant-safe monthly headline and freshness fields', () => {
  const summary = buildAssistantSpendingSummary({
    period: 'month',
    timeZone: 'Asia/Kolkata',
    bounds: {
      start: new Date('2026-10-01T00:00:00.000Z'),
      end: new Date('2026-11-01T00:00:00.000Z'),
    },
    totals: {
      spend: { totalInr: 18420, txnCount: 27, rewardsInr: 312.5 },
    },
    latestSmsObservedAt: '2026-10-16T10:30:00.000Z',
  });

    assert.deepEqual(summary, {
      period: 'month',
      timeZone: 'Asia/Kolkata',
      periodStart: '2026-10-01T00:00:00.000Z',
      periodEnd: '2026-11-01T00:00:00.000Z',
      currency: 'INR',
      totalSpendInr: 18420,
      transactionCount: 27,
      rewardsInr: 312.5,
      latestSmsObservedAt: '2026-10-16T10:30:00.000Z',
    });
    assert.equal(Object.hasOwn(summary, 'transactions'), false);
    assert.equal(Object.hasOwn(summary, 'smsBodies'), false);
});

test('normalizes a missing SMS observation timestamp to null', () => {
  const summary = buildAssistantSpendingSummary({
    period: 'month',
    timeZone: 'Asia/Kolkata',
    bounds: {
      start: new Date('2026-10-01T00:00:00.000Z'),
      end: new Date('2026-11-01T00:00:00.000Z'),
    },
    totals: { spend: { totalInr: 0, txnCount: 0, rewardsInr: 0 } },
  });

    assert.equal(summary.latestSmsObservedAt, null);
});
