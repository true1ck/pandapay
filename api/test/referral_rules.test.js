'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  normalizeInvitationCode,
  parsePaise,
  validateDistribution,
  chooseWeightedPrize,
  formatDateInZone,
  evaluateConsecutiveDates,
  hasQualifiedRun,
  getYearWindow,
} = require('../src/referral_rules');

const fixture = {
  inviter: [
    { id: 'ten', amountPaise: '1000', weight: 70 },
    { id: 'twenty', amountPaise: '2000', weight: 25 },
    { id: 'fifty', amountPaise: '5000', weight: 5 },
  ],
  referee: [
    { id: 'ten', amountPaise: '1000', weight: 70 },
    { id: 'twenty', amountPaise: '2000', weight: 25 },
    { id: 'fifty', amountPaise: '5000', weight: 5 },
  ],
};

const bambooSpinFixture = {
  inviter: [
    { id: 'zero', amountPaise: '0', weight: 1000 },
    { id: 'five', amountPaise: '500', weight: 2500 },
    { id: 'ten', amountPaise: '1000', weight: 2500 },
    { id: 'twenty-five', amountPaise: '2500', weight: 2000 },
    { id: 'fifty', amountPaise: '5000', weight: 1000 },
    { id: 'seventy-five', amountPaise: '7500', weight: 500 },
    { id: 'one-hundred', amountPaise: '10000', weight: 300 },
    { id: 'one-fifty', amountPaise: '15000', weight: 100 },
    { id: 'two-hundred', amountPaise: '20000', weight: 50 },
    { id: 'three-hundred', amountPaise: '30000', weight: 30 },
    { id: 'five-hundred', amountPaise: '50000', weight: 20 },
  ],
};

test('invitation code normalization accepts only bounded ASCII codes', () => {
  assert.equal(normalizeInvitationCode('  panda-abc123  '), 'PANDA-ABC123');
  for (const invalid of [null, 9, '', 'short', 'PANDA-ABC 123', 'PÁNDA-ABC123', 'X'.repeat(33)]) {
    assert.equal(normalizeInvitationCode(invalid), null);
  }
});
test('paise parser uses integer strings and preserves 64-bit precision', () => {
  assert.equal(parsePaise('1000'), 1000n);
  assert.equal(parsePaise('9007199254740993').toString(), '9007199254740993');
  assert.throws(() => parsePaise(1000), /integer minor-unit string/);
  assert.throws(() => parsePaise('1.25'), /integer minor-unit string/);
  assert.throws(() => parsePaise('0'), /supported range/);
  assert.throws(() => parsePaise('9223372036854775808'), /supported range/);
});

test('distribution validation rejects duplicate, zero, fractional and excessive weights', () => {
  assert.equal(validateDistribution(fixture, 'inviter').totalWeight, 100);
  assert.throws(() => validateDistribution({ inviter: [], referee: [] }, 'inviter'), /at least one/);
  assert.throws(() => validateDistribution({ inviter: [{ ...fixture.inviter[0], weight: 0 }] }, 'inviter'), /positive safe integers/);
  assert.throws(() => validateDistribution({ inviter: [fixture.inviter[0], fixture.inviter[0]] }, 'inviter'), /unique/);
  assert.throws(() => validateDistribution({ inviter: [{ id: 'x', amountPaise: '1.5', weight: 1 }] }, 'inviter'), /integer minor-unit/);
  assert.equal(validateDistribution({ inviter: [{ id: 'zero', amountPaise: '0', weight: 1 }] }, 'inviter').buckets[0].amountPaise, '0');
  assert.throws(() => validateDistribution({ inviter: [{ id: 'over-cap', amountPaise: '50001', weight: 1 }] }, 'inviter'), /cannot exceed INR 500/);
  assert.throws(() => validateDistribution({ inviter: [{ id: 'x', amountPaise: '10', weight: 0x7fffffff }, { id: 'y', amountPaise: '10', weight: 1 }] }, 'inviter'), /too large/);
});

test('weighted draw covers every fixture boundary without gaps or overlap', () => {
  assert.equal(chooseWeightedPrize(fixture, 'inviter', () => 0).id, 'ten');
  assert.equal(chooseWeightedPrize(fixture, 'inviter', () => 69).id, 'ten');
  assert.equal(chooseWeightedPrize(fixture, 'inviter', () => 70).id, 'twenty');
  assert.equal(chooseWeightedPrize(fixture, 'inviter', () => 94).id, 'twenty');
  assert.equal(chooseWeightedPrize(fixture, 'inviter', () => 95).id, 'fifty');
  assert.equal(chooseWeightedPrize(fixture, 'inviter', () => 99).id, 'fifty');
  assert.throws(() => chooseWeightedPrize(fixture, 'inviter', () => 100), /inside/);
  assert.throws(() => chooseWeightedPrize(fixture, 'invalid', () => 0), /role/);
});

test('₹500 wheel uses weighted ranges and gives the top prize 0.2% odds', () => {
  const { totalWeight, buckets } = validateDistribution(bambooSpinFixture, 'inviter');
  assert.equal(totalWeight, 10_000);
  assert.equal(buckets.filter((bucket) => BigInt(bucket.amountPaise) <= 10_000n)
    .reduce((total, bucket) => total + bucket.weight, 0), 9_800);
  assert.equal(buckets.filter((bucket) => BigInt(bucket.amountPaise) > 10_000n)
    .reduce((total, bucket) => total + bucket.weight, 0), 200);
  assert.equal(buckets.at(-1).weight / totalWeight * 100, 0.2);
  let lowerBound = 0;
  for (const bucket of buckets) {
    assert.equal(
      chooseWeightedPrize(bambooSpinFixture, 'inviter', () => lowerBound).id,
      bucket.id,
    );
    assert.equal(
      chooseWeightedPrize(
        bambooSpinFixture,
        'inviter',
        () => lowerBound + bucket.weight - 1,
      ).id,
      bucket.id,
    );
    lowerBound += bucket.weight;
  }
});

test('campaign dates use Asia/Kolkata and cross local midnight at 18:30 UTC', () => {
  assert.equal(formatDateInZone('2026-10-21T18:29:59.000Z'), '2026-10-21');
  assert.equal(formatDateInZone('2026-10-21T18:30:00.000Z'), '2026-10-22');
  assert.deepEqual(getYearWindow(2026), {
    from: new Date('2025-12-31T18:30:00.000Z'),
    until: new Date('2026-12-31T18:30:00.000Z'),
  });
});

test('three consecutive dates qualify; gaps restart the run and imports do not backdate dates', () => {
  assert.equal(hasQualifiedRun(['2026-10-21', '2026-10-22', '2026-10-23']), true);
  assert.equal(hasQualifiedRun(['2026-10-21', '2026-10-22', '2026-10-24', '2026-10-25']), false);
  assert.equal(hasQualifiedRun(['2026-10-21', '2026-10-21', '2026-10-22']), false);
  assert.deepEqual(evaluateConsecutiveDates(
    ['2026-10-21', '2026-10-22', '2026-10-23'], '2026-10-24'),
    { currentStreak: 3, bestStreak: 3, latestActivityDate: '2026-10-23' },
  );
});

test('current engagement run expires only after a whole local date is missed', () => {
  assert.equal(evaluateConsecutiveDates(['2026-10-21', '2026-10-22'], '2026-10-23').currentStreak, 2);
  assert.equal(evaluateConsecutiveDates(['2026-10-21', '2026-10-22'], '2026-10-24').currentStreak, 0);
});
