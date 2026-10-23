'use strict';

const crypto = require('node:crypto');
const {
  normalizeMerchantVpa,
  normalizeMerchantName,
  isGenericMerchantName,
} = require('./merchant_bulk_category');

const MAX_LIST_LIMIT = 100;
const MAX_EXAMPLES = 20;
const RULE_ENTITY = 'user_merchant_category_rules';
const RULE_ACTIONS = new Set(['category', 'flag']);
const UNSAFE_RULE_NAMES = new Set([
  'razorpay', 'payu', 'cashfree', 'billdesk', 'ccavenue', 'juspay', 'stripe',
  'payment gateway', 'gateway', 'upi', 'upi collect', 'phonepe', 'paytm',
  'bharatpe', 'mobikwik', 'amazon pay',
]);

class MerchantRuleError extends Error {
  constructor(code, status = 400, details = undefined) {
    super(code);
    this.name = 'MerchantRuleError';
    this.code = code;
    this.status = status;
    this.details = details;
  }
}

function uuid(value) {
  return typeof value === 'string'
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function bodyValue(body, snake, camel = snake) {
  return Object.prototype.hasOwnProperty.call(body || {}, snake) ? body[snake] : body?.[camel];
}

function parseAction(body, fallback = 'category') {
  const supplied = bodyValue(body, 'action', 'actionType');
  const action = supplied === undefined || supplied === null || supplied === ''
    ? fallback
    : String(supplied).trim().toLowerCase();
  if (!RULE_ACTIONS.has(action)) throw new MerchantRuleError('action_invalid', 400);
  return action;
}

function parseFlag(body, fallback = null) {
  const supplied = bodyValue(body, 'flag', 'flagKey');
  const flag = supplied === undefined || supplied === null || supplied === ''
    ? fallback
    : String(supplied).trim().toLowerCase();
  if (flag === null || flag === undefined) return null;
  if (!/^[a-z][a-z0-9_.:-]{0,63}$/.test(flag)) {
    throw new MerchantRuleError('flag_invalid', 400);
  }
  return flag;
}

function validateActionTarget(action, categoryId, userCategoryId, flag) {
  if (action === 'category') {
    if (!uuid(categoryId) || flag !== null) {
      throw new MerchantRuleError('category_action_target_invalid', 400);
    }
    return;
  }
  if (flag === null || categoryId !== null || userCategoryId !== null) {
    throw new MerchantRuleError('flag_action_target_invalid', 400);
  }
}

function requestHash(input) {
  return crypto.createHash('sha256').update(JSON.stringify(input)).digest('hex');
}

function ruleMatchFromTransaction(transaction) {
  const rawVpa = transaction?.merchant_vpa ?? transaction?.merchantVpa;
  const vpa = normalizeMerchantVpa(rawVpa);
  if (vpa) {
    if (!vpa.includes('@') || /\s/.test(vpa)) throw new MerchantRuleError('merchant_identity_unsafe', 422);
    return { basis: 'vpa', value: vpa };
  }
  const name = normalizeMerchantName(transaction?.merchant_name ?? transaction?.merchantName);
  if (!name || isGenericMerchantName(name) || UNSAFE_RULE_NAMES.has(name)
      || /\b(?:payment\s+)?gateway\b/i.test(name)) {
    throw new MerchantRuleError('merchant_identity_unsafe', 422);
  }
  return { basis: 'strict_name', value: name };
}

function assertSourceTransaction(transaction) {
  if (!transaction) throw new MerchantRuleError('source_transaction_not_found', 404);
  if (transaction.status !== 'active' || (transaction.entry_kind || 'spend') !== 'spend') {
    throw new MerchantRuleError('source_transaction_ineligible', 422);
  }
  if (transaction.is_split_parent || transaction.parent_txn_id || transaction.has_splits) {
    throw new MerchantRuleError('source_transaction_ineligible', 422);
  }
  return transaction;
}

async function loadSourceTransaction(client, profileId, sourceId) {
  if (!uuid(sourceId)) throw new MerchantRuleError('source_transaction_required', 400);
  const result = await client.query(
    `SELECT t.id, t.profile_id, t.merchant_name, t.merchant_vpa, t.status,
            t.entry_kind, t.category_id, t.user_category_id,
            t.is_split_parent, t.parent_txn_id,
            EXISTS (SELECT 1 FROM transaction_splits s WHERE s.transaction_id = t.id) AS has_splits
       FROM transactions t
      WHERE t.id = $1 AND t.profile_id = $2`,
    [sourceId, profileId],
  );
  return assertSourceTransaction(result.rows[0]);
}

async function loadCategoryTarget(client, profileId, categoryId, userCategoryId) {
  if (categoryId !== null && categoryId !== undefined && !uuid(categoryId)) {
    throw new MerchantRuleError('category_invalid', 400);
  }
  if (userCategoryId !== null && userCategoryId !== undefined && !uuid(userCategoryId)) {
    throw new MerchantRuleError('user_category_invalid', 400);
  }
  if (!uuid(categoryId) && (userCategoryId === null || userCategoryId === undefined)) {
    throw new MerchantRuleError('category_required', 400);
  }

  const userCategories = userCategoryId === null || userCategoryId === undefined
    ? { rows: [] }
    : await client.query(
      `SELECT id, name, parent_category_id, parent_user_category_id
         FROM user_categories WHERE profile_id = $1`,
      [profileId],
    );
  const byId = new Map(userCategories.rows.map((row) => [String(row.id), row]));
  let category = null;
  if (uuid(categoryId)) {
    const categoryResult = await client.query(
      'SELECT id, name, slug FROM spend_categories WHERE id = $1',
      [categoryId],
    );
    category = categoryResult.rows[0];
    if (!category) throw new MerchantRuleError('category_not_found', 422);
  }
  if (userCategoryId === null || userCategoryId === undefined) {
    return { categoryId: category.id, categoryName: category.name, categorySlug: category.slug, userCategoryId: null, userCategoryName: null };
  }
  const child = byId.get(String(userCategoryId));
  if (!child) throw new MerchantRuleError('user_category_not_found', 422);
  const seen = new Set();
  let current = child;
  let resolvedCategoryId = null;
  while (current) {
    if (seen.has(String(current.id))) throw new MerchantRuleError('category_parent_invalid', 422);
    seen.add(String(current.id));
    if (current.parent_category_id) {
      resolvedCategoryId = String(current.parent_category_id);
      break;
    }
    current = current.parent_user_category_id
      ? byId.get(String(current.parent_user_category_id))
      : null;
  }
  if (!category) {
    const categoryResult = await client.query(
      'SELECT id, name, slug FROM spend_categories WHERE id = $1',
      [resolvedCategoryId],
    );
    category = categoryResult.rows[0];
    if (!category) throw new MerchantRuleError('category_not_found', 422);
  }
  if (String(resolvedCategoryId) !== String(category.id)) {
    throw new MerchantRuleError('category_parent_mismatch', 422);
  }
  return {
    categoryId: category.id,
    categoryName: category.name,
    categorySlug: category.slug,
    userCategoryId: child.id,
    userCategoryName: child.name,
  };
}

function categoryIdentity(target) {
  return {
    categoryId: target.categoryId,
    categoryName: target.categoryName,
    categorySlug: target.categorySlug,
    userCategoryId: target.userCategoryId || null,
    userCategoryName: target.userCategoryName || null,
  };
}

function safeMerchantName(name) {
  if (typeof name !== 'string') return null;
  const normalized = name.trim().replace(/\s+/g, ' ');
  return normalized ? normalized.slice(0, 120) : null;
}

function responseForRule(row, extra = {}) {
  if (!row) return null;
  const action = row.action || row.action_type || 'category';
  const flag = row.flag || row.flag_key || null;
  const category = {
    categoryId: row.category_id,
    categoryName: row.category_name || null,
    categorySlug: row.category_slug || null,
    userCategoryId: row.user_category_id || null,
    userCategoryName: row.user_category_name || null,
  };
  return {
    id: row.id,
    action,
    flag,
    flagKey: flag,
    matchBasis: row.match_basis,
    matchValue: row.match_value,
    merchantName: safeMerchantName(row.display_merchant_name || row.merchant_name),
    displayMerchantName: safeMerchantName(row.display_merchant_name || row.merchant_name),
    category,
    ...category,
    isActive: row.is_active === true,
    version: Number(row.version),
    sourceTransactionId: row.source_transaction_id || null,
    createdAt: row.created_at || null,
    updatedAt: row.updated_at || null,
    historicTransactionsUnchanged: true,
    ...extra,
  };
}

const RULE_SELECT = `
  SELECT r.id, r.profile_id, r.match_basis, r.match_value, r.action, r.flag, r.category_id,
         r.user_category_id, r.is_active, r.version, r.source_transaction_id,
         r.created_at, r.updated_at,
         sc.name AS category_name, sc.slug AS category_slug,
         uc.name AS user_category_name,
         source_txn.merchant_name AS display_merchant_name
    FROM user_merchant_category_rules r
    LEFT JOIN spend_categories sc ON sc.id = r.category_id
    LEFT JOIN user_categories uc ON uc.id = r.user_category_id AND uc.profile_id = r.profile_id
    LEFT JOIN transactions source_txn
      ON source_txn.id = r.source_transaction_id AND source_txn.profile_id = r.profile_id`;

async function readRule(client, profileId, ruleId, lock = false) {
  const result = await client.query(
    `${RULE_SELECT} WHERE r.id = $1 AND r.profile_id = $2${lock ? ' FOR UPDATE OF r' : ''}`,
    [ruleId, profileId],
  );
  return result.rows[0] || null;
}

async function readRuleByKey(client, profileId, basis, value, lock = false) {
  const result = await client.query(
    `${RULE_SELECT} WHERE r.profile_id = $1 AND r.match_basis = $2 AND r.match_value = $3
       ORDER BY r.is_active DESC, r.updated_at DESC${lock ? ' FOR UPDATE OF r' : ''}`,
    [profileId, basis, value],
  );
  return result.rows[0] || null;
}

function conflict(res, code, current) {
  return res.status(409).json({ error: code, current: current ? responseForRule(current) : undefined });
}

async function writeSyncChange(client, profileId, rule, operation) {
  await client.query(
    `INSERT INTO change_log
       (profile_id, device_id, entity, entity_id, op, payload, field_clocks, client_seq)
     VALUES ($1, NULL, $2, $3, 'update', $4::jsonb, '{}'::jsonb, 0)`,
    [profileId, RULE_ENTITY, rule.id, JSON.stringify({
      match_basis: rule.match_basis,
      match_value: rule.match_value,
      action: rule.action || 'category',
      flag: rule.flag || null,
      category_id: rule.category_id,
      user_category_id: rule.user_category_id,
      is_active: rule.is_active,
      version: rule.version,
      operation,
    })],
  );
}

async function writeAudit(client, profileId, actorId, operation, oldRule, newRule) {
  await client.query(
    `INSERT INTO user_merchant_category_rule_audit
      (profile_id, rule_id, actor_id, operation, old_action, old_flag,
        new_action, new_flag, old_category_id, old_user_category_id,
        new_category_id, new_user_category_id, old_is_active, new_is_active, version)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)`,
    [profileId, newRule.id, actorId, operation,
      oldRule?.action || 'category', oldRule?.flag || null,
      newRule.action || 'category', newRule.flag || null,
      oldRule?.category_id || null, oldRule?.user_category_id || null,
      newRule.category_id, newRule.user_category_id || null,
      oldRule?.is_active ?? null, newRule.is_active, newRule.version],
  );
}

async function loadExamples(client, profileId, match) {
  const clause = match.basis === 'vpa'
    ? 't.merchant_vpa = $2'
    : `lower(regexp_replace(btrim(t.merchant_name), '\\s+', ' ', 'g')) = $2 AND t.merchant_vpa IS NULL`;
  const result = await client.query(
    `SELECT t.id, t.merchant_name, t.occurred_at, t.amount_inr
       FROM transactions t
      WHERE t.profile_id = $1 AND t.status = 'active' AND t.entry_kind = 'spend'
        AND ${clause}
      ORDER BY t.occurred_at DESC, t.id DESC LIMIT ${MAX_EXAMPLES}`,
    [profileId, match.value],
  );
  return result.rows.map((row) => ({
    id: row.id,
    merchantName: safeMerchantName(row.merchant_name),
    occurredAt: row.occurred_at,
    amountInr: row.amount_inr,
  }));
}

function parseIdempotency(req, body) {
  const header = typeof req.get === 'function' ? req.get('Idempotency-Key') : req.headers?.['idempotency-key'];
  const key = typeof header === 'string' && header.trim() ? header.trim() : bodyValue(body, 'idempotency_key', 'idempotencyKey');
  if (typeof key !== 'string' || key.trim().length < 8 || key.trim().length > 200) {
    throw new MerchantRuleError('idempotency_key_required', 400);
  }
  return key.trim();
}

function parseExpectedVersion(body) {
  const value = bodyValue(body, 'expected_version', 'expectedVersion');
  if (value === undefined || value === null || value === '') return null;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1) throw new MerchantRuleError('expected_version_invalid', 400);
  return parsed;
}

function decodeCursor(value) {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string') throw new MerchantRuleError('cursor_invalid', 400);
  try {
    const parsed = JSON.parse(Buffer.from(value, 'base64url').toString('utf8'));
    if (!parsed || typeof parsed.updatedAt !== 'string' || !uuid(parsed.id)) throw new Error('invalid');
    return parsed;
  } catch (_) {
    throw new MerchantRuleError('cursor_invalid', 400);
  }
}

function encodeCursor(row) {
  if (!row?.updated_at || !row?.id) return null;
  return Buffer.from(JSON.stringify({ updatedAt: row.updated_at, id: row.id })).toString('base64url');
}

async function createRule({ client, profileId, actorId, body, idempotencyKey }) {
  const sourceId = bodyValue(body, 'source_transaction_id', 'sourceTransactionId');
  const categoryId = bodyValue(body, 'category_id', 'categoryId');
  const userCategoryId = bodyValue(body, 'user_category_id', 'userCategoryId');
  const action = parseAction(body);
  const flag = parseFlag(body);
  const expectedVersion = parseExpectedVersion(body);
  const hash = requestHash({ sourceId, action, flag, categoryId, userCategoryId: userCategoryId || null, expectedVersion });
  await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))', [`merchant-rule-idempotency:${profileId}:${idempotencyKey}`]);
  const existingIdempotency = await client.query(
    `SELECT request_hash, result FROM user_merchant_category_rule_idempotency
      WHERE profile_id = $1 AND idempotency_key = $2 FOR UPDATE`,
    [profileId, idempotencyKey],
  );
  if (existingIdempotency.rows[0]) {
    if (existingIdempotency.rows[0].request_hash !== hash) {
      throw new MerchantRuleError('idempotency_key_reused', 409);
    }
    if (existingIdempotency.rows[0].result) return { status: 200, result: existingIdempotency.rows[0].result, idempotent: true };
  } else {
    await client.query(
      `INSERT INTO user_merchant_category_rule_idempotency(profile_id,idempotency_key,request_hash)
       VALUES($1,$2,$3)`,
      [profileId, idempotencyKey, hash],
    );
  }

  const source = await loadSourceTransaction(client, profileId, sourceId);
  const match = ruleMatchFromTransaction(source);
  const target = action === 'category'
    ? await loadCategoryTarget(client, profileId, categoryId, userCategoryId)
    : { categoryId: null, userCategoryId: null };
  validateActionTarget(action, target.categoryId, target.userCategoryId, flag);
  let rule = await readRuleByKey(client, profileId, match.basis, match.value, true);
  const oldRule = rule;
  let operation = 'create';
  let resultStatus = 201;
  if (rule) {
    if (expectedVersion === null) throw new MerchantRuleError('rule_exists', 409, responseForRule(rule));
    if (Number(rule.version) !== expectedVersion) throw new MerchantRuleError('version_conflict', 409, responseForRule(rule));
    operation = rule.is_active ? 'replace' : 'enable';
    resultStatus = 200;
    const updated = await client.query(
      `UPDATE user_merchant_category_rules
          SET action=$1, flag=$2, category_id=$3, user_category_id=$4, source_transaction_id=$5,
              is_active=true, version=version+1, updated_at=now()
        WHERE id=$6 AND profile_id=$7 RETURNING *`,
      [action, flag, target.categoryId, target.userCategoryId, source.id, rule.id, profileId],
    );
    rule = (await readRule(client, profileId, updated.rows[0].id)) || updated.rows[0];
  } else {
    try {
      const inserted = await client.query(
        `INSERT INTO user_merchant_category_rules
           (profile_id,match_basis,match_value,action,flag,category_id,user_category_id,source_transaction_id)
         VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id`,
        [profileId, match.basis, match.value, action, flag, target.categoryId, target.userCategoryId, source.id],
      );
      rule = await readRule(client, profileId, inserted.rows[0].id);
    } catch (error) {
      if (error?.code === '23505') {
        const conflicting = await readRuleByKey(client, profileId, match.basis, match.value);
        throw new MerchantRuleError('rule_exists', 409, responseForRule(conflicting));
      }
      throw error;
    }
  }
  await writeAudit(client, profileId, actorId, operation, oldRule, rule);
  await writeSyncChange(client, profileId, rule, operation);
  const result = responseForRule(rule, { statement: 'Future transactions only; historic transactions were unchanged.' });
  await client.query(
    `UPDATE user_merchant_category_rule_idempotency SET result=$3::jsonb
      WHERE profile_id=$1 AND idempotency_key=$2`,
    [profileId, idempotencyKey, JSON.stringify(result)],
  );
  return { status: resultStatus, result };
}

function errorResponse(res, error) {
  if (error instanceof MerchantRuleError) {
    if (error.status === 409 && error.details) {
      return res.status(409).json({ error: error.code, currentRule: error.details });
    }
    return res.status(error.status).json({ error: error.code });
  }
  if (error?.code === '23505') return res.status(409).json({ error: 'rule_conflict' });
  if (error?.code === '42P01') return res.status(503).json({ error: 'rules_unavailable' });
  console.error('merchant category rule route error', error);
  return res.status(500).json({ error: 'internal_error' });
}

function registerUserMerchantCategoryRuleRoutes(app, { requireAuth, withUserClient } = {}) {
  if (!app || typeof app.get !== 'function' || typeof app.post !== 'function'
    || typeof app.patch !== 'function' || typeof app.delete !== 'function') throw new TypeError('app is required');
  if (typeof requireAuth !== 'function' || typeof withUserClient !== 'function') throw new TypeError('auth/db dependencies are required');

  app.get('/merchant-category-rules', requireAuth, async (req, res) => {
    try {
      const includeDisabled = String(req.query?.includeDisabled ?? req.query?.include_disabled ?? 'true') !== 'false';
      const parsedLimit = Number(req.query?.limit ?? 50);
      const parsedOffset = Number(req.query?.offset ?? 0);
      const limit = Number.isSafeInteger(parsedLimit) ? Math.min(Math.max(parsedLimit, 1), MAX_LIST_LIMIT) : 50;
      const offset = Number.isSafeInteger(parsedOffset) ? Math.max(parsedOffset, 0) : 0;
      const cursor = decodeCursor(req.query?.cursor);
      const ownerFilter = `r.profile_id=$1 ${includeDisabled ? '' : 'AND r.is_active'} `
        + (cursor ? 'AND (r.updated_at, r.id) < ($2::timestamptz, $3::uuid)' : '');
      const values = cursor ? [req.userId, cursor.updatedAt, cursor.id, limit] : [req.userId, limit, offset];
      const page = cursor ? '$4' : '$2';
      const skip = cursor ? '' : ' OFFSET $3';
      const result = await withUserClient(req.userId, (client) => client.query(
        `${RULE_SELECT} WHERE ${ownerFilter}
         ORDER BY r.updated_at DESC, r.id LIMIT ${page}${skip}`,
        values,
      ));
      return res.json({
        rules: result.rows.map((row) => responseForRule(row)), limit,
        ...(cursor ? { cursor: req.query.cursor } : { offset }),
        nextCursor: result.rows.length === limit ? encodeCursor(result.rows.at(-1)) : null,
        historicTransactionsUnchanged: true,
      });
    } catch (error) { return errorResponse(res, error); }
  });

  app.post('/merchant-category-rules/preview', requireAuth, async (req, res) => {
    try {
      const body = req.body || {};
      const sourceId = bodyValue(body, 'source_transaction_id', 'sourceTransactionId');
      const categoryId = bodyValue(body, 'category_id', 'categoryId');
      const userCategoryId = bodyValue(body, 'user_category_id', 'userCategoryId');
      const action = parseAction(body);
      const flag = parseFlag(body);
      const result = await withUserClient(req.userId, async (client) => {
        const source = await loadSourceTransaction(client, req.userId, sourceId);
        const match = ruleMatchFromTransaction(source);
        const target = action === 'category'
          ? await loadCategoryTarget(client, req.userId, categoryId, userCategoryId)
          : { categoryId: null, userCategoryId: null, categoryName: null, categorySlug: null, userCategoryName: null };
        validateActionTarget(action, target.categoryId, target.userCategoryId, flag);
        const examples = await loadExamples(client, req.userId, match);
        const current = await readRuleByKey(client, req.userId, match.basis, match.value);
        return {
          sourceTransactionId: source.id,
          merchantName: safeMerchantName(source.merchant_name),
          displayMerchantName: safeMerchantName(source.merchant_name),
          matchBasis: match.basis,
          matchValue: match.value,
          action,
          flag,
          ...categoryIdentity(target),
          category: categoryIdentity(target),
          canCreate: true,
          examples,
          existingRule: current ? responseForRule(current) : null,
          historicTransactionsUnchanged: true,
        };
      });
      return res.json(result);
    } catch (error) { return errorResponse(res, error); }
  });

  app.post('/merchant-category-rules', requireAuth, async (req, res) => {
    try {
      const body = req.body || {};
      const idempotencyKey = parseIdempotency(req, body);
      const result = await withUserClient(req.userId, (client) => createRule({
        client, profileId: req.userId, actorId: req.userId, body, idempotencyKey,
      }));
      return res.status(result.status).json(result.result);
    } catch (error) { return errorResponse(res, error); }
  });

  app.patch('/merchant-category-rules/:id', requireAuth, async (req, res) => {
    try {
      if (!uuid(req.params.id)) throw new MerchantRuleError('rule_not_found', 404);
      const body = req.body || {};
      const expectedVersion = parseExpectedVersion(body);
      if (expectedVersion === null) throw new MerchantRuleError('expected_version_required', 400);
      const result = await withUserClient(req.userId, async (client) => {
        const current = await readRule(client, req.userId, req.params.id, true);
        if (!current) throw new MerchantRuleError('rule_not_found', 404);
        if (Number(current.version) !== expectedVersion) throw new MerchantRuleError('version_conflict', 409, responseForRule(current));
        const action = parseAction(body, current.action || 'category');
        const flag = parseFlag(body, current.flag || null);
        const hasCategory = Object.prototype.hasOwnProperty.call(body, 'categoryId') || Object.prototype.hasOwnProperty.call(body, 'category_id');
        const hasUserCategory = Object.prototype.hasOwnProperty.call(body, 'userCategoryId') || Object.prototype.hasOwnProperty.call(body, 'user_category_id');
        const target = action === 'category' && (hasCategory || hasUserCategory)
          ? await loadCategoryTarget(client, req.userId,
            hasCategory ? bodyValue(body, 'category_id', 'categoryId') : current.category_id,
            hasUserCategory ? bodyValue(body, 'user_category_id', 'userCategoryId') : current.user_category_id)
          : action === 'category'
            ? { categoryId: current.category_id, userCategoryId: current.user_category_id }
            : { categoryId: null, userCategoryId: null };
        validateActionTarget(action, target.categoryId, target.userCategoryId, flag);
        const active = Object.prototype.hasOwnProperty.call(body, 'is_active') || Object.prototype.hasOwnProperty.call(body, 'isActive')
          ? bodyValue(body, 'is_active', 'isActive') : current.is_active;
        if (typeof active !== 'boolean') throw new MerchantRuleError('is_active_invalid', 400);
        const operation = active === current.is_active ? 'update' : active ? 'enable' : 'disable';
        await client.query(
          `UPDATE user_merchant_category_rules SET action=$1,flag=$2,category_id=$3,user_category_id=$4,is_active=$5,version=version+1,updated_at=now()
            WHERE id=$6 AND profile_id=$7`,
          [action, flag, target.categoryId, target.userCategoryId || null, active, current.id, req.userId],
        );
        const updated = await readRule(client, req.userId, current.id);
        await writeAudit(client, req.userId, req.userId, operation, current, updated);
        await writeSyncChange(client, req.userId, updated, operation);
        return responseForRule(updated, { statement: 'Future transactions only; historic transactions were unchanged.' });
      });
      return res.json(result);
    } catch (error) { return errorResponse(res, error); }
  });

  app.delete('/merchant-category-rules/:id', requireAuth, async (req, res) => {
    try {
      if (!uuid(req.params.id)) throw new MerchantRuleError('rule_not_found', 404);
      const expectedVersion = parseExpectedVersion(req.body || {});
      const result = await withUserClient(req.userId, async (client) => {
        const current = await readRule(client, req.userId, req.params.id, true);
        if (!current) throw new MerchantRuleError('rule_not_found', 404);
        if (expectedVersion !== null && Number(current.version) !== expectedVersion) {
          throw new MerchantRuleError('version_conflict', 409, responseForRule(current));
        }
        if (!current.is_active) return responseForRule(current, { statement: 'Future transactions only; historic transactions were unchanged.' });
        await client.query(
          `UPDATE user_merchant_category_rules SET is_active=false,version=version+1,updated_at=now()
            WHERE id=$1 AND profile_id=$2`, [current.id, req.userId],
        );
        const updated = await readRule(client, req.userId, current.id);
        await writeAudit(client, req.userId, req.userId, 'delete', current, updated);
        await writeSyncChange(client, req.userId, updated, 'delete');
        return responseForRule(updated, { statement: 'Future transactions only; historic transactions were unchanged.' });
      });
      return res.json(result);
    } catch (error) { return errorResponse(res, error); }
  });
}

module.exports = {
  MAX_LIST_LIMIT,
  RULE_ACTIONS,
  MerchantRuleError,
  assertSourceTransaction,
  categoryIdentity,
  decodeCursor,
  encodeCursor,
  loadCategoryTarget,
  normalizeMerchantVpa,
  normalizeMerchantName,
  parseAction,
  parseFlag,
  requestHash,
  responseForRule,
  ruleMatchFromTransaction,
  validateActionTarget,
  registerUserMerchantCategoryRuleRoutes,
};
