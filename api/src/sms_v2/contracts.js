'use strict';

// SMS pipeline v2 contract validators (WP-01).
//
// The JSON Schemas in contracts/sms/v2 are the source of truth. This module
// compiles them once with Ajv (strict, allErrors) and maps Ajv's raw errors to
// the stable codes in contracts/sms/v2/error_codes.json. The Dart validator in
// packages/pandapay_domain runs the same schemas and the same mapping, and both
// must pass every fixture in contracts/sms/v2/fixtures.
//
// Error-code mapping: a schema node carries `x-code` (one code for any failure
// at that node), `x-codes` (a code per failing keyword) and, on object nodes,
// `x-required-codes` (a code per missing property). A failure with none of
// those maps to the generic `<kind>.malformed` code.

const fs = require('node:fs');
const path = require('node:path');
const Ajv2020 = require('ajv/dist/2020');
const addFormats = require('ajv-formats');

const SCHEMA_DIR = process.env.SMS_V2_CONTRACTS_DIR
  ? path.resolve(process.env.SMS_V2_CONTRACTS_DIR)
  : path.resolve(__dirname, '../../../contracts/sms/v2');

const BASE = 'https://pandapay.app/contracts/sms/v2/';
const DAY_MS = 24 * 60 * 60 * 1000;

const REQUEST_ROUTES = [
  'facts_batch', 'rule_stats_batch', 'unknown_templates', 'corrections',
  'admin_rule_draft', 'admin_rule_publish', 'admin_rule_pause', 'admin_rule_rollback', 'admin_correction_decision',
];
const RESPONSE_ROUTES = ['facts_batch', 'unknown_templates', 'corrections', 'sync'];

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function buildAjv() {
  const ajv = new Ajv2020({ strict: true, strictRequired: false, allErrors: true, verbose: true, discriminator: true, allowUnionTypes: true });
  addFormats(ajv);
  ajv.addVocabulary(['x-code', 'x-codes', 'x-required-codes']);
  const files = [];
  for (const f of fs.readdirSync(SCHEMA_DIR)) if (f.endsWith('.schema.json')) files.push(path.join(SCHEMA_DIR, f));
  const apiDir = path.join(SCHEMA_DIR, 'api');
  for (const f of fs.readdirSync(apiDir)) if (f.endsWith('.schema.json')) files.push(path.join(apiDir, f));
  for (const f of files) ajv.addSchema(readJson(f));
  return ajv;
}

const ajv = buildAjv();
const compile = (file) => ajv.getSchema(BASE + file);
const validators = {
  fact: compile('fact.schema.json'),
  instrument: compile('instrument.schema.json'),
  event: compile('event.schema.json'),
  ledger: compile('ledger_entry.schema.json'),
  bundle: compile('rule_bundle.schema.json'),
};
const requestValidators = Object.fromEntries(REQUEST_ROUTES.map((r) => [r, compile(`api/${r}.request.schema.json`)]));
const responseValidators = Object.fromEntries(RESPONSE_ROUTES.map((r) => [r, compile(`api/${r}.response.schema.json`)]));

const WRAPPER_KEYWORDS = new Set(['if']);

function codeFor(err, fallback) {
  const ps = err.parentSchema || {};
  const kw = err.keyword;
  if (kw === 'required') {
    const rc = ps['x-required-codes'];
    const missing = err.params && err.params.missingProperty;
    if (rc && missing && rc[missing]) return rc[missing];
  }
  const codesMap = ps['x-codes'];
  if (codesMap && codesMap[kw]) return codesMap[kw];
  if (ps['x-code']) return ps['x-code'];
  return fallback;
}

function mapAjvErrors(errors, fallback) {
  const out = [];
  const seen = new Set();
  for (const err of errors || []) {
    if (WRAPPER_KEYWORDS.has(err.keyword)) continue;
    // Errors raised inside a oneOf/anyOf branch are replaced by the branch
    // keyword's own error, which carries the code.
    if (/\/(oneOf|anyOf)\/\d+|\/contains\//.test(err.schemaPath || '')) continue;
    const code = codeFor(err, fallback);
    const p = err.instancePath || '';
    const key = `${code}@${p}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ code, path: p });
  }
  return out;
}

// ---------- semantic checks (rules JSON Schema cannot express) ----------

function factSemantics(f, base) {
  const errs = [];
  if (f.occurredAt) {
    if (Date.parse(f.occurredAt) - Date.parse(f.observedAt) > DAY_MS) errs.push({ code: 'fact.occurred_after_observed', path: `${base}/occurredAt` });
  }
  const roles = new Set();
  (f.amounts || []).forEach((a, i) => {
    if (roles.has(a.role)) errs.push({ code: 'fact.amount.duplicate_role', path: `${base}/amounts/${i}/role` });
    roles.add(a.role);
  });
  (f.evidence || []).forEach((s, i) => {
    if (s.end < s.start) errs.push({ code: 'fact.evidence.span_invalid', path: `${base}/evidence/${i}` });
  });
  return errs;
}

function eventSemantics(e, base) {
  const errs = [];
  if (e.legs.length > 0 && e.legs[0].factId !== e.eventId) errs.push({ code: 'event.anchor_mismatch', path: `${base}/eventId` });
  const seen = new Set();
  e.legs.forEach((l, i) => {
    if (seen.has(l.factId)) errs.push({ code: 'event.leg_duplicate', path: `${base}/legs/${i}/factId` });
    seen.add(l.factId);
  });
  return errs;
}

function ledgerSemantics(l, base) {
  const errs = [];
  if (l.category !== null && !Object.prototype.hasOwnProperty.call(l.to, 'external')) errs.push({ code: 'ledger.category_requires_external_to', path: `${base}/category` });
  if ((l.category === null) !== (l.categorySource === null)) errs.push({ code: 'ledger.category_source_mismatch', path: `${base}/categorySource` });
  return errs;
}

function sameAsRefs(emit) {
  const refs = [];
  if (emit.instrument && typeof emit.instrument.sameAs === 'number') refs.push(['instrument', emit.instrument.sameAs]);
  if (emit.counterparty && typeof emit.counterparty.sameAs === 'number') refs.push(['counterparty', emit.counterparty.sameAs]);
  if (emit.attrs && typeof emit.attrs === 'object') {
    for (const [k, v] of Object.entries(emit.attrs)) {
      if (v && typeof v === 'object' && !Array.isArray(v) && typeof v.sameAs === 'number') refs.push([`attrs/${k}`, v.sameAs]);
    }
  }
  return refs;
}

function bundleSemantics(b, base) {
  const errs = [];
  const ids = new Set();
  b.rules.forEach((r, ri) => {
    if (ids.has(r.id)) errs.push({ code: 'bundle.rule.duplicate_id', path: `${base}/rules/${ri}/id` });
    ids.add(r.id);
    r.emit.forEach((e, ei) => {
      for (const [where, target] of sameAsRefs(e)) {
        if (target >= ei) errs.push({ code: 'bundle.rule.same_as_invalid', path: `${base}/rules/${ri}/emit/${ei}/${where}` });
      }
    });
  });
  return errs;
}

// ---------- public API ----------

function run(validate, doc, fallback, semantics) {
  const ok = validate(doc);
  let errors = ok ? [] : mapAjvErrors(validate.errors, fallback);
  if (errors.length === 0 && semantics) errors = semantics(doc);
  return { ok: errors.length === 0, errors };
}

const validateFact = (doc) => run(validators.fact, doc, 'fact.malformed', (d) => factSemantics(d, ''));
const validateInstrument = (doc) => run(validators.instrument, doc, 'instrument.malformed');
const validateEvent = (doc) => run(validators.event, doc, 'event.malformed', (d) => eventSemantics(d, ''));
const validateLedgerEntry = (doc) => run(validators.ledger, doc, 'ledger.malformed', (d) => ledgerSemantics(d, ''));
const validateBundle = (doc) => run(validators.bundle, doc, 'bundle.malformed', (d) => bundleSemantics(d, ''));

function requestSemantics(route, body) {
  if (route === 'admin_rule_draft') return [];
  if (route !== 'facts_batch') return [];
  const errs = [];
  body.items.forEach((it, i) => it.facts.forEach((f, j) => errs.push(...factSemantics(f, `/items/${i}/facts/${j}`))));
  body.events.forEach((e, i) => errs.push(...eventSemantics(e, `/events/${i}`)));
  body.ledger.forEach((l, i) => errs.push(...ledgerSemantics(l, `/ledger/${i}`)));
  return errs;
}

function validateRequest(routeName, body) {
  const validate = requestValidators[routeName];
  if (!validate) throw new Error(`unknown SMS v2 request route: ${routeName}`);
  return run(validate, body, `request.${routeName}.malformed`, (d) => requestSemantics(routeName, d));
}

function validateResponse(routeName, body) {
  const validate = responseValidators[routeName];
  if (!validate) throw new Error(`unknown SMS v2 response route: ${routeName}`);
  return run(validate, body, `response.${routeName}.malformed`, null);
}

const errorCodes = readJson(path.join(SCHEMA_DIR, 'error_codes.json'));

module.exports = {
  SCHEMA_DIR,
  REQUEST_ROUTES,
  RESPONSE_ROUTES,
  errorCodes,
  validateFact,
  validateInstrument,
  validateEvent,
  validateLedgerEntry,
  validateBundle,
  validateRequest,
  validateResponse,
};
