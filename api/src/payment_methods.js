'use strict';

/**
 * transactions.payment_method vocabulary: contract `transaction-payment-methods`
 * v1 (app/test/fixtures/payment_methods_v1.json is the single source of truth,
 * and api/test/payment_method_api.test.js fails if this list drifts from it).
 *
 * The stored `instrument` is NOT changed by this vocabulary: cheque is
 * instrument `upi_bank` plus payment_method `cheque`. 'upi' predates the
 * contract (SMS v2 writes it) and keeps its meaning.
 *
 * Pure helpers only; no database access here.
 */

const PAYMENT_METHODS = Object.freeze([
  { wire: 'upi', label: 'UPI', group: 'bank', instruments: ['upi_bank', 'credit_card', 'debit_card'], mainChip: false },
  { wire: 'net_banking', label: 'Net banking', group: 'bank', instruments: ['upi_bank'], mainChip: false },
  { wire: 'neft', label: 'NEFT', group: 'bank', instruments: ['upi_bank'], mainChip: false },
  { wire: 'imps', label: 'IMPS', group: 'bank', instruments: ['upi_bank'], mainChip: false },
  { wire: 'rtgs', label: 'RTGS', group: 'bank', instruments: ['upi_bank'], mainChip: false, minAmountInr: 200000 },
  { wire: 'cheque', label: 'Cheque', group: 'bank', instruments: ['upi_bank'], mainChip: true },
  { wire: 'demand_draft', label: 'Demand draft', group: 'bank', instruments: ['upi_bank'], mainChip: false },
  { wire: 'auto_debit', label: 'Auto-debit (NACH / standing instruction)', group: 'bank', instruments: ['upi_bank'], mainChip: false },
  { wire: 'emi', label: 'EMI', group: 'credit', instruments: ['credit_card', 'debit_card', 'upi_bank', 'other'], mainChip: false },
  { wire: 'pay_later', label: 'Pay later', group: 'credit', instruments: ['other'], mainChip: false },
  { wire: 'prepaid_card', label: 'Prepaid / forex card', group: 'cards', instruments: ['wallet'], mainChip: false },
  { wire: 'gift_card', label: 'Gift card / voucher', group: 'other', instruments: ['other'], mainChip: false },
  { wire: 'reward_points', label: 'Reward points', group: 'other', instruments: ['other'], mainChip: false },
].map((method) => Object.freeze({ ...method, instruments: Object.freeze([...method.instruments]) })));

const PAYMENT_METHOD_GROUPS = Object.freeze(['bank', 'credit', 'cards', 'other']);
const PAYMENT_METHOD_INSTRUMENTS = Object.freeze(['credit_card', 'debit_card', 'cash', 'upi_bank', 'wallet', 'other']);
const PAYMENT_METHOD_WIRES = Object.freeze(PAYMENT_METHODS.map((method) => method.wire));

const BY_WIRE = new Map(PAYMENT_METHODS.map((method) => [method.wire, method]));

function isValidPaymentMethod(method) {
  return typeof method === 'string' && BY_WIRE.has(method);
}

/**
 * True when `method` may be stored on a transaction whose instrument is
 * `instrument`. A null/absent method is always compatible (nothing to store).
 * An unknown method or instrument is never compatible. `cash` accepts no method.
 */
function isMethodCompatibleWithInstrument(method, instrument) {
  if (method === null || method === undefined) return true;
  if (!isValidPaymentMethod(method)) return false;
  return BY_WIRE.get(method).instruments.includes(instrument);
}

/**
 * Reads the optional `paymentMethod` body field.
 *   absent (undefined)  -> { provided: false }
 *   null                -> { provided: true, value: null }   (explicit clear)
 *   known wire string   -> { provided: true, value }
 *   anything else       -> { error }  (unknown value, wrong type, empty string)
 * No case folding or trimming: only the exact wire values are accepted.
 */
function normalisePaymentMethodInput(raw) {
  if (raw === undefined) return { provided: false };
  if (raw === null) return { provided: true, value: null };
  if (!isValidPaymentMethod(raw)) {
    return { error: `paymentMethod must be null or one of ${PAYMENT_METHOD_WIRES.join(', ')}` };
  }
  return { provided: true, value: raw };
}

/**
 * POST /transactions: returns { error } for a 400, otherwise { value } where
 * value is the method to persist (null when none was given).
 */
function resolvePaymentMethodForCreate(raw, instrument) {
  const parsed = normalisePaymentMethodInput(raw);
  if (parsed.error) return { error: parsed.error };
  const value = parsed.provided ? parsed.value : null;
  if (value !== null && !isMethodCompatibleWithInstrument(value, instrument)) {
    return { error: `paymentMethod ${value} is not valid for the ${instrument} instrument` };
  }
  return { value };
}

/**
 * PATCH /transactions/:id: `storedMethod` is the row's current payment_method,
 * `newInstrument` the instrument after this edit (the stored one when the body
 * carries none). Returns { error } for a 400, otherwise { value, changed }.
 *
 *   - absent field keeps the stored value, EXCEPT when this edit changes the
 *     instrument to one the stored method does not belong to. That is rejected
 *     (400) so the row never ends up with, say, a cheque on a cash entry; the
 *     client resolves it by sending paymentMethod (null to clear, or a method
 *     valid for the new instrument). Legacy 'upi' (written by SMS v2 and
 *     before this contract) is exempt: an older client that omits the field
 *     must keep editing such rows exactly as it does today.
 *   - explicit null clears.
 *   - a string must be a known wire value valid for newInstrument.
 */
function resolvePaymentMethodForPatch(raw, storedMethod, newInstrument) {
  const parsed = normalisePaymentMethodInput(raw);
  if (parsed.error) return { error: parsed.error };
  const stored = storedMethod ?? null;
  if (!parsed.provided) {
    if (stored !== null && stored !== 'upi'
        && !isMethodCompatibleWithInstrument(stored, newInstrument)) {
      return {
        error: `instrument ${newInstrument} is not valid for the saved payment method ${stored}; send paymentMethod (null to clear) with the instrument change`,
      };
    }
    return { value: stored, changed: false };
  }
  if (parsed.value !== null && !isMethodCompatibleWithInstrument(parsed.value, newInstrument)) {
    return { error: `paymentMethod ${parsed.value} is not valid for the ${newInstrument} instrument` };
  }
  return { value: parsed.value, changed: parsed.value !== stored };
}

module.exports = {
  PAYMENT_METHODS,
  PAYMENT_METHOD_GROUPS,
  PAYMENT_METHOD_INSTRUMENTS,
  PAYMENT_METHOD_WIRES,
  isValidPaymentMethod,
  isMethodCompatibleWithInstrument,
  normalisePaymentMethodInput,
  resolvePaymentMethodForCreate,
  resolvePaymentMethodForPatch,
};
