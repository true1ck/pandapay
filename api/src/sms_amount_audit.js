// Audits typed source facts without uploading or storing original SMS text.
// Missing source evidence is explicitly unverified, never assumed correct.
const { safeErrorCode } = require('./safeErrorCode');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NON_PAYMENT_FIELDS = [
  'limitInr', 'availableBalanceInr', 'outstandingInr',
  'amountDueInr', 'minimumDueInr', 'proposedAmountInr',
];

function equalMoney(left, right) {
  const a = Number(left), b = Number(right);
  return left != null && right != null && Number.isFinite(a) && Number.isFinite(b)
    && a > 0 && b > 0 && Math.abs(a - b) < .005;
}

function classifyAmountAudit(transaction, facts) {
  const usable = facts.filter((fact) => fact.status !== 'discarded' && fact.status !== 'superseded');
  const protectedRecord = Boolean(transaction.note || transaction.user_category_id
    || transaction.has_tags || transaction.has_manual_observation || transaction.has_user_sync
    || usable.some((fact) => fact.has_override));
  // An AI proposal is not source proof, nor is an override safe to undo.
  const grounded = usable.filter((fact) => fact.provenance?.channel !== 'ai');
  const posted = grounded.some((fact) => ['posted_movement', 'bill_payment'].includes(fact.fact_type)
    && equalMoney(fact.payload?.amountInr, transaction.amount_inr));
  const nonPayment = grounded.some((fact) => NON_PAYMENT_FIELDS.some((field) =>
    equalMoney(fact.payload?.[field], transaction.amount_inr)));
  const disposition = protectedRecord ? 'protected' : posted ? 'verified'
    : nonPayment ? 'candidate' : 'unverified';
  return {
    transaction_id: transaction.id,
    source_key: transaction.source_key || null,
    amount_inr: transaction.amount_inr,
    occurred_at: transaction.occurred_at,
    disposition,
    reason: disposition === 'candidate' ? 'non_payment_amount_without_posted_evidence'
      : disposition === 'protected' ? 'preserved_user_annotation_or_override'
        : disposition === 'verified' ? 'matching_posted_amount_fact' : 'insufficient_typed_evidence',
  };
}

async function readAuditRows(client, userId, { limit = 200, cursor = null, ids = null, forUpdate = false } = {}) {
  const params = [userId];
  let restriction = '';
  if (ids) { params.push(ids); restriction += ` AND t.id=ANY($${params.length}::uuid[])`; }
  if (cursor) { params.push(cursor); restriction += ` AND t.id>$${params.length}::uuid`; }
  params.push(limit);
  const result = await client.query(
    `SELECT t.*,
      EXISTS (SELECT 1 FROM transaction_tag_links l WHERE l.profile_id=t.profile_id
        AND l.transaction_id=t.id AND l.deleted_at IS NULL) AS has_tags,
      EXISTS (SELECT 1 FROM transaction_observations o WHERE o.profile_id=t.profile_id
        AND o.transaction_id=t.id AND o.source='manual') AS has_manual_observation,
      EXISTS (SELECT 1 FROM change_log c WHERE c.profile_id=t.profile_id
        AND c.entity='transactions' AND c.entity_id=t.id AND c.device_id IS NOT NULL) AS has_user_sync,
      ARRAY(SELECT o.source_key FROM transaction_observations o WHERE o.profile_id=t.profile_id
        AND o.transaction_id=t.id AND o.source IN ('sms','sms_bulk') AND o.source_key IS NOT NULL) AS source_keys
     FROM transactions t WHERE t.profile_id=$1 AND t.status='active'
       AND t.source IN ('sms','sms_bulk') AND t.entry_kind='spend'${restriction}
     ORDER BY t.id LIMIT $${params.length}${forUpdate ? ' FOR UPDATE OF t' : ''}`, params);
  return result.rows;
}

async function auditTransactions(client, userId, options = {}) {
  const rows = await readAuditRows(client, userId, options);
  const keys = [...new Set(rows.flatMap((row) => [row.source_key, ...(row.source_keys || [])]).filter(Boolean))];
  const facts = keys.length ? (await client.query(
    `SELECT s.source_key,f.fact_type,f.payload,f.provenance,f.status,
       EXISTS (SELECT 1 FROM fact_overrides o WHERE o.profile_id=f.profile_id
         AND o.source_id=f.source_id AND o.fact_index=f.fact_index) AS has_override
     FROM sms_sources s JOIN sms_source_facts f ON f.source_id=s.id AND f.profile_id=s.profile_id
     WHERE s.profile_id=$1 AND s.source_key=ANY($2::text[])`, [userId, keys])).rows : [];
  const byKey = new Map();
  for (const fact of facts) {
    if (!byKey.has(fact.source_key)) byKey.set(fact.source_key, []);
    byKey.get(fact.source_key).push(fact);
  }
  return rows.map((row) => ({
    row,
    audit: classifyAmountAudit(row, [...new Set([row.source_key, ...(row.source_keys || [])])]
      .flatMap((key) => byKey.get(key) || [])),
  }));
}

function registerSmsAmountAuditRoutes(app, { requireAuth, withUserClient, loadUserCardForState, reverseTransactionState }) {
  app.get('/transactions/amount-audit', requireAuth, async (req, res) => {
    const limit = req.query.limit == null ? 200 : Number(req.query.limit);
    const cursor = req.query.cursor || null;
    if (!Number.isInteger(limit) || limit < 1 || limit > 200 || (cursor && !UUID.test(cursor))) {
      return res.status(400).json({ error: 'invalid_audit_page' });
    }
    try {
      const result = await withUserClient(req.userId, async (client) => {
        const audited = await auditTransactions(client, req.userId, { limit: limit + 1, cursor });
        const page = audited.slice(0, limit).map((entry) => entry.audit);
        const counts = { candidate: 0, protected: 0, verified: 0, unverified: 0 };
        for (const row of page) counts[row.disposition] += 1;
        const total = await client.query(`SELECT count(*)::int AS total FROM transactions
          WHERE profile_id=$1 AND status='active' AND entry_kind='spend' AND source IN ('sms','sms_bulk')`, [req.userId]);
        return { items: page, summary: { ...counts, page_count: page.length, total_active_sms: total.rows[0]?.total || 0 },
          coverage: 'typed_facts_only', next_cursor: audited.length > limit ? page.at(-1).transaction_id : null };
      });
      res.json(result);
    } catch (error) {
      console.error('SMS amount audit failed', safeErrorCode(error));
      res.status(500).json({ error: 'amount_audit_unavailable' });
    }
  });

  app.post('/transactions/amount-audit/repair', requireAuth, async (req, res) => {
    const ids = req.body?.transaction_ids;
    if (!Array.isArray(ids) || !ids.length || ids.length > 50
      || ids.some((id) => typeof id !== 'string' || !UUID.test(id)) || new Set(ids).size !== ids.length) {
      return res.status(400).json({ error: 'choose_1_to_50_transaction_ids' });
    }
    try {
      const result = await withUserClient(req.userId, async (client) => {
        // Same lock as canonical ingestion; serialize a repair with replays.
        await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1::text,0))', [`transaction-ingest:${req.userId}`]);
        const audited = await auditTransactions(client, req.userId, { ids, limit: 50, forUpdate: true });
        const repaired = [];
        for (const { row, audit } of audited) {
          if (audit.disposition !== 'candidate') continue;
          if (row.instrument === 'credit_card' && row.user_card_id && row.state_applied !== false) {
            const card = await loadUserCardForState(client, req.userId, row.user_card_id);
            if (!card) continue;
            await reverseTransactionState(client, req.userId, card, row);
          }
          await client.query(`UPDATE transactions SET status='ignored', state_applied=false,
            note='[ignored: wrong_transaction] [amount-role-audit:v1]', updated_at=now()
            WHERE profile_id=$1 AND id=$2 AND status='active'`, [req.userId, row.id]);
          repaired.push(row.id);
        }
        return { repaired, skipped: ids.filter((id) => !repaired.includes(id)), coverage: 'typed_facts_only' };
      });
      res.json(result);
    } catch (error) {
      console.error('SMS amount repair failed', safeErrorCode(error));
      res.status(500).json({ error: 'amount_repair_unavailable' });
    }
  });
}

module.exports = { classifyAmountAudit, auditTransactions, registerSmsAmountAuditRoutes };
