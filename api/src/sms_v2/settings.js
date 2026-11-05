'use strict';

// Admin-adjustable values. The environment sets hard ceilings and the model
// allow-list, so a console change can never exceed what the host allows.
// Every key here has a row in the console's Settings tab: GET
// /admin/sms/v2/settings returns exactly listSettings(), so a setting cannot
// exist without a console row.
const SETTINGS = Object.freeze({
  templates_per_user_per_day: { type: 'int', default: 50, min: 1, max: 500, env: 'SMS_V2_UNKNOWN_TEMPLATES_PER_DAY' },
  corrections_per_user_per_day: { type: 'int', default: 200, min: 1, max: 2000, env: 'SMS_V2_CORRECTIONS_PER_DAY' },
  signals_per_user_per_day: { type: 'int', default: 500, min: 1, max: 5000, env: 'SMS_V2_LEARNING_SIGNALS_PER_DAY' },
  signals_min_distinct_users: { type: 'int', default: 3, min: 2, max: 20 },
  signals_retention_days: { type: 'int', default: 180, min: 30, max: 730 },
  intake_enabled: { type: 'bool', default: true }, // false: phones' layouts and signals are refused with 503 learning_paused
  ai_enabled: { type: 'bool', default: true },
  ai_merchant_suggestions_enabled: { type: 'bool', default: false },
  ai_model: { type: 'model', default: null }, // null = SMS_V2_AI_MODEL
  ai_rpm: { type: 'int', default: 30, min: 1, ceilingEnv: 'SMS_V2_AI_RPM' },
  ai_tpm: { type: 'int', default: 100000, min: 1000, ceilingEnv: 'SMS_V2_AI_TPM' },
  ai_temperature: { type: 'number', default: 0.1, min: 0, max: 1 },
  ai_max_output_tokens: { type: 'int', default: 4096, min: 512, max: 8192 },
  ai_monthly_budget_usd: { type: 'number', default: 10, min: 0, max: 1000 },
  auto_pause_min_hits: { type: 'int', default: 50, min: 10, max: 10000 },
  auto_pause_min_rate: { type: 'number', default: 0.01, min: 0.001, max: 0.5 },
});

// The few values the public API needs (see pandapay.sms_v2_public_settings()).
const PUBLIC_KEYS = Object.freeze([
  'intake_enabled', 'templates_per_user_per_day', 'corrections_per_user_per_day', 'signals_per_user_per_day',
]);
const USER_LIMIT_KEYS = Object.freeze(['templates_per_user_per_day', 'signals_per_user_per_day']);

class SettingError extends Error {
  constructor(key) {
    super('setting_invalid');
    this.status = 422;
    this.code = 'setting_invalid';
    this.key = key;
  }
}

function allowedModels(env) {
  return String(env.SMS_V2_AI_MODELS_ALLOWED || env.SMS_V2_AI_MODEL || '')
    .split(',').map((s) => s.trim()).filter(Boolean);
}

// The largest value the host allows for a key: the environment ceiling when it
// names one (or, for per-day caps, the operator's configured value), else the
// registry maximum. `undefined` means unbounded.
function ceilingOf(spec, env) {
  const source = spec.ceilingEnv ?? spec.env;
  if (source && env[source] !== undefined && Number.isFinite(Number(env[source]))) return Number(env[source]);
  return spec.max;
}

function validateSetting(key, value, env = process.env) {
  const spec = Object.hasOwn(SETTINGS, key) ? SETTINGS[key] : undefined;
  if (!spec) throw new SettingError(key);
  if (spec.type === 'bool') {
    if (typeof value !== 'boolean') throw new SettingError(key);
    return value;
  }
  if (spec.type === 'model') {
    if (value !== null && !allowedModels(env).includes(value)) throw new SettingError(key);
    return value;
  }
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new SettingError(key);
  if (spec.type === 'int' && !Number.isSafeInteger(value)) throw new SettingError(key);
  const ceiling = ceilingOf(spec, env);
  if (value < spec.min || (ceiling !== undefined && value > ceiling)) throw new SettingError(key);
  return value;
}

function defaultsOf() {
  return Object.fromEntries(Object.entries(SETTINGS).map(([key, spec]) => [key, spec.default]));
}

// Defaults overlaid with stored values; a stored value that no longer
// validates (a lowered ceiling, a removed model) falls back to its default.
function mergeSettings(rows, env = process.env) {
  const merged = defaultsOf();
  for (const row of rows) {
    if (!Object.hasOwn(SETTINGS, row.key)) continue;
    try { merged[row.key] = validateSetting(row.key, row.value, env); } catch { /* keep default */ }
  }
  return merged;
}

// One row for every key in SETTINGS: what the console shows.
function listSettings(storedRows, env = process.env) {
  const stored = new Map(storedRows.map((row) => [row.key, row]));
  return Object.entries(SETTINGS).map(([key, spec]) => {
    const row = stored.get(key);
    const numeric = spec.type === 'int' || spec.type === 'number';
    return {
      key,
      type: spec.type,
      value: row ? row.value : spec.default,
      default: spec.default,
      min: numeric ? spec.min : null,
      max: numeric ? spec.max ?? null : null,
      ceiling: numeric ? ceilingOf(spec, env) ?? null : null,
      allowed: spec.type === 'model' ? allowedModels(env) : null,
      stored: !!row,
      updatedAt: row ? row.updatedAt : null,
      updatedBy: row ? row.updatedBy : null,
      reason: row ? row.reason : null,
    };
  });
}

const SELECT_STORED = `SELECT key, value, updated_by AS "updatedBy", reason,
  to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "updatedAt"
  FROM sms_v2_settings ORDER BY key`;

async function storedSettings(client) {
  return (await client.query(SELECT_STORED)).rows;
}

const TTL_MS = 60 * 1000;
const caches = new Map();
function clearSettingsCache() { caches.clear(); }

async function cached(name, load, { now = Date.now, ttlMs = TTL_MS, force = false } = {}) {
  const hit = caches.get(name);
  if (!force && hit && now() - hit.at < ttlMs) return hit.value;
  const value = await load();
  caches.set(name, { at: now(), value });
  return value;
}

// Admin and worker processes: every key, defaults merged, cached for 60 s.
function readSettings(client, options = {}) {
  const env = options.env || process.env;
  return cached('all', async () => mergeSettings(await storedSettings(client), env), options);
}

// Public API: only stored values for the public keys. Absent keys fall back to
// the operator's environment and the built-in defaults at the call site.
function readPublicSettings(client, options = {}) {
  return cached('public', async () => {
    const result = await client.query('SELECT pandapay.sms_v2_public_settings() AS settings');
    const raw = result.rows?.[0]?.settings;
    const out = {};
    if (raw && typeof raw === 'object') for (const key of PUBLIC_KEYS) if (Object.hasOwn(raw, key)) out[key] = raw[key];
    return out;
  }, options);
}

// False only when an admin switched intake off. Fakes without settings stay open.
async function intakeOpen(security, req) {
  if (typeof security?.storedSettings !== 'function') return true;
  try {
    return (await security.storedSettings(req)).intake_enabled !== false;
  } catch {
    return true;
  }
}

module.exports = {
  SETTINGS, PUBLIC_KEYS, USER_LIMIT_KEYS, SettingError,
  validateSetting, mergeSettings, listSettings, storedSettings, readSettings, readPublicSettings,
  clearSettingsCache, ceilingOf, intakeOpen,
};
