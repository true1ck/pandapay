'use strict';

const { randomInt: secureRandomInt } = require('node:crypto');

const MAX_PAISE = 9223372036854775807n;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const INVITE_RE = /^[A-Z0-9]+(?:-[A-Z0-9]+)*$/;

function normalizeInvitationCode(value) {
  if (typeof value !== 'string') return null;
  const code = value.trim().toUpperCase();
  if (code.length < 6 || code.length > 32 || !INVITE_RE.test(code)) return null;
  return code;
}

function parsePaise(value, { allowZero = false } = {}) {
  if (typeof value !== 'string' || !/^(0|[1-9]\d{0,18})$/.test(value)) {
    throw new TypeError('amountPaise must be an integer minor-unit string');
  }
  const paise = BigInt(value);
  if (paise > MAX_PAISE || (!allowZero && paise <= 0n)) {
    throw new RangeError('amountPaise is outside the supported range');
  }
  return paise;
}

function validateDistribution(distribution, role) {
  if (!['inviter', 'referee'].includes(role)) {
    throw new TypeError('role must be inviter or referee');
  }
  const buckets = distribution?.[role];
  if (!Array.isArray(buckets) || buckets.length === 0) {
    throw new TypeError(`${role} distribution must contain at least one bucket`);
  }

  const seen = new Set();
  let totalWeight = 0;
  const validated = buckets.map((bucket) => {
    if (!bucket || typeof bucket !== 'object' || Array.isArray(bucket)) {
      throw new TypeError('each prize bucket must be an object');
    }
    const id = bucket.id;
    const weight = bucket.weight;
    if (typeof id !== 'string' || id.trim() !== id || id.length < 1 || id.length > 80 || seen.has(id)) {
      throw new TypeError('prize bucket IDs must be unique non-empty strings');
    }
    if (!Number.isSafeInteger(weight) || weight <= 0) {
      throw new TypeError('prize weights must be positive safe integers');
    }
    const amountPaise = parsePaise(bucket.amountPaise, { allowZero: true });
    if (amountPaise > 50_000n) {
      throw new RangeError('prize amounts cannot exceed INR 500');
    }
    totalWeight += weight;
    if (!Number.isSafeInteger(totalWeight) || totalWeight > 0x7fffffff) {
      throw new RangeError('total prize weight is too large');
    }
    seen.add(id);
    return Object.freeze({ id, weight, amountPaise: amountPaise.toString() });
  });

  return Object.freeze({ totalWeight, buckets: Object.freeze(validated) });
}

function chooseWeightedPrize(distribution, role, randomInt = secureRandomInt) {
  const { totalWeight, buckets } = validateDistribution(distribution, role);
  const draw = randomInt(totalWeight);
  if (!Number.isInteger(draw) || draw < 0 || draw >= totalWeight) {
    throw new RangeError('random source must return an integer inside [0, totalWeight)');
  }
  let upperBound = 0;
  for (const bucket of buckets) {
    upperBound += bucket.weight;
    if (draw < upperBound) return bucket;
  }
  throw new Error('validated distribution did not cover the random draw');
}

function assertDateOnly(value) {
  if (typeof value !== 'string' || !DATE_RE.test(value)) {
    throw new TypeError(`invalid campaign date: ${value}`);
  }
  const parsed = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(parsed.valueOf()) || parsed.toISOString().slice(0, 10) !== value) {
    throw new TypeError(`invalid campaign date: ${value}`);
  }
  return parsed;
}

function formatDateInZone(instant, timeZone = 'Asia/Kolkata') {
  const date = instant instanceof Date ? instant : new Date(instant);
  if (Number.isNaN(date.valueOf())) throw new TypeError('activity timestamp is invalid');
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(date);
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${value.year}-${value.month}-${value.day}`;
}

function evaluateConsecutiveDates(dateValues, localToday) {
  assertDateOnly(localToday);
  const dates = [...new Set(dateValues)].map((day) => {
    assertDateOnly(day);
    return day;
  }).sort();

  let bestStreak = 0;
  let run = 0;
  let previous = null;
  for (const day of dates) {
    const currentDate = assertDateOnly(day);
    if (previous && currentDate.valueOf() - previous.valueOf() === 86_400_000) run += 1;
    else run = 1;
    bestStreak = Math.max(bestStreak, run);
    previous = currentDate;
  }

  const latest = dates.at(-1) ?? null;
  let currentStreak = 0;
  if (latest) {
    const latestDate = assertDateOnly(latest);
    const today = assertDateOnly(localToday);
    const daysBehind = (today.valueOf() - latestDate.valueOf()) / 86_400_000;
    if (daysBehind === 0 || daysBehind === 1) currentStreak = run;
  }

  return Object.freeze({ currentStreak, bestStreak, latestActivityDate: latest });
}

function hasQualifiedRun(dateValues, requiredDays = 3) {
  if (!Number.isSafeInteger(requiredDays) || requiredDays < 1 || requiredDays > 30) {
    throw new RangeError('requiredDays must be between 1 and 30');
  }
  let run = 0;
  let previous = null;
  for (const day of [...new Set(dateValues)].map(assertDateOnly).sort((a, b) => a - b)) {
    if (previous && day.valueOf() - previous.valueOf() === 86_400_000) run += 1;
    else run = 1;
    if (run >= requiredDays) return true;
    previous = day;
  }
  return false;
}

function getYearWindow(year, timeZone = 'Asia/Kolkata') {
  if (!Number.isSafeInteger(year) || year < 2000 || year > 2200) {
    throw new RangeError('year must be between 2000 and 2200');
  }
  const from = new Date(`${year}-01-01T00:00:00.000Z`);
  const until = new Date(`${year + 1}-01-01T00:00:00.000Z`);
  const localMidnightToUtc = (date) => {
    const localDate = formatDateInZone(date, timeZone);
    if (localDate !== date.toISOString().slice(0, 10)) {
      throw new Error('getYearWindow currently expects an Asia/Kolkata calendar');
    }
    const offsetProbe = new Date(`${localDate}T00:00:00.000Z`);
    const localized = new Intl.DateTimeFormat('en-CA', {
      timeZone,
      year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
    }).formatToParts(offsetProbe);
    const p = Object.fromEntries(localized.map((part) => [part.type, part.value]));
    const localAsUtc = Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day),
      Number(p.hour), Number(p.minute), Number(p.second));
    return new Date(offsetProbe.valueOf() - (localAsUtc - offsetProbe.valueOf()));
  };
  return Object.freeze({ from: localMidnightToUtc(from), until: localMidnightToUtc(until) });
}

module.exports = {
  normalizeInvitationCode,
  parsePaise,
  validateDistribution,
  chooseWeightedPrize,
  formatDateInZone,
  evaluateConsecutiveDates,
  hasQualifiedRun,
  getYearWindow,
};
