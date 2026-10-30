'use strict';

const crypto = require('node:crypto');
const { safeErrorCode } = require('../safeErrorCode');
const { validateField } = require('../admin_rule_families');
const { SUPPORT_TICKET_KINDS } = require('../support_tickets');
// External delivery requires a separately reviewed, injected adapter. Never
// load the customer config or its provider credentials from a private handler.
const unavailableNotifications = Object.freeze({ isConfigured: () => false });

function registerInlineAdminRoutes(app, { withUserClient, requireAdmin, requireAuth, notificationService = unavailableNotifications }) {
  const CARD_TYPES = ['credit', 'debit', 'prepaid', 'forex'];
  const REWARD_UNITS = ['cashback_percent', 'points_per_100', 'points_per_150', 'points_per_200', 'miles_per_100', 'flat_points', 'discount_percent'];
  const CARD_NETWORKS = ['rupay', 'visa', 'mastercard', 'amex', 'diners'];
  const CARD_STATUS_TRANSITIONS = { draft: ['in_review'], in_review: ['draft', 'published'], published: ['archived'], archived: [] };
app.get('/admin/me', requireAuth, async (req, res) => {
  res.json({ isAdmin: true, email: req.admin.email, role: req.admin.role, permissions: req.admin.permissions });
});

app.get('/admin/cards', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query('SELECT * FROM v_admin_card_catalogue_export ORDER BY name')
    );
    res.json({ cards: result.rows });
  } catch (err) {
    console.error('GET /admin/cards error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/issuers', requireAdmin, async (req, res) => {
  const { slug, name, shortName, logoUrl, websiteUrl, reason } = req.body || {};
  if (typeof slug !== 'string' || !slug.trim()) {
    return res.status(400).json({ error: 'slug is required' });
  }
  if (typeof name !== 'string' || !name.trim()) {
    return res.status(400).json({ error: 'name is required' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const inserted = await client.query(
        `INSERT INTO issuers (slug, name, short_name, logo_url, website_url)
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (slug) DO NOTHING
         RETURNING *`,
        [slug, name, shortName || null, logoUrl || null, websiteUrl || null]
      );
      if (inserted.rows.length > 0) {
        await client.query(
          `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, after_value, reason)
           VALUES ($1, 'create_issuer', 'issuers', $2, $3, $4)`,
          [req.userId, inserted.rows[0].id, JSON.stringify(inserted.rows[0]), reason || null]
        );
        return { issuer: inserted.rows[0], created: true };
      }
      const existing = await client.query('SELECT * FROM issuers WHERE slug = $1', [slug]);
      return { issuer: existing.rows[0], created: false };
    });
    res.status(result.created ? 201 : 200).json({ issuer: result.issuer });
  } catch (err) {
    console.error('POST /admin/issuers error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/cards', requireAdmin, async (req, res) => {
  const fields = [
    { name: 'issuerId', column: 'issuer_id', type: 'string', required: true },
    { name: 'slug', column: 'slug', type: 'string', required: true },
    { name: 'name', column: 'name', type: 'string', required: true },
    { name: 'network', column: 'network', type: 'enum', values: CARD_NETWORKS, required: true },
    { name: 'cardType', column: 'card_type', type: 'enum', values: CARD_TYPES },
    { name: 'joiningFeeInr', column: 'joining_fee_inr', type: 'number', min: 0 },
    { name: 'annualFeeInr', column: 'annual_fee_inr', type: 'number', min: 0 },
    { name: 'isUpiLinkable', column: 'is_upi_linkable', type: 'boolean' },
    { name: 'baseRewardUnit', column: 'base_reward_unit', type: 'enum', values: REWARD_UNITS },
    { name: 'baseRewardRate', column: 'base_reward_rate', type: 'number', min: 0 },
    { name: 'pointValueInr', column: 'point_value_inr', type: 'number', min: 0 },
    { name: 'sourceUrl', column: 'source_url', type: 'string' },
    { name: 'extendedData', column: 'extended_data', type: 'jsonb' },
  ];
  const body = req.body || {};
  const errors = [];
  const values = {};
  for (const field of fields) {
    const present = Object.prototype.hasOwnProperty.call(body, field.name);
    if (!present) {
      if (field.required) errors.push(`${field.name} is required`);
      continue;
    }
    const err = validateField(field, body[field.name]);
    if (err) errors.push(err);
    else values[field.column] = field.type === 'jsonb' ? JSON.stringify(body[field.name]) : body[field.name];
  }
  if (errors.length) return res.status(400).json({ error: errors.join('; ') });

  try {
    const result = await withUserClient(req.userId, async (client) => {
      const existing = await client.query('SELECT id FROM card_products WHERE slug = $1', [values.slug]);
      if (existing.rows.length > 0) return { conflict: true };

      const columns = ['status', ...Object.keys(values)];
      const vals = ['draft', ...Object.values(values)];
      const placeholders = vals.map((_, i) => `$${i + 1}`);
      const inserted = await client.query(
        `INSERT INTO card_products (${columns.join(', ')}) VALUES (${placeholders.join(', ')}) RETURNING *`,
        vals
      );
      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, after_value, reason)
         VALUES ($1, 'create_card_product', 'card_products', $2, $3, $4)`,
        [req.userId, inserted.rows[0].id, JSON.stringify(inserted.rows[0]), body.reason || null]
      );
      return { card: inserted.rows[0] };
    });
    if (result.conflict) {
      return res.status(409).json({ error: `card_products.slug '${values.slug}' already exists` });
    }
    res.status(201).json({ card: result.card });
  } catch (err) {
    console.error('POST /admin/cards error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.put('/admin/reward-rules/:id', requireAdmin, async (req, res) => {
  const { rate } = req.body || {};
  if (typeof rate !== 'number' || !Number.isFinite(rate) || rate < 0) {
    return res.status(400).json({ error: 'rate must be a non-negative number' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const before = await client.query(
        'SELECT id, card_product_id, rate FROM reward_rules WHERE id = $1',
        [req.params.id]
      );
      if (before.rows.length === 0) return null;

      const updated = await client.query(
        'UPDATE reward_rules SET rate = $1 WHERE id = $2 RETURNING id, card_product_id, rate',
        [rate, req.params.id]
      );

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
         VALUES ($1, 'update_reward_rule_rate', 'reward_rules', $2, $3, $4, $5)`,
        [
          req.userId,
          req.params.id,
          JSON.stringify({ rate: before.rows[0].rate }),
          JSON.stringify({ rate: updated.rows[0].rate }),
          req.body.reason || null,
        ]
      );

      return updated.rows[0];
    });

    if (!result) return res.status(404).json({ error: 'reward_rule not found' });
    res.json({ rewardRule: result });
  } catch (err) {
    console.error('PUT /admin/reward-rules/:id error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/parser-patterns', requireAdmin, async (req, res) => {
  const { channel, isActive } = req.query;
  const conditions = [];
  const params = [];
  if (channel) {
    params.push(channel);
    conditions.push(`channel = $${params.length}`);
  }
  if (isActive === 'true' || isActive === 'false') {
    params.push(isActive === 'true');
    conditions.push(`is_active = $${params.length}`);
  }
  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT id, issuer_id, channel, sender_pattern, regex, field_map, version,
                is_active, sample_text, success_count, failure_count, created_at, updated_at
           FROM parser_patterns
           ${where}
          ORDER BY updated_at DESC`,
        params
      )
    );
    res.json({ parserPatterns: result.rows });
  } catch (err) {
    console.error('GET /admin/parser-patterns error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/parser-patterns', requireAdmin, async (req, res) => {
  const { issuerId, channel, senderPattern, regex, fieldMap, sampleText, reason } = req.body || {};
  const VALID_CHANNELS = ['manual', 'sms', 'email', 'statement', 'sms_bulk', 'imported'];
  if (!VALID_CHANNELS.includes(channel)) {
    return res.status(400).json({ error: `channel must be one of ${VALID_CHANNELS.join('/')}` });
  }
  if (typeof regex !== 'string' || !regex.trim()) {
    return res.status(400).json({ error: 'regex is required' });
  }
  try {
    new RegExp(regex);
  } catch (err) {
    return res.status(400).json({ error: 'regex is not a valid JS regular expression' });
  }
  if (typeof fieldMap !== 'object' || fieldMap === null || Array.isArray(fieldMap)) {
    return res.status(400).json({ error: 'fieldMap must be an object' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const inserted = await client.query(
        `INSERT INTO parser_patterns (issuer_id, channel, sender_pattern, regex, field_map, sample_text)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id, issuer_id, channel, sender_pattern, regex, field_map, version, is_active, sample_text, success_count, failure_count`,
        [issuerId || null, channel, senderPattern || null, regex, JSON.stringify(fieldMap), sampleText || null]
      );

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, after_value, reason)
         VALUES ($1, 'create_parser_pattern', 'parser_patterns', $2, $3, $4)`,
        [req.userId, inserted.rows[0].id, JSON.stringify(inserted.rows[0]), reason || null]
      );

      return inserted.rows[0];
    });
    res.status(201).json({ parserPattern: result });
  } catch (err) {
    console.error('POST /admin/parser-patterns error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.put('/admin/parser-patterns/:id', requireAdmin, async (req, res) => {
  const { senderPattern, regex, fieldMap, isActive, sampleText, reason } = req.body || {};
  if (regex !== undefined) {
    if (typeof regex !== 'string' || !regex.trim()) {
      return res.status(400).json({ error: 'regex must be a non-empty string' });
    }
    try {
      new RegExp(regex);
    } catch (err) {
      return res.status(400).json({ error: 'regex is not a valid JS regular expression' });
    }
  }
  if (fieldMap !== undefined && (typeof fieldMap !== 'object' || fieldMap === null || Array.isArray(fieldMap))) {
    return res.status(400).json({ error: 'fieldMap must be an object' });
  }
  if (isActive !== undefined && typeof isActive !== 'boolean') {
    return res.status(400).json({ error: 'isActive must be a boolean' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const before = await client.query(
        `SELECT id, sender_pattern, regex, field_map, version, is_active, sample_text
           FROM parser_patterns WHERE id = $1`,
        [req.params.id]
      );
      if (before.rows.length === 0) return null;
      const prior = before.rows[0];

      const contentChanged = regex !== undefined || fieldMap !== undefined || senderPattern !== undefined;
      const updated = await client.query(
        `UPDATE parser_patterns
            SET sender_pattern = COALESCE($1, sender_pattern),
                regex          = COALESCE($2, regex),
                field_map      = COALESCE($3, field_map),
                is_active      = COALESCE($4, is_active),
                sample_text    = COALESCE($5, sample_text),
                version        = version + CASE WHEN $6 THEN 1 ELSE 0 END,
                updated_at     = now()
          WHERE id = $7
          RETURNING id, issuer_id, channel, sender_pattern, regex, field_map, version, is_active, sample_text, success_count, failure_count`,
        [
          senderPattern === undefined ? null : senderPattern,
          regex === undefined ? null : regex,
          fieldMap === undefined ? null : JSON.stringify(fieldMap),
          isActive === undefined ? null : isActive,
          sampleText === undefined ? null : sampleText,
          contentChanged,
          req.params.id,
        ]
      );

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
         VALUES ($1, 'update_parser_pattern', 'parser_patterns', $2, $3, $4, $5)`,
        [req.userId, req.params.id, JSON.stringify(prior), JSON.stringify(updated.rows[0]), reason || null]
      );

      return updated.rows[0];
    });

    if (!result) return res.status(404).json({ error: 'parser_pattern not found' });
    res.json({ parserPattern: result });
  } catch (err) {
    console.error('PUT /admin/parser-patterns/:id error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.delete('/admin/parser-patterns/:id', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const before = await client.query(`SELECT * FROM parser_patterns WHERE id = $1`, [req.params.id]);
      if (before.rows.length === 0) return null;

      await client.query(`DELETE FROM parser_patterns WHERE id = $1`, [req.params.id]);

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, reason)
         VALUES ($1, 'delete_parser_pattern', 'parser_patterns', $2, $3, $4)`,
        [req.userId, req.params.id, JSON.stringify(before.rows[0]), req.body?.reason || null]
      );

      return { deleted: true };
    });

    if (!result) return res.status(404).json({ error: 'parser_pattern not found' });
    res.json(result);
  } catch (err) {
    console.error('DELETE /admin/parser-patterns/:id error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/cards/:id/status', requireAdmin, async (req, res) => {
  const { status: nextStatus, reason } = req.body || {};
  if (!Object.keys(CARD_STATUS_TRANSITIONS).includes(nextStatus)) {
    return res.status(400).json({ error: 'status must be one of draft/in_review/published/archived' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const before = await client.query(
        'SELECT id, status, verified_at, verified_by FROM card_products WHERE id = $1',
        [req.params.id]
      );
      if (before.rows.length === 0) return { notFound: true };

      const currentStatus = before.rows[0].status;
      if (!CARD_STATUS_TRANSITIONS[currentStatus].includes(nextStatus)) {
        return { invalidTransition: true, currentStatus };
      }

      const setVerification = nextStatus === 'published' && !before.rows[0].verified_at;
      const updated = await client.query(
        `UPDATE card_products
            SET status = $1,
                verified_at = CASE WHEN $2 THEN now() ELSE verified_at END,
                verified_by = CASE WHEN $2 THEN $3::uuid ELSE verified_by END
          WHERE id = $4
          RETURNING id, status, verified_at, verified_by`,
        [nextStatus, setVerification, req.userId, req.params.id]
      );

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
         VALUES ($1, 'change_card_status', 'card_products', $2, $3, $4, $5)`,
        [
          req.userId,
          req.params.id,
          JSON.stringify({ status: currentStatus, verified_at: before.rows[0].verified_at }),
          JSON.stringify(updated.rows[0]),
          reason || null,
        ]
      );

      return { card: updated.rows[0] };
    });

    if (result.notFound) return res.status(404).json({ error: 'card_product not found' });
    if (result.invalidTransition) {
      return res
        .status(409)
        .json({ error: `cannot transition from ${result.currentStatus} to ${nextStatus}` });
    }
    res.json(result);
  } catch (err) {
    console.error('POST /admin/cards/:id/status error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/card-requests', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT issuer_name, product_name, network_guess,
                sum(request_count) AS total_requests,
                count(*) AS distinct_reporters,
                bool_or(state = 'pending') AS has_pending,
                min(created_at) AS first_requested_at,
                max(created_at) AS last_requested_at,
                extract(day FROM now() - min(created_at) FILTER (WHERE state = 'pending'))
                  AS oldest_pending_age_days,
                bool_or(state = 'pending' AND created_at < now() - interval '14 days')
                  AS is_stale
           FROM card_requests
          GROUP BY issuer_name, product_name, network_guess
          ORDER BY is_stale DESC, sum(request_count) DESC, max(created_at) DESC`
      )
    );
    res.json({ requestGroups: result.rows });
  } catch (err) {
    console.error('GET /admin/card-requests error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/card-requests/start-scraping', requireAdmin, async (req, res) => {
  const { issuerName, productName, baseUrl } = req.body || {};
  if (!issuerName || typeof issuerName !== 'string') {
    return res.status(400).json({ error: 'issuerName is required' });
  }
  if (!baseUrl || typeof baseUrl !== 'string') {
    return res.status(400).json({ error: 'baseUrl is required' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const source = await client.query(
        `INSERT INTO sources (kind, name, base_url, tos_reviewed, is_enabled)
         VALUES ('bank_official', $1, $2, false, false)
         RETURNING id, name, base_url, tos_reviewed, is_enabled`,
        [`${issuerName}${productName ? ' — ' + productName : ''}`, baseUrl]
      );

      const resolved = await client.query(
        `UPDATE card_requests SET state = 'resolved'
          WHERE issuer_name = $1 AND state = 'pending'
            AND ($2::text IS NULL OR product_name = $2)
          RETURNING id`,
        [issuerName, productName || null]
      );

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
         VALUES ($1, 'start_scraping_source', 'sources', $2, NULL, $3, $4)`,
        [
          req.userId,
          source.rows[0].id,
          JSON.stringify(source.rows[0]),
          `${resolved.rows.length} card_requests resolved`,
        ]
      );

      return { source: source.rows[0], resolvedRequestCount: resolved.rows.length };
    });
    res.status(201).json(result);
  } catch (err) {
    console.error('POST /admin/card-requests/start-scraping error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/error-reports', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT er.id, er.card_product_id, cp.name AS card_name, er.field_path,
                er.shown_value, er.claimed_value, er.source_url, er.attachment_path,
                er.state, er.created_at,
                extract(day FROM now() - er.created_at) AS age_days,
                (er.state = 'pending' AND er.created_at < now() - interval '7 days') AS is_stale
           FROM data_error_reports er
           JOIN card_products cp ON cp.id = er.card_product_id
          ORDER BY is_stale DESC, er.state = 'pending' DESC, er.created_at DESC`
      )
    );
    res.json({ errorReports: result.rows });
  } catch (err) {
    console.error('GET /admin/error-reports error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/error-reports/:id/approve', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const reportResult = await client.query(
        `SELECT * FROM data_error_reports WHERE id = $1 AND state = 'pending'`,
        [req.params.id]
      );
      if (reportResult.rows.length === 0) return { status: 404 };
      const report = reportResult.rows[0];

      const fieldMatch = /^reward_rules\.([0-9a-f-]{36})\.rate$/.exec(report.field_path);
      if (!fieldMatch) {
        await client.query(`UPDATE data_error_reports SET state = 'resolved' WHERE id = $1`, [report.id]);
        await client.query(
          `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
           VALUES ($1, 'resolve_error_report', 'data_error_reports', $2, $3, $4, $5)`,
          [
            req.userId,
            report.id,
            JSON.stringify({ shown: report.shown_value }),
            JSON.stringify({ claimed: report.claimed_value }),
            req.body?.reason || `Resolved data error report for field '${report.field_path}'`,
          ]
        );
        return { ok: true, resolved: true };
      }
      const ruleId = fieldMatch[1];
      const newRate = Number(report.claimed_value);
      if (!Number.isFinite(newRate) || newRate < 0) {
        return { status: 422, error: 'claimed_value is not a valid non-negative rate' };
      }

      const before = await client.query(
        'SELECT id, card_product_id, rate FROM reward_rules WHERE id = $1 AND card_product_id = $2',
        [ruleId, report.card_product_id]
      );
      if (before.rows.length === 0) {
        return { status: 422, error: 'reward_rule not found for this card' };
      }

      const updated = await client.query(
        'UPDATE reward_rules SET rate = $1 WHERE id = $2 RETURNING id, rate',
        [newRate, ruleId]
      );

      const card = await client.query(
        'SELECT data_version FROM card_products WHERE id = $1',
        [report.card_product_id]
      );

      const change = await client.query(
        `INSERT INTO card_catalogue_changes
           (card_product_id, data_version_after, field_path, old_value, new_value, change_summary, approved_by)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         RETURNING id`,
        [
          report.card_product_id,
          card.rows[0].data_version,
          report.field_path,
          JSON.stringify(before.rows[0].rate),
          JSON.stringify(updated.rows[0].rate),
          `Corrected via user report: rate ${before.rows[0].rate} -> ${updated.rows[0].rate}`,
          req.userId,
        ]
      );

      await client.query(`UPDATE data_error_reports SET state = 'resolved' WHERE id = $1`, [report.id]);

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
         VALUES ($1, 'approve_error_report', 'data_error_reports', $2, $3, $4, $5)`,
        [
          req.userId,
          report.id,
          JSON.stringify({ rate: before.rows[0].rate }),
          JSON.stringify({ rate: updated.rows[0].rate }),
          'Approved via AD-2.2 error queue',
        ]
      );

      return { status: 200, changeId: change.rows[0].id, newDataVersion: card.rows[0].data_version };
    });

    if (result.status !== 200) return res.status(result.status).json({ error: result.error || 'not_found' });
    res.json({ changeId: result.changeId });
  } catch (err) {
    console.error('POST /admin/error-reports/:id/approve error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/error-reports/:id/reject', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const updated = await client.query(
        `UPDATE data_error_reports SET state = 'dismissed' WHERE id = $1 AND state = 'pending' RETURNING id`,
        [req.params.id]
      );
      if (updated.rows.length === 0) return null;
      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, reason)
         VALUES ($1, 'reject_error_report', 'data_error_reports', $2, $3)`,
        [req.userId, req.params.id, req.body?.reason || null]
      );
      return updated.rows[0];
    });
    if (!result) return res.status(404).json({ error: 'not found or already resolved' });
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /admin/error-reports/:id/reject error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/alerts', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT a.id, a.card_product_id, cp.name AS card_name, a.field_path, a.field_label,
                a.signal_count, a.distinct_signal_kinds, a.corroboration_score, a.state,
                a.first_signal_at, a.last_signal_at, a.decision_note
           FROM policy_change_alerts a
           JOIN card_products cp ON cp.id = a.card_product_id
          ORDER BY a.state = 'open' DESC, a.corroboration_score DESC, a.last_signal_at DESC`
      )
    );
    res.json({ alerts: result.rows });
  } catch (err) {
    console.error('GET /admin/alerts error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/alerts/:id', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const alert = await client.query(
        `SELECT a.*, cp.name AS card_name FROM policy_change_alerts a
           JOIN card_products cp ON cp.id = a.card_product_id
          WHERE a.id = $1`,
        [req.params.id]
      );
      if (alert.rows.length === 0) return null;

      const evidence = await client.query(
        `SELECT id, signal, excerpt, weight, created_at FROM policy_alert_evidence
          WHERE alert_id = $1 ORDER BY created_at`,
        [req.params.id]
      );

      const proposals = await client.query(
        `SELECT id, model_name, proposed_fields, model_confidence, evidence_excerpt, created_at
           FROM extraction_proposals
          WHERE card_product_id = $1
          ORDER BY created_at DESC LIMIT 5`,
        [alert.rows[0].card_product_id]
      );

      return { alert: alert.rows[0], evidence: evidence.rows, proposals: proposals.rows };
    });

    if (!result) return res.status(404).json({ error: 'alert not found' });
    res.json(result);
  } catch (err) {
    console.error('GET /admin/alerts/:id error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/alerts/:id/decide', requireAdmin, async (req, res) => {
  const { decision, note } = req.body || {};
  const validDecisions = ['approved', 'rejected', 'needs_more_evidence'];
  if (!validDecisions.includes(decision)) {
    return res.status(400).json({ error: `decision must be one of: ${validDecisions.join(', ')}` });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const updated = await client.query(
        `UPDATE policy_change_alerts
            SET state = $1, decided_by = $2, decided_at = now(), decision_note = $3
          WHERE id = $4 AND state = 'open'
          RETURNING id`,
        [decision, req.userId, note || null, req.params.id]
      );
      if (updated.rows.length === 0) return null;

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, after_value, reason)
         VALUES ($1, 'decide_policy_alert', 'policy_change_alerts', $2, $3, $4)`,
        [req.userId, req.params.id, JSON.stringify({ decision }), note || null]
      );

      return updated.rows[0];
    });

    if (!result) return res.status(404).json({ error: 'alert not found or not open' });
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /admin/alerts/:id/decide error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/notifications/broadcast', requireAdmin, async (req, res) => {
  const {
    category = 'general',
    severity = 'info',
    title,
    body = '',
    deepLink = '/notifications',
    dedupeKey,
  } = req.body || {};
  if (typeof title !== 'string' || title.trim().length < 1 || title.length > 160) {
    return res.status(400).json({ error: 'title is required and must be at most 160 characters' });
  }
  if (typeof body !== 'string' || body.length > 2000) {
    return res.status(400).json({ error: 'body must be at most 2000 characters' });
  }
  if (typeof category !== 'string' || category.length > 60) {
    return res.status(400).json({ error: 'category is invalid' });
  }
  if (typeof severity !== 'string' || severity.length > 20) {
    return res.status(400).json({ error: 'severity is invalid' });
  }
  if (!notificationService.isConfigured()) {
    return res.status(503).json({
      error: 'notification_service_not_configured',
      message: 'Remote push delivery is not configured on the API',
    });
  }

  const idempotencyKey = typeof dedupeKey === 'string' && dedupeKey.trim()
    ? dedupeKey.trim().slice(0, 200)
    : `pandapay-broadcast:${crypto.randomUUID()}`;
  try {
    const result = await notificationService.sendBroadcast({
      title: title.trim(),
      body,
      category,
      severity,
      deepLink,
      dedupeKey: idempotencyKey,
    });
    return res.status(202).json({
      ok: true,
      requested: true,
      message: 'Global push notification accepted for delivery to registered devices',
      transactionId: result?.transactionId || idempotencyKey,
    });
  } catch (err) {
    console.error('POST /admin/notifications/broadcast error', safeErrorCode(err));
    if (err?.code === 'notification_service_auth_failed') {
      return res.status(503).json({
        error: 'notification_service_auth_failed',
        message: 'The notification provider rejected the API key configured on the PandaPay server.',
      });
    }
    return res.status(502).json({ error: 'notification_service_unavailable' });
  }
});

app.get('/admin/support-tickets', requireAdmin, async (req, res) => {
  const { state, kind } = req.query || {};
  try {
    const result = await withUserClient(req.userId, (client) => {
      const conditions = [];
      const params = [];
      if (state && ['pending', 'resolved', 'dismissed'].includes(state)) {
        params.push(state);
        conditions.push(`st.state = $${params.length}`);
      }
      if (kind && SUPPORT_TICKET_KINDS.includes(kind)) {
        params.push(kind);
        conditions.push(`st.kind = $${params.length}`);
      }
      const whereClause = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
      return client.query(
        `SELECT st.id, st.profile_id, st.kind, st.message, st.diagnostics, st.app_version,
                st.state, st.response, st.created_at,
                p.email AS user_email, p.display_name AS user_name,
                extract(day FROM now() - st.created_at) AS age_days,
                (st.state = 'pending' AND st.created_at < now() - interval '7 days') AS is_stale
           FROM support_tickets st
           LEFT JOIN profiles p ON p.id = st.profile_id
           ${whereClause}
          ORDER BY is_stale DESC, st.state = 'pending' DESC, st.created_at DESC`,
        params
      );
    });
    res.json({ supportTickets: result.rows });
  } catch (err) {
    console.error('GET /admin/support-tickets error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/support-tickets/:id/resolve', requireAdmin, async (req, res) => {
  const { response, reason } = req.body || {};
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const updated = await client.query(
        `UPDATE support_tickets
            SET state = 'resolved',
                response = COALESCE($1, response)
          WHERE id = $2 AND state = 'pending'
          RETURNING id, state, response`,
        [response?.trim() || null, req.params.id]
      );
      if (updated.rows.length === 0) return null;
      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, reason)
         VALUES ($1, 'resolve_support_ticket', 'support_tickets', $2, $3)`,
        [req.userId, req.params.id, reason || response?.trim() || 'Resolved by admin']
      );
      return updated.rows[0];
    });
    if (!result) return res.status(404).json({ error: 'not found or already decided' });
    res.json({ ok: true, ticket: result });
  } catch (err) {
    console.error('POST /admin/support-tickets/:id/resolve error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/support-tickets/:id/dismiss', requireAdmin, async (req, res) => {
  const { reason } = req.body || {};
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const updated = await client.query(
        `UPDATE support_tickets
            SET state = 'dismissed'
          WHERE id = $1 AND state = 'pending'
          RETURNING id, state`,
        [req.params.id]
      );
      if (updated.rows.length === 0) return null;
      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, reason)
         VALUES ($1, 'dismiss_support_ticket', 'support_tickets', $2, $3)`,
        [req.userId, req.params.id, reason || 'Dismissed by admin']
      );
      return updated.rows[0];
    });
    if (!result) return res.status(404).json({ error: 'not found or already decided' });
    res.json({ ok: true, ticket: result });
  } catch (err) {
    console.error('POST /admin/support-tickets/:id/dismiss error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/merchants', requireAdmin, async (req, res) => {
  const { categoryId, minConfidenceScore, published, q } = req.query;
  const conditions = [];
  const params = [];
  if (categoryId) {
    params.push(categoryId);
    conditions.push(`m.category_id = $${params.length}`);
  }
  if (minConfidenceScore) {
    params.push(Number(minConfidenceScore));
    conditions.push(`m.confidence_score >= $${params.length}`);
  }
  if (published === 'true' || published === 'false') {
    params.push(published === 'true');
    conditions.push(`m.is_published = $${params.length}`);
  }
  if (q) {
    params.push(`%${q}%`);
    conditions.push(`(m.display_name ILIKE $${params.length} OR m.vpa ILIKE $${params.length})`);
  }
  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT m.id, m.vpa, m.display_name, m.mcc, m.category_id, sc.name AS category_name,
                m.confidence, m.confidence_score, m.confirmation_count, m.distinct_device_count,
                m.is_p2p, m.is_published, m.operator_locked, m.first_seen_on, m.last_confirmed_on,
                l.grid_lat, l.grid_lng, l.geohash6
           FROM merchants m
           LEFT JOIN spend_categories sc ON sc.id = m.category_id
           LEFT JOIN LATERAL (
             SELECT grid_lat, grid_lng, geohash6 FROM merchant_locations
              WHERE merchant_id = m.id ORDER BY confirmation_count DESC LIMIT 1
           ) l ON true
           ${where}
          ORDER BY m.last_confirmed_on DESC LIMIT 200`,
        params
      )
    );
    res.json({ merchants: result.rows });
  } catch (err) {
    console.error('GET /admin/merchants error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/merchants/:id', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const merchant = await client.query(
        `SELECT m.*, sc.name AS category_name FROM merchants m
          LEFT JOIN spend_categories sc ON sc.id = m.category_id
         WHERE m.id = $1`,
        [req.params.id]
      );
      if (merchant.rows.length === 0) return null;

      const [locations, contributions, conflicts] = await Promise.all([
        client.query(
          'SELECT * FROM merchant_locations WHERE merchant_id = $1 ORDER BY confirmation_count DESC',
          [req.params.id]
        ),
        client.query(
          'SELECT * FROM merchant_contributions WHERE merchant_id = $1 ORDER BY submitted_on DESC LIMIT 100',
          [req.params.id]
        ),
        client.query(
          'SELECT * FROM merchant_conflicts WHERE merchant_id = $1 ORDER BY detected_at DESC',
          [req.params.id]
        ),
      ]);

      return {
        merchant: merchant.rows[0],
        locations: locations.rows,
        contributions: contributions.rows,
        conflicts: conflicts.rows,
      };
    });

    if (!result) return res.status(404).json({ error: 'merchant not found' });
    res.json(result);
  } catch (err) {
    console.error('GET /admin/merchants/:id error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/merchants/:id/override', requireAdmin, async (req, res) => {
  const { displayName, categoryId, mcc, reason } = req.body || {};
  if (displayName === undefined && categoryId === undefined && mcc === undefined) {
    return res.status(400).json({ error: 'at least one of displayName/categoryId/mcc is required' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const before = await client.query('SELECT * FROM merchants WHERE id = $1', [req.params.id]);
      if (before.rows.length === 0) return null;

      const updated = await client.query(
        `UPDATE merchants
            SET display_name = COALESCE($1, display_name),
                category_id = COALESCE($2, category_id),
                mcc = COALESCE($3, mcc),
                operator_locked = true,
                mcc_operator_verified = CASE WHEN $3::text IS NOT NULL
                                                   AND btrim($3::text) <> ''
                                             THEN true ELSE mcc_operator_verified END,
                updated_at = now()
          WHERE id = $4
      RETURNING *`,
        [displayName ?? null, categoryId ?? null, mcc ?? null, req.params.id]
      );

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
         VALUES ($1, 'merchant_override', 'merchants', $2, $3, $4, $5)`,
        [req.userId, req.params.id, JSON.stringify(before.rows[0]), JSON.stringify(updated.rows[0]), reason || null]
      );

      return updated.rows[0];
    });

    if (!result) return res.status(404).json({ error: 'merchant not found' });
    res.json({ merchant: result });
  } catch (err) {
    console.error('POST /admin/merchants/:id/override error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/merchants/:id/unpublish', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const updated = await client.query(
        `UPDATE merchants SET is_published = false, updated_at = now() WHERE id = $1 RETURNING id, is_published`,
        [req.params.id]
      );
      if (updated.rows.length === 0) return null;

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
         VALUES ($1, 'merchant_unpublish', 'merchants', $2, $3, $4, $5)`,
        [
          req.userId,
          req.params.id,
          JSON.stringify({ is_published: true }),
          JSON.stringify({ is_published: false }),
          req.body?.reason || null,
        ]
      );
      return updated.rows[0];
    });
    if (!result) return res.status(404).json({ error: 'merchant not found' });
    res.json({ merchant: result });
  } catch (err) {
    console.error('POST /admin/merchants/:id/unpublish error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/merchant-conflicts', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT c.*, m.vpa, m.display_name AS merchant_display_name
           FROM merchant_conflicts c
           JOIN merchants m ON m.id = c.merchant_id
          WHERE c.state = 'pending'
          ORDER BY c.detected_at ASC`
      )
    );
    res.json({ conflicts: result.rows });
  } catch (err) {
    console.error('GET /admin/merchant-conflicts error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/merchant-conflicts/:id/resolve', requireAdmin, async (req, res) => {
  const { resolvedValue, reason } = req.body || {};
  if (resolvedValue === undefined) {
    return res.status(400).json({ error: 'resolvedValue is required' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const conflict = await client.query('SELECT * FROM merchant_conflicts WHERE id = $1', [req.params.id]);
      if (conflict.rows.length === 0) return null;
      const { merchant_id: merchantId, field } = conflict.rows[0];

      if (!['display_name', 'mcc', 'category_id'].includes(field)) {
        throw new Error(`unsupported conflict field: ${field}`);
      }

      await client.query(
        `UPDATE merchants
            SET ${field} = $1,
                operator_locked = true,
                mcc_operator_verified = CASE WHEN $3 = 'mcc'
                                                   AND $1::text IS NOT NULL
                                                   AND btrim($1::text) <> ''
                                             THEN true ELSE mcc_operator_verified END,
                confidence = 'operator_verified',
                updated_at = now()
          WHERE id = $2`,
        [resolvedValue, merchantId, field]
      );

      const updated = await client.query(
        `UPDATE merchant_conflicts
            SET state = 'resolved', resolved_value = $1, resolved_by = $2, resolved_at = now()
          WHERE id = $3
      RETURNING *`,
        [JSON.stringify(resolvedValue), req.userId, req.params.id]
      );

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
         VALUES ($1, 'merchant_conflict_resolve', 'merchant_conflicts', $2, $3, $4, $5)`,
        [
          req.userId,
          req.params.id,
          JSON.stringify(conflict.rows[0].competing_values),
          JSON.stringify(resolvedValue),
          reason || null,
        ]
      );

      return updated.rows[0];
    });
    if (!result) return res.status(404).json({ error: 'conflict not found' });
    res.json({ conflict: result });
  } catch (err) {
    console.error('POST /admin/merchant-conflicts/:id/resolve error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/abuse-signals', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT * FROM abuse_signals WHERE is_blocked = false ORDER BY severity DESC, detected_at DESC LIMIT 200`
      )
    );
    res.json({ abuseSignals: result.rows });
  } catch (err) {
    console.error('GET /admin/abuse-signals error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/abuse-signals/:id/block', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const signal = await client.query('SELECT * FROM abuse_signals WHERE id = $1', [req.params.id]);
      if (signal.rows.length === 0) return null;
      const { device_hash: deviceHash } = signal.rows[0];

      await client.query('UPDATE abuse_signals SET is_blocked = true WHERE device_hash = $1', [deviceHash]);
      const reverted = await client.query(
        `UPDATE merchant_contributions
            SET is_counted = false, rejected_reason = 'device_hash blocked (abuse signal)'
          WHERE device_hash = $1 AND is_counted = true
      RETURNING id`,
        [deviceHash]
      );

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
         VALUES ($1, 'device_block', 'abuse_signals', $2, $3, $4, $5)`,
        [
          req.userId,
          req.params.id,
          JSON.stringify({ device_hash: deviceHash, is_blocked: false }),
          JSON.stringify({ device_hash: deviceHash, is_blocked: true, contributions_reverted: reverted.rows.length }),
          req.body?.reason || null,
        ]
      );

      return { deviceHash, contributionsReverted: reverted.rows.length };
    });
    if (!result) return res.status(404).json({ error: 'abuse signal not found' });
    res.json(result);
  } catch (err) {
    console.error('POST /admin/abuse-signals/:id/block error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/acceptance-summary', requireAdmin, async (req, res) => {
  const { network, rail, published } = req.query;
  const conditions = [];
  const params = [];
  if (network) {
    params.push(network);
    conditions.push(`a.network = $${params.length}`);
  }
  if (rail) {
    params.push(rail);
    conditions.push(`a.rail = $${params.length}`);
  }
  if (published === 'true' || published === 'false') {
    params.push(published === 'true');
    conditions.push(`a.is_published = $${params.length}`);
  }
  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT a.merchant_id, a.network, a.rail, a.accepted_count, a.declined_count,
                a.confidence_score, a.is_published, a.last_updated_on,
                m.vpa, m.display_name
           FROM acceptance_summary a
           JOIN merchants m ON m.id = a.merchant_id
           ${where}
          ORDER BY a.last_updated_on DESC LIMIT 200`,
        params
      )
    );
    res.json({ acceptanceSummary: result.rows });
  } catch (err) {
    console.error('GET /admin/acceptance-summary error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/acceptance-summary/:merchantId', requireAdmin, async (req, res) => {
  const { network, rail } = req.query;
  if (!network || !rail) {
    return res.status(400).json({ error: 'network and rail query params are required' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const summary = await client.query(
        `SELECT a.*, m.vpa, m.display_name
           FROM acceptance_summary a
           JOIN merchants m ON m.id = a.merchant_id
          WHERE a.merchant_id = $1 AND a.network = $2 AND a.rail = $3`,
        [req.params.merchantId, network, rail]
      );
      if (summary.rows.length === 0) return null;

      const reports = await client.query(
        `SELECT id, result, device_hash, submitted_on FROM acceptance_reports
          WHERE merchant_id = $1 AND network = $2 AND rail = $3
          ORDER BY submitted_on DESC LIMIT 100`,
        [req.params.merchantId, network, rail]
      );

      return { summary: summary.rows[0], reports: reports.rows };
    });
    if (!result) return res.status(404).json({ error: 'acceptance summary not found' });
    res.json(result);
  } catch (err) {
    console.error('GET /admin/acceptance-summary/:merchantId error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/acceptance-summary/publish', requireAdmin, async (req, res) => {
  const { merchantId, network, rail, published, reason } = req.body || {};
  if (!merchantId || !network || !rail || typeof published !== 'boolean') {
    return res.status(400).json({ error: 'merchantId, network, rail, and published (boolean) are required' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const before = await client.query(
        'SELECT is_published FROM acceptance_summary WHERE merchant_id = $1 AND network = $2 AND rail = $3',
        [merchantId, network, rail]
      );
      if (before.rows.length === 0) return null;

      const updated = await client.query(
        `UPDATE acceptance_summary SET is_published = $1, last_updated_on = CURRENT_DATE
          WHERE merchant_id = $2 AND network = $3 AND rail = $4
      RETURNING *`,
        [published, merchantId, network, rail]
      );

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
         VALUES ($1, 'acceptance_summary_publish', 'acceptance_summary', $2, $3, $4, $5)`,
        [
          req.userId,
          merchantId,
          JSON.stringify({ is_published: before.rows[0].is_published }),
          JSON.stringify({ is_published: published }),
          reason || null,
        ]
      );

      return updated.rows[0];
    });
    if (!result) return res.status(404).json({ error: 'acceptance summary not found' });
    res.json({ acceptanceSummary: result });
  } catch (err) {
    console.error('POST /admin/acceptance-summary/publish error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/effective-rate-summary', requireAdmin, async (req, res) => {
  const { cardProductId, categoryId, divergentOnly } = req.query;
  const conditions = [];
  const params = [];
  if (cardProductId) {
    params.push(cardProductId);
    conditions.push(`s.card_product_id = $${params.length}`);
  }
  if (categoryId) {
    params.push(categoryId);
    conditions.push(`s.category_id = $${params.length}`);
  }
  if (divergentOnly === 'true') {
    conditions.push('s.is_divergent = true');
  }
  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT s.card_product_id, s.category_id, s.period_month, s.sample_count, s.distinct_devices,
                s.observed_rate_mean, s.observed_rate_p50, s.published_rate, s.divergence_pct,
                s.observed_cap_ceiling, s.published_cap_value, s.is_divergent, s.alert_raised_at,
                cp.name AS card_name, sc.name AS category_name,
                la.id AS linked_alert_id, la.state AS linked_alert_state
           FROM effective_rate_summary s
           JOIN card_products cp ON cp.id = s.card_product_id
           LEFT JOIN spend_categories sc ON sc.id = s.category_id
           LEFT JOIN LATERAL (
             SELECT id, state FROM policy_change_alerts
              WHERE card_product_id = s.card_product_id AND state = 'open'
              ORDER BY last_signal_at DESC LIMIT 1
           ) la ON true
           ${where}
          ORDER BY s.period_month DESC, s.divergence_pct DESC NULLS LAST LIMIT 200`,
        params
      )
    );
    res.json({ effectiveRateSummary: result.rows });
  } catch (err) {
    console.error('GET /admin/effective-rate-summary error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/effective-rate-summary/:cardProductId/:categoryId/samples', requireAdmin, async (req, res) => {
  const { periodMonth } = req.query;
  if (!periodMonth) return res.status(400).json({ error: 'periodMonth query param is required' });
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT id, spend_bucket_inr, observed_reward_inr, observed_rate, device_hash, submitted_on
           FROM effective_rate_samples
          WHERE card_product_id = $1 AND category_id = $2
            AND date_trunc('month', period_month) = date_trunc('month', $3::date)
          ORDER BY submitted_on DESC LIMIT 200`,
        [req.params.cardProductId, req.params.categoryId, periodMonth]
      )
    );
    res.json({ samples: result.rows });
  } catch (err) {
    console.error('GET /admin/effective-rate-summary/:cardProductId/:categoryId/samples error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/sources', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT s.id, s.kind, s.issuer_id, i.name AS issuer_name, s.name, s.base_url,
                s.robots_allows, s.robots_checked_at, s.tos_reviewed, s.tos_note,
                s.crawl_frequency, s.is_enabled, s.created_at,
                (SELECT count(*) FROM source_pages sp WHERE sp.source_id = s.id) AS page_count
           FROM sources s
           LEFT JOIN issuers i ON i.id = s.issuer_id
          ORDER BY s.tos_reviewed ASC, s.name`
      )
    );
    res.json({ sources: result.rows });
  } catch (err) {
    console.error('GET /admin/sources error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/sources', requireAdmin, async (req, res) => {
  const { kind, issuerId, name, baseUrl, tosNote, reason } = req.body || {};
  const VALID_KINDS = ['bank_official', 'news_review', 'regulator', 'other'];
  if (!VALID_KINDS.includes(kind)) {
    return res.status(400).json({ error: `kind must be one of ${VALID_KINDS.join('/')}` });
  }
  if (typeof name !== 'string' || !name.trim()) {
    return res.status(400).json({ error: 'name is required' });
  }
  if (typeof baseUrl !== 'string' || !/^https?:\/\//.test(baseUrl)) {
    return res.status(400).json({ error: 'baseUrl must be a valid http(s) URL' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const inserted = await client.query(
        `INSERT INTO sources (kind, issuer_id, name, base_url, tos_note, tos_reviewed, is_enabled)
         VALUES ($1, $2, $3, $4, $5, false, false)
         RETURNING *`,
        [kind, issuerId || null, name.trim(), baseUrl, tosNote || null]
      );
      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, after_value, reason)
         VALUES ($1, 'create_source', 'sources', $2, $3, $4)`,
        [req.userId, inserted.rows[0].id, JSON.stringify(inserted.rows[0]), reason || null]
      );
      return inserted.rows[0];
    });
    res.status(201).json({ source: result });
  } catch (err) {
    console.error('POST /admin/sources error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.patch('/admin/sources/:id', requireAdmin, async (req, res) => {
  const { tosReviewed, tosNote, isEnabled, crawlFrequencyDays, reason } = req.body || {};
  if (tosReviewed !== undefined && typeof tosReviewed !== 'boolean') {
    return res.status(400).json({ error: 'tosReviewed must be a boolean' });
  }
  if (isEnabled !== undefined && typeof isEnabled !== 'boolean') {
    return res.status(400).json({ error: 'isEnabled must be a boolean' });
  }
  if (crawlFrequencyDays !== undefined && (!Number.isInteger(crawlFrequencyDays) || crawlFrequencyDays < 1)) {
    return res.status(400).json({ error: 'crawlFrequencyDays must be a positive integer' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const before = await client.query(`SELECT * FROM sources WHERE id = $1`, [req.params.id]);
      if (before.rows.length === 0) return null;

      const effectiveTosReviewed = tosReviewed !== undefined ? tosReviewed : before.rows[0].tos_reviewed;
      const effectiveIsEnabled = isEnabled !== undefined ? isEnabled : before.rows[0].is_enabled;
      if (effectiveIsEnabled && !effectiveTosReviewed) {
        return { error: 'cannot enable a source before its ToS has been reviewed' };
      }

      const updated = await client.query(
        `UPDATE sources SET
           tos_reviewed = COALESCE($1, tos_reviewed),
           tos_note = COALESCE($2, tos_note),
           is_enabled = COALESCE($3, is_enabled),
           crawl_frequency = COALESCE($4::int * interval '1 day', crawl_frequency)
         WHERE id = $5
         RETURNING *`,
        [tosReviewed ?? null, tosNote ?? null, isEnabled ?? null, crawlFrequencyDays ?? null, req.params.id]
      );

      await client.query(
        `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
         VALUES ($1, 'update_source', 'sources', $2, $3, $4, $5)`,
        [req.userId, req.params.id, JSON.stringify(before.rows[0]), JSON.stringify(updated.rows[0]), reason || null]
      );
      return { source: updated.rows[0] };
    });
    if (!result) return res.status(404).json({ error: 'source not found' });
    if (result.error) return res.status(400).json({ error: result.error });
    res.json(result);
  } catch (err) {
    console.error('PATCH /admin/sources/:id error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/scrape-runs', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT r.id, r.source_id, s.name AS source_name, r.triggered_by, r.status,
                r.pages_fetched, r.pages_changed, r.started_at, r.finished_at, r.duration_ms, r.error_text
           FROM scrape_runs r
           JOIN sources s ON s.id = r.source_id
          ORDER BY r.started_at DESC NULLS LAST LIMIT 100`
      )
    );
    res.json({ scrapeRuns: result.rows });
  } catch (err) {
    console.error('GET /admin/scrape-runs error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/source-pages/:id/snapshots', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT id, content_hash, extracted_text, http_status, captured_at
           FROM page_snapshots WHERE source_page_id = $1
          ORDER BY captured_at DESC LIMIT 5`,
        [req.params.id]
      )
    );
    res.json({ snapshots: result.rows });
  } catch (err) {
    console.error('GET /admin/source-pages/:id/snapshots error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/sources/:id/pages', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT id, url, page_role, card_product_id, last_crawled_at, last_changed_at, consecutive_failures, is_enabled
           FROM source_pages WHERE source_id = $1 ORDER BY page_role, url`,
        [req.params.id]
      )
    );
    res.json({ sourcePages: result.rows });
  } catch (err) {
    console.error('GET /admin/sources/:id/pages error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/data-quality-dashboard', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query('SELECT * FROM v_data_quality_dashboard')
    );
    res.json({ dashboard: result.rows[0] });
  } catch (err) {
    console.error('GET /admin/data-quality-dashboard error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/anonymization-audit-runs', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query('SELECT * FROM anonymization_audit_runs ORDER BY ran_at DESC LIMIT 50')
    );
    res.json({ auditRuns: result.rows });
  } catch (err) {
    console.error('GET /admin/anonymization-audit-runs error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/admin/anonymization-audit-runs/latest', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query('SELECT * FROM anonymization_audit_runs ORDER BY ran_at DESC LIMIT 1')
    );
    res.json({ latestRun: result.rows[0] || null });
  } catch (err) {
    console.error('GET /admin/anonymization-audit-runs/latest error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/admin/anonymization-audit-runs/run', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const run = await client.query(
        `SELECT pandapay.run_anonymization_audit($1) AS id`,
        [req.body?.gitSha || null]
      );
      const runId = run.rows[0].id;
      const detail = await client.query('SELECT * FROM anonymization_audit_runs WHERE id = $1', [runId]);
      return detail.rows[0];
    });
    res.status(201).json({ auditRun: result });
  } catch (err) {
    console.error('POST /admin/anonymization-audit-runs/run error', safeErrorCode(err));
    res.status(500).json({ error: 'internal_error' });
  }
});
}

module.exports = { registerInlineAdminRoutes };
