'use strict';

// SMS pipeline v2 / WP-08: storage for POST /sms/v2/facts:batch and
// GET /sms/v2/sync. Every function takes a pg `client` that is already inside
// withUserClient(profileId, ...), so RLS applies. Writes are bulk statements
// over jsonb_to_recordset: the number of queries per request does not grow with
// the number of items (only card-state updates, which run the existing
// per-transaction reward machinery, are per row, and only for new card spends).

const { isDeepStrictEqual } = require('node:util');
const { projectEvent, movesCardState } = require('./projection');

// ---------- SQL fragments: contract-shaped JSON built in the database ----------

// ISO-8601 UTC with the fractional part only when it is not zero.
const ts = (c) => `(to_char(${c} at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS') || coalesce(nullif('.' || rtrim(to_char(${c} at time zone 'UTC','US'),'0'),'.'),'') || 'Z')`;
// Same instant at microsecond precision, used only for sync cursors.
const cursorTs = (c) => `to_char(${c} at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;

const endpointSql = (side) => `case
    when ${side}_instrument_id is not null then jsonb_build_object('instrumentId', ${side}_instrument_id)
    when ${side}_external is not null then jsonb_build_object('external', ${side}_external)
    else jsonb_build_object('ownUnresolved', ${side}_own_unresolved) end`;

const INSTRUMENT_DOC = `jsonb_build_object(
  'instrumentId', instrument_id, 'kind', kind, 'issuerSlug', issuer_slug, 'maskDigits', mask_digits,
  'maskLength', mask_length, 'displayName', display_name, 'status', status, 'userCardId', user_card_id,
  'parentInstrumentId', parent_instrument_id, 'aliases', aliases, 'creditLimitMinor', credit_limit_minor,
  'creditLimitSource', credit_limit_source, 'creditLimitAt', ${ts('credit_limit_at')},
  'availableMinor', available_minor, 'availableAt', ${ts('available_at')}, 'pointsBalance', points_balance,
  'pointsAt', ${ts('points_at')}, 'firstSeenAt', ${ts('first_seen_at')}, 'lastSeenAt', ${ts('last_seen_at')},
  'evidenceCount', evidence_count)`;

const EVENT_DOC = `jsonb_build_object(
  'eventId', event_id, 'type', type, 'status', status, 'legs', legs, 'linkRuleId', link_rule_id,
  'confidence', confidence, 'occurredAt', ${ts('occurred_at')}, 'amountMinor', amount_minor)`;

const FACT_DOC = `(payload - 'senderBrand' - 'bodyHash') || jsonb_build_object(
  'contractVersion', contract_version, 'factId', fact_id, 'sourceKey', source_key,
  'factType', fact_type, 'observedAt', ${ts('observed_at')}, 'occurredAt', ${ts('occurred_at')},
  'provenance', provenance, 'evidence', '[]'::jsonb)`;

const LEDGER_DOC = `jsonb_build_object(
  'entryId', entry_id, 'eventId', event_id, 'from', ${endpointSql('from')}, 'to', ${endpointSql('to')},
  'amountMinor', amount_minor, 'unit', unit, 'occurredAt', ${ts('occurred_at')}, 'category', category_slug,
  'categorySource', category_source, 'countsAsTransaction', counts_as_transaction, 'isSpend', is_spend,
  'isIncome', is_income, 'isInvestment', is_investment)`;

// ---------- pure rules (unit-tested without a database) ----------

const later = (a, b) => Date.parse(a) > Date.parse(b);

// Timestamps compare as instants, so "…:20Z" and "…:20.000Z" are the same value.
const UTC_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?Z$/;
function canon(v) {
  if (typeof v === 'string') return UTC_RE.test(v) ? Date.parse(v) : v;
  if (Array.isArray(v)) return v.map(canon);
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, canon(x)]));
  return v;
}
const sameDoc = (a, b) => isDeepStrictEqual(canon(a), canon(b));
function ledgerMoney(entry) {
  const { category, categorySource, ...money } = entry;
  return money;
}

// Keep the value with the later timestamp; a missing value never wins.
function pickLatest(exVal, exAt, incVal, incAt) {
  if (incVal === null || incVal === undefined) return [exVal ?? null, exAt ?? null];
  if (exVal === null || exVal === undefined) return [incVal, incAt ?? null];
  if (exAt && (!incAt || later(exAt, incAt))) return [exVal, exAt];
  return [incVal, incAt ?? null];
}

/** Merges an uploaded instrument into the stored one (same instrumentId). */
function mergeInstrument(ex, inc) {
  const m = { ...inc };
  // Detection is automatic; confirmed/rejected are explicit user decisions.
  if (inc.status === 'detected' && ex.status !== 'detected') m.status = ex.status;
  const exUser = ex.creditLimitSource === 'user';
  const incUser = inc.creditLimitSource === 'user';
  let limit;
  if (ex.creditLimitMinor !== null && exUser && !incUser) {
    limit = [ex.creditLimitMinor, ex.creditLimitAt, ex.creditLimitSource]; // a user-entered limit is never overwritten by SMS
  } else if (inc.creditLimitMinor !== null && incUser && !exUser) {
    limit = [inc.creditLimitMinor, inc.creditLimitAt, inc.creditLimitSource];
  } else {
    const [v, at] = pickLatest(ex.creditLimitMinor, ex.creditLimitAt, inc.creditLimitMinor, inc.creditLimitAt);
    limit = [v, at, v === null ? null : (v === inc.creditLimitMinor ? inc.creditLimitSource : ex.creditLimitSource)];
  }
  [m.creditLimitMinor, m.creditLimitAt, m.creditLimitSource] = limit;
  [m.availableMinor, m.availableAt] = pickLatest(ex.availableMinor, ex.availableAt, inc.availableMinor, inc.availableAt);
  [m.pointsBalance, m.pointsAt] = pickLatest(ex.pointsBalance, ex.pointsAt, inc.pointsBalance, inc.pointsAt);
  m.userCardId = inc.userCardId ?? ex.userCardId ?? null;
  m.parentInstrumentId = inc.parentInstrumentId ?? ex.parentInstrumentId ?? null;
  m.firstSeenAt = later(ex.firstSeenAt, inc.firstSeenAt) ? inc.firstSeenAt : ex.firstSeenAt;
  m.lastSeenAt = later(inc.lastSeenAt, ex.lastSeenAt) ? inc.lastSeenAt : ex.lastSeenAt;
  m.evidenceCount = Math.max(ex.evidenceCount, inc.evidenceCount);
  return m;
}

// awaiting_leg -> complete | ambiguous; ambiguous -> complete; anything ->
// user_confirmed; nothing leaves user_confirmed.
const STATUS_NEXT = Object.freeze({
  awaiting_leg: new Set(['awaiting_leg', 'complete', 'ambiguous', 'user_confirmed']),
  ambiguous: new Set(['ambiguous', 'complete', 'user_confirmed']),
  complete: new Set(['complete', 'user_confirmed']),
  user_confirmed: new Set(['user_confirmed']),
});

/**
 * Merges an uploaded event into the stored one. Legs only grow: the result is
 * the stored legs followed by any new ones. Returns {ok, merged, changed} or
 * {ok:false, code}.
 */
function mergeEvent(ex, inc) {
  if (!ex) return { ok: true, merged: inc, changed: true };
  if (!STATUS_NEXT[ex.status].has(inc.status)) {
    return { ok: false, code: ex.status === 'user_confirmed' ? 'event_status_locked' : 'event_status_transition_invalid' };
  }
  if (inc.status === 'user_confirmed') {
    return { ok: true, merged: inc, changed: !sameDoc(inc, ex) };
  }
  const roleById = new Map(ex.legs.map((l) => [l.factId, l.role]));
  const legs = ex.legs.map((l) => ({ factId: l.factId, role: l.role }));
  for (const l of inc.legs) {
    if (!roleById.has(l.factId)) {
      roleById.set(l.factId, l.role);
      legs.push({ factId: l.factId, role: l.role });
    } else if (roleById.get(l.factId) !== l.role) {
      return { ok: false, code: 'event_leg_role_conflict' };
    }
  }
  const merged = { ...inc, legs };
  return { ok: true, merged, changed: !sameDoc(merged, ex) };
}

/** The amount an own -> own ledger entry must equal, or null when unconstrained. */
function ownEntryLegAmounts(legs, postedByFact) {
  const pick = (role) => legs.filter((l) => l.role === role)
    .map((l) => postedByFact.get(l.factId)).filter((v) => v !== undefined && v !== null);
  const debit = pick('debit_leg');
  if (debit.length) return debit;
  const credit = pick('credit_leg');
  return credit.length ? credit : null;
}

const isOwnEndpoint = (e) => e && (e.instrumentId !== undefined || e.ownUnresolved !== undefined);

// ---------- row builders ----------

const instrumentRow = (i) => ({
  instrument_id: i.instrumentId, kind: i.kind, issuer_slug: i.issuerSlug, mask_digits: i.maskDigits, mask_length: i.maskLength,
  display_name: i.displayName, status: i.status, user_card_id: i.userCardId, parent_instrument_id: i.parentInstrumentId,
  aliases: i.aliases, credit_limit_minor: i.creditLimitMinor, credit_limit_source: i.creditLimitSource, credit_limit_at: i.creditLimitAt,
  available_minor: i.availableMinor, available_at: i.availableAt, points_balance: i.pointsBalance, points_at: i.pointsAt,
  first_seen_at: i.firstSeenAt, last_seen_at: i.lastSeenAt, evidence_count: i.evidenceCount,
});
const INSTRUMENT_COLS = `instrument_id uuid, kind text, issuer_slug text, mask_digits text, mask_length int, display_name text,
  status text, user_card_id uuid, parent_instrument_id uuid, aliases jsonb, credit_limit_minor bigint, credit_limit_source text,
  credit_limit_at timestamptz, available_minor bigint, available_at timestamptz, points_balance bigint, points_at timestamptz,
  first_seen_at timestamptz, last_seen_at timestamptz, evidence_count int`;

const eventRow = (e) => ({
  event_id: e.eventId, type: e.type, status: e.status, legs: e.legs, link_rule_id: e.linkRuleId, confidence: e.confidence,
  occurred_at: e.occurredAt, amount_minor: e.amountMinor,
});
const EVENT_COLS = `event_id text, type text, status text, legs jsonb, link_rule_id text, confidence float8,
  occurred_at timestamptz, amount_minor bigint`;

const endpointCols = (side, e) => ({
  [`${side}_instrument_id`]: e.instrumentId ?? null,
  [`${side}_external`]: e.external ?? null,
  [`${side}_own_unresolved`]: e.ownUnresolved ?? null,
});
const ledgerRow = (l) => ({
  entry_id: l.entryId, event_id: l.eventId, ...endpointCols('from', l.from), ...endpointCols('to', l.to),
  amount_minor: l.amountMinor, unit: l.unit, occurred_at: l.occurredAt, category_slug: l.category, category_source: l.categorySource,
  counts_as_transaction: l.countsAsTransaction, is_spend: l.isSpend, is_income: l.isIncome, is_investment: l.isInvestment,
});
const LEDGER_COLS = `entry_id text, event_id text, from_instrument_id uuid, from_external text, from_own_unresolved text,
  to_instrument_id uuid, to_external text, to_own_unresolved text, amount_minor bigint, unit text, occurred_at timestamptz,
  category_slug text, category_source text, counts_as_transaction boolean, is_spend boolean, is_income boolean, is_investment boolean`;

function factRow(item, fact) {
  const {
    contractVersion, factId, sourceKey, factType, observedAt, occurredAt, provenance, evidence, ...rest // eslint-disable-line no-unused-vars
  } = fact;
  const mention = rest.instrument ? { ...rest.instrument, raw: null } : null; // raw tokens never leave the phone
  return {
    fact_id: factId, source_key: sourceKey, fact_type: factType, contract_version: contractVersion, observed_at: observedAt,
    occurred_at: occurredAt, i_kind: mention ? mention.kind : null, i_issuer: mention ? mention.issuerSlug : null,
    i_mask: mention ? mention.maskDigits : null,
    payload: { ...rest, instrument: mention, senderBrand: item.senderBrand, bodyHash: item.bodyHash },
    provenance,
  };
}

const J = (v) => JSON.stringify(v);
const rej = (id, kind, code, path = '') => ({ id, kind, status: 'rejected', errors: [{ code, path }] });
const ok = (id, kind, status) => ({ id, kind, status });

// ---------- ingest ----------

async function takeProfileLock(client, profileId) {
  // Same key insertTransactionAndUpdateState takes, so v1 and v2 writers for one
  // profile never interleave; it also makes updated_at monotonic per profile.
  await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))', [`transaction-ingest:${profileId}`]);
}

// Inserts new rows with ON CONFLICT DO NOTHING and returns the ids actually
// inserted. An id that exists under another profile is invisible to RLS, so it
// shows up as "not inserted" and the caller rejects it without leaking the row.
async function insertNew(client, sql, params) {
  const r = await client.query(sql, params);
  return new Set(r.rows.map((x) => x.id));
}

async function upsertInstruments(client, profileId, instruments, results) {
  if (!instruments.length) return;
  const seenIds = new Set();
  const keyOwner = new Map();
  const list = [];
  for (const inst of instruments) {
    if (seenIds.has(inst.instrumentId)) { results.push(ok(inst.instrumentId, 'instrument', 'duplicate')); continue; }
    seenIds.add(inst.instrumentId);
    const key = `${inst.kind}|${inst.issuerSlug}|${inst.maskDigits || ''}`;
    if (keyOwner.has(key)) {
      results.push(rej(inst.instrumentId, 'instrument', 'instrument_key_conflict', `existingInstrumentId:${keyOwner.get(key)}`));
      continue;
    }
    keyOwner.set(key, inst.instrumentId);
    list.push(inst);
  }
  if (!list.length) return;

  const cardIds = [...new Set(list.map((i) => i.userCardId).filter(Boolean))];
  const knownCards = new Set();
  if (cardIds.length) {
    const r = await client.query('SELECT id FROM user_cards WHERE profile_id = $1 AND id = ANY($2::uuid[])', [profileId, cardIds]);
    r.rows.forEach((x) => knownCards.add(x.id));
  }
  const valid = [];
  for (const inst of list) {
    if (inst.userCardId && !knownCards.has(inst.userCardId)) {
      results.push(rej(inst.instrumentId, 'instrument', 'instrument_user_card_unknown', '/userCardId'));
    } else valid.push(inst);
  }
  if (!valid.length) return;

  const conflicts = await client.query(
    `SELECT r.instrument_id AS incoming, i.instrument_id AS existing
       FROM jsonb_to_recordset($2::jsonb) AS r(instrument_id uuid, kind text, issuer_slug text, mask_digits text)
       JOIN sms_v2_instruments i ON i.profile_id = $1 AND i.kind = r.kind AND i.issuer_slug = r.issuer_slug
                                AND coalesce(i.mask_digits, '') = coalesce(r.mask_digits, '')
      WHERE i.instrument_id <> r.instrument_id`,
    [profileId, J(valid.map((i) => ({ instrument_id: i.instrumentId, kind: i.kind, issuer_slug: i.issuerSlug, mask_digits: i.maskDigits })))],
  );
  const conflictOf = new Map(conflicts.rows.map((x) => [x.incoming, x.existing]));
  const live = [];
  for (const inst of valid) {
    if (conflictOf.has(inst.instrumentId)) {
      results.push(rej(inst.instrumentId, 'instrument', 'instrument_key_conflict', `existingInstrumentId:${conflictOf.get(inst.instrumentId)}`));
    } else live.push(inst);
  }
  if (!live.length) return;

  const existingRows = await client.query(
    `SELECT instrument_id AS id, ${INSTRUMENT_DOC} AS doc FROM sms_v2_instruments
      WHERE profile_id = $1 AND instrument_id = ANY($2::uuid[])`,
    [profileId, live.map((i) => i.instrumentId)],
  );
  const existing = new Map(existingRows.rows.map((x) => [x.id, x.doc]));

  const toInsert = [];
  const toUpdate = [];
  for (const inst of live) {
    const ex = existing.get(inst.instrumentId);
    if (!ex) { toInsert.push(inst); continue; }
    const merged = mergeInstrument(ex, inst);
    if (sameDoc(merged, ex)) results.push(ok(inst.instrumentId, 'instrument', 'duplicate'));
    else toUpdate.push(merged);
  }

  if (toInsert.length) {
    const inserted = await insertNew(
      client,
      `INSERT INTO sms_v2_instruments (instrument_id, profile_id, kind, issuer_slug, mask_digits, mask_length, display_name, status,
         user_card_id, parent_instrument_id, aliases, credit_limit_minor, credit_limit_source, credit_limit_at, available_minor,
         available_at, points_balance, points_at, first_seen_at, last_seen_at, evidence_count, updated_at)
       SELECT r.instrument_id, $1, r.kind, r.issuer_slug, r.mask_digits, r.mask_length, r.display_name, r.status, r.user_card_id,
              r.parent_instrument_id, r.aliases, r.credit_limit_minor, r.credit_limit_source, r.credit_limit_at, r.available_minor,
              r.available_at, r.points_balance, r.points_at, r.first_seen_at, r.last_seen_at, r.evidence_count, clock_timestamp()
         FROM jsonb_to_recordset($2::jsonb) AS r(${INSTRUMENT_COLS})
       ON CONFLICT (instrument_id) DO NOTHING
       RETURNING instrument_id AS id`,
      [profileId, J(toInsert.map(instrumentRow))],
    );
    for (const inst of toInsert) {
      results.push(inserted.has(inst.instrumentId) ? ok(inst.instrumentId, 'instrument', 'accepted') : rej(inst.instrumentId, 'instrument', 'instrument_id_conflict', '/instrumentId'));
    }
  }
  if (toUpdate.length) {
    await client.query(
      `UPDATE sms_v2_instruments i
          SET kind = r.kind, issuer_slug = r.issuer_slug, mask_digits = r.mask_digits, mask_length = r.mask_length,
              display_name = r.display_name, status = r.status, user_card_id = r.user_card_id,
              parent_instrument_id = r.parent_instrument_id, aliases = r.aliases, credit_limit_minor = r.credit_limit_minor,
              credit_limit_source = r.credit_limit_source, credit_limit_at = r.credit_limit_at,
              available_minor = r.available_minor, available_at = r.available_at, points_balance = r.points_balance,
              points_at = r.points_at, first_seen_at = r.first_seen_at, last_seen_at = r.last_seen_at,
              evidence_count = r.evidence_count, updated_at = clock_timestamp()
         FROM jsonb_to_recordset($2::jsonb) AS r(${INSTRUMENT_COLS})
        WHERE i.instrument_id = r.instrument_id AND i.profile_id = $1`,
      [profileId, J(toUpdate.map(instrumentRow))],
    );
    toUpdate.forEach((m) => results.push(ok(m.instrumentId, 'instrument', 'accepted')));
  }
}

async function insertFacts(client, profileId, items, results) {
  const rows = [];
  const seen = new Set();
  for (const item of items) {
    for (const fact of item.facts) {
      if (seen.has(fact.factId)) { results.push(ok(fact.factId, 'fact', 'duplicate')); continue; }
      seen.add(fact.factId);
      rows.push(factRow(item, fact));
    }
  }
  if (!rows.length) return;
  const inserted = await insertNew(
    client,
    `INSERT INTO sms_v2_facts (fact_id, profile_id, source_key, fact_type, contract_version, observed_at, occurred_at,
       instrument_id, payload, provenance)
     SELECT r.fact_id, $1, r.source_key, r.fact_type, r.contract_version, r.observed_at, r.occurred_at,
            (SELECT i.instrument_id FROM sms_v2_instruments i
              WHERE i.profile_id = $1 AND i.kind = r.i_kind AND i.issuer_slug = r.i_issuer AND i.mask_digits = r.i_mask),
            r.payload, r.provenance
       FROM jsonb_to_recordset($2::jsonb) AS r(fact_id text, source_key text, fact_type text, contract_version text,
         observed_at timestamptz, occurred_at timestamptz, i_kind text, i_issuer text, i_mask text, payload jsonb, provenance jsonb)
     ON CONFLICT (fact_id) DO NOTHING
     RETURNING fact_id AS id`,
    [profileId, J(rows)],
  );
  const missed = rows.filter((r) => !inserted.has(r.fact_id)).map((r) => r.fact_id);
  let ours = new Set();
  if (missed.length) {
    const r = await client.query('SELECT fact_id AS id FROM sms_v2_facts WHERE profile_id = $1 AND fact_id = ANY($2::text[])', [profileId, missed]);
    ours = new Set(r.rows.map((x) => x.id));
  }
  for (const row of rows) {
    if (inserted.has(row.fact_id)) results.push(ok(row.fact_id, 'fact', 'accepted'));
    else if (ours.has(row.fact_id)) results.push(ok(row.fact_id, 'fact', 'duplicate'));
    else results.push(rej(row.fact_id, 'fact', 'fact_id_conflict', '/factId'));
  }
}

async function upsertEvents(client, profileId, events, results) {
  const stored = []; // events written by this call (new or changed), contract shape
  if (!events.length) return stored;
  const ids = [...new Set(events.map((e) => e.eventId))];
  const existingRows = await client.query(
    `SELECT event_id AS id, ${EVENT_DOC} AS doc FROM sms_v2_events WHERE profile_id = $1 AND event_id = ANY($2::text[]) FOR UPDATE`,
    [profileId, ids],
  );
  const current = new Map(existingRows.rows.map((x) => [x.id, x.doc]));
  const fromDb = new Set(current.keys());

  const legIds = [...new Set(events.flatMap((e) => e.legs.map((l) => l.factId)))];
  const known = new Set();
  if (legIds.length) {
    const r = await client.query('SELECT fact_id AS id FROM sms_v2_facts WHERE profile_id = $1 AND fact_id = ANY($2::text[])', [profileId, legIds]);
    r.rows.forEach((x) => known.add(x.id));
  }

  const outcome = new Map(); // eventId -> result entry (last write wins for repeats in one request)
  const written = new Set();
  const order = [];
  for (const inc of events) {
    const missing = inc.legs.findIndex((l) => !known.has(l.factId));
    if (missing >= 0) { outcome.set(inc.eventId, rej(inc.eventId, 'event', 'event_leg_fact_unknown', `/legs/${missing}/factId`)); continue; }
    const m = mergeEvent(current.get(inc.eventId), inc);
    if (!m.ok) { outcome.set(inc.eventId, rej(inc.eventId, 'event', m.code, '/status')); continue; }
    if (!m.changed) { outcome.set(inc.eventId, ok(inc.eventId, 'event', 'duplicate')); continue; }
    current.set(inc.eventId, m.merged);
    if (!written.has(inc.eventId)) order.push(inc.eventId);
    written.add(inc.eventId);
    outcome.set(inc.eventId, ok(inc.eventId, 'event', 'accepted'));
  }

  const toInsert = order.filter((id) => !fromDb.has(id)).map((id) => current.get(id));
  const toUpdate = order.filter((id) => fromDb.has(id)).map((id) => current.get(id));
  if (toInsert.length) {
    const inserted = await insertNew(
      client,
      `INSERT INTO sms_v2_events (event_id, profile_id, type, status, legs, link_rule_id, confidence, occurred_at, amount_minor, updated_at)
       SELECT r.event_id, $1, r.type, r.status, r.legs, r.link_rule_id, r.confidence, r.occurred_at, r.amount_minor, clock_timestamp()
         FROM jsonb_to_recordset($2::jsonb) AS r(${EVENT_COLS})
       ON CONFLICT (event_id) DO NOTHING
       RETURNING event_id AS id`,
      [profileId, J(toInsert.map(eventRow))],
    );
    for (const e of toInsert) {
      if (inserted.has(e.eventId)) stored.push(e);
      else outcome.set(e.eventId, rej(e.eventId, 'event', 'event_id_conflict', '/eventId'));
    }
  }
  if (toUpdate.length) {
    await client.query(
      `UPDATE sms_v2_events e
          SET type = r.type, status = r.status, legs = r.legs, link_rule_id = r.link_rule_id, confidence = r.confidence,
              occurred_at = r.occurred_at, amount_minor = r.amount_minor, updated_at = clock_timestamp()
         FROM jsonb_to_recordset($2::jsonb) AS r(${EVENT_COLS})
        WHERE e.event_id = r.event_id AND e.profile_id = $1`,
      [profileId, J(toUpdate.map(eventRow))],
    );
    stored.push(...toUpdate);
  }
  // One result per distinct event id; a repeat in the same request reports the final outcome.
  const reported = new Set();
  for (const inc of events) {
    if (reported.has(inc.eventId)) { results.push(ok(inc.eventId, 'event', 'duplicate')); continue; }
    reported.add(inc.eventId);
    results.push(outcome.get(inc.eventId));
  }
  return stored;
}

async function upsertLedger(client, profileId, ledger, results, { categoryOnly = false } = {}) {
  const accepted = [];
  if (!ledger.length) return accepted;
  const list = [];
  const seen = new Set();
  for (const l of ledger) {
    if (seen.has(l.entryId)) { results.push(ok(l.entryId, 'ledger', 'duplicate')); continue; }
    seen.add(l.entryId);
    list.push(l);
  }
  const eventIds = [...new Set(list.map((l) => l.eventId))];
  const evRows = await client.query(
    'SELECT event_id AS id, legs FROM sms_v2_events WHERE profile_id = $1 AND event_id = ANY($2::text[])',
    [profileId, eventIds],
  );
  const legsOf = new Map(evRows.rows.map((x) => [x.id, x.legs]));

  // Posted amounts of the debit / credit legs, for the own -> own amount rule.
  const legFactIds = new Set();
  for (const l of list) {
    if (isOwnEndpoint(l.from) && isOwnEndpoint(l.to) && legsOf.has(l.eventId)) {
      legsOf.get(l.eventId).forEach((g) => { if (g.role === 'debit_leg' || g.role === 'credit_leg') legFactIds.add(g.factId); });
    }
  }
  const posted = new Map();
  if (legFactIds.size) {
    const r = await client.query(
      `SELECT f.fact_id AS id,
              (SELECT (a->>'minor')::bigint FROM jsonb_array_elements(f.payload->'amounts') a WHERE a->>'role' = 'posted' LIMIT 1) AS minor
         FROM sms_v2_facts f WHERE f.profile_id = $1 AND f.fact_id = ANY($2::text[])`,
      [profileId, [...legFactIds]],
    );
    r.rows.forEach((x) => { if (x.minor !== null) posted.set(x.id, Number(x.minor)); });
  }

  const valid = [];
  for (const l of list) {
    if (!legsOf.has(l.eventId)) { results.push(rej(l.entryId, 'ledger', 'ledger_event_unknown', '/eventId')); continue; }
    if (l.unit === 'INR' && isOwnEndpoint(l.from) && isOwnEndpoint(l.to)) {
      const allowed = ownEntryLegAmounts(legsOf.get(l.eventId), posted);
      if (allowed && !allowed.includes(l.amountMinor)) { results.push(rej(l.entryId, 'ledger', 'ledger_own_amount_mismatch', '/amountMinor')); continue; }
    }
    valid.push(l);
  }
  if (!valid.length) return accepted;

  const existingRows = await client.query(
    `SELECT entry_id AS id, ${LEDGER_DOC} AS doc FROM sms_v2_ledger_entries WHERE profile_id = $1 AND entry_id = ANY($2::text[])`,
    [profileId, valid.map((l) => l.entryId)],
  );
  const existing = new Map(existingRows.rows.map((x) => [x.id, x.doc]));
  const toInsert = [];
  const toUpdate = [];
  const refresh = [];
  for (const l of valid) {
    const ex = existing.get(l.entryId);
    if (categoryOnly && !ex) {
      results.push(rej(l.entryId, 'ledger', 'ledger_event_unknown', '/eventId'));
      continue;
    }
    const next = ex?.categorySource === 'user' && l.categorySource !== 'user'
      ? { ...l, category: ex.category, categorySource: ex.categorySource }
      : l;
    // A historical category pass cannot replace a newer money correction.
    // Re-emit the server reading so the uploader's next pull can converge.
    if (categoryOnly && !sameDoc(ledgerMoney(l), ledgerMoney(ex))) {
      results.push(ok(l.entryId, 'ledger', 'duplicate'));
      refresh.push(ex);
    } else if (!ex) toInsert.push(next);
    else if (sameDoc(next, ex)) {
      results.push(ok(l.entryId, 'ledger', 'duplicate'));
      if (categoryOnly || !sameDoc(next, l)) refresh.push(ex);
    } else toUpdate.push(next);
  }
  if (refresh.length) {
    await client.query('UPDATE sms_v2_ledger_entries SET updated_at=clock_timestamp() WHERE profile_id=$1 AND entry_id=ANY($2::text[])', [profileId, refresh.map((entry) => entry.entryId)]);
  }
  if (toInsert.length) {
    const inserted = await insertNew(
      client,
      `INSERT INTO sms_v2_ledger_entries (entry_id, profile_id, event_id, from_instrument_id, from_external, from_own_unresolved,
         to_instrument_id, to_external, to_own_unresolved, amount_minor, unit, occurred_at, category_slug, category_source,
         counts_as_transaction, is_spend, is_income, is_investment, updated_at)
       SELECT r.entry_id, $1, r.event_id, r.from_instrument_id, r.from_external, r.from_own_unresolved, r.to_instrument_id,
              r.to_external, r.to_own_unresolved, r.amount_minor, r.unit, r.occurred_at, r.category_slug, r.category_source,
              r.counts_as_transaction, r.is_spend, r.is_income, r.is_investment, clock_timestamp()
         FROM jsonb_to_recordset($2::jsonb) AS r(${LEDGER_COLS})
       ON CONFLICT (entry_id) DO NOTHING
       RETURNING entry_id AS id`,
      [profileId, J(toInsert.map(ledgerRow))],
    );
    for (const l of toInsert) {
      if (inserted.has(l.entryId)) { results.push(ok(l.entryId, 'ledger', 'accepted')); accepted.push(l); }
      else results.push(rej(l.entryId, 'ledger', 'ledger_id_conflict', '/entryId'));
    }
  }
  if (toUpdate.length) {
    await client.query(
      `UPDATE sms_v2_ledger_entries e
          SET event_id = r.event_id, from_instrument_id = r.from_instrument_id, from_external = r.from_external,
              from_own_unresolved = r.from_own_unresolved, to_instrument_id = r.to_instrument_id, to_external = r.to_external,
              to_own_unresolved = r.to_own_unresolved, amount_minor = r.amount_minor, unit = r.unit, occurred_at = r.occurred_at,
              category_slug = r.category_slug, category_source = r.category_source,
              counts_as_transaction = r.counts_as_transaction, is_spend = r.is_spend, is_income = r.is_income,
              is_investment = r.is_investment, updated_at = clock_timestamp()
         FROM jsonb_to_recordset($2::jsonb) AS r(${LEDGER_COLS})
        WHERE e.entry_id = r.entry_id AND e.profile_id = $1`,
      [profileId, J(toUpdate.map(ledgerRow))],
    );
    toUpdate.forEach((l) => { results.push(ok(l.entryId, 'ledger', 'accepted')); accepted.push(l); });
  }
  return accepted;
}

// ---------- transactions projection ----------

const TXN_COLS = `t.id, t.event_id, t.source_key, t.pipeline_version, t.amount_inr, t.occurred_at, t.merchant_name, t.category_id, t.user_category_id,
  t.user_card_id, t.entry_kind::text AS entry_kind, t.instrument::text AS instrument, t.rail::text AS rail, t.status::text AS status,
  t.state_applied, t.is_backfill`;

const sameRow = (row, spec) => Math.round(Number(row.amount_inr) * 100) === spec.amountMinor
  && new Date(row.occurred_at).getTime() === Date.parse(spec.occurredAt)
  && (row.merchant_name || null) === (spec.merchantName || null)
  && (row.category_id || null) === (spec.categoryId || null)
  && (row.user_card_id || null) === (spec.userCardId || null)
  && row.entry_kind === spec.entryKind && row.instrument === spec.instrument && row.rail === spec.rail;

const rowMovesCard = (r) => r.entry_kind === 'spend' && r.instrument === 'credit_card' && Boolean(r.user_card_id);

async function projectTransactions(client, profileId, eventIds, { backfill, categoryOnly = false, deps }) {
  if (!eventIds.length) return { inserted: 0, updated: 0, stateApplied: 0 };
  const evRows = await client.query(`SELECT event_id AS id, ${EVENT_DOC} AS doc FROM sms_v2_events WHERE profile_id = $1 AND event_id = ANY($2::text[])`, [profileId, eventIds]);
  const events = new Map(evRows.rows.map((x) => [x.id, x.doc]));
  const ledRows = await client.query(
    `SELECT event_id, entry_id, ${ts('occurred_at')} AS occurred_at, unit, from_instrument_id, from_external, to_instrument_id, to_external, category_slug
       FROM sms_v2_ledger_entries WHERE profile_id = $1 AND event_id = ANY($2::text[])`,
    [profileId, eventIds],
  );
  const ledgerOf = new Map();
  const instrumentIds = new Set();
  for (const r of ledRows.rows) {
    const e = { entryId: r.entry_id, occurredAt: r.occurred_at, unit: r.unit, fromInstrumentId: r.from_instrument_id, fromExternal: r.from_external, toInstrumentId: r.to_instrument_id, toExternal: r.to_external, category: r.category_slug };
    if (!ledgerOf.has(r.event_id)) ledgerOf.set(r.event_id, []);
    ledgerOf.get(r.event_id).push(e);
    if (e.fromInstrumentId) instrumentIds.add(e.fromInstrumentId);
    if (e.toInstrumentId) instrumentIds.add(e.toInstrumentId);
  }
  const instruments = new Map();
  if (instrumentIds.size) {
    const r = await client.query('SELECT instrument_id AS id, kind, user_card_id, status FROM sms_v2_instruments WHERE profile_id = $1 AND instrument_id = ANY($2::uuid[])', [profileId, [...instrumentIds]]);
    r.rows.forEach((x) => instruments.set(x.id, { kind: x.kind, userCardId: x.user_card_id, status: x.status }));
  }
  const anchorRows = await client.query(
    `SELECT fact_id AS id, source_key, payload->'attrs'->>'rail' AS rail FROM sms_v2_facts WHERE profile_id = $1 AND fact_id = ANY($2::text[])`,
    [profileId, eventIds],
  );
  const anchors = new Map(anchorRows.rows.map((x) => [x.id, { sourceKey: x.source_key, rail: x.rail }]));

  const rejectedEvents = eventIds.filter((id) => (ledgerOf.get(id) || []).some((e) =>
    [e.fromInstrumentId, e.toInstrumentId].some((instId) => instId && instruments.get(instId)?.status === 'rejected')));
  if (rejectedEvents.length) {
    // The sync contract has no ledger tombstones. Re-emit the unchanged event
    // alongside the rejected instrument so clients clear/reproject its ledger.
    await client.query('DELETE FROM sms_v2_ledger_entries WHERE profile_id = $1 AND event_id = ANY($2::text[])', [profileId, rejectedEvents]);
    await client.query('UPDATE sms_v2_events SET updated_at = clock_timestamp() WHERE profile_id = $1 AND event_id = ANY($2::text[])', [profileId, rejectedEvents]);
  }

  const specs = new Map();
  for (const id of eventIds) {
    const ev = events.get(id);
    if (!ev) continue;
    const spec = projectEvent({ event: ev, ledger: ledgerOf.get(id) || [], instruments, anchor: anchors.get(id) || null });
    if (spec && spec.amountMinor < 1e12) specs.set(id, spec);
  }

  const legacySources = await client.query(
    'SELECT DISTINCT superseded_by_event_id AS id FROM transactions WHERE profile_id=$1 AND superseded_by_event_id=ANY($2::text[])',
    [profileId, eventIds],
  );
  const historyEvents = new Set(legacySources.rows.map(r => r.id));

  const slugs = [...new Set([...specs.values()].map((s) => s.categorySlug).filter(Boolean))];
  const categoryId = new Map();
  if (slugs.length) {
    const r = await client.query('SELECT slug, id FROM spend_categories WHERE slug = ANY($1::text[])', [slugs]);
    r.rows.forEach((x) => categoryId.set(x.slug, x.id));
  }
  specs.forEach((s) => { s.categoryId = s.categorySlug ? categoryId.get(s.categorySlug) || null : null; });

  const existingRows = await client.query(`SELECT ${TXN_COLS} FROM transactions t WHERE t.profile_id = $1 AND t.event_id = ANY($2::text[]) FOR UPDATE`, [profileId, eventIds]);
  const rowOf = new Map(existingRows.rows.map((r) => [r.event_id, r]));

  const cards = new Map();
  const cardFor = async (id) => {
    if (!cards.has(id)) cards.set(id, await deps.loadUserCardForState(client, profileId, id));
    return cards.get(id);
  };
  const stats = { inserted: 0, updated: 0, stateApplied: 0 };
  if (categoryOnly) {
    const updates = [];
    for (const [eventId, row] of rowOf) {
      const spec = specs.get(eventId);
      if (spec && row.status === 'active' && !row.user_category_id && (row.category_id || null) !== (spec.categoryId || null)) {
        updates.push({ id: row.id, category_id: spec.categoryId });
      }
    }
    if (updates.length) {
      await client.query(`UPDATE transactions t SET category_id=r.category_id
        FROM jsonb_to_recordset($2::jsonb) AS r(id uuid, category_id uuid)
        WHERE t.profile_id=$1 AND t.id=r.id AND t.status='active' AND t.user_category_id IS NULL`, [profileId, J(updates)]);
    }
    stats.updated = updates.length;
    return stats;
  }

  // ---- events that no longer map to a row: retire the row, undo its card state ----
  for (const [id, row] of rowOf) {
    if (specs.has(id) || !events.has(id) || row.status !== 'active') continue;
    if (row.state_applied && rowMovesCard(row)) {
      const card = await cardFor(row.user_card_id);
      if (card) await deps.reverseTransactionState(client, profileId, card, row);
    }
    await client.query(`UPDATE transactions SET status = 'ignored', state_applied = false, note = '[sms_v2: event no longer counts]' WHERE id = $1`, [row.id]);
    stats.updated += 1;
  }

  // ---- source keys: adopt a v1 row for the same message, avoid collisions ----
  const fresh = [...specs.values()].filter((s) => !rowOf.has(s.eventId));
  const adopted = new Set();
  if (fresh.length) {
    const keys = [...new Set(fresh.map((s) => s.sourceKey).filter(Boolean))];
    const held = new Map();
    if (keys.length) {
      const r = await client.query('SELECT id, source_key, event_id, status FROM transactions WHERE profile_id = $1 AND source_key = ANY($2::text[])', [profileId, keys]);
      r.rows.forEach((x) => held.set(x.source_key, x));
    }
    const used = new Set();
    const adoptions = [];
    for (const s of fresh) {
      const h = s.sourceKey ? held.get(s.sourceKey) : null;
      if (h && !h.event_id && h.status !== 'superseded' && !used.has(s.sourceKey)) {
        adoptions.push({ id: h.id, event_id: s.eventId });
        adopted.add(s.eventId);
        used.add(s.sourceKey);
      } else if (s.sourceKey && (h || used.has(s.sourceKey))) {
        s.sourceKey = `${s.sourceKey}#${s.eventId.slice(0, 12)}`; // a second event anchored on the same message
        used.add(s.sourceKey);
      } else if (s.sourceKey) used.add(s.sourceKey);
    }
    if (adoptions.length) {
      await client.query(
        `UPDATE transactions t SET event_id = r.event_id, pipeline_version = 2
           FROM jsonb_to_recordset($2::jsonb) AS r(id uuid, event_id text)
          WHERE t.id = r.id AND t.profile_id = $1`,
        [profileId, J(adoptions)],
      );
      stats.updated += adoptions.length;
    }
  }

  // ---- insert new rows ----
  const toInsert = fresh.filter((s) => !adopted.has(s.eventId));
  const newRows = [];
  if (toInsert.length) {
    const r = await client.query(
      `INSERT INTO transactions (profile_id, user_card_id, amount_inr, occurred_at, merchant_name, category_id, rail, source,
         status, reward_state, source_key, instrument, entry_kind, state_applied, is_backfill, event_id, pipeline_version)
       SELECT $1, r.user_card_id, r.amount_minor::numeric / 100, r.occurred_at, r.merchant_name, r.category_id, r.rail::txn_rail,
              'sms', 'active', 'estimated', r.source_key, r.instrument::txn_instrument, r.entry_kind::txn_entry_kind, false, r.is_backfill,
              r.event_id, 2
         FROM jsonb_to_recordset($2::jsonb) AS r(event_id text, amount_minor bigint, occurred_at timestamptz, merchant_name text,
           category_id uuid, user_card_id uuid, rail text, instrument text, entry_kind text, source_key text, is_backfill boolean)
       ON CONFLICT (profile_id, event_id) WHERE event_id IS NOT NULL DO NOTHING
       RETURNING id, event_id, amount_inr, occurred_at, merchant_name, category_id, user_card_id, rail::text AS rail,
                 entry_kind::text AS entry_kind, instrument::text AS instrument, is_backfill`,
      [profileId, J(toInsert.map((s) => ({
        event_id: s.eventId, amount_minor: s.amountMinor, occurred_at: s.occurredAt, merchant_name: s.merchantName,
        category_id: s.categoryId, user_card_id: s.userCardId, rail: s.rail, instrument: s.instrument, entry_kind: s.entryKind,
        source_key: s.sourceKey, is_backfill: backfill === true || historyEvents.has(s.eventId),
      })))],
    );
    newRows.push(...r.rows);
    stats.inserted += r.rowCount;
  }

  // ---- existing active rows: refresh, keeping card state exact ----
  const changed = [];
  for (const [id, row] of rowOf) {
    const spec = specs.get(id);
    const restoring = row.status === 'ignored' && events.get(id)?.status === 'user_confirmed';
    if (!spec || (row.status !== 'active' && !restoring)) continue;
    const merged = {
      ...spec,
      merchantName: spec.merchantName ?? row.merchant_name,
      categoryId: spec.categoryId ?? row.category_id,
      userCardId: ['credit_card', 'debit_card'].includes(spec.instrument) ? (spec.userCardId ?? row.user_card_id) : null,
    };
    if (restoring || !sameRow(row, merged)) changed.push({ row, spec: merged });
  }
  for (const { row } of changed) {
    if (row.state_applied && rowMovesCard(row)) {
      const card = await cardFor(row.user_card_id);
      if (card) await deps.reverseTransactionState(client, profileId, card, row);
    }
  }
  if (changed.length) {
    await client.query(
      `UPDATE transactions t
          SET amount_inr = r.amount_minor::numeric / 100, occurred_at = r.occurred_at, merchant_name = r.merchant_name,
              category_id = r.category_id, user_card_id = r.user_card_id, rail = r.rail::txn_rail,
              instrument = r.instrument::txn_instrument, entry_kind = r.entry_kind::txn_entry_kind,
              pipeline_version = 2, state_applied = false, status = 'active'
         FROM jsonb_to_recordset($2::jsonb) AS r(id uuid, amount_minor bigint, occurred_at timestamptz, merchant_name text,
           category_id uuid, user_card_id uuid, rail text, instrument text, entry_kind text)
        WHERE t.id = r.id AND t.profile_id = $1`,
      [profileId, J(changed.map(({ row, spec }) => ({
        id: row.id, amount_minor: spec.amountMinor, occurred_at: spec.occurredAt, merchant_name: spec.merchantName,
        category_id: spec.categoryId, user_card_id: spec.userCardId, rail: spec.rail, instrument: spec.instrument, entry_kind: spec.entryKind,
      })))],
    );
    stats.updated += changed.length;
  }

  // ---- apply card state exactly once ----
  // New rows, rows just rewritten, and rows that gained a card since they were
  // first stored. Never for backfill rows, never twice for the same row.
  const candidates = [];
  if (backfill !== true) {
    for (const r of newRows) if (!r.is_backfill && rowMovesCard(r)) candidates.push({ id: r.id, row: r });
  }
  const changedIds = new Set(changed.map((c) => c.row.id));
  for (const { row, spec } of changed) {
    if (!row.is_backfill && movesCardState(spec)) candidates.push({ id: row.id, spec });
  }
  for (const [id, row] of rowOf) {
    if (specs.has(id) && row.status === 'active' && !row.is_backfill && !changedIds.has(row.id) && !row.state_applied && rowMovesCard(row)) {
      candidates.push({ id: row.id, row });
    }
  }
  const applied = [];
  for (const c of candidates) {
    const src = c.row
      ? { cardId: c.row.user_card_id, amount: Number(c.row.amount_inr), occurred: c.row.occurred_at, categoryId: c.row.category_id, merchantName: c.row.merchant_name, rail: c.row.rail }
      : { cardId: c.spec.userCardId, amount: c.spec.amountMinor / 100, occurred: new Date(c.spec.occurredAt), categoryId: c.spec.categoryId, merchantName: c.spec.merchantName, rail: c.spec.rail };
    const card = await cardFor(src.cardId);
    if (!card) continue; // archived or missing card: the row is kept without card state
    await deps.applyTransactionState(client, profileId, card, {
      txnId: c.id, userCardId: src.cardId, amount: src.amount, occurred: src.occurred, categoryId: src.categoryId, sign: 1,
      merchantName: src.merchantName, rail: src.rail,
    });
    applied.push(c.id);
  }
  if (applied.length) {
    await client.query('UPDATE transactions SET state_applied = true WHERE profile_id = $1 AND id = ANY($2::uuid[])', [profileId, applied]);
    stats.stateApplied = applied.length;
  }
  return stats;
}

/**
 * The whole batch, inside the caller's transaction.
 * @returns {{results: object[], stats: object}}
 */
async function ingestBatch(client, profileId, body, { backfill = false, categoryOnly = false, deps, hooks }) {
  await takeProfileLock(client, profileId);
  const results = [];
  await upsertInstruments(client, profileId, body.instruments, results);
  await insertFacts(client, profileId, body.items, results);
  if (hooks?.afterFactsStored) {
    const factIds = [...new Set(results.filter(r => r.kind === 'fact' && r.status !== 'rejected').map(r => r.id))];
    if (factIds.length) await hooks.afterFactsStored(client, profileId, factIds);
  }
  const storedEvents = await upsertEvents(client, profileId, body.events, results);
  if (storedEvents.length && hooks && hooks.afterEventsStored) await hooks.afterEventsStored(client, profileId, storedEvents);
  const acceptedLedger = await upsertLedger(client, profileId, body.ledger, results, { categoryOnly });
  const affected = new Set([...storedEvents.map((e) => e.eventId), ...acceptedLedger.map((l) => l.eventId)]);
  const uploadedInstruments = results.filter((r) => r.kind === 'instrument' && r.status !== 'rejected').map((r) => r.id);
  if (uploadedInstruments.length) {
    const rejected = await client.query(
      `SELECT DISTINCT l.event_id FROM sms_v2_ledger_entries l
         JOIN sms_v2_instruments i ON i.profile_id = l.profile_id
          AND (i.instrument_id = l.from_instrument_id OR i.instrument_id = l.to_instrument_id)
        WHERE l.profile_id = $1 AND i.status = 'rejected' AND i.instrument_id = ANY($2::uuid[])`,
      [profileId, uploadedInstruments],
    );
    rejected.rows.forEach((r) => affected.add(r.event_id));
  }
  const stats = await projectTransactions(client, profileId, [...affected], { backfill, categoryOnly, deps });
  return { results, stats };
}

// ---------- sync ----------

const SYNC_LIMIT = 1000;

function encodeCursor(c) { return Buffer.from(JSON.stringify(c), 'utf8').toString('base64url'); }

function decodeCursor(raw) {
  if (raw === undefined || raw === null || raw === '') return {};
  try {
    const c = JSON.parse(Buffer.from(String(raw), 'base64url').toString('utf8'));
    if (!c || typeof c !== 'object' || Array.isArray(c)) return null;
    for (const k of Object.keys(c)) {
      const v = c[k];
      if (k === 'a' || k === 'c') { if (typeof v !== 'string' || v.length > 512) return null; continue; } // hook cursors
      if (!['i', 'e', 'l', 'f'].includes(k)) return null;
      if (!Array.isArray(v) || v.length !== 2 || typeof v[0] !== 'string' || typeof v[1] !== 'string') return null;
      if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/.test(v[0])) return null;
    }
    return c;
  } catch (_) {
    return null;
  }
}

async function readEntity(client, profileId, { table, idCol, doc, cur, timeCol = 'updated_at' }) {
  const args = [profileId, SYNC_LIMIT + 1];
  let where = 'profile_id = $1';
  if (cur) {
    args.push(cur[0], cur[1]);
    where += ` AND (${timeCol}, ${idCol}) > ($3::timestamptz, $4::${idCol === 'instrument_id' ? 'uuid' : 'text'})`;
  }
  const r = await client.query(
    `SELECT ${doc} AS doc, ${idCol}::text AS id, ${cursorTs(timeCol)} AS cur
       FROM ${table} WHERE ${where} ORDER BY ${timeCol}, ${idCol} LIMIT $2`,
    args,
  );
  const more = r.rows.length > SYNC_LIMIT;
  const rows = more ? r.rows.slice(0, SYNC_LIMIT) : r.rows;
  const last = rows.length ? [rows[rows.length - 1].cur, rows[rows.length - 1].id] : cur || null;
  return { docs: rows.map((x) => x.doc), updatedAt: Object.fromEntries(rows.map((x) => [x.id, x.cur])), more, last };
}

/** Changes after `cursor` (already decoded). Returns {instruments, events, ledger, cursor, hasMore}. */
async function readChanges(client, profileId, cursor, hookCursors = {}) {
  const inst = await readEntity(client, profileId, { table: 'sms_v2_instruments', idCol: 'instrument_id', doc: INSTRUMENT_DOC, cur: cursor.i });
  const ev = await readEntity(client, profileId, { table: 'sms_v2_events', idCol: 'event_id', doc: EVENT_DOC, cur: cursor.e });
  const led = await readEntity(client, profileId, { table: 'sms_v2_ledger_entries', idCol: 'entry_id', doc: LEDGER_DOC, cur: cursor.l });
  const facts = await readEntity(client, profileId, { table: 'sms_v2_facts', idCol: 'fact_id', doc: FACT_DOC, cur: cursor.f, timeCol: 'created_at' });
  const next = {};
  if (facts.last) next.f = facts.last;
  if (inst.last) next.i = inst.last;
  if (ev.last) next.e = ev.last;
  if (led.last) next.l = led.last;
  if (hookCursors.a) next.a = hookCursors.a;
  if (hookCursors.c) next.c = hookCursors.c;
  return {
    instruments: inst.docs, events: ev.docs, ledger: led.docs, facts: facts.docs,
    updatedAt: { instruments: inst.updatedAt, events: ev.updatedAt, ledger: led.updatedAt },
    cursor: encodeCursor(next), hasMore: inst.more || ev.more || led.more || facts.more,
  };
}

module.exports = {
  ingestBatch, readChanges, encodeCursor, decodeCursor, SYNC_LIMIT,
  mergeInstrument, mergeEvent, ownEntryLegAmounts, projectTransactions, takeProfileLock,
};
