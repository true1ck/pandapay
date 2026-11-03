'use strict';

// Synthetic builders for WP-08 tests. No real SMS text, names or numbers.

const crypto = require('node:crypto');

const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const uuid4 = () => crypto.randomUUID();

const T0 = '2026-11-01T07:00:11Z';
const T_OBS = '2026-11-01T07:00:20Z';

function mention(o = {}) {
  return {
    kind: 'credit_card', issuerSlug: 'hdfc', maskDigits: '5678', maskLength: 16, productName: null, raw: null, ...o,
  };
}

function factId(sourceKey, ruleId = 'SYN-RULE', idx = 0) { return sha(`${sourceKey}|${ruleId}|${idx}`); }

/** A movement fact (or another type when `factType` is given). */
function fact(o = {}) {
  const sourceKey = o.sourceKey || `sms:synthetic:${crypto.randomUUID()}`;
  const factType = o.factType || 'movement';
  const base = {
    contractVersion: '2.0',
    factId: o.factId || factId(sourceKey, o.ruleId, o.idx || 0),
    sourceKey,
    factType,
    observedAt: o.observedAt || T_OBS,
    occurredAt: o.occurredAt === undefined ? T0 : o.occurredAt,
    instrument: o.instrument === undefined ? mention() : o.instrument,
    counterparty: o.counterparty === undefined ? { name: 'SYNTHETIC SHOP', vpa: null, kind: 'merchant', accountMask: null } : o.counterparty,
    amounts: o.amounts || [{ role: 'posted', minor: o.minor || 49900, unit: 'INR' }],
    references: {},
    attrs: o.attrs || { direction: 'debit', purpose: 'purchase', rail: o.rail || 'card' },
    provenance: {
      engine: 'rules', ruleId: o.ruleId || 'SYN-RULE', ruleVersion: 1, bundleVersion: 1, engineVersion: '2.0.0', appVersion: '1.0.0+1',
    },
    evidence: [],
    confidence: 0.99,
  };
  return base;
}

function item(facts, o = {}) {
  const sourceKey = o.sourceKey || (facts[0] && facts[0].sourceKey) || `sms:synthetic:${crypto.randomUUID()}`;
  return {
    sourceKey, senderBrand: o.senderBrand || 'HDFCBK', observedAt: o.observedAt || T_OBS, bodyHash: sha(`body:${sourceKey}`), facts,
  };
}

function instrument(o = {}) {
  return {
    instrumentId: o.instrumentId || uuid4(),
    kind: o.kind || 'credit_card',
    issuerSlug: o.issuerSlug || 'hdfc',
    maskDigits: o.maskDigits === undefined ? '5678' : o.maskDigits,
    maskLength: 16,
    displayName: o.displayName || 'Synthetic card',
    status: o.status || 'detected',
    userCardId: o.userCardId || null,
    parentInstrumentId: null,
    aliases: { senders: [], vpas: [], productNames: [] },
    creditLimitMinor: o.creditLimitMinor === undefined ? null : o.creditLimitMinor,
    creditLimitSource: o.creditLimitSource === undefined ? (o.creditLimitMinor ? 'sms' : null) : o.creditLimitSource,
    creditLimitAt: o.creditLimitAt === undefined ? (o.creditLimitMinor ? T0 : null) : o.creditLimitAt,
    availableMinor: o.availableMinor === undefined ? null : o.availableMinor,
    availableAt: o.availableAt === undefined ? null : o.availableAt,
    pointsBalance: null,
    pointsAt: null,
    firstSeenAt: '2026-10-01T05:00:00Z',
    lastSeenAt: o.lastSeenAt || T_OBS,
    evidenceCount: o.evidenceCount === undefined ? 1 : o.evidenceCount,
  };
}

function event(anchor, o = {}) {
  const legs = o.legs || [{ factId: anchor.factId, role: o.role || 'debit_leg' }];
  return {
    eventId: anchor.factId,
    type: o.type || 'purchase',
    status: o.status || 'complete',
    legs,
    linkRuleId: o.linkRuleId === undefined ? null : o.linkRuleId,
    confidence: o.confidence === undefined ? 0.95 : o.confidence,
    occurredAt: o.occurredAt || T0,
    amountMinor: o.amountMinor || anchor.amounts[0].minor,
  };
}

function ledger(ev, o = {}) {
  const index = o.index || 0;
  const to = o.to || { external: 'SYNTHETIC SHOP' };
  const external = Object.prototype.hasOwnProperty.call(to, 'external');
  return {
    entryId: sha(`${ev.eventId}|${index}`),
    eventId: ev.eventId,
    from: o.from || { instrumentId: o.fromInstrumentId },
    to,
    amountMinor: o.amountMinor || ev.amountMinor,
    unit: 'INR',
    occurredAt: o.occurredAt || ev.occurredAt,
    category: o.category === undefined ? (external ? 'food' : null) : o.category,
    categorySource: o.categorySource === undefined ? (o.category === null ? null : (external ? 'catalogue' : null)) : o.categorySource,
    countsAsTransaction: o.countsAsTransaction === undefined ? true : o.countsAsTransaction,
    isSpend: o.isSpend === undefined ? true : o.isSpend,
    isIncome: o.isIncome || false,
    isInvestment: o.isInvestment || false,
  };
}

function batch(o = {}) {
  return {
    contractVersion: '2.0', appVersion: '1.0.0+1', deviceId: 'synthetic-device-0001',
    items: o.items || [], instruments: o.instruments || [], events: o.events || [], ledger: o.ledger || [],
  };
}

module.exports = { sha, uuid4, T0, T_OBS, mention, factId, fact, item, instrument, event, ledger, batch };
