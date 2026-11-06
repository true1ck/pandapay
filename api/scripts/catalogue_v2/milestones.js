'use strict';

// Plan C7.8 — spend milestones with the right clock.
//
// The v1 loader set every milestone's anchor to card_anniversary (both
// branches of its ternary returned the same value). Here the period decides
// the anchor, welcome windows become window_days, and the reward is parsed
// into reward_points / reward_kind where the label states it.
//
// milestone_rules has no engine-version gate, so every row written here is
// also in the v1 feed. Event milestones the engines can't evaluate (birthday,
// upgrade, activation without a window) are therefore still left out and
// reported, as before.

const { asNumber, isNA } = require('./util');

const PERIOD = {
  card_anniversary_year: { period: 'annual', anchor: 'card_anniversary' },
  annual: { period: 'annual', anchor: 'card_anniversary' },
  enrollment_year: { period: 'annual', anchor: 'card_anniversary' },
  membership_year: { period: 'annual', anchor: 'card_anniversary' },
  calendar_year: { period: 'annual', anchor: 'calendar_year' },
  fiscal_year: { period: 'annual', anchor: 'fiscal_year' },
  quarter: { period: 'quarter', anchor: 'calendar_year' },
  calendar_quarter: { period: 'quarter', anchor: 'calendar_year' },
  half_year: { period: 'half_year', anchor: 'calendar_year' },
  calendar_month: { period: 'calendar_month', anchor: 'calendar_year' },
  month: { period: 'calendar_month', anchor: 'calendar_year' },
  statement_cycle: { period: 'statement_cycle', anchor: 'statement_cycle' },
  statement_cycle_quarter: { period: 'quarter', anchor: 'calendar_year', approximated: true },
  lifetime: { period: 'lifetime', anchor: 'card_anniversary' },
};

const EVENT = /\b(birthday|upgrade|renewal fee|anniversary gift|referral|refer)\b/i;
const WELCOME = /\b(welcome|activation|joining|first[ _-]?(?:\d+|year|transaction|spend|purchase)|new card)\b/i;

function windowDaysFrom(...texts) {
  for (const t of texts) {
    const s = String(t || '').toLowerCase().replace(/_/g, ' ');
    const m = s.match(/(?:first|within|in|one time)\s*(\d{1,3})\s*(?:days?|d)\b/) ||
      s.match(/\b(\d{1,3})\s*(?:days?)\b/) ||
      s.match(/\b(\d{2,3})d\b/);
    if (m) {
      const n = Number(m[1]);
      if (n > 0 && n <= 365) return n;
    }
  }
  return null;
}

// "10,000 bonus Membership Rewards points", "₹5,000 Tata CLiQ voucher".
function parseReward(label) {
  const text = String(label || '');
  const lower = text.toLowerCase();
  let kind = null;
  if (/fee (waiver|reversal)|waiv(er|ed) .*fee|annual fee|joining fee/.test(lower)) kind = 'fee_waiver';
  else if (/\b(points?|miles|neucoins|cashpoints|reward points|edge miles|\brp\b)\b/.test(lower)) kind = 'points';
  else if (/voucher|gift card|e-gift|egift/.test(lower)) kind = 'voucher';
  else if (/cashback|cash back/.test(lower)) kind = 'cashback';
  else if (/lounge|membership|ticket|coupon|stay|night|access/.test(lower)) kind = 'benefit';
  let points = null;
  if (kind === 'points') {
    const m = text.match(/([\d,]+(?:\.\d+)?)\s*(?:lakh\s+)?(?:bonus\s+|extra\s+|additional\s+)?(?:[A-Za-z]+\s+){0,3}(?:points?|miles|neucoins|cashpoints|RP)\b/i);
    if (m) {
      const n = Number(m[1].replace(/,/g, ''));
      if (Number.isFinite(n) && n > 0) points = n;
    }
  }
  return { kind, points };
}

function transformMilestones(record) {
  const source = record?.fee_waiver_and_milestones?.spend_milestones;
  const milestones = [];
  const flags = [];
  const anchors = {};
  const usedLabels = new Set();
  const seenTerms = new Map();
  (Array.isArray(source) ? source : []).forEach((m, idx) => {
    const sourceId = isNA(m?.id) ? `milestone-${idx + 1}` : String(m.id);
    const flag = (code, detail = null) => flags.push({ code, source_local_id: sourceId, detail });
    const identity = `${m?.id || ''} ${m?.label || ''}`;
    if (EVENT.test(identity.replace(/[_-]/g, ' '))) return flag('unsupported_milestone', 'event milestone');

    const threshold = asNumber(m?.threshold_spend_inr);
    const rewardValue = asNumber(m?.reward_value_inr);
    if (threshold === null || threshold <= 0 || rewardValue === null) return flag('milestone_missing_values');

    const periodKey = String(m?.period || '').toLowerCase();
    let spec = PERIOD[periodKey];
    let windowDays = null;
    const periodWindow = periodKey.match(/(?:first|one_time|within)?_?(\d{1,3})_days?/);
    const isWelcome = WELCOME.test(identity.replace(/[_-]/g, ' ')) || Boolean(periodWindow);
    if (isWelcome) {
      windowDays = periodWindow ? Number(periodWindow[1]) : windowDaysFrom(m?.id, m?.label);
      if (!windowDays) return flag('unsupported_milestone', 'welcome milestone without a window');
      // A one-time window counted from the card's start.
      spec = { period: 'lifetime', anchor: 'card_anniversary' };
    }
    if (!spec) return flag('unsupported_milestone', `unknown period ${m?.period}`);
    if (spec.approximated) flag('period_approximated', m?.period);

    let label = typeof m?.label === 'string' && m.label.trim() ? m.label.trim() : `₹${rewardValue} at ₹${threshold} spend`;
    const reward = parseReward(m?.label);
    // The same milestone twice (same label, terms and reward) would be paid
    // twice; keep the first. A shared label on different terms is kept, the
    // label made unique by the source id.
    const sameTerms = JSON.stringify([label, spec.period, spec.anchor, threshold, rewardValue,
      isWelcome ? false : m?.is_repeatable === true, reward.points, reward.kind, windowDays]);
    if (seenTerms.has(sameTerms)) return flag('duplicate_milestone_dropped', `duplicates ${seenTerms.get(sameTerms)}`);
    seenTerms.set(sameTerms, sourceId);
    if (usedLabels.has(label)) label = `${label} (${sourceId})`;
    usedLabels.add(label);
    anchors[`${spec.period}/${spec.anchor}`] = (anchors[`${spec.period}/${spec.anchor}`] || 0) + 1;
    milestones.push({
      key: sourceId,
      source_local_id: sourceId,
      label,
      period: spec.period,
      anchor: spec.anchor,
      threshold_spend_inr: threshold,
      reward_description: label,
      reward_value_inr: rewardValue,
      is_repeatable: isWelcome ? false : m?.is_repeatable === true,
      reward_points: reward.points,
      reward_kind: reward.kind,
      window_days: windowDays,
      excluded_category_slugs: [],
    });
  });
  return { milestones, flags, anchors };
}

module.exports = { parseReward, transformMilestones, windowDaysFrom };
