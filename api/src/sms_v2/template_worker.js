"use strict";

const crypto = require("node:crypto");
const { validateRequest, validateBundle } = require("./contracts");
const { lintPattern } = require("./rules_admin_route");
const { redactionError, sampleError } = require("./ai_templates");
const { readSettings, DEFAULT_AI_MODEL, envNumber } = require("./settings");
const { repairEmit } = require("./draft_repair");
const { draftLayout } = require("./draft_layout");
const { LayoutError, FILLS, buildMatcher, slotValues, exampleBodies, checkedExamples, fillWith, fillSynthetic, fillTags } = require("./layout_matcher");
const { sanityErrors, isDoubtful, DOUBTFUL_CONFIDENCE } = require("./draft_sanity");
const { PROMPT_VERSION, SMS_PLACEHOLDERS, SMS_DOMAIN_RULES, buildPrompt } = require("./ai_prompt");

const path = require("node:path");
const { SCHEMA_DIR } = require("./contracts");
const factSchema = require(path.join(SCHEMA_DIR, "fact.schema.json"));
const ruleSchema = require(path.join(SCHEMA_DIR, "rule_bundle.schema.json"));
const Ajv2020 = require("ajv/dist/2020");
const addFormats = require("ajv-formats");
const attrAjv = new Ajv2020({
  strict: false,
  discriminator: true,
  allowUnionTypes: true,
});
addFormats(attrAjv);
for (const file of require("node:fs")
  .readdirSync(SCHEMA_DIR)
  .filter((file) => file.endsWith(".schema.json"))) {
  attrAjv.addSchema(require(path.join(SCHEMA_DIR, file)));
}
const attrValidators = Object.fromEntries(
  Object.keys(factSchema.$defs).map((type) => [
    type,
    attrAjv.compile({
      $ref: `${factSchema.$id}#/$defs/${type}/properties/attrs`,
    }),
  ]),
);

// Compose passes an unset variable through as "", which means "not set".
const isSet = (env, key) => env[key] !== undefined && env[key] !== "";

// The provider could not be used right now (rate limit, overloaded, timed out, network): the layout is fine and
// the same request is worth sending again later. This is NOT a bad draft, so it never costs the layout one of its
// tries; the worker puts the layout back in the queue and waits.
class ProviderBusyError extends Error {
  constructor(reason, { retryAfterMs = 0, status = null, systemic = false, configFault = false } = {}) {
    super(reason);
    this.name = "ProviderBusyError";
    this.retryAfterMs = retryAfterMs;
    this.status = status;
    // The fault is ours or the account's (bad key, wrong model, billing), not the layout's: it says nothing about
    // the layout, so it never counts against it however often it repeats.
    this.systemic = systemic;
    // The service answered but is wrong for this worker (token, prompt revision, model, routing): every layout gets
    // the same answer until someone fixes it, so no layout's job attempt is spent on it and the worker rests.
    this.configFault = configFault;
  }
}
// After this many separate provider failures for one layout (over many waits) it is given up on, so a layout the
// provider can never answer does not circle for ever.
const MAX_PROVIDER_FAILURES = 8;
const BUSY_STATUSES = new Set([408, 425, 429, 500, 502, 503, 504]);
const BUSY_WAIT_MS = { min: 5000, max: 120000 };
// Wait before trying again after a key / model / billing problem: it will not fix itself in seconds.
const SYSTEMIC_WAIT_MS = 300000;
// Answers that mean the request is refused for reasons unrelated to the layout (key, model, billing).
const SYSTEMIC_BODY =
  /API[_ ]?KEY|PERMISSION_DENIED|billing|is not found for API version|models\/\S+ is not found|not supported for generateContent|SERVICE_DISABLED/i;
const QUOTA_BODY = /quota|resource[_ -]?exhausted|rate.?limit/i;
function isSystemicProviderAnswer(status, bodyText) {
  const body = String(bodyText ?? "");
  // A refusal that talks about quota is a rate limit, not a broken key.
  if (status === 403 && QUOTA_BODY.test(body)) return false;
  if (status === 401 || status === 403 || status === 404) return true;
  return status === 400 && SYSTEMIC_BODY.test(body);
}
// The wait the provider itself asks for, in ms (0 when it does not say): the Retry-After header, or the
// retryDelay Gemini puts in the body of a 429 ("34s").
function providerDelayMs(bodyText, headers) {
  const seconds = Number(headers?.get?.("retry-after"));
  if (Number.isFinite(seconds) && seconds > 0) return seconds * 1000;
  try {
    for (const detail of JSON.parse(bodyText)?.error?.details ?? []) {
      const match = /^([0-9.]+)s$/i.exec(String(detail?.retryDelay ?? ""));
      if (match && Number(match[1]) > 0) return Math.round(Number(match[1]) * 1000);
    }
  } catch {
    // Not JSON: no delay given.
  }
  return 0;
}
// How long to wait before the next try: what the provider asked for (up to an hour: a daily quota says so),
// else a short pause that grows with the number of failures in a row.
const MAX_ASKED_WAIT_MS = 3600000;
function busyWaitMs(error, inARow = 1) {
  const asked = Number.isFinite(error?.retryAfterMs) && error.retryAfterMs > 0 ? error.retryAfterMs : 0;
  if (asked > 0) return Math.min(MAX_ASKED_WAIT_MS, Math.max(BUSY_WAIT_MS.min, asked));
  const grown = BUSY_WAIT_MS.min * 2 ** Math.min(Math.max(inARow, 1) - 1, 5);
  return Math.min(BUSY_WAIT_MS.max, Math.max(BUSY_WAIT_MS.min, grown));
}

function positiveInteger(env, key, fallback) {
  const value = Number(isSet(env, key) ? env[key] : fallback);
  if (!Number.isSafeInteger(value) || value < 1)
    throw new Error(`${key}_invalid`);
  return value;
}
// Only GEMINI_API_KEY and a database login must come from the host. The model,
// rate limits and answer length are Settings-tab values stored in the database;
// these are the fallbacks until an admin changes them.
function workerConfig(env = process.env) {
  const model = env.SMS_V2_AI_MODEL || DEFAULT_AI_MODEL;
  if (!/^[A-Za-z0-9_.-]+$/.test(model))
    throw new Error("SMS_V2_AI_MODEL_required");
  const price = (key) => {
    if (!isSet(env, key)) return null;
    const value = Number(env[key]);
    if (!Number.isFinite(value) || value < 0) throw new Error(`${key}_invalid`);
    return value;
  };
  return {
    model,
    rpm: positiveInteger(env, "SMS_V2_AI_RPM", 60),
    tpm: positiveInteger(env, "SMS_V2_AI_TPM", 100000),
    maxOutputTokens: positiveInteger(env, "SMS_V2_AI_MAX_OUTPUT_TOKENS", 4096),
    inputPrice: price("SMS_V2_AI_INPUT_USD_PER_MILLION"),
    outputPrice: price("SMS_V2_AI_OUTPUT_USD_PER_MILLION"),
  };
}

// Console settings (settings.js) over the environment-derived config. The
// environment stays a hard ceiling for rate limits.
function applyWorkerSettings(config, settings, env = process.env) {
  // A blank variable (compose passes an unset one as "") is no ceiling, never 0.
  const capped = (value, key) => {
    const ceiling = envNumber(env, key);
    return ceiling === undefined ? value : Math.min(value, ceiling);
  };
  return {
    ...config,
    model: settings.ai_model || config.model,
    rpm: capped(settings.ai_rpm, "SMS_V2_AI_RPM"),
    tpm: capped(settings.ai_tpm, "SMS_V2_AI_TPM"),
    temperature: settings.ai_temperature,
    maxOutputTokens: settings.ai_max_output_tokens,
  };
}

// Whether a rule's pattern reads [text], with its requireAll / rejectAny words.
function ruleMatches(rule, text) {
  const folded = text.toLowerCase();
  if (
    rule.match.requireAll?.some((word) => !folded.includes(word.toLowerCase())) ||
    rule.match.rejectAny?.some((word) => folded.includes(word.toLowerCase()))
  )
    return null;
  return new RegExp(rule.match.pattern, rule.match.flags).exec(text);
}

function captureReferences(rule) {
  const names = [];
  const walk = (node) => {
    if (Array.isArray(node)) return node.forEach(walk);
    if (!node || typeof node !== "object") return;
    for (const [key, value] of Object.entries(node)) {
      if ((key === "from" || key.endsWith("From")) && typeof value === "string")
        names.push(value);
      else if (key === "references" && value && typeof value === "object")
        names.push(...Object.values(value));
      else walk(value);
    }
  };
  walk(rule.emit);
  return names;
}

// The fields the worker itself decides are stamped, not left to the model: the
// rule id, version, provisional status, author, sender and template binding. The
// pattern, facts and examples stay the model's, and are still validated.
function stampDraft(rule, template, model) {
  if (!rule || typeof rule !== "object" || Array.isArray(rule)) return rule;
  const stamped = {
    ...rule,
    id: `AI-${template.template_hash}`,
    version: 1,
    status: "provisional",
    createdBy: `ai:${model}`,
    senders: [template.sender_brand],
    ...(rule.match && typeof rule.match === "object"
      ? { match: { ...rule.match, templateHash: template.template_hash } }
      : {}),
  };
  if (!stamped.examples && Array.isArray(stamped.tests)) {
    stamped.examples = stamped.tests;
    delete stamped.tests;
  }
  if (typeof stamped.confidence !== "number" || !Number.isFinite(stamped.confidence)) {
    stamped.confidence = 0.9;
  }
  // A layout too thin to be sure of (no debit/credit word, unlabelled amounts) is read below the phone's confident line, so the person is asked.
  if (isDoubtful(stamped, template.redacted_body)) stamped.confidence = Math.min(stamped.confidence, DOUBTFUL_CONFIDENCE);
  if (!stamped.updatedAt || typeof stamped.updatedAt !== "string") {
    stamped.updatedAt = new Date().toISOString();
  }
  return stamped;
}

const REFERENCE_KEYS = Object.keys(factSchema.properties.references.properties);

// "<ruleId>@<version>" of the first active rule for the sender that reads this layout with every way of
// writing its values (three fills), or null. One fill is not enough: a rule that only reads "Rs. 127.45"
// would be called a cover and then fail on "INR 1,23,456.78". The AI is not asked about a covered layout.
// A rule for every sender ("*") covers it too, but only when it is sure of what it reads (confidence at
// least GENERIC_COVER_CONFIDENCE): a catch-all that reads unsurely leaves the message in review, which is
// exactly what the AI is for.
const GENERIC_COVER_CONFIDENCE = 0.7;
function coveredBy(template, rules) {
  const samples = FILLS.map((values) => fillWith(template.redacted_body, values));
  for (const rule of rules) {
    if (!rule?.match?.pattern) continue;
    const own = rule.senders?.includes(template.sender_brand);
    const generic = !own && rule.senders?.includes("*") && Number(rule.confidence) >= GENERIC_COVER_CONFIDENCE;
    if (!own && !generic) continue;
    try {
      if (samples.every((sample) => ruleMatches(rule, sample))) return `${rule.id}@${rule.version}`;
    } catch {
      // A rule that cannot run is not a cover.
    }
  }
  return null;
}

class AnswerError extends Error {
  constructor(code) {
    super(code);
    this.name = "AnswerError";
    this.code = code;
  }
}

// Slot names the model wrote ("<AMT1>", "AMT1") become the pattern's group names ("amt1").
const slotName = (value) => String(value).replace(/[<>\s]/g, "").toLowerCase();
function normalizeSlots(node) {
  if (Array.isArray(node)) return node.map(normalizeSlots);
  if (!node || typeof node !== "object") return node;
  const out = {};
  for (const [key, value] of Object.entries(node)) {
    if ((key === "from" || key.endsWith("From")) && typeof value === "string") out[key] = slotName(value);
    else if (key === "references" && value && typeof value === "object" && !Array.isArray(value))
      out.references = Object.fromEntries(Object.entries(value).map(([k, v]) => [k, typeof v === "string" ? slotName(v) : v]));
    else out[key] = normalizeSlots(value);
  }
  return out;
}

// The rule for a layout: the pattern comes from the layout (layout_matcher.js), the facts from the model's
// answer, the examples from the layout. The rule is then checked like any draft (validateDraft).
// `repair: false` builds the rule exactly as the model wrote it; the tests that prove the validator names each kind of
// wrong wiring use it. Production always repairs.
function buildRule(answer, template, matcher, model, { repair: repairFacts = true } = {}) {
  if (!answer || typeof answer !== "object" || Array.isArray(answer) || !Array.isArray(answer.emit) || !answer.emit.length || answer.emit.length > 6)
    throw new AnswerError("answer_shape_invalid");
  // Slips in how the model wrote the facts are repaired first (draft_repair.js): what it got right is never changed.
  const normalized = normalizeSlots(answer.emit);
  const repair = repairFacts ? repairEmit(normalized, matcher.slots) : { emit: normalized, repairs: [] };
  const emit = repair.emit.map((fact) => {
    if (!fact || typeof fact !== "object" || Array.isArray(fact)) throw new AnswerError("answer_shape_invalid");
    const out = { ...fact };
    // Money is rupees unless the model says points; the engine reads the date forms itself.
    if (Array.isArray(out.amounts))
      out.amounts = out.amounts.map((a) => (a && typeof a === "object" && !a.unit ? { ...a, unit: String(a.role).startsWith("points") ? "POINTS" : "INR" } : a));
    if (out.occurredAt && typeof out.occurredAt === "object") {
      const { formats: _formats, ...rest } = out.occurredAt;
      out.occurredAt = rest;
    }
    return out;
  });
  const types = emit.map((fact) => fact.factType);
  const sender = template.sender_brand;
  // The examples that were checked against this pattern before the AI was asked (checkedExamples); the first and last fixed
  // word, which exampleBodies takes, can leave a "negative" the pattern still reads, and every answer then fails example_mismatch.
  let examples;
  try {
    examples = checkedExamples(template.redacted_body, matcher);
  } catch {
    examples = exampleBodies(template.redacted_body);
  }
  const { positives, negatives } = examples;
  const rule = stampDraft(
    {
      version: 1,
      family: typeof answer.family === "string" && /^[a-z][a-z0-9_]{0,40}$/.test(answer.family) ? answer.family : "ai_layout",
      senders: [sender],
      priority: 500,
      match: { pattern: matcher.pattern, flags: matcher.flags },
      emit,
      confidence: Number.isFinite(answer.confidence) ? Math.min(1, Math.max(0, answer.confidence)) : 0.9,
      examples: [
        ...positives.map((body) => ({ sender, body, expectFactTypes: types })),
        ...negatives.map((body) => ({ sender, body, expectFactTypes: [] })),
      ],
    },
    template,
    model,
  );
  // Which repairs were made, for the attempt record. Not part of the rule (the contract allows no extra keys).
  Object.defineProperty(rule, "repairs", { value: repair.repairs, enumerable: false });
  return rule;
}

// What the phone's engine makes of a slot used as an attribute (rule_engine.dart: _dateAttrKeys, _instantAttrKeys and
// the amount attributes): the synthetic value of the right kind, not the raw text of the slot.
const ENGINE_ATTR_VALUES = Object.freeze({
  dueDate: "2026-11-20",
  statementDate: "2026-11-20",
  asOf: "2026-11-20T00:00:00Z",
  dueAt: "2026-11-20T00:00:00Z",
  expiresAt: "2026-11-20T00:00:00Z",
  previousMinor: 12745,
  amountMinor: 12745,
});

// One line for a failed attribute check, e.g. "attrs_movement/purpose: one of purchase|p2p|atm".
function attrProblem(factType, problem) {
  const where = problem.instancePath || "/";
  const { keyword, params = {} } = problem;
  const detail =
    keyword === "enum" ? `one of ${(params.allowedValues ?? []).join("|")}`
    : keyword === "additionalProperties" ? `unknown attribute ${params.additionalProperty}`
    : keyword === "required" ? `missing ${params.missingProperty}`
    : keyword === "type" ? `must be ${params.type}`
    : keyword === "format" ? `must be a ${params.format}`
    : keyword;
  return `attrs_${factType}${where}: ${detail}`.slice(0, 160);
}

function validateDraft(rule, template, model, otherLayouts = []) {
  const structural = validateRequest("admin_rule_draft", rule);
  if (!structural.ok) return structural.errors.map((error) => error.code);
  const errors = [];
  if (rule.id !== `AI-${template.template_hash}`)
    errors.push("template_rule_id_required");
  if (
    rule.status !== "provisional" ||
    rule.createdBy !== `ai:${model}` ||
    rule.version !== 1
  )
    errors.push("provisional_metadata_required");
  if (
    rule.match.templateHash !== template.template_hash ||
    rule.senders.length !== 1 ||
    rule.senders[0] !== template.sender_brand
  )
    errors.push("template_scope_required");
  if (lintPattern(rule.match.pattern, rule.match.flags).length)
    return [...errors, "regex_dialect_invalid"];
  const regex = new RegExp(rule.match.pattern, rule.match.flags);
  const names = new Set(
    [...rule.match.pattern.matchAll(/\(\?<([A-Za-z_][A-Za-z0-9_]*)>/g)].map(
      (match) => match[1],
    ),
  );
  const references = captureReferences(rule);
  const missingSlots = [...new Set(references.filter((name) => !names.has(name)))];
  if (missingSlots.length) {
    errors.push("capture_group_missing");
    // So the second try can correct it: which slot does not exist, and which ones do.
    errors.push(`slot_not_in_layout: ${missingSlots.slice(0, 3).join(",")} (the layout has: ${[...names].join(",") || "no slots"})`.slice(0, 160));
  }
  // The phone refuses a fact whose reference key is not in the fact contract.
  for (const emit of rule.emit ?? [])
    for (const key of Object.keys(emit.references ?? {}))
      if (!REFERENCE_KEYS.includes(key)) errors.push("reference_key_invalid");
  const matches = (body) => {
    const folded = body.toLowerCase();
    if (
      rule.match.requireAll?.some(
        (word) => !folded.includes(word.toLowerCase()),
      ) ||
      rule.match.rejectAny?.some((word) => folded.includes(word.toLowerCase()))
    )
      return null;
    return regex.exec(body);
  };
  const sample = matches(fillSynthetic(template.redacted_body));
  if (!sample || references.some((name) => !sample.groups?.[name]))
    errors.push("template_sample_mismatch");
  // Once promoted, this rule reads more than one layout. It must not read a
  // sibling layout of the same sender that already has its own rule.
  for (const other of otherLayouts.slice(0, 50)) {
    if (other.template_hash === template.template_hash) continue;
    if (matches(fillSynthetic(other.redacted_body))) {
      errors.push("draft_overmatches_other_layouts");
      break;
    }
  }
  const priorAttrs = [];
  for (const emit of rule.emit) {
    const attrs = {};
    for (const [key, value] of Object.entries(emit.attrs || {})) {
      if (value && typeof value === "object" && "from" in value) {
        const raw = sample?.groups?.[value.from];
        attrs[key] = raw === undefined ? raw : ENGINE_ATTR_VALUES[key] ?? raw;
      } else if (value && typeof value === "object" && "sameAs" in value) {
        attrs[key] = priorAttrs[value.sameAs]?.[value.field || key];
      } else attrs[key] = value;
    }
    if (emit.factType === "balance_snapshot" && !attrs.asOf)
      attrs.asOf = "2026-11-20T00:00:00Z";
    const checkAttrs = attrValidators[emit.factType];
    if (!checkAttrs?.(attrs)) {
      errors.push("emitted_attrs_invalid");
      // Say which attribute and why, so the second try can fix it and the console shows it: a schema path and the
      // allowed values, never message text.
      for (const problem of (checkAttrs?.errors ?? []).slice(0, 3)) errors.push(attrProblem(emit.factType, problem));
    }
    priorAttrs.push(attrs);
  }

  const positives = rule.examples.filter(
    (example) => example.expectFactTypes.length,
  );
  const negatives = rule.examples.filter(
    (example) => !example.expectFactTypes.length,
  );
  if (
    new Set(positives.map((example) => example.body)).size < 2 ||
    new Set(negatives.map((example) => example.body)).size < 2
  )
    errors.push("two_positive_negative_examples_required");
  const types = rule.emit.map((emit) => emit.factType);
  for (const example of rule.examples) {
    const matched =
      example.sender === template.sender_brand && !!matches(example.body);
    if (
      matched !== !!example.expectFactTypes.length ||
      (matched &&
        (example.expectFactTypes.length !== types.length ||
          types.some((type, index) => example.expectFactTypes[index] !== type)))
    )
      errors.push("example_mismatch");
  }
  const words = template.redacted_body;
  if (
    types.includes("movement") &&
    /\b(?:blocked|on hold|lien|released|declined|failed|unsuccessful|scheduled|will be debited|limit (?:increased|enhanced)|available balance)\b/i.test(
      words,
    ) &&
    !/\b(?:debited|credited|spent|paid|withdrawn)\b/i.test(words)
  )
    errors.push("movement_family_conflict");
  if (/\bblocked\b/i.test(words) && types.includes("movement"))
    errors.push("hold_cannot_emit_movement");
  errors.push(...sanityErrors(rule, template.redacted_body));
  const bundle = {
    schema: "pandapay.sms.rules/2",
    bundleVersion: 0,
    createdAt: "2026-01-01T00:00:00Z",
    expiresAt: "2026-01-08T00:00:00Z",
    minEngineVersion: "2.0.0",
    taxonomyVersion: 1,
    senders: [],
    ignoreRules: [],
    rules: [rule],
    counterpartyPurposes: [],
    linkRules: [],
    categoryRules: [],
    merchantAliases: [],
    signature: null,
  };
  const validation = validateBundle(bundle);
  if (!validation.ok)
    errors.push(...validation.errors.map((error) => error.code));
  return [...new Set(errors)];
}

// Validation runs in one long-lived worker thread so a catastrophic regex in a
// model draft cannot freeze the process. The thread loads this module once, so
// the per-draft deadline measures validation only, never module start-up (a
// fresh thread per draft took longer than the old 1.5 s limit on the small
// production host). On a timeout the thread is terminated and the next draft
// gets a new one.
const VALIDATION_TIMEOUT_MS = 10000;
const VALIDATION_START_TIMEOUT_MS = 60000;
let validator = null;

function validationTimeoutMs(env = process.env) {
  const value = Number(env.SMS_V2_VALIDATION_TIMEOUT_MS);
  return Number.isSafeInteger(value) && value >= 100 ? value : VALIDATION_TIMEOUT_MS;
}

function startValidator() {
  const { Worker } = require("node:worker_threads");
  const worker = new Worker(
    `
    const { parentPort, workerData } = require('node:worker_threads');
    const { validateDraft } = require(workerData.module);
    parentPort.on('message', ({ id, args }) => {
      let errors;
      try { errors = validateDraft(...args); } catch { errors = ['draft_invalid']; }
      parentPort.postMessage({ id, errors });
    });
    parentPort.postMessage({ ready: true });
  `,
    { eval: true, workerData: { module: __filename } },
  );
  const state = { worker, pending: new Map(), nextId: 1, dead: false };
  const fail = (code) => {
    state.dead = true;
    if (validator === state) validator = null;
    worker.terminate().catch(() => {});
    for (const settle of state.pending.values()) settle(code);
    state.pending.clear();
  };
  state.fail = fail;
  state.ready = new Promise((resolve) => {
    const timer = setTimeout(() => {
      fail("validation_failed");
      resolve();
    }, VALIDATION_START_TIMEOUT_MS);
    timer.unref();
    worker.on("message", (message) => {
      if (message.ready) {
        clearTimeout(timer);
        // Held open only while a draft is being checked, never just by existing.
        worker.unref();
        resolve();
      } else state.pending.get(message.id)?.(message.errors);
    });
  });
  worker.once("error", () => fail("validation_failed"));
  worker.once("exit", () => fail("validation_failed"));
  return state;
}

async function validateDraftSafely(rule, template, model, otherLayouts = [], { timeoutMs = validationTimeoutMs() } = {}) {
  validator ||= startValidator();
  const state = validator;
  await state.ready;
  if (state.dead) return ["validation_failed"];
  return new Promise((resolve) => {
    const id = state.nextId++;
    const timer = setTimeout(() => state.fail("validation_timeout"), timeoutMs);
    state.worker.ref();
    state.pending.set(id, (result) => {
      clearTimeout(timer);
      state.worker.unref();
      state.pending.delete(id);
      resolve(typeof result === "string" ? [result] : result);
    });
    state.worker.postMessage({ id, args: [rule, template, model, otherLayouts] });
  });
}

// Reserves a minute of provider capacity and writes the attempt row, in the
// caller's transaction. Returns "capacity" when the minute is full, else null.
// Layout drafts and shop suggestions share this, so they share one budget.
async function reserveCapacity(client, { prompt, config, templateHash, attempt, jobId }) {
  // Gemini counts about one token per 3 to 4 bytes of this JSON prompt; 3 is the safe side.
  const estimate = Math.ceil(Buffer.byteLength(prompt, "utf8") / 3) + config.maxOutputTokens;
  await client.query(
    "SELECT pg_advisory_xact_lock(hashtext('sms_v2_ai_capacity'))",
  );
  const minute = (
    await client.query("SELECT date_trunc('minute',clock_timestamp()) AS minute")
  ).rows[0].minute;
  await client.query(
    "INSERT INTO sms_v2_ai_capacity(minute) VALUES($1) ON CONFLICT DO NOTHING",
    [minute],
  );
  const used = (
    await client.query(
      "SELECT requests,reserved_tokens FROM sms_v2_ai_capacity WHERE minute=$1 FOR UPDATE",
      [minute],
    )
  ).rows[0];
  if (used.requests + 1 > config.rpm || Number(used.reserved_tokens) + estimate > config.tpm)
    return "capacity";
  await client.query(
    "UPDATE sms_v2_ai_capacity SET requests=requests+1,reserved_tokens=reserved_tokens+$2 WHERE minute=$1",
    [minute, estimate],
  );
  await client.query(
    "INSERT INTO sms_v2_template_attempts(template_hash,attempt,model,capacity_minute,reserved_tokens,job_id) VALUES($1,$2,$3,$4,$5,$6)",
    [templateHash, attempt, config.model, minute, estimate, jobId],
  );
  return null;
}

// Month-to-date provider spend in USD (UTC month), across layouts and shops.
async function monthSpendUsd(client) {
  return Number(
    (
      await client.query(
        "SELECT coalesce(sum(cost_usd),0) AS spent FROM sms_v2_template_attempts WHERE started_at >= date_trunc('month', clock_timestamp() AT TIME ZONE 'utc') AT TIME ZONE 'utc'",
      )
    ).rows[0].spent,
  );
}

// Records what a finished attempt used, and tops up the reservation if needed.
async function recordUsage(client, { jobId, attempt, usage }) {
  const attemptRow = (
    await client.query(
      `UPDATE sms_v2_template_attempts SET input_tokens=$3,output_tokens=$4,total_tokens=$5,latency_ms=$6,cost_usd=$7,outcome=$8,prompt_version=$9,
        error_kind=$10,error_codes=$11::text[],http_status=$12
        WHERE job_id=$1 AND attempt=$2 RETURNING capacity_minute,reserved_tokens`,
      [jobId, attempt, usage.inputTokens, usage.outputTokens, usage.totalTokens, usage.latencyMs, usage.costUsd, usage.outcome, usage.promptVersion ?? null, usage.errorKind ?? null, usage.errorCodes ?? null, usage.httpStatus ?? null],
    )
  ).rows[0];
  if (attemptRow && usage.totalTokens > attemptRow.reserved_tokens) {
    await client.query(
      "UPDATE sms_v2_ai_capacity SET reserved_tokens=reserved_tokens+$2 WHERE minute=$1",
      [attemptRow.capacity_minute, usage.totalTokens - attemptRow.reserved_tokens],
    );
  }
}

const NO_DRAFT_USAGE = { inputTokens: 0, outputTokens: 0, totalTokens: 0, costUsd: null };

// In service mode the service owns cost and limits, so the worker books tokens but never a price.
function draftUsage(response, config, layoutOnly) {
  const tokens = (value) => Number.isSafeInteger(value) && value >= 0 ? value : 0;
  const inputTokens = tokens(response?.inputTokens);
  const outputTokens = tokens(response?.outputTokens);
  const totalTokens = Math.max(tokens(response?.totalTokens), inputTokens + outputTokens);
  const billedOutputTokens = Math.max(outputTokens, totalTokens - inputTokens);
  const costUsd = layoutOnly || config.inputPrice === null || config.outputPrice === null || !Number.isSafeInteger(response?.totalTokens)
    ? null
    : (inputTokens * config.inputPrice + billedOutputTokens * config.outputPrice) / 1000000;
  return { inputTokens, outputTokens: billedOutputTokens, totalTokens, costUsd };
}

// `transaction` (the production worker login, see ai_worker_store.js) or
// `withAdminClient` + `adminId` (the private admin API login, used locally).
// Both run every operation in one transaction. Submitter and consent rows are
// never read directly: pandapay.sms_v2_ai_consent_people answers how many
// consenting people submitted a layout, in either mode.
const DRAFT_JOB_DEADLINE_MS = 90000;
const DRAFT_JOB_LEASE_MS = 120000;
const MAX_DRAFT_ROUTE_CALLS = 15; // Up to seven providers, one re-ask of each that answered wrongly, and one exhaustion response.
// A job that ends with a rejected draft or the 90 s budget run out while "some route had trouble" is retried
// (5 min, 30 min, 24 h) without counting against the layout. Three such exhausted cycles in a row (nine jobs) fail it
// for good, so a layout that always times out cannot use the provider for ever.
const INFRA_EXHAUSTION_CYCLES = 3;
function infraExhaustionTerminal(template) {
  return template.ai_job_attempts >= 3 && template.ai_counted_jobs + 1 >= INFRA_EXHAUSTION_CYCLES;
}

async function reapExpiredDraftJobs(client, draftingVersion) {
  await client.query(
    `WITH expired AS (
       SELECT template_hash FROM sms_v2_unknown_templates
        WHERE ai_status='working' AND lease_expires_at<=clock_timestamp()
        ORDER BY lease_expires_at,template_hash LIMIT 50 FOR UPDATE SKIP LOCKED
     )
     UPDATE sms_v2_unknown_templates t SET ai_status='queued',lease_id=NULL,lease_expires_at=NULL,
       ai_drafting_version=coalesce(t.ai_drafting_version,$1),ai_job_attempts=greatest(t.ai_job_attempts,1),
       ai_run_after=clock_timestamp()+pandapay.sms_v2_draft_retry_delay(greatest(t.ai_job_attempts,1)),
       failure_code=CASE WHEN t.ai_job_attempts=3 THEN 'draft_infrastructure_exhausted' ELSE 'worker_interrupted' END,
       result_revision=nextval('sms_v2_template_revision')
       FROM expired WHERE t.template_hash=expired.template_hash`,
    [draftingVersion],
  );
}

function createPgWorkerStore({ withAdminClient, adminId, transaction, draftingVersion }) {
  const tx = transaction
    ? (operation) => transaction(operation)
    : (operation) => withAdminClient(adminId, "learning.publish", operation);
  const currentConsent = `pandapay.sms_v2_ai_consent_people(t.template_hash)>0`;
  // Held back for more than 2 minutes only because the AI service was down: a systemic failure (never a bad draft),
  // still queued, with current consent. jobs/outage_recovery.js makes these due once the service answers again.
  const outageDeferred = `t.ai_status='queued' AND t.failure_detail[1]='systemic'
    AND t.failure_code IN ('provider_unavailable','draft_infrastructure_exhausted')
    AND t.ai_run_after > clock_timestamp() + interval '2 minutes' AND ${currentConsent}`;
  return {
    // Admin-set values, read fresh at each loop (settings.js).
    settings() {
      return tx((client) => readSettings(client, { force: true }));
    },
    // The ready drafts the audit re-checks (jobs/draft_audit.js): consenting submitters, no admin decision. At most 300 a pass.
    readyDraftsForAudit() {
      return tx(async (client) =>
        (await client.query(
          `SELECT t.template_hash, t.sender_brand, t.redacted_body, t.ai_draft, t.ai_model FROM sms_v2_unknown_templates t
            WHERE t.ai_status='ready' AND t.ai_draft IS NOT NULL AND t.admin_decision IS NULL AND ${currentConsent}
            ORDER BY t.template_hash LIMIT 300`,
        )).rows,
      );
    },
    // Replaces a ready draft with its repaired version (only its `emit` may differ), while it is still exactly `before`,
    // undecided and consented. The database function is the one narrow door: the worker's row policy allows no direct update
    // of a ready row. The new result revision makes phones pull it. Returns whether it replaced anything.
    replaceReadyDraft(templateHash, before, after) {
      return tx(async (client) =>
        (await client.query("SELECT pandapay.sms_v2_ai_replace_ready_draft($1::text, $2::jsonb, $3::jsonb) AS done",
          [templateHash, JSON.stringify(before), JSON.stringify(after)])).rows[0].done === true,
      );
    },
    outageDeferredCount() {
      return tx(async (client) =>
        Number((await client.query(`SELECT count(*)::int AS n FROM sms_v2_unknown_templates t WHERE ${outageDeferred}`)).rows[0].n));
    },
    // Makes the outage-held layouts due now. Their tries and cycles are untouched, so the usual limits still apply.
    releaseAfterOutage() {
      return tx(async (client) => {
        await client.query("SELECT pg_advisory_xact_lock(hashtext('sms_v2_template_results'))");
        return (await client.query(`UPDATE sms_v2_unknown_templates t SET ai_run_after=clock_timestamp() WHERE ${outageDeferred}`)).rowCount;
      });
    },
    // Drops Gemini's raw draft once an admin decision is final (approved and
    // published a week ago, or rejected), keeping the decision record. Returns
    // how many drafts were cleared.
    cleanupDecided() {
      return tx(async (client) =>
        Number((await client.query("SELECT pandapay.sms_v2_ai_cleanup_decided() AS n")).rows[0].n),
      );
    },
    // Month-to-date provider spend in USD (UTC month), layouts and shops together.
    monthSpend() {
      return tx((client) => monthSpendUsd(client));
    },
    async claim() {
      return tx(async (client) => {
        await client.query(
          "SELECT pg_advisory_xact_lock(hashtext('sms_v2_template_results'))",
        );
        if (draftingVersion) {
          await reapExpiredDraftJobs(client, draftingVersion);
          await client.query(
            `WITH capped AS (
               SELECT template_hash FROM sms_v2_unknown_templates
                WHERE ai_status='queued' AND coalesce((ai_counted_jobs_by_version->>$1)::int,0)>=5
                ORDER BY queued_at,template_hash LIMIT 50 FOR UPDATE SKIP LOCKED
             )
             UPDATE sms_v2_unknown_templates t SET ai_status='failed',failure_code='draft_layout_cap',
               ai_drafting_version=$1,ai_counted_jobs=5,result_revision=nextval('sms_v2_template_revision')
               FROM capped WHERE t.template_hash=capped.template_hash`,
            [draftingVersion],
          );
        } else {
          await client.query(
            "UPDATE sms_v2_unknown_templates SET ai_status='failed',failure_code='worker_interrupted',result_revision=nextval('sms_v2_template_revision') WHERE ai_status='working' AND lease_expires_at<clock_timestamp()",
          );
        }
        const row = (
          await client.query(`SELECT t.* FROM sms_v2_unknown_templates t WHERE t.ai_status='queued' AND ${currentConsent}
          ${draftingVersion ? "AND t.ai_run_after<=clock_timestamp() AND coalesce((t.ai_counted_jobs_by_version->>$1)::int,0)<5" : ""}
          ORDER BY t.queued_at,t.template_hash
          LIMIT 1 FOR UPDATE OF t SKIP LOCKED`, draftingVersion ? [draftingVersion] : [])
        ).rows[0];
        if (!row) return null;
        const leaseId = crypto.randomUUID();
        if (draftingVersion) {
          const restart = row.ai_drafting_version !== draftingVersion || row.ai_job_attempts >= 3;
          const updated = await client.query(
            `UPDATE sms_v2_unknown_templates SET ai_status='working',lease_id=$2,
              lease_expires_at=clock_timestamp()+($3*interval '1 millisecond'),
              ai_drafting_version=$4,ai_job_attempts=$5,ai_counted_jobs=coalesce((ai_counted_jobs_by_version->>$4)::int,0),
              ai_excluded_providers=CASE WHEN $6::boolean THEN '{}'::text[] ELSE ai_excluded_providers END,
              failure_code=NULL,failure_detail=NULL,result_revision=nextval('sms_v2_template_revision')
              WHERE template_hash=$1 RETURNING *`,
            [row.template_hash, leaseId, DRAFT_JOB_LEASE_MS, draftingVersion,
              restart ? 1 : row.ai_job_attempts + 1, restart],
          );
          return updated.rows[0];
        }
        await client.query(
          "UPDATE sms_v2_unknown_templates SET ai_status='working',lease_id=$2,lease_expires_at=clock_timestamp()+interval '3 minutes',result_revision=nextval('sms_v2_template_revision') WHERE template_hash=$1",
          [row.template_hash, leaseId],
        );
        return { ...row, lease_id: leaseId };
      });
    },
    // Every active rule for the sender, to see whether one already reads a layout and which families it uses.
    activeRules(template) {
      return tx(async (client) =>
        (
          await client.query(
            "SELECT body FROM sms_v2_rules WHERE status='active' AND ($1=ANY(senders) OR '*'=ANY(senders)) ORDER BY ('*'=ANY(senders)),rule_id,version DESC LIMIT 600",
            [template.sender_brand],
          )
        ).rows.map((row) => row.body),
      );
    },
    // Up to three layouts of the sender whose AI draft the admin rejected, with the reason (never the free-text note).
    previousMistakes(template) {
      return tx(async (client) =>
        (
          await client.query(
            `SELECT redacted_body,admin_reason FROM sms_v2_unknown_templates
              WHERE sender_brand=$1 AND template_hash<>$2 AND admin_decision='rejected'
              ORDER BY decided_at DESC LIMIT 3`,
            [template.sender_brand, template.template_hash],
          )
        ).rows.map((row) => ({ redactedBody: row.redacted_body, reason: row.admin_reason })),
      );
    },
    // Counts of distinct people by correction kind for this layout.
    userReports(template) {
      return tx(async (client) =>
        Object.fromEntries(
          (
            await client.query(
              "SELECT correction_kind, people FROM pandapay.sms_v2_ai_report_counts($1)",
              [template.template_hash],
            )
          ).rows.map((row) => [row.correction_kind, Number(row.people)]),
        ),
      );
    },
    // How many times the provider failed to answer this layout (an attempt that came back with no tokens), across
    // all earlier waits. Used to give up on a layout only after many separate failures.
    providerFailures(template) {
      return tx(async (client) =>
        Number(
          (
            await client.query(
              "SELECT count(*)::int AS n FROM sms_v2_template_attempts WHERE template_hash=$1 AND outcome='rejected' AND coalesce(total_tokens,0)=0",
              [template.template_hash],
            )
          ).rows[0].n,
        ),
      );
    },
    // Whether the provider answered any layout lately (an attempt that used tokens in the last hour). When it has
    // not, a failing layout is a victim of an outage, not the cause, and must not be given up on.
    providerRecentlyWorked() {
      return tx(
        async (client) =>
          Number(
            (
              await client.query(
                "SELECT count(*)::int AS n FROM sms_v2_template_attempts WHERE started_at >= clock_timestamp()-interval '1 hour' AND coalesce(total_tokens,0)>0",
              )
            ).rows[0].n,
          ) > 0,
      );
    },
    // Puts layouts that failed through no fault of their own (provider down, worker restarted or crashed) back in
    // the queue, a few times each, and layouts whose drafts failed under an older prompt (once per prompt change).
    // Returns how many. A layout the current prompt already failed on stays failed.
    requeueFailed(promptVersion = null) {
      return tx(async (client) =>
        Number(
          (await client.query(
            draftingVersion
              ? "SELECT pandapay.sms_v2_ai_requeue_durable($1::text) AS n"
              : "SELECT pandapay.sms_v2_ai_requeue_failed($1::text) AS n",
            [draftingVersion ?? promptVersion],
          )).rows[0].n,
        ),
      );
    },
    async beginAttempt(template, attempt, prompt, config) {
      return tx(async (client) => {
        const row = (
          await client.query(
            `SELECT t.* FROM sms_v2_unknown_templates t WHERE t.template_hash=$1 AND t.lease_id=$2 AND t.ai_status='working'
              AND t.lease_expires_at>clock_timestamp() AND ${currentConsent} FOR UPDATE OF t`,
            [template.template_hash, template.lease_id],
          )
        ).rows[0];
        if (!row) return "consent_or_lease_lost";
        return reserveCapacity(client, {
          prompt,
          config,
          templateHash: template.template_hash,
          attempt,
          jobId: template.lease_id,
        });
      });
    },
    recordAttempt(template, attempt, usage) {
      return tx((client) =>
        recordUsage(client, { jobId: template.lease_id, attempt, usage }),
      );
    },
    // `detail` is the list of failure codes (never text). The swapped-number sample is deleted once the answer is
    // final (ready, failed or covered); a layout going back in the queue keeps it.
    // retryKind: "content" (the draft was bad), "infrastructure" (the provider was in trouble; the attempt stays spent),
    // "capacity" or "refund" (nothing was learned about the layout: the attempt is handed back). `evidence` says an
    // infrastructure retry came with a layout actually being drafted; `excluded` lists providers whose draft was rejected.
    finish(template, { rule = null, code = null, model, requeue = false, covered = null, detail = null, retryKind = null, retryAfterMs = 0, acceptedAttempt = null, evidence = false, excluded = [] }) {
      return tx(async (client) => {
        await client.query(
          "SELECT pg_advisory_xact_lock(hashtext('sms_v2_template_results'))",
        );
        let result;
        if (draftingVersion) {
          const retriesRemain = template.ai_job_attempts < 3;
          const exhaustedByInfra = evidence && retryKind === "infrastructure" && !retriesRemain;
          const terminalInfra = exhaustedByInfra && infraExhaustionTerminal(template);
          const retry = retryKind !== null && (retryKind !== "content" || retriesRemain) && !terminalInfra;
          const countJob = !!rule || (retryKind === "content" && !retriesRemain) || exhaustedByInfra;
          const failureCode = retryKind === "infrastructure" && !retriesRemain
            ? "draft_infrastructure_exhausted"
            : code;
          const status = covered ? "covered" : retry ? "queued" : rule ? "ready" : "failed";
          result = await client.query(
            `UPDATE sms_v2_unknown_templates t SET ai_status=$3,ai_draft=$4::jsonb,failure_code=$5,ai_model=$6,
              covered_by=$7,failure_detail=$8,sample=NULL,lease_id=NULL,lease_expires_at=NULL,
              ai_counted_jobs=ai_counted_jobs+$9::int,
              ai_counted_jobs_by_version=CASE WHEN $9::int=0 THEN ai_counted_jobs_by_version
                ELSE jsonb_set(ai_counted_jobs_by_version,ARRAY[ai_drafting_version],to_jsonb(ai_counted_jobs+1)) END,
              ai_job_attempts=ai_job_attempts-CASE WHEN $10::boolean THEN 1 ELSE 0 END,
              ai_run_after=CASE
                WHEN $10::boolean THEN clock_timestamp()+greatest(interval '1 minute',$11*interval '1 millisecond')
                WHEN $3='queued' THEN clock_timestamp()+greatest(
                  pandapay.sms_v2_draft_retry_delay(ai_job_attempts),$11*interval '1 millisecond')
                ELSE ai_run_after END,
              ai_excluded_providers=CASE WHEN $3='queued' THEN
                ARRAY(SELECT DISTINCT e FROM unnest(ai_excluded_providers||$12::text[]) AS e ORDER BY e) ELSE '{}'::text[] END,
              result_revision=nextval('sms_v2_template_revision')
              WHERE template_hash=$1 AND lease_id=$2 AND ai_status='working'
                AND lease_expires_at>clock_timestamp() AND ${currentConsent}`,
            [template.template_hash, template.lease_id, status, rule ? JSON.stringify(rule) : null, failureCode, model,
              covered, detail, Number(countJob), retryKind === "capacity" || retryKind === "refund", retryAfterMs, excluded],
          );
        } else {
          result = await client.query(
            `UPDATE sms_v2_unknown_templates t SET ai_status=$3::text,ai_draft=$4::jsonb,failure_code=$5,ai_model=$6,covered_by=$7,
            failure_detail=$8::text[],sample=CASE WHEN $3::text='queued' THEN sample ELSE NULL END,
            lease_id=NULL,lease_expires_at=NULL,result_revision=nextval('sms_v2_template_revision')
            WHERE template_hash=$1 AND lease_id=$2 AND ai_status='working' AND lease_expires_at>clock_timestamp()
            ${acceptedAttempt ? `AND ${currentConsent}` : ""}`,
            [
              template.template_hash,
              template.lease_id,
              covered ? "covered" : requeue ? "queued" : rule ? "ready" : "failed",
              rule ? JSON.stringify(rule) : null,
              code,
              model,
              covered,
              detail,
            ],
          );
        }
        if (acceptedAttempt) {
          const { attempt, usage } = acceptedAttempt;
          await recordUsage(client, {
            jobId: template.lease_id,
            attempt,
            usage: result.rowCount === 1 ? usage : {
              ...usage, ...NO_DRAFT_USAGE, outcome: "discarded", errorKind: "consent_or_lease_lost",
            },
          });
        }
        return result.rowCount === 1;
      });
    },
  };
}

// What went wrong in an attempt, as codes only (never text): kept on the attempt row and on the layout.
function failureOf(error) {
  if (error instanceof ProviderBusyError)
    return { kind: error.systemic ? "systemic" : "provider_busy", codes: [error.message], status: error.status ?? null };
  if (error instanceof SyntaxError)
    return error.noRouteLeft
      ? { kind: "no_route_left", codes: ["ai_service_no_route_left"], status: null }
      : { kind: "json_invalid", codes: ["answer_not_json"], status: null };
  if (error instanceof AnswerError || error instanceof LayoutError) return { kind: "answer_invalid", codes: [error.code], status: null };
  return { kind: "provider_error", codes: [String(error?.message ?? "provider_error").slice(0, 60)], status: null };
}

async function runTemplateWorkerOnce({
  store,
  provider,
  config: baseConfig = workerConfig(),
  clock = Date.now,
  // Aborted when the process is told to stop: the in-flight provider call is cancelled and the attempt handed back.
  shutdown = null,
}) {
  const layoutOnly = typeof provider.generateLayout === "function";
  let config = baseConfig;
  let settings = null;
  if (typeof store.settings === "function") {
    settings = await store.settings();
    if (settings.ai_enabled === false) return { status: "disabled" };
    // The service owns cost and limits: only the direct provider is held to the monthly budget.
    if (
      !layoutOnly &&
      typeof store.monthSpend === "function" &&
      (await store.monthSpend()) >= settings.ai_monthly_budget_usd
    )
      return { status: "budget" };
    config = applyWorkerSettings(baseConfig, settings);
    // The separate service owns model selection and the output limit. Use the
    // worker's deployment settings for matching provenance, price and capacity.
    if (layoutOnly) config = { ...config, model: baseConfig.model, maxOutputTokens: baseConfig.maxOutputTokens };
  }
  // Nor does the worker throttle a service call by request/token rate: the service rate-limits and falls back itself.
  if (layoutOnly) config = { ...config, rpm: Infinity, tpm: Infinity };
  // Seconds to rest after a call to the provider, so the queue drains gently (free keys have small limits).
  const gapSeconds = settings?.ai_min_gap_seconds ?? 0;
  // Start before claiming so queue bookkeeping and the request to Render, including a cold start,
  // share the same time budget. The lease leaves extra time for the final PostgreSQL write.
  const attemptDeadline = performance.now() + DRAFT_JOB_DEADLINE_MS;
  const deadline = AbortSignal.timeout(DRAFT_JOB_DEADLINE_MS);
  const callSignal = shutdown ? AbortSignal.any([deadline, shutdown]) : deadline;
  if (shutdown?.aborted) return { status: "shutdown" };
  const claimed = await store.claim();
  if (!claimed) return { status: "idle" };
  // The layout is cleaned before it is drafted, checked and matched (draft_layout.js); the hash stays the original's.
  const template = { ...claimed, redacted_body: draftLayout(claimed.redacted_body) };
  const durable = layoutOnly && template.ai_job_attempts > 0 && !!template.ai_drafting_version;
  const routing = durable ? { skipProviders: template.ai_excluded_providers } : null;
  let errors = [];
  let failure = null;
  let draft = null;
  const rejectedProviders = new Set();
  // The routes already asked a second time with the reasons their draft was refused (once each, then the later routes).
  const rerunDone = new Set();
  try {
    const rules = typeof store.activeRules === "function" ? await store.activeRules(template) : [];
    // A layout the active rules already read is not worth a provider call.
    const covered = coveredBy(template, rules);
    if (covered) {
      await store.finish(template, { model: config.model, covered });
      return { status: "covered", templateHash: template.template_hash, covered };
    }
    // Every key is resting after a rate limit: wait without spending a try or a reservation.
    const resting = typeof provider.waitMs === "function" ? provider.waitMs() : 0;
    if (resting > 0) {
      await store.finish(template, { model: config.model, requeue: true });
      return { status: "provider_busy", retryAfterMs: resting };
    }
    let matcher;
    const layout = { senderBrand: template.sender_brand, redactedBody: template.redacted_body };
    try {
      if (layoutOnly) provider.assertLayout?.(layout);
      matcher = buildMatcher(template.redacted_body);
      // Our own pattern and examples must agree before an AI call is spent (a layout they cannot agree on fails for any answer).
      checkedExamples(template.redacted_body, matcher);
    } catch (error) {
      // A layout too garbled to learn (too many name slots, no words): say so, never guess.
      const code = error instanceof LayoutError ? error.code : "layout_invalid";
      await store.finish(template, { model: config.model, code, detail: ["layout", code] });
      return { status: "failed", templateHash: template.template_hash };
    }
    let directContext;
    if (!layoutOnly) {
      // The legacy provider only uses wording when allowed, safe, and really this layout.
      const wording = settings?.ai_use_sample === false || !template.sample || sampleError(template.sample) ? null : fillTags(template.sample);
      const slots = wording ? slotValues(matcher, wording) : null;
      directContext = {
        sample: slots ? wording : null,
        slots,
        reports: typeof store.userReports === "function" ? await store.userReports(template) : {},
        mistakes: typeof store.previousMistakes === "function" ? await store.previousMistakes(template) : [],
        families: [...new Set(rules.map((rule) => rule.family).filter(Boolean))],
      };
    }
    // A durable job walks the service's routes (up to MAX_DRAFT_ROUTE_CALLS calls, each to a later route, so none repeats
    // a paid request). Any other service call gets one attempt: the service only sees the layout, a retry would repeat it.
    for (let attempt = 1; attempt <= (durable ? MAX_DRAFT_ROUTE_CALLS : layoutOnly ? 1 : 2); attempt++) {
      // In service mode this prompt is used locally for the capacity estimate only.
      const prompt = buildPrompt({ template, matcher, ...directContext, fix: layoutOnly ? [] : errors });
      const blocked = await store.beginAttempt(template, attempt, prompt.system + prompt.user, config);
      if (blocked) {
        if (blocked === "consent_or_lease_lost") return { status: "lease_lost" };
        await store.finish(template, {
          model: config.model,
          code: blocked,
          // Waiting for capacity is never a reason to give up on a layout, on any try.
          requeue: blocked === "capacity",
          ...(durable && blocked === "capacity" ? { retryKind: "capacity" } : {}),
        });
        return { status: blocked };
      }
      const started = clock();
      let response;
      let busy = null;
      let layoutError = null;
      // The model that really answered: the service may fall back to another AI than the one pinned in config.
      let answeredModel = config.model;
      try {
        response = layoutOnly
          ? await provider.generateLayout({
              ...layout, model: config.model, maxOutputTokens: config.maxOutputTokens,
              // Why the last draft was refused, so the next one can correct it (sent only to a service that supports it).
              fix: errors,
              ...(durable ? {
                signal: callSignal,
                routing: { ...routing, timeoutMs: Math.max(1, Math.floor(attemptDeadline - performance.now())) },
              } : {}),
            })
          : await provider.generate({
              system: prompt.system,
              prompt: prompt.user,
              model: config.model,
              maxOutputTokens: config.maxOutputTokens,
              temperature: config.temperature,
            });
        const answer = typeof response.answer === "string" ? JSON.parse(response.answer) : response.answer;
        if (layoutOnly && typeof response.model === "string") answeredModel = response.model;
        const rule = buildRule(answer, template, matcher, answeredModel);
        errors = await validateDraftSafely(rule, template, answeredModel, []);
        failure = errors.length ? { kind: "validation", codes: errors, status: null } : null;
        if (!errors.length) draft = rule;
      } catch (error) {
        // An unrouted call that answered with unusable output still reports what it used.
        if (layoutOnly) response ??= error?.usage;
        failure = failureOf(error);
        errors = failure.codes;
        if (error instanceof ProviderBusyError) busy = error;
        if (layoutOnly && error instanceof LayoutError) layoutError = error.code;
        if (durable && failure.kind === "provider_error") {
          busy = new ProviderBusyError("draft_worker_unavailable", { systemic: true });
          failure = failureOf(busy);
          errors = failure.codes;
        }
      }
      const usage = {
        // A rejected draft was still billed: keep its tokens (zero when no answer came back). The service owns the price.
        ...draftUsage(response, config, layoutOnly),
        latencyMs: Math.max(0, clock() - started),
        promptVersion: provider.promptVersion ?? PROMPT_VERSION,
        outcome: busy?.systemic ? "provider_error" : errors.length ? "rejected" : "valid",
        errorKind: failure?.kind ?? null,
        // A valid draft lists the repairs it needed (draft_repair.js), so how often they rescue a draft can be measured.
        errorCodes: failure?.codes ?? (draft?.repairs?.length ? draft.repairs.map((code) => `repaired_${code}`) : null),
        httpStatus: failure?.status ?? null,
      };
      if (!layoutOnly || errors.length) await store.recordAttempt(template, attempt, usage);
      if (layoutError) {
        await store.finish(template, { model: config.model, code: layoutError, detail: ["layout", layoutError] });
        return { status: "failed", templateHash: template.template_hash };
      }
      if (busy) {
        if (durable) {
          // Told to stop, or the service is misconfigured: nothing was learned about the layout, so hand the attempt
          // back. A misconfigured service also makes the worker rest instead of walking the queue.
          const interrupted = shutdown?.aborted === true;
          const refund = interrupted || busy.configFault;
          const saved = await store.finish(template, {
            model: config.model, code: interrupted ? "worker_interrupted" : "provider_unavailable",
            detail: [failure.kind, ...failure.codes],
            retryKind: refund ? "refund" : "infrastructure", retryAfterMs: busy.retryAfterMs || 0,
          });
          if (saved === false) return { status: "lease_lost" };
          if (interrupted) return { status: "shutdown" };
          return {
            status: "provider_busy", retryAfterMs: busy.retryAfterMs || SYSTEMIC_WAIT_MS,
            providerStatus: busy.status, systemic: true, rescheduled: !refund, gapSeconds,
          };
        }
        // The provider failed, not the draft. Do not spend the layout's tries on it: put it back in the queue and
        // let the worker wait. Only a layout the provider has failed on many separate times is given up on.
        if (busy.systemic) {
          await store.finish(template, { model: config.model, requeue: true });
          return {
            status: "provider_busy",
            retryAfterMs: busy.retryAfterMs || SYSTEMIC_WAIT_MS,
            providerStatus: busy.status,
            systemic: true,
          };
        }
        const failures = typeof store.providerFailures === "function" ? await store.providerFailures(template) : 0;
        // With no success anywhere in the last hour this is an outage: wait it out rather than blame the layout.
        const providerWorked =
          typeof store.providerRecentlyWorked === "function" ? await store.providerRecentlyWorked() : true;
        if (failures >= MAX_PROVIDER_FAILURES && providerWorked) {
          await store.finish(template, { model: config.model, code: "provider_unavailable", detail: [failure.kind, ...failure.codes] });
          return { status: "failed", templateHash: template.template_hash };
        }
        await store.finish(template, { model: config.model, requeue: true });
        return { status: "provider_busy", retryAfterMs: busy.retryAfterMs || 0, providerStatus: busy.status };
      }
      if (!errors.length) {
        const saved = await store.finish(template, {
          rule: draft,
          model: answeredModel,
          ...(layoutOnly ? { acceptedAttempt: { attempt, usage } } : {}),
        });
        if (saved === false) return { status: "lease_lost" };
        return { status: "ready", templateHash: template.template_hash, gapSeconds };
      }
      if (durable) {
        routing.hadInfrastructureFailure ||= response?.routeHadInfrastructureFailure === true;
        if (response?.routeProvider) rejectedProviders.add(response.routeProvider);
        if (!response?.routeProvider) break;
        // A route whose draft was refused is asked once more, now with the reasons (a service that announced it; an older
        // one answers the next route as before). After that the later routes follow.
        routing.rerun = !rerunDone.has(response.routeProvider);
        rerunDone.add(response.routeProvider);
        routing.afterProvider = response.routeProvider;
      }
    }
    const infrastructure = durable && (deadline.aborted || routing.hadInfrastructureFailure);
    const saved = await store.finish(template, {
      model: config.model,
      code: infrastructure ? "provider_unavailable" : "draft_validation_failed",
      detail: [failure.kind, ...failure.codes],
      ...(durable ? { retryKind: infrastructure ? "infrastructure" : "content", evidence: infrastructure, excluded: [...rejectedProviders] } : {}),
    });
    if (saved === false) return { status: "lease_lost" };
    if (durable && (infrastructure ? !infraExhaustionTerminal(template) : template.ai_job_attempts < 3)) return { status: "retry_scheduled", gapSeconds };
    return { status: "failed", templateHash: template.template_hash, gapSeconds };
  } catch {
    const interrupted = durable && shutdown?.aborted === true;
    const saved = await store.finish(template, {
      model: config.model,
      code: interrupted ? "worker_interrupted" : "worker_failed",
      ...(durable ? { retryKind: interrupted ? "refund" : "infrastructure" } : {}),
    });
    if (saved === false) return { status: "lease_lost" };
    if (interrupted) return { status: "shutdown" };
    if (durable) return { status: "retry_scheduled", gapSeconds };
    return { status: "failed", templateHash: template.template_hash };
  }
}

// The keys the host gives the worker, in order: GEMINI_API_KEY, GEMINI_FALLBACK_API_KEY, then GEMINI_API_KEYS
// (comma separated). Used in turn, so each free key carries half the load; a key that hits a limit rests.
function parseApiKeys(env = process.env) {
  const keys = [env.GEMINI_API_KEY, env.GEMINI_FALLBACK_API_KEY, ...String(env.GEMINI_API_KEYS ?? "").split(",")]
    .map((key) => String(key ?? "").trim())
    .filter(Boolean);
  return [...new Set(keys)];
}
// A daily quota says "PerDay": retrying in a minute only fails again.
const DAY_QUOTA = /PerDay/i;
const DAY_QUOTA_WAIT_MS = 30 * 60 * 1000;
const DEFAULT_QUOTA_WAIT_MS = 60 * 1000;

function createGeminiTemplateProvider({
  apiKey,
  apiKeys,
  fetchImpl = fetch,
  now = Date.now,
  fallbackModel = process.env.SMS_V2_AI_FALLBACK_MODEL || null,
  // Only a local test points this elsewhere (api/scripts/fake_gemini_server.js); a hosted worker never sets it.
  baseUrl = process.env.SMS_V2_AI_BASE_URL || "https://generativelanguage.googleapis.com",
} = {}) {
  const keys = apiKeys ?? (apiKey ? [apiKey] : parseApiKeys());
  if (!keys.length) throw new Error("GEMINI_API_KEY_required");
  const restingUntil = new Map();
  let turn = 0;

  async function once(key, model, { system, prompt, maxOutputTokens, temperature }) {
    let response;
    try {
      response = await fetchImpl(
        `${baseUrl.replace(/\/$/, "")}/v1beta/models/${encodeURIComponent(model)}:generateContent`,
        {
          method: "POST",
          redirect: "error",
          signal: AbortSignal.timeout(45000),
          headers: { "Content-Type": "application/json", "x-goog-api-key": key },
          body: JSON.stringify({
            ...(system ? { systemInstruction: { parts: [{ text: system }] } } : {}),
            contents: [{ role: "user", parts: [{ text: prompt }] }],
            generationConfig: {
              responseMimeType: "application/json",
              maxOutputTokens,
              ...(Number.isFinite(temperature) ? { temperature } : {}),
            },
          }),
        },
      );
    } catch (error) {
      // A timeout or a network failure says nothing about the layout: try again later.
      if (error?.name === "TimeoutError" || error?.name === "AbortError" || error instanceof TypeError)
        throw new ProviderBusyError("template_provider_unreachable");
      throw error;
    }
    if (!response.ok) {
      let bodyText = "";
      try {
        bodyText = (await response.text?.())?.slice(0, 4096) ?? "";
      } catch {
        bodyText = "";
      }
      const delay = providerDelayMs(bodyText, response.headers);
      // A rate limit: this key rests (the others may still work); the layout is fine.
      if (response.status === 429 || (response.status === 403 && QUOTA_BODY.test(bodyText))) {
        const wait = DAY_QUOTA.test(bodyText) ? Math.max(delay, DAY_QUOTA_WAIT_MS) : delay || DEFAULT_QUOTA_WAIT_MS;
        throw Object.assign(new ProviderBusyError("template_provider_busy", { status: response.status, retryAfterMs: wait }), { limited: true });
      }
      // 503 (overloaded) and the other "come back later" answers are not a bad draft either.
      if (BUSY_STATUSES.has(response.status))
        throw new ProviderBusyError("template_provider_busy", { status: response.status, retryAfterMs: delay });
      // An old model name answers 404: use the fallback model once.
      if (response.status === 404 && fallbackModel && model !== fallbackModel) throw Object.assign(new Error("model_missing"), { missingModel: true });
      // A refused key, model or billing is the same for every layout: wait, never fail layouts for it.
      if (isSystemicProviderAnswer(response.status, bodyText))
        throw new ProviderBusyError("template_provider_misconfigured", {
          status: response.status,
          retryAfterMs: SYSTEMIC_WAIT_MS,
          systemic: true,
        });
      throw new Error("template_provider_failed");
    }
    let size = 0;
    const chunks = [];
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > 262144) throw new Error("template_provider_response_too_large");
      chunks.push(chunk);
    }
    const result = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (result.candidates?.length !== 1 || result.candidates[0].finishReason !== "STOP") {
      // Billed even though it is cut off: keep the tokens for the books.
      throw Object.assign(new Error("template_provider_incomplete"), { usage: result.usageMetadata });
    }
    return {
      answer: result.candidates[0].content.parts
        .filter((part) => !part.thought)
        .map((part) => part.text || "")
        .join(""),
      inputTokens: result.usageMetadata?.promptTokenCount,
      outputTokens: result.usageMetadata?.candidatesTokenCount,
      totalTokens: result.usageMetadata?.totalTokenCount,
    };
  }

  return {
    // Milliseconds until some key may be used again (0 when one can be used now).
    waitMs() {
      const waits = keys.map((key) => Math.max(0, (restingUntil.get(key) ?? 0) - now()));
      return Math.min(...waits);
    },
    async generate(args) {
      let model = args.model;
      let usedFallback = false;
      let limit = null;
      for (let step = 0; step < keys.length; step++) {
        const index = (turn + step) % keys.length;
        const key = keys[index];
        if ((restingUntil.get(key) ?? 0) > now()) continue;
        for (;;) {
          try {
            const result = await once(key, model, args);
            turn = index + 1;
            return result;
          } catch (error) {
            if (error.missingModel && !usedFallback) {
              model = fallbackModel;
              usedFallback = true;
              continue;
            }
            if (!error.limited) throw error;
            restingUntil.set(key, now() + error.retryAfterMs);
            limit = error;
            break;
          }
        }
      }
      // Every key is resting (now, or just now): the layout waits, with the shortest wait among them.
      throw new ProviderBusyError("template_provider_busy", {
        status: limit?.status ?? 429,
        retryAfterMs: Math.max(this.waitMs(), 1000),
      });
    },
  };
}

module.exports = {
  ProviderBusyError,
  AnswerError,
  MAX_PROVIDER_FAILURES,
  busyWaitMs,
  providerDelayMs,
  isSystemicProviderAnswer,
  reserveCapacity,
  monthSpendUsd,
  recordUsage,
  PROMPT_VERSION,
  coveredBy,
  SMS_PLACEHOLDERS,
  SMS_DOMAIN_RULES,
  workerConfig,
  applyWorkerSettings,
  fillSynthetic,
  buildPrompt,
  buildRule,
  stampDraft,
  validateDraft,
  validateDraftSafely,
  createPgWorkerStore,
  runTemplateWorkerOnce,
  parseApiKeys,
  createGeminiTemplateProvider,
};
