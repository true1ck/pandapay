'use strict';

// SMS pipeline v2 / WP-08: pure mapping from a stored event (and its ledger
// entries) to the `transactions` row it projects, per Contracts -> Totals and
// counts. No I/O here, so the mapping is unit-tested without a database.

// Event type -> transactions.entry_kind. ipo_application and unknown are
// handled separately: they only sometimes (or never) become a row.
const ENTRY_KIND_BY_TYPE = Object.freeze({
  purchase: 'spend',
  subscription_charge: 'spend',
  fee: 'spend',
  emi: 'spend',
  bill_payment: 'spend',
  atm_withdrawal: 'spend',
  p2p_out: 'spend',
  refund: 'refund',
  cashback: 'income',
  income: 'income',
  p2p_in: 'income',
  dividend: 'income',
  investment: 'investment',
  own_transfer: 'transfer',
  card_bill_payment: 'transfer',
  wallet_topup: 'transfer',
  investment_withdrawal: 'transfer',
});

// Money arrives at one of the user's instruments for these types, so the row's
// instrument is the ledger entry's `to` side and its merchant the `from` side.
const INFLOW_TYPES = new Set(['refund', 'cashback', 'income', 'p2p_in', 'dividend', 'investment_withdrawal']);

// An IPO application is a row only once the hold converted into the allotment
// debit; while it is only held or released it is "blocked", never a row.
function ipoConverted(legs) {
  return (legs || []).some((l) => l.role === 'hold_converted' || l.role === 'debit_leg');
}

function entryKindFor(event) {
  if (event.status === 'ambiguous') return null;
  if (event.type === 'ipo_application') return ipoConverted(event.legs) ? 'investment' : null;
  return ENTRY_KIND_BY_TYPE[event.type] || null;
}

// txn_instrument enum: credit_card, debit_card, cash, upi_bank, wallet, other.
function instrumentEnumFor(instrumentKind, rail) {
  switch (instrumentKind) {
    case 'credit_card': return 'credit_card';
    case 'debit_card':
    case 'prepaid_card': return 'debit_card';
    case 'bank_account': return 'upi_bank';
    case 'wallet':
    case 'pay_later': return 'wallet';
    case 'broker':
    case 'loan': return 'other';
    default: return rail === 'cash' ? 'cash' : 'other';
  }
}

// txn_rail enum: upi_qr, swipe, online, contactless, atm, emi, unknown. Same
// rule as the v1 SMS import: only UPI and ATM are certain from the text.
function railEnumFor(eventType, factRail) {
  if (eventType === 'atm_withdrawal' || factRail === 'atm') return 'atm';
  if (eventType === 'emi') return 'emi';
  if (factRail === 'upi') return 'upi_qr';
  return 'unknown';
}

const CARD_ENUMS = new Set(['credit_card', 'debit_card']);

const byTimeThenId = (a, b) => {
  const t = Date.parse(a.occurredAt) - Date.parse(b.occurredAt);
  return t !== 0 ? t : (a.entryId < b.entryId ? -1 : a.entryId > b.entryId ? 1 : 0);
};

/**
 * @param {object} args
 * @param {object} args.event     {eventId, type, status, legs, occurredAt, amountMinor}
 * @param {object[]} args.ledger  rows: {entryId, occurredAt, unit, fromInstrumentId, fromExternal,
 *                                toInstrumentId, toExternal, category}
 * @param {Map<string,{kind:string,userCardId:?string}>} args.instruments by instrument id
 * @param {?{sourceKey:string, rail:?string}} args.anchor the event's anchor fact
 * @returns {?object} the row to upsert, or null when the event is not a row
 */
function projectEvent({ event, ledger, instruments, anchor }) {
  const entryKind = entryKindFor(event);
  if (!entryKind) return null;
  if (!(event.amountMinor > 0)) return null;
  const inflow = INFLOW_TYPES.has(event.type);
  const entries = (ledger || []).filter((e) => e.unit === 'INR').sort(byTimeThenId);

  let merchant = null;
  let instrumentId = null;
  let category = null;
  for (const e of entries) {
    if (merchant === null) merchant = (inflow ? e.fromExternal : e.toExternal) || null;
    if (instrumentId === null) instrumentId = (inflow ? e.toInstrumentId : e.fromInstrumentId) || null;
    if (category === null && e.category) category = e.category;
  }
  const instrument = instrumentId ? instruments.get(instrumentId) || null : null;
  const rail = anchor ? anchor.rail || null : null;
  const instrumentEnum = instrumentEnumFor(instrument ? instrument.kind : null, rail);
  return {
    eventId: event.eventId,
    entryKind,
    amountMinor: event.amountMinor,
    occurredAt: event.occurredAt,
    merchantName: merchant ? String(merchant).slice(0, 200) : null,
    categorySlug: category,
    // transactions_card_matches_instrument: only a credit or debit card row may carry a user card.
    userCardId: instrument && instrument.userCardId && CARD_ENUMS.has(instrumentEnum) ? instrument.userCardId : null,
    instrument: instrumentEnum,
    rail: railEnumFor(event.type, rail),
    sourceKey: anchor ? anchor.sourceKey : null,
  };
}

// Only a credit-card SPEND moves card state (same rule as
// insertTransactionAndUpdateState).
function movesCardState(row) {
  return row.entryKind === 'spend' && row.instrument === 'credit_card' && Boolean(row.userCardId);
}

module.exports = { ENTRY_KIND_BY_TYPE, INFLOW_TYPES, entryKindFor, instrumentEnumFor, railEnumFor, projectEvent, movesCardState, ipoConverted };
