/**
 * Typed source/fact contract (SMS intelligence Phase 1).
 *
 * One financial message yields SEVERAL typed facts, each carrying explicit
 * amount and date roles so downstream projections can never mistake a bill
 * total for a purchase or a mandate ceiling for a charge. Pure functions
 * here; persistence lives in the upsert writer used by future routes.
 *
 * Privacy: no raw body ever enters this contract. The body hash is the
 * identity; validated facts are the content.
 */

const crypto = require('crypto');

const CONTRACT_VERSION = 1;

const FACT_TYPES = [
  'posted_movement',
  'pending_or_failed_attempt',
  'balance_snapshot',
  'bill_obligation',
  'bill_payment',
  'mandate_lifecycle',
  'card_identity_hint',
  'security_or_service_alert',
  'promotion',
];

const FACT_STATUSES = ['active', 'superseded', 'discarded'];

const ENTRY_KINDS = ['spend', 'income', 'transfer', 'investment'];

const INSTRUMENTS = [
  'upi_bank',
  'credit_card',
  'debit_card',
  'cash',
  'wallet',
  'other',
];

/** The 15 canonical spend categories shared by the AI prompt, scoring and UI. */
const SPEND_CATEGORIES = [
  'groceries',
  'fuel',
  'dining',
  'online',
  'travel',
  'bills',
  'rent',
  'insurance',
  'education',
  'government',
  'wallet',
  'entertainment',
  'health',
  'emi',
  'other',
];

/** Amount roles keep "money mentioned" apart from "money moved". */
const AMOUNT_ROLES = ['posted', 'due_total', 'due_minimum', 'outstanding', 'ceiling', 'proposed'];

/** Which money field each role reads from inside the payload. */
const AMOUNT_FIELD_BY_ROLE = {
  posted: 'amountInr',
  due_total: 'amountDueInr',
  due_minimum: 'minimumDueInr',
  outstanding: 'outstandingInr',
  ceiling: 'limitInr',
  proposed: 'proposedAmountInr',
};

const PROVISION_BY_ROLE = {
  posted: 'occurredAt',
  due_total: 'dueDate',
  due_minimum: 'dueDate',
  outstanding: 'asOfAt',
  ceiling: 'asOfAt',
  proposed: 'proposedAt',
};

/** Fields a payload may carry, with their validation shapes. */
const PAYLOAD_FIELD_SHAPES = {
  entryKind: { in: ENTRY_KINDS },
  transferKind: { type: 'string' },
  amountRole: { in: AMOUNT_ROLES },
  amountInr: { number: true, positive: true },
  amountDueInr: { number: true, positive: true },
  minimumDueInr: { number: true, positive: true },
  outstandingInr: { number: true, positive: true },
  limitInr: { number: true, positive: true },
  proposedAmountInr: { number: true, positive: true },
  activationAmountInr: { number: true, nonnegative: true },
  availableBalanceInr: { number: true, nonnegative: true },
  occurredAt: { date: true },
  dueDate: { date: true },
  statementDate: { date: true },
  proposedAt: { date: true },
  asOfAt: { date: true },
  mandateStatus: { in: ['registered', 'scheduled', 'paused', 'cancelled', 'failed'] },
  targetKind: { in: ['card_bill', 'utility_or_other_bill', 'service_merchant', 'unknown'] },
  mandateReference: { shortText: true },
  serviceName: { shortText: true },
  planName: { shortText: true },
  plan: { shortText: true },
  subscriptionEvidence: { in: ['explicit', 'user_asserted', 'posted', 'historical', 'brand_prior'] },
  renewalMode: { in: ['one_time', 'automatic', 'manual', 'unknown'] },
  subscriptionStatus: { in: ['candidate', 'active', 'renewal_unverified', 'ended', 'payment_issue', 'cancelled', 'paused', 'unknown'] },
  cadenceDays: { integer: true, positive: true },
  cadenceExplicit: { boolean: true },
  accessEndDate: { date: true },
  nextPaymentDate: { date: true },
  nextPaymentAmountInr: { number: true, nonnegative: true },
  explicitSubscription: { boolean: true },
  userAsserted: { boolean: true },
  cardBill: { boolean: true },
  currency: { shortText: true },
  attemptStatus: { in: ['attempted', 'scheduled', 'failed'] },
  statementStatus: { in: ['outstanding', 'settled'] },
  alertKind: { in: ['otp', 'verification', 'service'] },
  last4: { digits: 4 },
  accountLast4: { digits: 4 },
  issuerName: { shortText: true },
  merchant: { shortText: true },
  transferParty: { shortText: true },
  billerName: { shortText: true },
  instrument: { in: INSTRUMENTS },
  reference: { shortText: true },
  cardType: { in: ['credit', 'debit'] },
  cardName: { shortText: true },
  category: { in: SPEND_CATEGORIES },
  isComplete: { boolean: true },
  confidence: { number: true },
};

/** Which payload fields are mandatory per fact type. */
const REQUIRED_FIELDS_BY_TYPE = {
  posted_movement: ['amountRole', 'entryKind', 'occurredAt'],
  pending_or_failed_attempt: ['attemptStatus', 'occurredAt'],
  balance_snapshot: ['availableBalanceInr', 'asOfAt'],
  bill_obligation: ['amountRole', 'dueDate'],
  bill_payment: ['amountRole', 'occurredAt'],
  mandate_lifecycle: ['mandateStatus', 'asOfAt'],
  card_identity_hint: ['asOfAt'],
  security_or_service_alert: ['alertKind', 'occurredAt'],
  promotion: [],
};

/** Fact types that must never carry moved-money semantics. */
const NON_POSTED_TYPES = new Set([
  'pending_or_failed_attempt',
  'bill_obligation',
  'mandate_lifecycle',
      'security_or_service_alert',
      'promotion',
      'card_identity_hint',
    ]);

function shortTextOk(value) {
  return (
    typeof value === 'string' &&
    value.trim().length > 0 &&
    value.trim().length <= 120
  );
}

function dateOk(value) {
  return typeof value === 'string' && !Number.isNaN(new Date(value).getTime());
}

function isPlainObject(value) {
  return (
    typeof value === 'object' &&
    value !== null &&
    !Array.isArray(value)
  );
}

/**
 * Validates one fact payload against its type's contract. Returns
 * { valid, errors } where every error names the offending field — call sites
 * must abstain (needs review) rather than post a half-trusted fact.
 */
function validatePayload(factType, payload) {
  const errors = [];
  if (!isPlainObject(payload)) {
    return { valid: false, errors: ['payload must be an object'] };
  }
  for (const [field, rule] of Object.entries(PAYLOAD_FIELD_SHAPES)) {
    if (!(field in payload) || payload[field] === null || payload[field] === undefined) {
      continue;
    }
    const value = payload[field];
    if (rule.type === 'string') {
      if (typeof value !== 'string') errors.push(`${field} must be a string`);
    }
    if (rule.in && !rule.in.includes(value)) {
      errors.push(`${field} must be one of ${rule.in.join(', ')}`);
    }
    if (rule.number && typeof value !== 'number') {
      errors.push(`${field} must be a number`);
    }
    if (rule.number === true && rule.positive && !(typeof value === 'number' && value > 0)) {
      errors.push(`${field} must be positive`);
    }
    if (rule.number === true && rule.nonnegative && !(typeof value === 'number' && value >= 0)) {
      errors.push(`${field} must be non-negative`);
    }
    if (rule.integer && !Number.isInteger(value)) {
      errors.push(`${field} must be an integer`);
    }
    if (rule.integer && rule.positive && !(Number.isInteger(value) && value > 0)) {
      errors.push(`${field} must be positive`);
    }
    if (rule.boolean && typeof value !== 'boolean') {
      errors.push(`${field} must be a boolean`);
    }
    if (rule.date && !dateOk(value)) {
      errors.push(`${field} must be an ISO date-time`);
    }
    if (rule.digits && !(typeof value === 'string' && new RegExp(`^\\d{${rule.digits}}$`).test(value))) {
      errors.push(`${field} must be exactly ${rule.digits} digits`);
    }
    if (rule.shortText && !shortTextOk(value)) {
      errors.push(`${field} must be a short non-empty string`);
    }
  }
  for (const required of REQUIRED_FIELDS_BY_TYPE[factType] || []) {
    const value = payload[required];
    if (value === null || value === undefined) {
      errors.push(`${required} is required for ${factType}`);
    }
  }
  // Amount/date role consistency: the declared role must match the field that
  // actually carries the money, and its date role must exist.
  const amountRole = payload.amountRole;
  if (amountRole && !AMOUNT_ROLES.includes(amountRole)) {
    errors.push(`amountRole must be one of ${AMOUNT_ROLES.join(', ')}`);
  }
  if (amountRole && AMOUNT_FIELD_BY_ROLE[amountRole]) {
    const amountField = AMOUNT_FIELD_BY_ROLE[amountRole];
    if (typeof payload[amountField] !== 'number' || payload[amountField] <= 0) {
      errors.push(`amountRole '${amountRole}' requires a positive ${amountField}`);
    }
    const dateField = PROVISION_BY_ROLE[amountRole];
    if (dateField && (payload[dateField] === null || payload[dateField] === undefined)) {
      errors.push(`amountRole '${amountRole}' requires ${dateField}`);
    }
  }
  // Guard the core invariant the classification plan lives by: non-posted
  // families must not claim a posted amount, and posted movements must not
  // borrow due/ceiling roles.
  if (NON_POSTED_TYPES.has(factType) && payload.amountRole !== undefined && payload.amountRole !== null &&
      payload.amountRole !== 'proposed' &&
      !(factType === 'mandate_lifecycle' && payload.amountRole === 'ceiling')) {
    if (factType === 'bill_obligation') {
      // Obligations may use due/outstanding roles; posted is never right.
      if (payload.amountRole === 'posted') {
        errors.push(`${factType} must not use amountRole 'posted'`);
      }
    } else {
      errors.push(`${factType} must not carry a due/posted amount role`);
    }
  }
  // A completed bill payment is an actual posted transfer with bill context.
  // Keep it distinct from an amount-due obligation while allowing the
  // transaction projection to consume the evidenced amountInr.
  if (factType === 'bill_payment') {
    if (payload.amountRole !== 'posted') {
      errors.push("bill_payment must use amountRole 'posted'");
    }
    if (payload.entryKind !== undefined && payload.entryKind !== 'transfer') {
      errors.push("bill_payment entryKind, when supplied, must be 'transfer'");
    }
  }
  if (factType === 'mandate_lifecycle' && payload.limitInr !== undefined) {
    if (payload.mandateStatus !== 'registered') {
      errors.push('limitInr is only meaningful for a registered mandate');
    }
  }
  // A registered mandate may omit its ceiling. The lifecycle and named
  // service evidence still establish authorization presence; the ceiling is
  // optional authorization metadata and must never gate classification.
  if (factType === 'posted_movement') {
    if (payload.entryKind === 'spend' && (payload.merchant === null || payload.merchant === undefined)) {
      errors.push("posted spend requires merchant");
    }
    if (payload.entryKind === 'transfer' && payload.amountRole && payload.amountRole !== 'posted') {
      errors.push('posted transfer must use amountRole posted');
    }
  }
  if (factType === 'security_or_service_alert') {
    if (payload.alertKind === 'otp' && payload.amountRole !== undefined) {
      errors.push('an OTP alert never carries an amount');
    }
  }
  return { valid: errors.length === 0, errors };
}

function validateFact(fact) {
  if (!isPlainObject(fact)) return { valid: false, errors: ['fact must be an object'] };
  const errors = [];
  if (typeof fact.factType !== 'string' || !FACT_TYPES.includes(fact.factType)) {
    errors.push(`factType must be one of ${FACT_TYPES.join(', ')}`);
    return { valid: false, errors };
  }
  if (
    fact.factIndex !== undefined &&
    fact.factIndex !== null &&
    !(Number.isInteger(fact.factIndex) && fact.factIndex >= 0)
  ) {
    errors.push('factIndex must be a non-negative integer');
  }
  const payloadCheck = validatePayload(fact.factType, fact.payload);
  if (!payloadCheck.valid) errors.push(...payloadCheck.errors);
  return { valid: errors.length === 0, errors };
}

function validateFactSet(facts) {
  const errors = [];
  for (const [index, fact] of (facts || []).entries()) {
    const result = validateFact(fact);
    if (!result.valid) {
      errors.push(`facts[${index}]: ${result.errors.join('; ')}`);
    }
  }
  return { valid: errors.length === 0, errors };
}

/** Canonical string so fact ordering is identical on every platform. */
function canonicalFactString(fact) {
  return JSON.stringify([fact.factType, fact.payload, fact.provenance || {}]);
}

/**
 * Assigns deterministic fact_index values: a stable sort of the fact content
 * itself, so replaying a source always maps fact N to the same slot. The
 * comparison is code-unit order, matching Dart's Asia/Kolkata-independent
 * compareTo, not localeCompare (which varies by machine locale).
 */
function assignDeterministicIndices(facts) {
  return facts
    .map((fact, order) => ({ fact, order, canonical: canonicalFactString(fact) }))
    .sort(
      (a, b) =>
        (a.canonical < b.canonical ? -1 : a.canonical > b.canonical ? 1 : 0) ||
        a.order - b.order,
    )
    .map((entry, factIndex) => ({ ...entry.fact, factIndex }));
}

/**
 * Deep-merges a user patch over a base payload. The user correction wins any
 * collision; keys the user never touched keep the parser value.
 */
function applyOverride(basePayload, patch) {
  if (!isPlainObject(basePayload) || !isPlainObject(patch)) {
    return { ...basePayload };
  }
  return { ...basePayload, ...patch };
}

/**
 * Resolve facts for consumption: override first, then validation of the
 * merged result. An invalid merged payload is refused (kept as an error) —
 * never silently fallen back to the parser's number, per no-fake-success.
 */
function resolveFactsWithOverrides({ facts, overrides }) {
  const byIndex = new Map(facts.map((fact) => [fact.factIndex, fact]));
  const errors = [];
  for (const [factIndex, patch] of overrides.entries()) {
    const base = byIndex.get(factIndex);
    if (!base) {
      errors.push(`override for fact ${factIndex} has no matching fact on this source`);
      continue;
    }
    const merged = applyOverride(base.payload, patch);
    const check = validateFact({ ...base, payload: merged });
    byIndex.set(factIndex, { ...base, payload: merged, overridden: true });
    if (!check.valid) errors.push(...check.errors);
  }
  const resolved = [];
  for (const fact of facts) {
    resolved.push(byIndex.get(fact.factIndex) || fact);
  }
  return { facts: resolved, errors };
}

/**
 * SHA-256 of the normalized body — mirrors device-side hashing. The raw body
 * itself must never reach this module.
 */
function bodyHashOf(sender, body) {
  return crypto
    .createHash('sha256')
    .update(
      JSON.stringify([String(sender || '').toUpperCase(), String(body || '')]),
    )
    .digest('hex');
}

/**
 * Writes (or replaces) the user correction for one fact slot. The upsert
 * re-player never calls this, so a correction survives every replay. The
 * patch itself is validated by the caller via resolveFactsWithOverrides
 * before this write happens.
 */
async function writeSmsFactOverride(
  client,
  profileId,
  { sourceId, factIndex, patch, reason },
) {
  await client.query(
    `INSERT INTO fact_overrides (profile_id, source_id, fact_index, patch, reason)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (source_id, fact_index)
     DO UPDATE SET patch = EXCLUDED.patch, reason = EXCLUDED.reason, applied_at = now()`,
    [profileId, sourceId, factIndex, JSON.stringify(patch), reason || null],
  );
}

/**
 * Upserts one source envelope + its fact set. Replaying the same source
 * (same sourceKey) re-uses the existing envelope and, because fact indices
 * are deterministic, leaves the fact rows — and fact IDs — untouched.
 * fact_overrides is never written here, so user corrections survive replays.
 * `client` is an open pg client (must already be inside a user transaction);
 * `profileId` scopes every row.
 */
async function upsertSmsSourceFacts(
  client,
  profileId,
  { sender, bodyHash, sourceKey, facts, occurredAt, channel = 'sms', indexOffset = 0 },
) {
  if (!Array.isArray(facts) || facts.length === 0) {
    throw new Error('facts must be a non-empty array');
  }
  if (!Number.isInteger(indexOffset) || indexOffset < 0) {
    throw new Error('indexOffset must be a non-negative integer');
  }
  const indexed = assignDeterministicIndices(facts).map((fact) => ({
    ...fact,
    factIndex: fact.factIndex + indexOffset,
  }));
  for (const fact of indexed) {
    if (fact.factIndex === undefined) throw new Error('indexing failed');
  }

  const sourceResult = await client.query(
    `INSERT INTO sms_sources
       (profile_id, source_key, sender, body_hash, channel, contract_version)
     VALUES ($1, $2, $3, $4, $5, $6)
     ON CONFLICT (profile_id, source_key) DO NOTHING
     RETURNING id`,
    [profileId, sourceKey, sender || null, bodyHash, channel, CONTRACT_VERSION],
  );
  let sourceId = sourceResult.rows[0]?.id || null;
  if (!sourceId) {
    const existing = await client.query(
      `SELECT id FROM sms_sources WHERE profile_id = $1 AND source_key = $2`,
      [profileId, sourceKey],
    );
    sourceId = existing.rows[0].id;
    await client.query(
      `UPDATE sms_sources SET updated_at = now() WHERE id = $1`,
      [sourceId],
    );
  }

  const factIds = new Map(); // factIndex -> fact uuid
  for (const fact of indexed) {
    const result = await client.query(
      `INSERT INTO sms_source_facts
         (source_id, profile_id, fact_index, fact_type, payload, provenance, status, contract_version)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       ON CONFLICT (source_id, fact_index) DO UPDATE
         SET updated_at = now()
       RETURNING id`,
      [
        sourceId,
        profileId,
        fact.factIndex,
        fact.factType,
        JSON.stringify(fact.payload || {}),
        JSON.stringify(fact.provenance || {}),
        fact.status || 'active',
        CONTRACT_VERSION,
      ],
    );
    factIds.set(fact.factIndex, result.rows[0].id);
  }

  return {
    sourceId,
    factIds: indexed.map((fact) => ({
      factIndex: fact.factIndex,
      id: factIds.get(fact.factIndex),
    })),
    replayed: sourceResult.rows.length === 0,
  };
}

/** Reads a source with its fact rows and applies user overrides. */
async function loadSmsSourceFacts(client, profileId, sourceKey) {
  const source = await client.query(
    `SELECT id, sender, body_hash, contract_version, first_seen_at, updated_at
       FROM sms_sources WHERE profile_id = $1 AND source_key = $2`,
    [profileId, sourceKey],
  );
  if (source.rows.length === 0) return null;
  const facts = (
    await client.query(
      `SELECT id, fact_index, fact_type, payload, provenance, status, contract_version
         FROM sms_source_facts WHERE source_id = $1 ORDER BY fact_index`,
      [source.rows[0].id],
    )
  ).rows.map((row) => ({
    id: row.id,
    factIndex: row.fact_index,
    factType: row.fact_type,
    payload: row.payload,
    provenance: row.provenance,
    status: row.status,
    contractVersion: row.contract_version,
  }));
  const overrides = (
    await client.query(
      `SELECT fact_index, patch FROM fact_overrides WHERE source_id = $1 ORDER BY fact_index`,
      [source.rows[0].id],
    )
  ).rows;

  const resolution = resolveFactsWithOverrides({
    facts,
    overrides: new Map(overrides.map((o) => [o.fact_index, o.patch])),
  });

  return {
    sourceId: source.rows[0].id,
    sourceKey,
    sender: source.rows[0].sender,
    bodyHash: source.rows[0].body_hash,
    contractVersion: source.rows[0].contract_version,
    facts: resolution.facts,
    errors: resolution.errors,
  };
}

module.exports = {
  CONTRACT_VERSION,
  FACT_TYPES,
  FACT_STATUSES,
  ENTRY_KINDS,
  INSTRUMENTS,
  SPEND_CATEGORIES,
  AMOUNT_ROLES,
  AMOUNT_FIELD_BY_ROLE,
  PROVISION_BY_ROLE,
  REQUIRED_FIELDS_BY_TYPE,
  validatePayload,
  validateFact,
  validateFactSet,
  assignDeterministicIndices,
  canonicalFactString,
  applyOverride,
  resolveFactsWithOverrides,
  bodyHashOf,
  upsertSmsSourceFacts,
  loadSmsSourceFacts,
  writeSmsFactOverride,
};
