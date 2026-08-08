require('dotenv').config();
const express = require('express');
const cors = require('cors');
const { withUserClient } = require('./db');
const { optionalAuth, requireAuth } = require('./auth');
const { periodBounds, effectiveRatePerRupee, effectivePointsPerRupee } = require('./cycles');
const { parseSmsAgainstPatterns, redactSmsShape } = require('./sms_parser');

const app = express();
app.use(cors());
app.use(express.json());
app.use(optionalAuth);

app.get('/health', (req, res) => res.json({ ok: true }));

/**
 * GET /profile — proves RLS is reachable end to end: an authenticated user
 * can only ever see their own profiles row, by construction (0011's
 * profiles_owner policy), not by anything this route does.
 */
app.get('/profile', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query('SELECT * FROM profiles WHERE id = $1', [req.userId])
    );
    res.json({ profile: result.rows[0] || null });
  } catch (err) {
    console.error('GET /profile error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /profile — onboarding: creates the profiles row for the
 * already-authenticated auth-service user id. profiles.id has no DB-level
 * FK to auth/'s users table (cross-database), so this route is the one
 * place that enforces "only ever insert a profile for your own verified id"
 * — the id column is never taken from the request body.
 */
app.post('/profile', requireAuth, async (req, res) => {
  const { displayName, locale, currency } = req.body || {};
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `INSERT INTO profiles (id, display_name, locale, currency)
         VALUES ($1, $2, COALESCE($3, 'en-IN'), COALESCE($4, 'INR'))
         ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name
         RETURNING *`,
        [req.userId, displayName || null, locale || null, currency || null]
      )
    );
    res.status(201).json({ profile: result.rows[0] });
  } catch (err) {
    console.error('POST /profile error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /catalogue — public read of published cards (0011's
 * card_products_public_read policy: `to public using (true)`), no auth
 * required. Proves the anon-read path works too, not just owner rows.
 */
app.get('/catalogue', async (req, res) => {
  try {
    const result = await withUserClient(null, (client) =>
      client.query('SELECT * FROM v_card_catalogue_export ORDER BY name')
    );
    res.json({ cards: result.rows });
  } catch (err) {
    console.error('GET /catalogue error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-0.3.2: readonly-vs-write is enforced in the repository layer, not just
 * the UI. requireAdmin checks pandapay.is_admin() for real (see
 * db/supabase/migrations/0011_rls_policies.sql — SECURITY DEFINER, fixed
 * this session after it recursed infinitely under a real non-superuser
 * role). NOTE: card_products' own RLS policy is `public_read using (true)`
 * — unconditional, not filtered to published rows — so Postgres RLS alone
 * does not hide draft cards from a non-admin reading the table directly.
 * This requireAdmin check is therefore the only thing actually gating
 * /admin/* in this build, not a second independent layer on top of RLS.
 * Flagged as a real gap, not fixed this session (would need either a
 * status-filtered RLS policy for non-admins or a security-definer view).
 */
async function requireAdmin(req, res, next) {
  if (!req.userId) {
    return res.status(401).json({ error: 'Missing or invalid access token' });
  }
  try {
    const isAdmin = await withUserClient(req.userId, async (client) => {
      const result = await client.query('SELECT pandapay.is_admin() AS is_admin');
      return result.rows[0].is_admin;
    });
    if (!isAdmin) {
      return res.status(403).json({ error: 'Admin access required' });
    }
    next();
  } catch (err) {
    console.error('requireAdmin error', err);
    res.status(500).json({ error: 'internal_error' });
  }
}

app.get('/admin/me', requireAuth, async (req, res) => {
  try {
    const isAdmin = await withUserClient(req.userId, async (client) => {
      const result = await client.query('SELECT pandapay.is_admin() AS is_admin');
      return result.rows[0].is_admin;
    });
    res.json({ isAdmin });
  } catch (err) {
    console.error('GET /admin/me error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /admin/cards — AD-1.1.1 catalogue browse: every card regardless of
 * publish status, via v_admin_card_catalogue_export.
 */
app.get('/admin/cards', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query('SELECT * FROM v_admin_card_catalogue_export ORDER BY name')
    );
    res.json({ cards: result.rows });
  } catch (err) {
    console.error('GET /admin/cards error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * PUT /admin/reward-rules/:id — AD-1.1.3 typed writer: the only field this
 * route can change is `rate`, validated as a positive number, never raw
 * JSON passthrough. AD-0.3.4: every mutating action writes admin_audit_log
 * — done in the same transaction as the update, so a write that reaches the
 * table but fails to audit is impossible (whole transaction rolls back).
 * The bump_card_data_version trigger (0003) fires automatically on the
 * reward_rules UPDATE, so this also correctly propagates a device-sync
 * version bump — verified, not assumed (see PROGRESS.md).
 */
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
    console.error('PUT /admin/reward-rules/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * UA-5.3 admin CRUD for `parser_patterns` — the per-issuer SMS regex
 * catalogue the sms_parser.js engine reads at parse time. Mirrors the
 * PUT /admin/reward-rules/:id typed-writer shape: every writable field is
 * individually validated (never a raw JSON passthrough), and every mutation
 * writes admin_audit_log in the SAME transaction as the write, so an
 * audit-less mutation is impossible by construction, same as every other
 * admin route in this file.
 */
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
    console.error('GET /admin/parser-patterns error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /admin/parser-patterns — create a new pattern. channel/regex/
 * field_map are required; a pattern with no way to identify the sender
 * (sender_pattern) is legal (senderMatches() treats a missing pattern as
 * "no restriction") but every other field is validated by type.
 */
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
    console.error('POST /admin/parser-patterns error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * PUT /admin/parser-patterns/:id — updates the pattern's content fields and
 * bumps `version` (parser_patterns.version exists precisely to distinguish
 * pattern revisions — a content edit without a version bump would make
 * that column meaningless), same before/after audit-log pattern as
 * PUT /admin/reward-rules/:id.
 */
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
    console.error('PUT /admin/parser-patterns/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * DELETE /admin/parser-patterns/:id — hard delete (this catalogue table has
 * no soft-delete/status column like card_products does, so unlike
 * POST /admin/cards/:id/status there is no archived state to move to).
 * Logged in admin_audit_log with the deleted row as before_value so the
 * content isn't lost from the audit trail even though the row is gone.
 */
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
    console.error('DELETE /admin/parser-patterns/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /admin/cards/:id/status — AD-1.1.4's draft->in_review->published
 * state machine (was UI-less since Chunk 6; the DB already enforced the
 * `card_published_needs_verification` CHECK — publishing without
 * `verified_at` set was always impossible, this route is just the first
 * thing that can legally reach 'published'). Allowed transitions only:
 * draft->in_review, in_review->draft (send back), in_review->published
 * (sets verified_at/verified_by if not already set — this is the human
 * verification pass, not automatic), published->archived. Any other
 * transition is rejected rather than silently allowed.
 */
const CARD_STATUS_TRANSITIONS = {
  draft: ['in_review'],
  in_review: ['draft', 'published'],
  published: ['archived'],
  archived: [],
};

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
    console.error('POST /admin/cards/:id/status error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /categories — spend_categories, slug -> id. The engine's
 * RecommendationContext.categoryId is the UUID FK reward_rules.category_id
 * actually uses, but every client-facing surface (chips, seed data docs)
 * refers to categories by slug — this is the lookup that bridges the two.
 * Public read, same policy shape as /catalogue.
 */
app.get('/categories', async (req, res) => {
  try {
    const result = await withUserClient(null, (client) =>
      client.query('SELECT id, slug, name FROM spend_categories ORDER BY sort_order')
    );
    res.json({ categories: result.rows });
  } catch (err) {
    console.error('GET /categories error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /app-status — S5/S6 (ui-spec System Surfaces, GAP_ANALYSIS.md §3):
 * forced upgrade / maintenance mode. Public, no auth — called before a
 * session exists, same reasoning as GET /categories above. Single-row
 * table (0020_app_status.sql); a missing row (shouldn't happen given the
 * migration's seed insert, but defensively) is treated the same as "no
 * restriction" rather than a 500, so a DB hiccup here never itself blocks
 * the whole app — the client's own fetch failure handling already fails
 * open the same way.
 */
app.get('/app-status', async (req, res) => {
  try {
    const result = await withUserClient(null, (client) =>
      client.query(
        'SELECT min_supported_version, maintenance_mode, maintenance_message FROM app_status WHERE id = true'
      )
    );
    const row = result.rows[0];
    res.json({
      minSupportedVersion: row?.min_supported_version ?? '1.0.0',
      maintenanceMode: row?.maintenance_mode ?? false,
      maintenanceMessage: row?.maintenance_message ?? null,
    });
  } catch (err) {
    console.error('GET /app-status error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /merchants/nearby — UA-8.3: foreground-triggered "check nearby
 * merchants" (see PROGRESS.md's UA-8 chunk for the explicit scope
 * reduction — no always-on background geofence monitoring, just this
 * one-shot lookup off a location read once). Public read, same shape/
 * policy pattern as GET /catalogue and GET /categories — no auth
 * required, only `is_published` merchants are ever returned (same
 * published-only filter AD-6's console table applies for admin viewing,
 * applied here unconditionally since this route has no admin gate at all).
 *
 * Distance filtering is done in SQL with a real haversine expression over
 * `merchant_locations.grid_lat`/`grid_lng` (AD-6/Chunk 23's grid-snapped
 * columns — nothing more precise exists to query), not the
 * packages/pandapay_domain haversine (that copy is for the pure-Dart
 * client-side matching path — app/lib/features/geofence/ — this SQL copy
 * is deliberately independent so the API doesn't need a Dart runtime).
 */
app.get('/merchants/nearby', async (req, res) => {
  const lat = Number(req.query.lat);
  const lng = Number(req.query.lng);
  const radiusM = req.query.radiusM !== undefined ? Number(req.query.radiusM) : 2000;

  if (!Number.isFinite(lat) || lat < -90 || lat > 90) {
    return res.status(400).json({ error: 'lat is required and must be between -90 and 90' });
  }
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) {
    return res.status(400).json({ error: 'lng is required and must be between -180 and 180' });
  }
  if (!Number.isFinite(radiusM) || radiusM <= 0 || radiusM > 50000) {
    return res.status(400).json({ error: 'radiusM must be a positive number, max 50000' });
  }

  try {
    const result = await withUserClient(null, (client) =>
      client.query(
        `SELECT merchant_id, display_name, category_id, confidence,
                grid_lat, grid_lng, distance_meters
           FROM (
             SELECT m.id AS merchant_id, m.display_name, m.category_id, m.confidence,
                    ml.grid_lat, ml.grid_lng,
                    2 * 6371000 * asin(sqrt(
                      sin(radians(ml.grid_lat - $1) / 2) ^ 2 +
                      cos(radians($1)) * cos(radians(ml.grid_lat)) *
                      sin(radians(ml.grid_lng - $2) / 2) ^ 2
                    )) AS distance_meters
               FROM merchant_locations ml
               JOIN merchants m ON m.id = ml.merchant_id
              WHERE m.is_published = true
           ) nearby
          WHERE distance_meters <= $3
          ORDER BY distance_meters ASC
          LIMIT 100`,
        [lat, lng, radiusM]
      )
    );
    res.json({ merchants: result.rows });
  } catch (err) {
    console.error('GET /merchants/nearby error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

const CARD_NETWORKS = ['rupay', 'visa', 'mastercard', 'amex', 'diners'];

/**
 * POST /card-requests — Task C-0b (ui-spec A8/C8): "my card isn't listed" /
 * "request a new card", available both during onboarding and any time from
 * Cards. `image_path` is a pre-uploaded storage path, never a raw file —
 * the client is responsible for uploading a FACE-ONLY photo (never the card
 * number) before calling this; this route just records the pointer, same
 * division of responsibility as every other *_path column in this schema.
 * profile_id is always req.userId, never taken from the body (same pattern
 * as POST /user-cards) so a request can never be attributed to someone else.
 */
app.post('/card-requests', requireAuth, async (req, res) => {
  const { issuerName, productName, networkGuess, imagePath } = req.body || {};
  if (!issuerName || typeof issuerName !== 'string' || !issuerName.trim()) {
    return res.status(400).json({ error: 'issuerName is required' });
  }
  if (!productName || typeof productName !== 'string' || !productName.trim()) {
    return res.status(400).json({ error: 'productName is required' });
  }
  if (networkGuess !== undefined && networkGuess !== null && !CARD_NETWORKS.includes(networkGuess)) {
    return res.status(400).json({ error: `networkGuess must be one of: ${CARD_NETWORKS.join(', ')}` });
  }
  try {
    // Task C-0b: a repeat request for the same issuer+product (case-
    // insensitive) from the SAME pending row bumps request_count instead of
    // inserting a duplicate — request_count is what AD-2.1's admin queue
    // sorts priority by, meant to reflect real distinct demand, not one
    // enthusiastic user retrying the form. No unique constraint exists on
    // (profile_id, issuer_name, product_name) to lean on `ON CONFLICT` for
    // this, so it's an explicit select-then-branch inside the same
    // transaction `withUserClient` already gives us.
    const result = await withUserClient(req.userId, async (client) => {
      const existing = await client.query(
        `SELECT id, request_count FROM card_requests
          WHERE profile_id = $1 AND state = 'pending'
            AND lower(issuer_name) = lower($2) AND lower(product_name) = lower($3)`,
        [req.userId, issuerName.trim(), productName.trim()]
      );
      if (existing.rows.length > 0) {
        const bumped = await client.query(
          `UPDATE card_requests SET request_count = request_count + 1
            WHERE id = $1
            RETURNING id, issuer_name, product_name, network_guess, state, request_count, created_at`,
          [existing.rows[0].id]
        );
        return bumped.rows[0];
      }
      const inserted = await client.query(
        `INSERT INTO card_requests (profile_id, issuer_name, product_name, network_guess, image_path)
         VALUES ($1, $2, $3, $4, $5)
         RETURNING id, issuer_name, product_name, network_guess, state, request_count, created_at`,
        [req.userId, issuerName.trim(), productName.trim(), networkGuess || null, imagePath || null]
      );
      return inserted.rows[0];
    });
    res.status(201).json({ cardRequest: result });
  } catch (err) {
    console.error('POST /card-requests error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /data-error-reports — Task C-0b (ui-spec C7 "Report Wrong Data").
 * Pre-filled from whichever C2 tab/row the user tapped from: `fieldPath` is
 * a caller-supplied identifier of what's wrong (e.g. "reward_rules[0].rate"),
 * not validated against the actual card shape server-side — same trust
 * boundary as the rest of this route (a human reviews every report before
 * anything is published, per data_error_reports' review_state workflow).
 * `attachmentPath` is a pre-uploaded storage path, same division of
 * responsibility as card_requests.image_path above.
 */
app.post('/data-error-reports', requireAuth, async (req, res) => {
  const { cardProductId, fieldPath, shownValue, claimedValue, sourceUrl, attachmentPath } = req.body || {};
  if (!cardProductId || typeof cardProductId !== 'string') {
    return res.status(400).json({ error: 'cardProductId is required' });
  }
  if (!fieldPath || typeof fieldPath !== 'string' || !fieldPath.trim()) {
    return res.status(400).json({ error: 'fieldPath is required' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const card = await client.query(`SELECT id FROM card_products WHERE id = $1`, [cardProductId]);
      if (card.rows.length === 0) return null;

      const inserted = await client.query(
        `INSERT INTO data_error_reports
           (profile_id, card_product_id, field_path, shown_value, claimed_value, source_url, attachment_path)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         RETURNING id, card_product_id, field_path, state, created_at`,
        [
          req.userId,
          cardProductId,
          fieldPath.trim(),
          shownValue ?? null,
          claimedValue ?? null,
          sourceUrl || null,
          attachmentPath || null,
        ]
      );
      return inserted.rows[0];
    });

    if (!result) return res.status(404).json({ error: 'card_product not found' });
    res.status(201).json({ errorReport: result });
  } catch (err) {
    console.error('POST /data-error-reports error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /merchants/search — B5: typed search over published merchants, by
 * display name only (not VPA — VPA search is a B3 scope reduction noted in
 * this plan's Task 12). Public read, same is_published-only filter as
 * GET /merchants/nearby, same q ILIKE pattern as GET /admin/merchants but
 * without the admin gate. Each row is shaped like a /merchants/nearby
 * candidate (minus distance_meters, since search has no origin point) so
 * the app can feed results into the same NearbyMerchantCandidate/
 * bestCardForMerchantProvider machinery nearby_merchants_screen.dart
 * already uses, rather than a third parallel "merchant result" shape.
 */
app.get('/merchants/search', async (req, res) => {
  const q = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  if (q.length === 0) {
    return res.status(400).json({ error: 'q is required' });
  }

  try {
    const result = await withUserClient(null, (client) =>
      client.query(
        `SELECT m.id AS merchant_id, m.display_name, m.category_id, m.confidence,
                l.grid_lat, l.grid_lng
           FROM merchants m
           LEFT JOIN LATERAL (
             SELECT grid_lat, grid_lng FROM merchant_locations
              WHERE merchant_id = m.id ORDER BY confirmation_count DESC LIMIT 1
           ) l ON true
          WHERE m.is_published = true AND m.display_name ILIKE $1
          ORDER BY m.confirmation_count DESC
          LIMIT 50`,
        [`%${q}%`]
      )
    );
    res.json({ merchants: result.rows });
  } catch (err) {
    console.error('GET /merchants/search error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /admin/card-requests — AD-2.1: New Card Request queue (A8/C8), grouped
 * by issuer+product with counts so priority follows actual demand. `state`
 * is the shared `review_state` enum (pending/resolved/dismissed) — there is
 * no separate "queue workflow" enum, per the schema this reuses.
 */
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
    console.error('GET /admin/card-requests error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /admin/card-requests/start-scraping — AD-2.1's "one-click start
 * scraping this issuer" action: creates a `sources` row pre-filled from the
 * request group, disabled by default (AD-3.1.2's ToS gate — `is_enabled`
 * cannot be true until `tos_reviewed` is true, enforced by the DB CHECK
 * constraint itself, not by this route). Marks every matching pending
 * request as resolved.
 */
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
    console.error('POST /admin/card-requests/start-scraping error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /admin/error-reports — AD-2.2: shown-vs-claimed side by side against
 * the *current live value*, not the value at report time — a stale report
 * against an already-corrected field should visibly show shown==claimed now.
 */
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
    console.error('GET /admin/error-reports error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /admin/error-reports/:id/approve — AD-2's DoD: approving a C7
 * correction produces a card_catalogue_changes row, a data_version bump
 * (via the existing bump_card_data_version trigger firing on the
 * reward_rules UPDATE), and an audit entry, all in one transaction.
 * Scope: only field_path values shaped 'reward_rules.<rule_id>.rate' are
 * approvable through this route today — that is the one card-rule mutation
 * this API already has a typed writer for (see PUT /admin/reward-rules/:id).
 * Any other field_path is rejected rather than silently no-op'd; widening
 * this is real AD-5 propagation work (a generic field_path -> table/column
 * resolver), not something to fake here.
 */
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
        return {
          status: 422,
          error: `field_path '${report.field_path}' has no typed writer yet — only reward_rules.<id>.rate is supported`,
        };
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
    console.error('POST /admin/error-reports/:id/approve error', err);
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
    console.error('POST /admin/error-reports/:id/reject error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /admin/alerts — AD-4.2/AD-5: the unified policy-change alert queue.
 * Ordered by corroboration_score so the strongest-evidence alerts (multiple
 * agreeing signal kinds) surface first, per §4's "queue ordering" framing.
 */
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
    console.error('GET /admin/alerts error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /admin/alerts/:id — AD-4.2's side-by-side diff view backend: every
 * piece of evidence (the actual excerpt, not just a signal count) plus any
 * heuristic extraction_proposals (Chunk 14 — explicitly NOT AI, see
 * scraper/pandapay_scraper/extraction.py) for the same card, so the
 * operator sees "why" this alert exists, not just "an alert exists."
 */
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
    console.error('GET /admin/alerts/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /admin/alerts/:id/decide — AD-4.4's "operator corrects rather than
 * retypes": this route only ever changes the ALERT's state
 * (open/approved/rejected/needs_more_evidence), never card data directly.
 * Applying a correction to reward_rules/etc still goes through the
 * existing typed writers (PUT /admin/reward-rules/:id, Chunk 6, or the C7
 * error-queue's approve route, Chunk 8) — this route can't, by
 * construction, silently write a heuristic guess into live card data.
 */
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
    console.error('POST /admin/alerts/:id/decide error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /user-cards — UA-3+: the signed-in user's own wallet. Owner-scoped by
 * RLS (0011's user_cards_owner policy), joined to v_card_catalogue_export's
 * underlying card_products for the display fields the app needs — never
 * includes archived cards (R4: user_cards are archived, never deleted, so
 * "my wallet" must filter is_archived itself; the DB doesn't do that for
 * you).
 */
app.get('/user-cards', requireAuth, async (req, res) => {
  // Task C-1 (ui-spec C1 My Cards "active/archived filter"): every other
  // consumer of this route (ranking, cap/milestone assembly) must never see
  // an archived card, so the filter defaults to active-only exactly as
  // before — ?includeArchived=true is opt-in, used only by C1's own toggle.
  const includeArchived = req.query.includeArchived === 'true';
  try {
    const result = await withUserClient(req.userId, async (client) => {
      // statement_day/opened_on added for Task 11 (E7 Billing Cycle Float —
      // the same two columns insertTransactionAndUpdateState below already
      // reads internally for period-bounds math, just never previously
      // returned to a client that could display them).
      // Task E-0 (Group E plan): credit_limit_inr/due_day/anniversary_on all
      // already existed in Postgres (0004_user_domain.sql) but were never
      // selected here — E3 (Credit Utilization), E8 (Due Date Calendar) and
      // E5 (Fee Waivers' days-to-anniversary) all stalled on this exact gap.
      const cards = await client.query(
        `SELECT uc.id, uc.card_product_id, uc.nickname, uc.is_default, uc.sort_order,
                uc.created_at, uc.statement_day, uc.due_day, uc.opened_on,
                uc.credit_limit_inr, uc.anniversary_on, uc.is_archived,
                uc.points_balance, uc.points_balance_state,
                cp.name AS card_name, cp.network, cp.is_upi_linkable
           FROM user_cards uc
           JOIN card_products cp ON cp.id = uc.card_product_id
          WHERE ($1::boolean OR uc.is_archived = false)
          ORDER BY uc.sort_order, uc.created_at`,
        [includeArchived]
      );

      // Chunk 17: the CURRENTLY-ACTIVE period's cap/milestone state, so the
      // app can build real CardSnapshot.capRemaining/milestoneProgress
      // instead of always evaluating every owned card as freshly-uncapped.
      // No row for a (cap_rule, current period) means no spend has been
      // logged against it yet this period — full headroom, which is
      // exactly what the engine already defaults to when a key is absent.
      for (const card of cards.rows) {
        const capStates = await client.query(
          `SELECT cap_rule_id, consumed, cap_value_snapshot FROM cap_states
            WHERE user_card_id = $1 AND period_start <= CURRENT_DATE AND period_end >= CURRENT_DATE`,
          [card.id]
        );
        // period_end added alongside Task E-0's other additions (E4's
        // days-left needs a real deadline date, not just a progress ratio).
        const milestoneStates = await client.query(
          `SELECT milestone_rule_id, qualified_spend, period_end FROM milestone_states
            WHERE user_card_id = $1 AND period_start <= CURRENT_DATE AND period_end >= CURRENT_DATE`,
          [card.id]
        );
        card.cap_states = capStates.rows;
        card.milestone_states = milestoneStates.rows;

        // Chunk 28: lifetime points-earned total (not period-scoped, unlike
        // caps/milestones — a points balance doesn't reset each cycle) and
        // the current-period fee-waiver progress, same "no row = no
        // progress yet" default as above.
        // Task C-4 fix: this previously summed points_ledger ONLY, silently
        // dropping uc.points_balance — the "current points balance, starting
        // point; we'll track from here" figure A9/C4 actually let a user
        // enter. A card added with an existing 12,000-point balance and zero
        // transactions since showed 0 pts everywhere, not 12,000 — folding
        // the starting balance in here is the one place every consumer
        // (C1's badge, C6, this endpoint) already reads from.
        const pointsTotal = await client.query(
          `SELECT COALESCE(SUM(delta_points), 0) AS total_points FROM points_ledger WHERE user_card_id = $1`,
          [card.id]
        );
        card.total_points_earned = Number(pointsTotal.rows[0].total_points) + Number(card.points_balance || 0);

        const feeWaiverStates = await client.query(
          `SELECT fw.fee_waiver_rule_id, fw.qualified_spend, fw.waived_at, fw.period_end,
                  r.threshold_spend_inr, r.waives_fee_inr
             FROM fee_waiver_states fw
             JOIN fee_waiver_rules r ON r.id = fw.fee_waiver_rule_id
            WHERE fw.user_card_id = $1 AND fw.period_start <= CURRENT_DATE AND fw.period_end >= CURRENT_DATE`,
          [card.id]
        );
        card.fee_waiver_states = feeWaiverStates.rows;
      }

      return cards.rows;
    });
    res.json({ userCards: result });
  } catch (err) {
    console.error('GET /user-cards error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /user-cards — add a card to the signed-in user's wallet.
 * profile_id is always req.userId, never taken from the body — same
 * pattern as POST /profile, so a user can never add a card to someone
 * else's wallet even if they tampered with the request.
 */
app.post('/user-cards', requireAuth, async (req, res) => {
  const { cardProductId, nickname } = req.body || {};
  if (!cardProductId || typeof cardProductId !== 'string') {
    return res.status(400).json({ error: 'cardProductId is required' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const card = await client.query(
        `SELECT id FROM card_products WHERE id = $1 AND status = 'published'`,
        [cardProductId]
      );
      if (card.rows.length === 0) return null;

      const inserted = await client.query(
        `INSERT INTO user_cards (profile_id, card_product_id, nickname)
         VALUES ($1, $2, $3)
         RETURNING id, card_product_id, nickname, is_default, sort_order, created_at`,
        [req.userId, cardProductId, nickname || null]
      );
      return inserted.rows[0];
    });

    if (!result) return res.status(404).json({ error: 'card_product not found or not published' });
    res.status(201).json({ userCard: result });
  } catch (err) {
    console.error('POST /user-cards error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /user-cards/:id/archive — R4: "archive, never delete." There is
 * deliberately no DELETE /user-cards/:id route.
 */
app.post('/user-cards/:id/archive', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `UPDATE user_cards SET is_archived = true, archived_at = now()
          WHERE id = $1 AND profile_id = $2
          RETURNING id`,
        [req.params.id, req.userId]
      )
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'user_card not found' });
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /user-cards/:id/archive error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /card-overrides — B8: every override rule the signed-in user owns,
 * enabled or disabled (the Manual Overrides screen shows both, with a
 * disabled-state pill — B8's empty state explains how to create one from
 * B3, not filtered out here). Same owner-scoped pattern as GET /user-cards.
 */
app.get('/card-overrides', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT co.id, co.user_card_id, co.scope, co.vpa, co.merchant_name,
                co.category_id, sc.name AS category_name, co.reason_note,
                co.is_enabled, co.created_at,
                cp.name AS card_name, uc.nickname AS card_nickname
           FROM card_overrides co
           JOIN user_cards uc ON uc.id = co.user_card_id
           JOIN card_products cp ON cp.id = uc.card_product_id
           LEFT JOIN spend_categories sc ON sc.id = co.category_id
          WHERE co.profile_id = $1
          ORDER BY co.created_at DESC`,
        [req.userId]
      )
    );
    res.json({ overrides: result.rows });
  } catch (err) {
    console.error('GET /card-overrides error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /card-overrides — B3's "Always use this card here" and B8's manual
 * "create a rule" both land here. `scope` determines which of vpa/
 * merchantName/categoryId is required — mirrors the table's
 * override_scope_populated CHECK constraint exactly so a bad request fails
 * with a clear 400 instead of a raw constraint-violation 500.
 */
app.post('/card-overrides', requireAuth, async (req, res) => {
  const { userCardId, scope, vpa, merchantName, categoryId, reasonNote } = req.body || {};
  if (!userCardId || typeof userCardId !== 'string') {
    return res.status(400).json({ error: 'userCardId is required' });
  }
  if (!['vpa', 'merchant_name', 'category'].includes(scope)) {
    return res.status(400).json({ error: "scope must be 'vpa', 'merchant_name', or 'category'" });
  }
  if (scope === 'vpa' && !vpa) {
    return res.status(400).json({ error: 'vpa is required when scope is vpa' });
  }
  if (scope === 'merchant_name' && !merchantName) {
    return res.status(400).json({ error: 'merchantName is required when scope is merchant_name' });
  }
  if (scope === 'category' && !categoryId) {
    return res.status(400).json({ error: 'categoryId is required when scope is category' });
  }

  try {
    const result = await withUserClient(req.userId, async (client) => {
      const owns = await client.query(
        `SELECT id FROM user_cards WHERE id = $1 AND profile_id = $2 AND is_archived = false`,
        [userCardId, req.userId]
      );
      if (owns.rows.length === 0) return null;

      const inserted = await client.query(
        `INSERT INTO card_overrides (profile_id, user_card_id, scope, vpa, merchant_name, category_id, reason_note)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         RETURNING id, user_card_id, scope, vpa, merchant_name, category_id, reason_note, is_enabled, created_at`,
        [req.userId, userCardId, scope, vpa || null, merchantName || null, categoryId || null, reasonNote || null]
      );
      return inserted.rows[0];
    });

    if (!result) return res.status(404).json({ error: 'user_card not found or not owned by you' });
    res.status(201).json({ override: result });
  } catch (err) {
    console.error('POST /card-overrides error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * PATCH /card-overrides/:id — B8's edit + enable/disable toggle. Only
 * is_enabled, reason_note, and user_card_id (re-pointing the rule at a
 * different card) are editable — scope/vpa/merchant_name/category_id are
 * NOT patchable here; changing what a rule targets is a delete-and-recreate
 * in the UI (Task 4), keeping this route's write surface small and the
 * override_scope_populated CHECK trivially satisfied (we never touch the
 * scope-defining columns).
 */
app.patch('/card-overrides/:id', requireAuth, async (req, res) => {
  const { isEnabled, reasonNote, userCardId } = req.body || {};
  const sets = [];
  const params = [];
  if (isEnabled !== undefined) {
    params.push(!!isEnabled);
    sets.push(`is_enabled = $${params.length}`);
  }
  if (reasonNote !== undefined) {
    params.push(reasonNote || null);
    sets.push(`reason_note = $${params.length}`);
  }
  if (userCardId !== undefined) {
    params.push(userCardId);
    sets.push(`user_card_id = $${params.length}`);
  }
  if (sets.length === 0) {
    return res.status(400).json({ error: 'nothing to update' });
  }

  try {
    const result = await withUserClient(req.userId, async (client) => {
      if (userCardId !== undefined) {
        const owns = await client.query(
          `SELECT id FROM user_cards WHERE id = $1 AND profile_id = $2 AND is_archived = false`,
          [userCardId, req.userId]
        );
        if (owns.rows.length === 0) return 'card_not_found';
      }
      params.push(req.params.id, req.userId);
      const updated = await client.query(
        `UPDATE card_overrides SET ${sets.join(', ')}
          WHERE id = $${params.length - 1} AND profile_id = $${params.length}
          RETURNING id, user_card_id, scope, vpa, merchant_name, category_id, reason_note, is_enabled, created_at`,
        params
      );
      return updated.rows[0] || null;
    });

    if (result === 'card_not_found') return res.status(404).json({ error: 'user_card not found or not owned by you' });
    if (!result) return res.status(404).json({ error: 'override not found' });
    res.json({ override: result });
  } catch (err) {
    console.error('PATCH /card-overrides/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * DELETE /card-overrides/:id — unlike transactions/user_cards (R4: archive,
 * never delete — they carry financial history), an override rule is pure
 * user *intent*, not a financial record, so a true delete is appropriate
 * here. Confirmation lives client-side (Task 4's delete-confirmation
 * dialog per this plan's Global Constraints).
 */
app.delete('/card-overrides/:id', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `DELETE FROM card_overrides WHERE id = $1 AND profile_id = $2 RETURNING id`,
        [req.params.id, req.userId]
      )
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'override not found' });
    res.json({ ok: true });
  } catch (err) {
    console.error('DELETE /card-overrides/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /user-cards/:id/unarchive — Task C-1: C1's active/archived filter
 * needs a way back, not just a one-way archive. Same R4 "never hard-delete"
 * spirit as archive itself — restoring is just flipping the same flag back.
 */
app.post('/user-cards/:id/unarchive', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `UPDATE user_cards SET is_archived = false, archived_at = NULL
          WHERE id = $1 AND profile_id = $2
          RETURNING id`,
        [req.params.id, req.userId]
      )
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'user_card not found' });
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /user-cards/:id/unarchive error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /user-cards/reorder — Task C-1 (ui-spec C1 "drag to reorder
 * priority"). Body: { order: [userCardId, ...] } in the user's new desired
 * order; each id's sort_order becomes its index in that array. Every id
 * must belong to the caller (profile_id = req.userId) — the UPDATE's WHERE
 * clause enforces that per-row rather than trusting the array, so a client
 * that somehow included someone else's id just silently updates 0 rows for
 * that id instead of touching another user's wallet.
 */
app.post('/user-cards/reorder', requireAuth, async (req, res) => {
  const { order } = req.body || {};
  if (!Array.isArray(order) || order.length === 0 || !order.every((id) => typeof id === 'string')) {
    return res.status(400).json({ error: 'order must be a non-empty array of user_card ids' });
  }
  try {
    await withUserClient(req.userId, async (client) => {
      for (let i = 0; i < order.length; i++) {
        await client.query(
          `UPDATE user_cards SET sort_order = $1 WHERE id = $2 AND profile_id = $3`,
          [i, order[i], req.userId]
        );
      }
    });
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /user-cards/reorder error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

const USER_CARD_PATCH_FIELDS = {
  nickname: 'nickname',
  creditLimitInr: 'credit_limit_inr',
  statementDay: 'statement_day',
  dueDay: 'due_day',
  pointsBalance: 'points_balance',
};

/**
 * PATCH /user-cards/:id — Task C-4 (ui-spec C4 Edit Card). Fields: nickname,
 * credit limit, statement/due dates, points balance — the ones with a real
 * backing column (checked \d user_cards against the live DB, not just
 * database.sql). "Card art/colour" is in the ui-spec's field list too, but
 * no per-user override column exists anywhere in the schema for it (only
 * card_products.art_asset/art_primary_color, which is catalogue-wide, not
 * per-owned-card) — flagged here rather than silently skipped or faked with
 * a migration nobody asked for; a real follow-up if this is wanted.
 * All fields optional; only the ones present in the body are updated.
 * `pointsBalance` sets points_balance_state='estimated' — a manual number
 * typed into a form is definitionally not a confirmed/reconciled figure
 * (same estimated/confirmed rule this whole schema holds everywhere else).
 */
app.patch('/user-cards/:id', requireAuth, async (req, res) => {
  const body = req.body || {};
  const sets = [];
  const values = [];
  for (const [bodyKey, column] of Object.entries(USER_CARD_PATCH_FIELDS)) {
    if (!(bodyKey in body)) continue;
    values.push(body[bodyKey]);
    sets.push(`${column} = $${values.length}`);
  }
  if ('pointsBalance' in body) {
    sets.push(`points_balance_state = 'estimated'`);
  }
  if (sets.length === 0) {
    return res.status(400).json({ error: 'no editable fields supplied' });
  }
  if (body.statementDay !== undefined && body.statementDay !== null) {
    const d = Number(body.statementDay);
    if (!Number.isInteger(d) || d < 1 || d > 31) return res.status(400).json({ error: 'statementDay must be 1-31' });
  }
  if (body.dueDay !== undefined && body.dueDay !== null) {
    const d = Number(body.dueDay);
    if (!Number.isInteger(d) || d < 1 || d > 31) return res.status(400).json({ error: 'dueDay must be 1-31' });
  }
  if (body.creditLimitInr !== undefined && body.creditLimitInr !== null) {
    const l = Number(body.creditLimitInr);
    if (!Number.isFinite(l) || l < 0) return res.status(400).json({ error: 'creditLimitInr must be a non-negative number' });
  }

  values.push(req.params.id, req.userId);
  const idParam = values.length - 1;
  const profileParam = values.length;

  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `UPDATE user_cards SET ${sets.join(', ')}
          WHERE id = $${idParam} AND profile_id = $${profileParam} AND is_archived = false
          RETURNING id, nickname, credit_limit_inr, statement_day, due_day, points_balance, points_balance_state`,
        values
      )
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'user_card not found' });
    res.json({ userCard: result.rows[0] });
  } catch (err) {
    console.error('PATCH /user-cards/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /user-cards/:id/points-ledger — Task C-6 (ui-spec C6 Points &
 * Expiry). Individual points_ledger rows for one owned card, newest first
 * — GET /user-cards only ever returns the SUM (total_points_earned); this
 * is the first route to expose per-entry `expires_on`/`reason`/`state`,
 * which C6 needs for per-program expiry urgency. Ownership checked via the
 * user_cards join, not just RLS — same belt-and-suspenders pattern as
 * every other :id route in this file.
 */
app.get('/user-cards/:id/points-ledger', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const owns = await client.query(`SELECT id FROM user_cards WHERE id = $1 AND profile_id = $2`, [
        req.params.id,
        req.userId,
      ]);
      if (owns.rows.length === 0) return null;
      return client.query(
        `SELECT id, delta_points, reason, state, expires_on, occurred_at
           FROM points_ledger WHERE user_card_id = $1
          ORDER BY occurred_at DESC`,
        [req.params.id]
      );
    });
    if (!result) return res.status(404).json({ error: 'user_card not found' });
    res.json({ pointsLedger: result.rows });
  } catch (err) {
    console.error('GET /user-cards/:id/points-ledger error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /user-cards/:id/points-adjustment — Task C-6 (ui-spec C6 "manual
 * balance correction, feeds reconciliation"). Rather than overwriting a
 * total anywhere (there is no single mutable total — GET /user-cards sums
 * points_ledger + the legacy points_balance starting figure, per Task C-4's
 * fix), a correction is itself one more points_ledger row, whose
 * delta_points is computed here so the NEW total after this row lands
 * equals exactly [newBalance] the user typed. This keeps "the sum of every
 * row" as the one and only source of truth C6/C1/C4 all already read,
 * rather than introducing a second mutable total that could drift from it.
 */
app.post('/user-cards/:id/points-adjustment', requireAuth, async (req, res) => {
  const { newBalance, expiresOn } = req.body || {};
  const target = Number(newBalance);
  if (!Number.isFinite(target)) {
    return res.status(400).json({ error: 'newBalance must be a number' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const owns = await client.query(
        `SELECT uc.id, uc.points_balance FROM user_cards uc WHERE uc.id = $1 AND uc.profile_id = $2`,
        [req.params.id, req.userId]
      );
      if (owns.rows.length === 0) return null;

      const currentLedgerSum = await client.query(
        `SELECT COALESCE(SUM(delta_points), 0) AS total FROM points_ledger WHERE user_card_id = $1`,
        [req.params.id]
      );
      const currentTotal = Number(currentLedgerSum.rows[0].total) + Number(owns.rows[0].points_balance || 0);
      const delta = target - currentTotal;

      const inserted = await client.query(
        `INSERT INTO points_ledger (profile_id, user_card_id, delta_points, reason, state, expires_on, occurred_at)
         VALUES ($1, $2, $3, 'manual correction', 'estimated', $4, now())
         RETURNING id, delta_points, reason, state, expires_on, occurred_at`,
        [req.userId, req.params.id, delta, expiresOn || null]
      );
      return inserted.rows[0];
    });
    if (!result) return res.status(404).json({ error: 'user_card not found' });
    res.status(201).json({ pointsLedgerEntry: result });
  } catch (err) {
    console.error('POST /user-cards/:id/points-adjustment error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /transactions — UA-3+ (Chunk 17): manual transaction entry
 * (source='manual', reward_state='estimated' — R3, nothing here is ever
 * 'confirmed' without a real statement/SMS reconciliation path, which
 * doesn't exist yet). Updates cap_states.consumed, milestone_states.
 * qualified_spend, points_ledger (Chunk 28: one entry per txn in the
 * reward's native unit), and fee_waiver_states.qualified_spend (Chunk 28:
 * auto-marks waived_at once the threshold is crossed) all in the SAME
 * transaction as the insert, so a transaction that's recorded but doesn't
 * update state is impossible — same "whole thing rolls back together"
 * pattern as the AD-1 typed writer's audit-log guarantee.
 */
/**
 * UA-5.3: the insert-and-update-all-state logic that used to live directly
 * inline in POST /transactions, factored out so POST /transactions/from-sms
 * (Chunk 31) can call the exact same cap/milestone/points/fee-waiver
 * machinery instead of re-implementing it — a transaction recorded via SMS
 * gets identical downstream state updates to one entered manually, by
 * construction, not by keeping two copies in sync by hand. Must be called
 * with a `client` already inside a withUserClient(userId, ...) transaction;
 * this function does not open its own.
 */
async function insertTransactionAndUpdateState(client, userId, {
  userCardId, amount, occurred, categoryId, rail, merchantName, note, source,
}) {
  const userCard = await loadUserCardForState(client, userId, userCardId);
  if (!userCard) return { status: 404, error: 'user_card not found' };

  const txn = await client.query(
    `INSERT INTO transactions
       (profile_id, user_card_id, amount_inr, occurred_at, merchant_name, category_id, rail, source, note, reward_state)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'estimated')
     RETURNING id, amount_inr, occurred_at`,
    [userId, userCardId, amount, occurred, merchantName || null, categoryId || null, rail || 'unknown', source || 'manual', note || null]
  );

  const stateUpdates = await applyTransactionState(client, userId, userCard, {
    txnId: txn.rows[0].id, userCardId, amount, occurred, categoryId, sign: 1,
  });

  // Task D-5 (ui-spec D5 Duplicate Review, §5.8): runs on every insert
  // through this one shared helper, so both POST /transactions (manual)
  // and POST /transactions/from-sms get duplicate detection for free —
  // exactly the "same amount+merchant+date across channels" case the spec
  // describes (a bank SMS and a later statement import both recording the
  // same swipe is the canonical example).
  await detectDuplicates(client, userId, {
    newTxnId: txn.rows[0].id, amount, occurred, merchantName, source: source || 'manual',
  });

  return { status: 201, transaction: txn.rows[0], ...stateUpdates };
}

/**
 * Task D-5: flags likely duplicates of the just-inserted transaction —
 * same amount, occurred within a 1-day window (channels don't always agree
 * on the exact timestamp), a DIFFERENT source (the whole point: the same
 * real-world swipe reaching this app twice via two channels), still
 * 'active'. Merchant name match is a confidence signal, not a hard filter
 * — many SMS never carry a merchant name at all, so requiring an exact
 * match would silently miss the most common real case. `match_score` is a
 * simple, documented heuristic (not a statistical model): 0.9 when
 * merchant names agree case-insensitively, 0.6 when at least one side has
 * no merchant name to compare (weaker signal, still worth a human look).
 * `ON CONFLICT DO NOTHING` on (txn_a_id, txn_b_id) means re-running this
 * for the same pair (shouldn't happen — each transaction is only inserted
 * once — but is possible if this were ever called twice) is a no-op, not
 * a duplicate duplicate-flag.
 */
async function detectDuplicates(client, userId, { newTxnId, amount, occurred, merchantName, source }) {
  const candidates = await client.query(
    `SELECT id, merchant_name FROM transactions
      WHERE profile_id = $1 AND status = 'active' AND id != $2
        AND amount_inr = $3 AND source != $4
        AND occurred_at BETWEEN $5::timestamptz - interval '1 day' AND $5::timestamptz + interval '1 day'`,
    [userId, newTxnId, amount, source, occurred]
  );

  for (const candidate of candidates.rows) {
    const bothNamed = merchantName && candidate.merchant_name;
    const namesMatch = bothNamed && merchantName.toLowerCase() === candidate.merchant_name.toLowerCase();
    if (bothNamed && !namesMatch) continue; // both have a name and they disagree — not a match
    const matchScore = namesMatch ? 0.9 : 0.6;
    const matchReason = namesMatch
      ? 'Same amount, same day, merchant name matches, different source'
      : 'Same amount, same day, different source (merchant name unavailable on at least one side)';

    const [txnA, txnB] = [newTxnId, candidate.id].sort();
    await client.query(
      `INSERT INTO duplicate_candidates (profile_id, txn_a_id, txn_b_id, match_score, match_reason)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (txn_a_id, txn_b_id) DO NOTHING`,
      [userId, txnA, txnB, matchScore, matchReason]
    );
  }
}

/**
 * Task C-0c: the `user_cards` + `card_products.point_value_inr` lookup that
 * both [applyTransactionState] and [reverseTransactionState] need, factored
 * out of the old inline query in insertTransactionAndUpdateState so edit/
 * ignore don't duplicate it. Same archived-card guard as before — you can't
 * apply OR reverse state against an archived card via this path (archiving
 * already excludes a card from ranking; state math intentionally stays
 * frozen once a card is archived rather than being editable afterward).
 */
async function loadUserCardForState(client, userId, userCardId) {
  const result = await client.query(
    `SELECT uc.id, uc.card_product_id, uc.statement_day, uc.opened_on, uc.created_at,
            cp.point_value_inr
       FROM user_cards uc
       JOIN card_products cp ON cp.id = uc.card_product_id
      WHERE uc.id = $1 AND uc.profile_id = $2 AND uc.is_archived = false`,
    [userCardId, userId]
  );
  return result.rows[0] || null;
}

/**
 * Task C-0c: the cap/milestone/points/fee-waiver mutation core, extracted
 * from insertTransactionAndUpdateState (UA-5.3's original factoring
 * separated "insert the row" from nothing — this separates "insert the
 * row" from "apply its effect on state") so [reverseTransactionState] can
 * run the exact same rule-matching and period-bounds logic with the
 * opposite sign, rather than re-deriving it and risking the two drifting
 * apart. `sign` is +1 to apply (POST /transactions, POST .../from-sms) or
 * -1 to reverse (PATCH edit's old-value undo, POST .../ignore).
 *
 * Cap/milestone/fee-waiver state is period-BUCKETED (no per-transaction
 * row to just delete), so reversing means recomputing the same delta this
 * transaction would have contributed and subtracting it back out —
 * correct as long as the underlying reward_rules/cap_rules haven't changed
 * between apply and reverse. A policy update mid-cycle could make a
 * reversal not exactly cancel its original apply; this is a known,
 * accepted limitation (flagged here, not hidden) rather than something
 * this pass solves by snapshotting every rule per transaction.
 * `GREATEST(0, ...)` on the way down guards against floating-point drift
 * ever pushing a consumed/qualified total negative.
 *
 * Points ledger is NOT bucketed — it's one row per transaction — so it
 * doesn't use the add/subtract pattern at all: sign=1 inserts a fresh row,
 * sign=-1 deletes the row keyed by `transaction_id`.
 */
async function applyTransactionState(client, userId, userCard, {
  txnId, userCardId, amount, occurred, categoryId, sign,
}) {
  const matchingRule = await client.query(
    `SELECT unit, rate FROM reward_rules
      WHERE card_product_id = $1 AND (category_id IS NULL OR category_id = $2)
      ORDER BY priority ASC LIMIT 1`,
    [userCard.card_product_id, categoryId || null]
  );
  const rewardRate = matchingRule.rows[0]
    ? effectiveRatePerRupee(matchingRule.rows[0].unit, Number(matchingRule.rows[0].rate), Number(userCard.point_value_inr) || 0)
    : 0;

  const capRules = await client.query(
    `SELECT id, period, cap_value, measure FROM cap_rules
      WHERE card_product_id = $1 AND (category_id IS NULL OR category_id = $2)`,
    [userCard.card_product_id, categoryId || null]
  );
  const capStateUpdates = [];
  for (const cap of capRules.rows) {
    let consumedDelta;
    if (cap.measure === 'reward_value') {
      consumedDelta = amount * rewardRate;
    } else if (cap.measure === 'txn_count') {
      consumedDelta = 1;
    } else {
      consumedDelta = amount;
    }
    consumedDelta *= sign;

    const { start, end } = periodBounds(cap.period, occurred, { statementDay: userCard.statement_day });
    const upserted = await client.query(
      `INSERT INTO cap_states (profile_id, user_card_id, cap_rule_id, period_start, period_end, consumed, cap_value_snapshot)
       VALUES ($1, $2, $3, $4, $5, GREATEST(0, $6), $7)
       ON CONFLICT (user_card_id, cap_rule_id, period_start)
       DO UPDATE SET consumed = GREATEST(0, cap_states.consumed + $6), updated_at = now()
       RETURNING cap_rule_id, period_start, period_end, consumed, cap_value_snapshot`,
      [userId, userCardId, cap.id, start, end, consumedDelta, cap.cap_value]
    );
    capStateUpdates.push(upserted.rows[0]);
  }

  const milestoneRules = await client.query(
    `SELECT id, period, anchor FROM milestone_rules WHERE card_product_id = $1`,
    [userCard.card_product_id]
  );
  const milestoneStateUpdates = [];
  for (const milestone of milestoneRules.rows) {
    const anchorDate = userCard.opened_on || userCard.created_at;
    const { start, end } = periodBounds(milestone.period, occurred, {
      statementDay: userCard.statement_day,
      anchor: milestone.anchor,
      anchorDate,
    });
    const upserted = await client.query(
      `INSERT INTO milestone_states (profile_id, user_card_id, milestone_rule_id, period_start, period_end, qualified_spend)
       VALUES ($1, $2, $3, $4, $5, GREATEST(0, $6))
       ON CONFLICT (user_card_id, milestone_rule_id, period_start)
       DO UPDATE SET qualified_spend = GREATEST(0, milestone_states.qualified_spend + $6), updated_at = now()
       RETURNING milestone_rule_id, period_start, period_end, qualified_spend`,
      [userId, userCardId, milestone.id, start, end, amount * sign]
    );
    milestoneStateUpdates.push(upserted.rows[0]);
  }

  // Points ledger: one row per transaction (not bucketed) — apply inserts,
  // reverse deletes the row this exact transaction wrote. flat_points
  // rules earn 0 per this helper (a fixed bonus isn't a per-transaction
  // rate) so no ledger noise is written or needs deleting for them.
  let pointsLedgerEntry = null;
  if (matchingRule.rows[0]) {
    const pointsPerRupee = effectivePointsPerRupee(matchingRule.rows[0].unit, Number(matchingRule.rows[0].rate));
    if (pointsPerRupee > 0) {
      if (sign > 0) {
        const deltaPoints = amount * pointsPerRupee;
        const inserted = await client.query(
          `INSERT INTO points_ledger (profile_id, user_card_id, transaction_id, delta_points, reason, state, occurred_at)
           VALUES ($1, $2, $3, $4, $5, 'estimated', $6)
           RETURNING id, delta_points, reason, occurred_at`,
          [userId, userCardId, txnId, deltaPoints, `${matchingRule.rows[0].unit} earned on transaction`, occurred]
        );
        pointsLedgerEntry = inserted.rows[0];
      } else {
        await client.query(`DELETE FROM points_ledger WHERE transaction_id = $1`, [txnId]);
      }
    }
  }

  // Fee-waiver progress: same bucketed add/subtract shape as caps above,
  // against fee_waiver_rules/fee_waiver_states. A category on
  // excluded_categories never counts toward the threshold, in either
  // direction. On reversal, if qualified_spend drops back below threshold,
  // waived_at is un-marked — otherwise the app would keep telling the user
  // a fee is waived after an edit/ignore made that no longer true, which
  // fails "never display a number the app can't justify" (ui-spec Data
  // honesty) worse than the (rare) case of un-waiving something the bank
  // itself would still honor once already granted.
  const feeWaiverRules = await client.query(
    `SELECT id, threshold_spend_inr, period, excluded_categories FROM fee_waiver_rules
      WHERE card_product_id = $1`,
    [userCard.card_product_id]
  );
  const feeWaiverStateUpdates = [];
  for (const rule of feeWaiverRules.rows) {
    if (categoryId && rule.excluded_categories && rule.excluded_categories.includes(categoryId)) {
      continue;
    }
    const { start, end } = periodBounds(rule.period, occurred, { statementDay: userCard.statement_day });
    const upserted = await client.query(
      `INSERT INTO fee_waiver_states (profile_id, user_card_id, fee_waiver_rule_id, period_start, period_end, qualified_spend)
       VALUES ($1, $2, $3, $4, $5, GREATEST(0, $6))
       ON CONFLICT (user_card_id, fee_waiver_rule_id, period_start)
       DO UPDATE SET qualified_spend = GREATEST(0, fee_waiver_states.qualified_spend + $6), updated_at = now()
       RETURNING id, fee_waiver_rule_id, period_start, period_end, qualified_spend, waived_at`,
      [userId, userCardId, rule.id, start, end, amount * sign]
    );
    let state = upserted.rows[0];
    if (!state.waived_at && Number(state.qualified_spend) >= Number(rule.threshold_spend_inr)) {
      const marked = await client.query(
        `UPDATE fee_waiver_states SET waived_at = now() WHERE id = $1
         RETURNING id, fee_waiver_rule_id, period_start, period_end, qualified_spend, waived_at`,
        [state.id]
      );
      state = marked.rows[0];
    } else if (state.waived_at && Number(state.qualified_spend) < Number(rule.threshold_spend_inr)) {
      const unmarked = await client.query(
        `UPDATE fee_waiver_states SET waived_at = NULL WHERE id = $1
         RETURNING id, fee_waiver_rule_id, period_start, period_end, qualified_spend, waived_at`,
        [state.id]
      );
      state = unmarked.rows[0];
    }
    feeWaiverStateUpdates.push(state);
  }

  return {
    capStates: capStateUpdates,
    milestoneStates: milestoneStateUpdates,
    pointsLedgerEntry,
    feeWaiverStates: feeWaiverStateUpdates,
  };
}

/**
 * Task C-0c: undo exactly what [applyTransactionState] did for an existing,
 * already-recorded transaction — driven by that transaction's OWN stored
 * fields (its original amount/category/occurred_at), never the caller's
 * new edit values, since what needs reversing is what was actually applied
 * originally. Used by PATCH /transactions/:id (reverse-old, then re-apply-
 * new) and POST /transactions/:id/ignore (reverse-old only).
 */
async function reverseTransactionState(client, userId, userCard, txnRow) {
  return applyTransactionState(client, userId, userCard, {
    txnId: txnRow.id,
    userCardId: txnRow.user_card_id,
    amount: Number(txnRow.amount_inr),
    occurred: txnRow.occurred_at,
    categoryId: txnRow.category_id,
    sign: -1,
  });
}

app.post('/transactions', requireAuth, async (req, res) => {
  const { userCardId, amountInr, occurredAt, categoryId, rail, merchantName, note } = req.body || {};
  const amount = Number(amountInr);
  if (!userCardId || typeof userCardId !== 'string') {
    return res.status(400).json({ error: 'userCardId is required' });
  }
  if (!Number.isFinite(amount) || amount <= 0) {
    return res.status(400).json({ error: 'amountInr must be a positive number' });
  }
  const occurred = occurredAt ? new Date(occurredAt) : new Date();
  if (Number.isNaN(occurred.getTime())) {
    return res.status(400).json({ error: 'occurredAt is not a valid date' });
  }

  try {
    const result = await withUserClient(req.userId, (client) =>
      insertTransactionAndUpdateState(client, req.userId, {
        userCardId, amount, occurred, categoryId, rail, merchantName, note, source: 'manual',
      })
    );

    if (result.status !== 201) return res.status(result.status).json({ error: result.error });
    res.status(201).json(result);
  } catch (err) {
    console.error('POST /transactions error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /transactions/from-sms — UA-5.3 auto-import. Takes a raw SMS
 * sender+body, finds active `parser_patterns` for channel='sms' whose
 * sender_pattern matches, parses via sms_parser.js, and on success calls
 * the SAME insertTransactionAndUpdateState() helper POST /transactions
 * uses (source='sms' instead of 'manual') — no duplicated cap/milestone/
 * points/fee-waiver logic. On parse failure, per parser_failures' evident
 * intent (its `redacted_shape_has_no_digits` CHECK — the table is designed
 * to hold NO raw SMS content, only a redacted shape for admin triage), we
 * insert a parser_failures row built from sms_parser.redactSmsShape()
 * rather than storing the raw body, and return 200 with parsed:false
 * rather than an error — a failed auto-parse is an expected, logged
 * outcome for this route, not a server error.
 */
app.post('/transactions/from-sms', requireAuth, async (req, res) => {
  const { sender, body, userCardId, occurredAt, categoryId, rail } = req.body || {};
  if (!body || typeof body !== 'string' || !body.trim()) {
    return res.status(400).json({ error: 'body is required' });
  }
  if (!userCardId || typeof userCardId !== 'string') {
    // The parser extracts amount/merchant/last4/date, not which of the
    // user's cards the SMS belongs to (last4 alone is not a safe/unique
    // match key across issuers) — same "caller supplies userCardId"
    // contract as POST /transactions, not a guess this route makes itself.
    return res.status(400).json({ error: 'userCardId is required' });
  }
  const occurred = occurredAt ? new Date(occurredAt) : new Date();
  if (Number.isNaN(occurred.getTime())) {
    return res.status(400).json({ error: 'occurredAt is not a valid date' });
  }

  try {
    const result = await withUserClient(req.userId, async (client) => {
      const patterns = await client.query(
        `SELECT id, issuer_id, sender_pattern, regex, field_map
           FROM parser_patterns
          WHERE channel = 'sms' AND is_active = true
          ORDER BY version DESC`
      );

      const parsed = parseSmsAgainstPatterns(patterns.rows, { sender, body });

      if (!parsed.ok) {
        const failure = await client.query(
          `INSERT INTO parser_failures (channel, sender_pattern, redacted_shape, occurrences)
           VALUES ('sms', $1, $2, 1)
           RETURNING id, redacted_shape, occurrences`,
          [sender || null, redactSmsShape(body)]
        );
        return { status: 200, parsed: false, reason: parsed.reason, parserFailure: failure.rows[0] };
      }

      // Bump the winning pattern's telemetry in the same transaction as the
      // insert it enabled — success_count/failure_count are evidently meant
      // to track a pattern's live hit rate, not just exist unused.
      await client.query(
        `UPDATE parser_patterns SET success_count = success_count + 1, updated_at = now() WHERE id = $1`,
        [parsed.patternId]
      );

      const inserted = await insertTransactionAndUpdateState(client, req.userId, {
        userCardId,
        amount: parsed.fields.amountInr,
        occurred,
        categoryId: categoryId || null,
        rail: rail || 'unknown',
        merchantName: parsed.fields.merchant || null,
        source: 'sms',
      });

      if (inserted.status !== 201) return inserted;
      return { status: 201, parsed: true, patternId: parsed.patternId, ...inserted };
    });

    if (result.status !== 201 && result.status !== 200) {
      return res.status(result.status).json({ error: result.error });
    }
    res.status(result.status).json(result);
  } catch (err) {
    console.error('POST /transactions/from-sms error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /transactions?from=&to=&cardId=&limit= — E10/E11/D1's shared gap
 * (implementation-plan-group-e-f-g.md: "third consumer of the same missing
 * query param — build it once"). All three are optional; omitting them
 * keeps the original "last 50, no filter" behaviour so existing callers
 * (the Activity tab) are unaffected. `from`/`to` are inclusive date
 * boundaries (YYYY-MM-DD), matched against occurred_at's date component so
 * a caller doesn't need to think about timezone-of-day edge cases.
 */
app.get('/transactions', requireAuth, async (req, res) => {
  const { from, to, cardId, categoryId, source } = req.query;
  const conditions = [`t.profile_id = $1`, `t.status = 'active'`];
  const params = [req.userId];
  if (from) {
    params.push(from);
    conditions.push(`t.occurred_at >= $${params.length}::date`);
  }
  if (to) {
    params.push(to);
    conditions.push(`t.occurred_at < ($${params.length}::date + interval '1 day')`);
  }
  if (cardId) {
    params.push(cardId);
    conditions.push(`t.user_card_id = $${params.length}`);
  }
  // Task D-1: category/source filters (ui-spec D1 "Search + filters (date,
  // card, category, source, needs-review)") — needs-review isn't a
  // transactions-table filter at all (it's the separate parser_failures
  // queue, D4's territory), so it isn't one of this route's params.
  if (categoryId) {
    params.push(categoryId);
    conditions.push(`t.category_id = $${params.length}`);
  }
  if (source) {
    params.push(source);
    conditions.push(`t.source = $${params.length}`);
  }
  // No hard cap when a date range is given (a month's worth of spend is the
  // whole point of E11); the original unfiltered "last 50" behaviour is
  // preserved for existing callers that pass neither.
  const limitClause = from || to || cardId || categoryId || source ? '' : 'LIMIT 50';

  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT t.id, t.user_card_id, t.amount_inr, t.occurred_at, t.merchant_name,
                t.category_id, sc.name AS category_name, t.rail, t.status, t.source, t.note,
                cp.name AS card_name, uc.nickname AS card_nickname
           FROM transactions t
           LEFT JOIN user_cards uc ON uc.id = t.user_card_id
           LEFT JOIN card_products cp ON cp.id = uc.card_product_id
           LEFT JOIN spend_categories sc ON sc.id = t.category_id
          WHERE ${conditions.join(' AND ')}
          ORDER BY t.occurred_at DESC ${limitClause}`,
        params
      )
    );
    res.json({ transactions: result.rows });
  } catch (err) {
    console.error('GET /transactions error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /transactions/:id — Task D-2/D-3 (Transaction Detail / Edit).
 * Deliberately does NOT filter `status = 'active'` like the list route
 * above — D2 has to be able to show an ignored transaction's detail (e.g.
 * reached from a "why did my caps change" investigation), not just active
 * ones. Ownership still enforced via profile_id, same as everywhere else.
 */
app.get('/transactions/:id', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT t.id, t.user_card_id, t.amount_inr, t.occurred_at, t.merchant_name,
                t.category_id, sc.name AS category_name, t.rail, t.status, t.source, t.note,
                cp.name AS card_name, uc.nickname AS card_nickname
           FROM transactions t
           LEFT JOIN user_cards uc ON uc.id = t.user_card_id
           LEFT JOIN card_products cp ON cp.id = uc.card_product_id
           LEFT JOIN spend_categories sc ON sc.id = t.category_id
          WHERE t.id = $1 AND t.profile_id = $2`,
        [req.params.id, req.userId]
      )
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'transaction not found' });
    res.json({ transaction: result.rows[0] });
  } catch (err) {
    console.error('GET /transactions/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

const TXN_SUMMARY_COLUMNS = `
  t.id, t.amount_inr, t.occurred_at, t.merchant_name, t.source, t.status,
  cp.name AS card_name, uc.nickname AS card_nickname
`;

/**
 * GET /duplicate-candidates — Task D-5 (ui-spec D5 Duplicate Review).
 * Pending pairs only, each side-by-side with both transactions' summaries
 * so the screen never has to make two more round trips per row.
 */
app.get('/duplicate-candidates', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const pairs = await client.query(
        `SELECT id, txn_a_id, txn_b_id, match_score, match_reason, detected_at
           FROM duplicate_candidates
          WHERE profile_id = $1 AND state = 'pending'
          ORDER BY detected_at DESC`,
        [req.userId]
      );
      for (const pair of pairs.rows) {
        const [a, b] = await Promise.all([
          client.query(
            `SELECT ${TXN_SUMMARY_COLUMNS} FROM transactions t
               LEFT JOIN user_cards uc ON uc.id = t.user_card_id
               LEFT JOIN card_products cp ON cp.id = uc.card_product_id
              WHERE t.id = $1`,
            [pair.txn_a_id]
          ),
          client.query(
            `SELECT ${TXN_SUMMARY_COLUMNS} FROM transactions t
               LEFT JOIN user_cards uc ON uc.id = t.user_card_id
               LEFT JOIN card_products cp ON cp.id = uc.card_product_id
              WHERE t.id = $1`,
            [pair.txn_b_id]
          ),
        ]);
        pair.txn_a = a.rows[0] || null;
        pair.txn_b = b.rows[0] || null;
      }
      return pairs.rows;
    });
    res.json({ duplicateCandidates: result });
  } catch (err) {
    console.error('GET /duplicate-candidates error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

const DUPLICATE_RESOLUTIONS = ['merged', 'kept_both', 'deleted_one'];

/**
 * POST /duplicate-candidates/:id/resolve — Task D-5. `resolution`:
 *   - 'kept_both': both transactions are legitimate after all — mark
 *     resolved, no transaction changes.
 *   - 'merged' / 'deleted_one': functionally identical server-side (no
 *     field-level merge UI exists in this pass — "merge" and "delete the
 *     other one" both reduce to the same action: keep [keepTransactionId],
 *     ignore the other, reversing the ignored one's cap/milestone/points
 *     contribution via the exact same [reverseTransactionState] Task C-0c
 *     already built and verified — never a second, divergent implementation
 *     of "undo a transaction's effect."
 */
app.post('/duplicate-candidates/:id/resolve', requireAuth, async (req, res) => {
  const { resolution, keepTransactionId } = req.body || {};
  if (!DUPLICATE_RESOLUTIONS.includes(resolution)) {
    return res.status(400).json({ error: `resolution must be one of: ${DUPLICATE_RESOLUTIONS.join(', ')}` });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const pair = await client.query(
        `SELECT id, txn_a_id, txn_b_id, state FROM duplicate_candidates WHERE id = $1 AND profile_id = $2`,
        [req.params.id, req.userId]
      );
      if (pair.rows.length === 0) return null;
      const { txn_a_id: txnA, txn_b_id: txnB, state } = pair.rows[0];
      if (state !== 'pending') return { status: 409, error: `already resolved ('${state}')` };

      if (resolution !== 'kept_both') {
        if (keepTransactionId !== txnA && keepTransactionId !== txnB) {
          return { status: 400, error: 'keepTransactionId must be one of the pair' };
        }
        const dropId = keepTransactionId === txnA ? txnB : txnA;
        const dropTxn = await client.query(
          `SELECT id, user_card_id, amount_inr, occurred_at, category_id, status, note
             FROM transactions WHERE id = $1 AND profile_id = $2 FOR UPDATE`,
          [dropId, req.userId]
        );
        if (dropTxn.rows.length > 0 && dropTxn.rows[0].status === 'active') {
          const txn = dropTxn.rows[0];
          const card = await loadUserCardForState(client, req.userId, txn.user_card_id);
          if (card) await reverseTransactionState(client, req.userId, card, txn);
          const noteTag = `[${resolution}: duplicate of ${keepTransactionId}]`;
          await client.query(
            `UPDATE transactions SET status = 'ignored', note = $1 WHERE id = $2`,
            [txn.note ? `${noteTag} ${txn.note}` : noteTag, dropId]
          );
        }
      }

      const updated = await client.query(
        `UPDATE duplicate_candidates SET state = 'resolved', resolution = $1, resolved_at = now()
          WHERE id = $2 RETURNING id, state, resolution, resolved_at`,
        [resolution, req.params.id]
      );
      return { status: 200, duplicateCandidate: updated.rows[0] };
    });

    if (!result) return res.status(404).json({ error: 'duplicate_candidate not found' });
    if (result.status !== 200) return res.status(result.status).json({ error: result.error });
    res.json(result);
  } catch (err) {
    console.error('POST /duplicate-candidates/:id/resolve error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * PATCH /transactions/:id — Task C-0c (ui-spec D3 Edit Transaction).
 * "Recomputes caps/milestones on save" is the whole point of this route:
 * reverse whatever the transaction's OLD values contributed (via
 * [reverseTransactionState], using its stored fields, not the request
 * body), write the new field values, then re-apply state for the new
 * values (via [applyTransactionState]) — all inside one
 * `withUserClient` transaction, so a half-applied edit can't happen.
 * Only 'active' transactions can be edited; an ignored/reversed/deleted
 * transaction must go through nothing here (editing something already
 * excluded from state would be meaningless — there's nothing to reverse
 * cleanly since its contribution was already reversed when it was
 * ignored).
 */
app.patch('/transactions/:id', requireAuth, async (req, res) => {
  const { amountInr, occurredAt, categoryId, rail, merchantName, userCardId } = req.body || {};
  if (amountInr !== undefined && (!Number.isFinite(Number(amountInr)) || Number(amountInr) <= 0)) {
    return res.status(400).json({ error: 'amountInr must be a positive number' });
  }
  if (occurredAt !== undefined && Number.isNaN(new Date(occurredAt).getTime())) {
    return res.status(400).json({ error: 'occurredAt is not a valid date' });
  }

  try {
    const result = await withUserClient(req.userId, async (client) => {
      // FOR UPDATE: this row is about to be reversed-then-reapplied: two
      // concurrent edits interleaving their reverse/apply halves would
      // corrupt the bucketed cap/milestone totals in a way that's very
      // hard to detect after the fact. Locked for the lifetime of this
      // transaction, released on COMMIT/ROLLBACK by withUserClient.
      const existing = await client.query(
        `SELECT id, user_card_id, amount_inr, occurred_at, category_id, rail, merchant_name, status
           FROM transactions WHERE id = $1 AND profile_id = $2 FOR UPDATE`,
        [req.params.id, req.userId]
      );
      if (existing.rows.length === 0) return { status: 404, error: 'transaction not found' };
      const old = existing.rows[0];
      if (old.status !== 'active') {
        return { status: 409, error: `cannot edit a transaction with status '${old.status}'` };
      }

      const oldCard = await loadUserCardForState(client, req.userId, old.user_card_id);
      if (!oldCard) return { status: 404, error: 'user_card for this transaction not found or archived' };
      await reverseTransactionState(client, req.userId, oldCard, old);

      const newValues = {
        userCardId: userCardId ?? old.user_card_id,
        amount: amountInr !== undefined ? Number(amountInr) : Number(old.amount_inr),
        occurred: occurredAt !== undefined ? new Date(occurredAt) : old.occurred_at,
        categoryId: categoryId !== undefined ? categoryId : old.category_id,
        rail: rail ?? old.rail,
        merchantName: merchantName !== undefined ? merchantName : old.merchant_name,
      };

      const newCard = await loadUserCardForState(client, req.userId, newValues.userCardId);
      if (!newCard) return { status: 404, error: 'target user_card not found or archived' };

      const updated = await client.query(
        `UPDATE transactions
            SET user_card_id = $1, amount_inr = $2, occurred_at = $3, category_id = $4, rail = $5, merchant_name = $6
          WHERE id = $7
          RETURNING id, user_card_id, amount_inr, occurred_at, category_id, rail, merchant_name, status`,
        [
          newValues.userCardId, newValues.amount, newValues.occurred, newValues.categoryId,
          newValues.rail, newValues.merchantName, old.id,
        ]
      );

      const stateUpdates = await applyTransactionState(client, req.userId, newCard, {
        txnId: old.id, userCardId: newValues.userCardId, amount: newValues.amount,
        occurred: newValues.occurred, categoryId: newValues.categoryId, sign: 1,
      });

      return { status: 200, transaction: updated.rows[0], ...stateUpdates };
    });

    if (result.status !== 200) return res.status(result.status).json({ error: result.error });
    res.json(result);
  } catch (err) {
    console.error('PATCH /transactions/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

const IGNORE_REASONS = ['refund', 'reversal', 'transfer'];

/**
 * POST /transactions/:id/ignore — Task C-0c (ui-spec D2 "mark ignored
 * (refund/reversal/transfer)"). Reverses this transaction's cap/milestone/
 * points/fee-waiver contribution (via [reverseTransactionState]) and sets
 * status='ignored' — the row itself is kept (R4-style "never hard-delete",
 * same precedent as user_cards/card_requests), just excluded from
 * GET /transactions (`WHERE status = 'active'`) and from all state going
 * forward. No dedicated ignore-reason column exists on `transactions`
 * (checked database.sql — only a free-text `note`) so the reason is
 * recorded there as `[ignored: <reason>] <existing note>` rather than
 * silently dropped; a structured column is a real follow-up if reporting
 * on ignore reasons ever needs to query them, not invented here as an
 * unrequested migration.
 */
app.post('/transactions/:id/ignore', requireAuth, async (req, res) => {
  const { reason } = req.body || {};
  if (!reason || !IGNORE_REASONS.includes(reason)) {
    return res.status(400).json({ error: `reason must be one of: ${IGNORE_REASONS.join(', ')}` });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const existing = await client.query(
        `SELECT id, user_card_id, amount_inr, occurred_at, category_id, rail, merchant_name, status, note
           FROM transactions WHERE id = $1 AND profile_id = $2 FOR UPDATE`,
        [req.params.id, req.userId]
      );
      if (existing.rows.length === 0) return { status: 404, error: 'transaction not found' };
      const txn = existing.rows[0];
      if (txn.status !== 'active') {
        return { status: 409, error: `transaction is already '${txn.status}'` };
      }

      const card = await loadUserCardForState(client, req.userId, txn.user_card_id);
      if (!card) return { status: 404, error: 'user_card for this transaction not found or archived' };
      await reverseTransactionState(client, req.userId, card, txn);

      const noteTag = `[ignored: ${reason}]`;
      const newNote = txn.note ? `${noteTag} ${txn.note}` : noteTag;
      const updated = await client.query(
        `UPDATE transactions SET status = 'ignored', note = $1 WHERE id = $2 RETURNING id, status, note`,
        [newNote, txn.id]
      );
      return { status: 200, transaction: updated.rows[0] };
    });

    if (result.status !== 200) return res.status(result.status).json({ error: result.error });
    res.json(result);
  } catch (err) {
    console.error('POST /transactions/:id/ignore error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET/POST /lounge-usage — Task E6. lounge_usage exists (0004) with zero
 * routes until now. GET is owner-scoped (RLS + explicit profile_id filter,
 * belt-and-braces same as every other route here); POST is the "log a
 * visit" manual-entry path the spec calls for — logged_manually defaults
 * true because this route has no other way to receive a visit (no bank
 * feed integration exists).
 */
app.get('/lounge-usage', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT id, user_card_id, benefit_id, used_on, airport, logged_manually, created_at
           FROM lounge_usage
          WHERE profile_id = $1
          ORDER BY used_on DESC`,
        [req.userId]
      )
    );
    res.json({ loungeUsage: result.rows });
  } catch (err) {
    console.error('GET /lounge-usage error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/lounge-usage', requireAuth, async (req, res) => {
  const { userCardId, benefitId, usedOn, airport } = req.body || {};
  if (!userCardId || typeof userCardId !== 'string') {
    return res.status(400).json({ error: 'userCardId is required' });
  }
  if (!benefitId || typeof benefitId !== 'string') {
    return res.status(400).json({ error: 'benefitId is required' });
  }
  const usedOnDate = usedOn ? new Date(usedOn) : new Date();
  if (Number.isNaN(usedOnDate.getTime())) {
    return res.status(400).json({ error: 'usedOn is not a valid date' });
  }
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `INSERT INTO lounge_usage (profile_id, user_card_id, benefit_id, used_on, airport, logged_manually)
         VALUES ($1, $2, $3, $4, $5, true)
         RETURNING id, user_card_id, benefit_id, used_on, airport, logged_manually, created_at`,
        [req.userId, userCardId, benefitId, usedOnDate.toISOString().slice(0, 10), airport || null]
      )
    );
    res.status(201).json({ loungeUsage: result.rows[0] });
  } catch (err) {
    console.error('POST /lounge-usage error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /monthly-reports?month=YYYY-MM-01 — Task E9. monthly_reports (0004)
 * is "materialized monthly so the report opens instantly" per its own
 * comment, but nothing populates it. Per the plan's recommendation, this
 * route computes the CURRENT month on demand (cheap, always fresh) and
 * upserts the row so it becomes the materialized record once the month is
 * over; past months just read whatever's already stored. No cron exists in
 * this pass (flagged in the final report) — a past month with no stored
 * row simply reads as "not available" rather than being silently
 * recomputed from possibly-since-changed data.
 *
 * The baseline_single_card_inr / value_missed_inr fields need a genuine
 * "what would a single best-overall card have earned instead" historical
 * recompute the engine doesn't have yet (flagged in the plan as shared
 * with D6 Missed Opportunities) — left at 0 here with breakdown noting
 * this explicitly rather than fabricating a number, honouring the
 * "never display a number the app can't justify" rule.
 */
app.get('/monthly-reports', requireAuth, async (req, res) => {
  const monthParam = req.query.month; // 'YYYY-MM-01'
  const month = monthParam ? new Date(monthParam) : new Date();
  if (Number.isNaN(month.getTime())) {
    return res.status(400).json({ error: 'month is not a valid date' });
  }
  const periodMonth = `${month.getUTCFullYear()}-${String(month.getUTCMonth() + 1).padStart(2, '0')}-01`;
  const now = new Date();
  const isCurrentMonth = month.getUTCFullYear() === now.getUTCFullYear() && month.getUTCMonth() === now.getUTCMonth();

  try {
    const result = await withUserClient(req.userId, async (client) => {
      if (!isCurrentMonth) {
        const stored = await client.query(
          `SELECT * FROM monthly_reports WHERE profile_id = $1 AND period_month = $2`,
          [req.userId, periodMonth]
        );
        return stored.rows[0] || null;
      }

      // On-demand recompute for the current, still-in-progress month.
      const spend = await client.query(
        `SELECT COALESCE(SUM(amount_inr), 0) AS total_spend
           FROM transactions
          WHERE profile_id = $1 AND status = 'active' AND occurred_at >= $2::date
            AND occurred_at < ($2::date + interval '1 month')`,
        [req.userId, periodMonth]
      );
      const rewards = await client.query(
        `SELECT COALESCE(SUM(expected_value_inr), 0) AS rewards_earned
           FROM transactions
          WHERE profile_id = $1 AND status = 'active' AND occurred_at >= $2::date
            AND occurred_at < ($2::date + interval '1 month')`,
        [req.userId, periodMonth]
      );
      const totalSpend = Number(spend.rows[0].total_spend);
      const rewardsEarned = Number(rewards.rows[0].rewards_earned);

      const upserted = await client.query(
        `INSERT INTO monthly_reports (profile_id, period_month, total_spend_inr, rewards_earned_inr, breakdown)
         VALUES ($1, $2, $3, $4, $5::jsonb)
         ON CONFLICT (profile_id, period_month) DO UPDATE
           SET total_spend_inr = EXCLUDED.total_spend_inr,
               rewards_earned_inr = EXCLUDED.rewards_earned_inr,
               breakdown = EXCLUDED.breakdown,
               generated_at = now()
         RETURNING *`,
        [
          req.userId,
          periodMonth,
          totalSpend,
          rewardsEarned,
          JSON.stringify({ note: 'baseline/value-missed not computed this pass — needs the shared historical-recompute calculator (see D6/E9 in the plan)' }),
        ]
      );
      return upserted.rows[0];
    });
    res.json({ monthlyReport: result });
  } catch (err) {
    console.error('GET /monthly-reports error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /my-contributions — Task E12, scoped down from the plan's original
 * ask. merchant_contributions (0007_crowdsource.sql) is deliberately R2
 * privacy-designed with NO profile_id column anywhere in that migration
 * ("R2 IS ABSOLUTE HERE... Devices are identified by a salted, ROTATING
 * hash used only for rate limiting") — there is no way to scope this query
 * to "rows this signed-in profile submitted" without adding a profile_id
 * column to a table whose own migration comment states that's deliberate,
 * which is a schema-design decision out of scope for this pass, not a
 * one-line query fix. Returning fabricated or device-hash-approximated
 * per-user numbers would violate the app's own "never display a number it
 * can't justify" rule, so this route instead returns network-wide
 * aggregate stats only (safe under R2 — no per-user data at all) and the
 * client is expected to combine this with a LOCAL on-device counter for
 * "contributions submitted from this device" (see E12 screen/report notes).
 */
app.get('/my-contributions', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT COUNT(*) FILTER (WHERE is_published) AS published_merchant_count,
                COUNT(DISTINCT device_hash) AS contributing_device_count
           FROM merchants m
           LEFT JOIN merchant_contributions mc ON mc.merchant_id = m.id`
      )
    );
    res.json({ networkStats: result.rows[0] });
  } catch (err) {
    console.error('GET /my-contributions error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /profile/contributions-opt-in — E12's opt-out toggle, mirrors H4
 * per the plan (H4 out of scope, this becomes its first consumer per the
 * plan's recommendation). profiles.contributions_opt_in already exists
 * (0004_user_domain.sql, default false) — this is the first write path for
 * it.
 */
app.post('/profile/contributions-opt-in', requireAuth, async (req, res) => {
  const { optIn } = req.body || {};
  if (typeof optIn !== 'boolean') {
    return res.status(400).json({ error: 'optIn must be a boolean' });
  }
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `UPDATE profiles SET contributions_opt_in = $2 WHERE id = $1 RETURNING contributions_opt_in`,
        [req.userId, optIn]
      )
    );
    res.json({ profile: result.rows[0] || null });
  } catch (err) {
    console.error('POST /profile/contributions-opt-in error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

const CONSENT_PURPOSES = ['terms', 'crowdsource', 'marketing'];

/**
 * GET /consents — Task H-0 (Group H plan). Latest row per purpose for the
 * signed-in profile — user_consents (0004_user_domain.sql) is an
 * append-only audit log (a new row per change, never an in-place update),
 * so "current state" means the most recent row per purpose, not the whole
 * table. See GET /consents/history below for the full log (H4).
 */
app.get('/consents', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT DISTINCT ON (purpose) purpose, granted, granted_at, revoked_at, policy_version, source_screen
           FROM user_consents WHERE profile_id = $1
           ORDER BY purpose, granted_at DESC`,
        [req.userId]
      )
    );
    res.json({ consents: result.rows });
  } catch (err) {
    console.error('GET /consents error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /consents/history — H4's "consent history with timestamps" (DPDP).
 * Every row ever written, most recent first — unlike GET /consents above,
 * this deliberately does NOT collapse to latest-per-purpose.
 */
app.get('/consents/history', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT purpose, granted, granted_at, revoked_at, policy_version, source_screen
           FROM user_consents WHERE profile_id = $1
           ORDER BY granted_at DESC`,
        [req.userId]
      )
    );
    res.json({ consents: result.rows });
  } catch (err) {
    console.error('GET /consents/history error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /consents — DPDP §8.2: purpose-specific, unbundled, timestamped,
 * versioned. Always inserts a NEW row (never UPDATEs an existing one) —
 * user_consents is an audit log, not a mutable settings row; a later
 * revocation is its own new row with granted=false, not an edit to the
 * grant row.
 */
app.post('/consents', requireAuth, async (req, res) => {
  const { purpose, granted, policyVersion, sourceScreen } = req.body || {};
  if (!CONSENT_PURPOSES.includes(purpose)) {
    return res.status(400).json({ error: `purpose must be one of ${CONSENT_PURPOSES.join(', ')}` });
  }
  if (typeof granted !== 'boolean') {
    return res.status(400).json({ error: 'granted must be a boolean' });
  }
  if (!policyVersion || typeof policyVersion !== 'string') {
    return res.status(400).json({ error: 'policyVersion is required' });
  }
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `INSERT INTO user_consents (profile_id, purpose, policy_version, granted, source_screen)
         VALUES ($1, $2, $3, $4, $5)
         RETURNING purpose, granted, granted_at, policy_version, source_screen`,
        [req.userId, purpose, policyVersion, granted, sourceScreen || null]
      )
    );
    res.status(201).json({ consent: result.rows[0] });
  } catch (err) {
    console.error('POST /consents error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

// PATCH /user-cards/:id was independently started here as "Task H-0b" to
// unblock A9/H — since consolidated into the single Task C-4 implementation
// further up this file (search USER_CARD_PATCH_FIELDS), which covers the
// same nickname/creditLimit/statementDay/dueDay fields plus pointsBalance
// (C4's own field list) with the same validation bounds. Two routes
// registered for the same method+path is silent, confusing dead code in
// Express (the first match always wins) rather than a real conflict, but
// leaving both was worse than resolving it — removed here, not duplicated.

const NOTIFICATION_PREF_DEFAULTS = {
  category_location: false,
  category_caps: true,
  category_milestones: true,
  category_fee_waivers: true,
  category_bills: true,
  category_expiry: true,
  category_monthly_report: false,
  category_needs_review: true,
  quiet_hours_start: null,
  quiet_hours_end: null,
  daily_cap: 3,
};
const NOTIFICATION_PREF_COLUMNS = Object.keys(NOTIFICATION_PREF_DEFAULTS);

/**
 * GET /notification-preferences — Task H-0d. A user who has never opened
 * H3 has no row in notification_preferences yet; this returns the
 * migration's own column defaults (conservative, per spec) rather than a
 * loading error, so H3 always has something sane to render pre-toggled.
 */
app.get('/notification-preferences', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(`SELECT * FROM notification_preferences WHERE profile_id = $1`, [req.userId])
    );
    const row = result.rows[0];
    res.json({ preferences: row ? row : { profile_id: req.userId, ...NOTIFICATION_PREF_DEFAULTS } });
  } catch (err) {
    console.error('GET /notification-preferences error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * PUT /notification-preferences — upsert, accepting any subset of the
 * boolean/time/int columns. Immediate-write, no separate Save button, same
 * pattern as POST /profile/contributions-opt-in above.
 */
app.put('/notification-preferences', requireAuth, async (req, res) => {
  const updates = {};
  for (const col of NOTIFICATION_PREF_COLUMNS) {
    if (req.body && Object.prototype.hasOwnProperty.call(req.body, col)) {
      updates[col] = req.body[col];
    }
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      // Two steps, not a single upsert: a fresh INSERT must let the
      // table's own column defaults apply for anything not in `updates`
      // (they're NOT NULL columns — passing an explicit null on first
      // insert violates that, which a single INSERT ... VALUES ($null...)
      // ON CONFLICT statement can't avoid). Ensure the row exists with
      // its defaults first, then COALESCE-update only the provided keys.
      await client.query(
        `INSERT INTO notification_preferences (profile_id) VALUES ($1) ON CONFLICT DO NOTHING`,
        [req.userId]
      );
      const setClauses = NOTIFICATION_PREF_COLUMNS.map((c) => `${c} = COALESCE($${NOTIFICATION_PREF_COLUMNS.indexOf(c) + 2}, ${c})`);
      return client.query(
        `UPDATE notification_preferences SET ${setClauses.join(', ')}, updated_at = now()
          WHERE profile_id = $1
          RETURNING *`,
        [req.userId, ...NOTIFICATION_PREF_COLUMNS.map((c) => (c in updates ? updates[c] : null))]
      );
    });
    res.json({ preferences: result.rows[0] });
  } catch (err) {
    console.error('PUT /notification-preferences error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

app.get('/notification-preferences/muted-merchants', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT nmm.merchant_id, nmm.muted_at, m.display_name AS merchant_name
           FROM notification_muted_merchants nmm
           JOIN merchants m ON m.id = nmm.merchant_id
          WHERE nmm.profile_id = $1
          ORDER BY nmm.muted_at DESC`,
        [req.userId]
      )
    );
    res.json({ mutedMerchants: result.rows });
  } catch (err) {
    console.error('GET /notification-preferences/muted-merchants error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/notification-preferences/muted-merchants', requireAuth, async (req, res) => {
  const { merchantId } = req.body || {};
  if (!merchantId) return res.status(400).json({ error: 'merchantId is required' });
  try {
    await withUserClient(req.userId, (client) =>
      client.query(
        `INSERT INTO notification_muted_merchants (profile_id, merchant_id)
         VALUES ($1, $2) ON CONFLICT (profile_id, merchant_id) DO NOTHING`,
        [req.userId, merchantId]
      )
    );
    res.status(201).json({ ok: true });
  } catch (err) {
    console.error('POST /notification-preferences/muted-merchants error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

app.delete('/notification-preferences/muted-merchants/:merchantId', requireAuth, async (req, res) => {
  try {
    await withUserClient(req.userId, (client) =>
      client.query(
        `DELETE FROM notification_muted_merchants WHERE profile_id = $1 AND merchant_id = $2`,
        [req.userId, req.params.merchantId]
      )
    );
    res.json({ ok: true });
  } catch (err) {
    console.error('DELETE /notification-preferences/muted-merchants/:merchantId error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /account/delete-request — Task H-0e / H2. DPDP §8.2 right to
 * erasure, with a grace period per the spec's own "double-confirmed,
 * grace period" requirement — this does NOT call
 * pandapay.execute_account_deletion() directly. It only schedules the
 * deletion (profiles.deletion_requested_at/deletion_due_at, both columns
 * already existed unused — 0004_user_domain.sql). Actually executing the
 * deletion once deletion_due_at passes needs a scheduled sweep job, which
 * is explicitly out of this plan's scope — see H2's screen doc-comment.
 */
app.post('/account/delete-request', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `UPDATE profiles SET deletion_requested_at = now(), deletion_due_at = now() + interval '30 days'
          WHERE id = $1
          RETURNING deletion_requested_at, deletion_due_at`,
        [req.userId]
      )
    );
    res.json({ profile: result.rows[0] || null });
  } catch (err) {
    console.error('POST /account/delete-request error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/** DELETE /account/delete-request — cancels a pending deletion. */
app.delete('/account/delete-request', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `UPDATE profiles SET deletion_requested_at = null, deletion_due_at = null
          WHERE id = $1
          RETURNING deletion_requested_at, deletion_due_at`,
        [req.userId]
      )
    );
    res.json({ profile: result.rows[0] || null });
  } catch (err) {
    console.error('DELETE /account/delete-request error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

const SUPPORT_TICKET_KINDS = ['bug', 'wrong_card_data', 'card_request', 'general'];

/**
 * POST /support-tickets — Task H-0e / H9. support_tickets
 * (0009_platform_ops.sql) already enforces the same kind check via a DB
 * CHECK constraint; validating here first turns a bad value into a clean
 * 400 instead of a raw constraint-violation 500.
 */
app.post('/support-tickets', requireAuth, async (req, res) => {
  const { kind, message, diagnostics, appVersion } = req.body || {};
  if (!SUPPORT_TICKET_KINDS.includes(kind)) {
    return res.status(400).json({ error: `kind must be one of ${SUPPORT_TICKET_KINDS.join(', ')}` });
  }
  if (!message || typeof message !== 'string' || !message.trim()) {
    return res.status(400).json({ error: 'message is required' });
  }
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `INSERT INTO support_tickets (profile_id, kind, message, diagnostics, app_version)
         VALUES ($1, $2, $3, $4, $5)
         RETURNING id, kind, state, created_at`,
        [req.userId, kind, message.trim(), diagnostics ? JSON.stringify(diagnostics) : null, appVersion || null]
      )
    );
    res.status(201).json({ ticket: result.rows[0] });
  } catch (err) {
    console.error('POST /support-tickets error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /changelog — Task H-0e / H10. No auth required — release notes
 * aren't PII, and H10 must be reachable from a fresh install before any
 * sign-in happens.
 */
app.get('/changelog', async (req, res) => {
  try {
    const result = await withUserClient(null, (client) =>
      client.query(
        `SELECT id, app_version, title, body_markdown, highlights_data_change, published_at
           FROM changelog_entries ORDER BY published_at DESC LIMIT 20`
      )
    );
    res.json({ entries: result.rows });
  } catch (err) {
    console.error('GET /changelog error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-6 Crowdsourced Data Visibility.
 *
 * Scope note vs the full ui-spec: AD-6.1.1's `flutter_map`/OSM pin-cluster
 * map is NOT built here — this is a filtered table over the same data
 * (`merchants` + `merchant_locations`), same filters (AD-6.1.4: category,
 * confidence, published), same grid-snapped-only coordinates (AD-6.1.5 —
 * `grid_lat`/`grid_lng` are the only columns that exist, so there is
 * nothing more precise to leak even from a table view). A real interactive
 * map is a genuinely separate, larger UI investment (new Flutter Web
 * dependency, tile layer, clustering) not attempted in this pass — noted
 * in PROGRESS.md, not silently substituted.
 */
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
    console.error('GET /admin/merchants error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-6.2.1 merchant record detail: contribution history, locations, and
 * confidence breakdown. "Confidence breakdown" here is the raw inputs the
 * confidence score is presumably computed from (confirmation_count,
 * distinct_device_count, operator_locked) — the actual scoring function
 * lives in a not-yet-written batch job (nothing in this codebase computes
 * confidence_score today; it's written directly by contributions/manual
 * override only), so this endpoint surfaces the inputs, not a re-derivation.
 */
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
    console.error('GET /admin/merchants/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-6.2.2 manual override/merge — sets whichever fields are provided plus
 * `operator_locked = true`, so a later automated recomputation (AD-6.3.3,
 * conflict auto-resolution) cannot silently undo an operator's decision.
 * Typed writer, same pattern as PUT /admin/reward-rules/:id — no raw JSON
 * passthrough, only the specific fields this action is allowed to touch.
 */
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
    console.error('POST /admin/merchants/:id/override error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/** AD-6.2.3 unpublish — for a record found to be wrong or poisoned. */
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
    console.error('POST /admin/merchants/:id/unpublish error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-6.3.1/6.3.2 conflict resolution queue — only the cases the automatic
 * majority-wins-weighted-toward-recency rule (mentioned in the plan, not
 * implemented anywhere in this codebase as an automated job — that rule
 * lives entirely in this screen's human operator today) doesn't confidently
 * resolve, i.e. every row with state = 'pending'.
 */
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
    console.error('GET /admin/merchant-conflicts error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-6.3.3: resolution writes the value, locks the record, and audits.
 * "Recomputes confidence" per the plan text is skipped for the same reason
 * noted on GET /admin/merchants/:id — no confidence-scoring job exists yet
 * to call; bumping to 'operator_verified' (the enum's own explicit
 * human-decided tier, distinct from the automated unverified/low/medium/
 * high ladder) is the honest representation of "an operator just decided
 * this," not a stand-in for a real recomputation.
 */
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
        `UPDATE merchants SET ${field} = $1, operator_locked = true, confidence = 'operator_verified', updated_at = now() WHERE id = $2`,
        [resolvedValue, merchantId]
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
    console.error('POST /admin/merchant-conflicts/:id/resolve error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/** AD-6.4.1 abuse & quality controls: unresolved (not yet blocked) signals. */
app.get('/admin/abuse-signals', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT * FROM abuse_signals WHERE is_blocked = false ORDER BY severity DESC, detected_at DESC LIMIT 200`
      )
    );
    res.json({ abuseSignals: result.rows });
  } catch (err) {
    console.error('GET /admin/abuse-signals error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-6.4.2: block a device hash from contributing, and bulk-revert its
 * contributions by marking them `is_counted = false` so any consumer of
 * merchant_contributions (a future confidence-recomputation job) excludes
 * them going forward. Marks every abuse_signals row for the same device
 * hash as blocked too, not just the one that was clicked — a device
 * flagged for burst submissions and impossible geography on separate rows
 * should not need two separate block clicks.
 */
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
    console.error('POST /admin/abuse-signals/:id/block error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-7 Acceptance Map & Effective Rate Monitor.
 *
 * Same scope note as AD-6 (Chunk 23): AD-7.1's map filtered to
 * acceptance_summary is a filtered table here, not a real flutter_map view
 * — same reasoning (a real map is a separate UI investment), same
 * grid-snapped-coordinates-only constraint (inherited automatically since
 * this reads acceptance_summary joined to merchants, not a new location
 * source).
 */
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
    console.error('GET /admin/acceptance-summary error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-7.2 acceptance record detail: report counts (from the raw
 * acceptance_reports, not just the pre-aggregated summary) and confidence.
 */
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
    console.error('GET /admin/acceptance-summary/:merchantId error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-7.2's "publish gate mirroring the merchant gate" — same shape as
 * POST /admin/merchants/:id/unpublish, just a boolean toggle rather than
 * always-unpublish, since acceptance rows start unpublished (default
 * false) and need an explicit publish action too, not only an unpublish one.
 */
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
    console.error('POST /admin/acceptance-summary/publish error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-7.3/7.4 effective rate monitor + cap-ceiling detection, AD-7.5 linked
 * to AD-5 (here: AD-6's policy_change_alerts queue) so a divergent row is
 * never a dead end — `linked_alert_id` is a best-effort match (most recent
 * open alert for the same card_product_id, since effective_rate_summary
 * has no direct FK to policy_change_alerts and nothing in this codebase
 * automatically raises an alert from a divergence yet — see `is_divergent`/
 * `alert_raised_at` columns, which exist in schema but are never written by
 * any job here; this view surfaces the divergence, it does not yet trigger
 * one).
 */
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
    console.error('GET /admin/effective-rate-summary error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/** AD-7.3 detail: the raw samples behind one card+category+month summary row. */
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
    console.error('GET /admin/effective-rate-summary/:cardProductId/:categoryId/samples error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-8 Data Quality Dashboard — a single query over v_data_quality_dashboard
 * (already defined in db/supabase/migrations/0010_functions_and_views.sql,
 * this route just exposes it; the view was not written this chunk).
 *
 * Scope note: AD-8.3 ("trend lines, not just current values") and AD-8.4
 * ("operator alerting when any backlog crosses a threshold") are NOT
 * implemented. Trend lines need a time-series table snapshotting these
 * numbers over time — none exists, and adding one plus a scheduled
 * snapshot job is a separate, real piece of work, not a one-line addition.
 * Alerting needs a notification channel (email/Slack/etc.) this codebase
 * has never had. Both are flagged here rather than faked with a single
 * fabricated data point pretending to be a trend.
 */
app.get('/admin/data-quality-dashboard', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query('SELECT * FROM v_data_quality_dashboard')
    );
    res.json({ dashboard: result.rows[0] });
  } catch (err) {
    console.error('GET /admin/data-quality-dashboard error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-9 Anonymization Audit Automation.
 *
 * `pandapay.run_anonymization_audit()` (the 6-check function itself) already
 * existed in db/supabase/migrations/0010_functions_and_views.sql — not
 * written this chunk. What's new here: exposing its run history to the
 * console (AD-9.1), and — separately, see .github/workflows/anonymization-
 * audit.yml added alongside this route — actually calling it from CI on
 * every push/PR and failing the build on any check failure (AD-9.2).
 */
app.get('/admin/anonymization-audit-runs', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query('SELECT * FROM anonymization_audit_runs ORDER BY ran_at DESC LIMIT 50')
    );
    res.json({ auditRuns: result.rows });
  } catch (err) {
    console.error('GET /admin/anonymization-audit-runs error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-9.1 "latest result" convenience — same data as the list's first row,
 * as its own endpoint so the console's summary card doesn't need to fetch
 * and re-sort the whole history just to show the current state.
 */
app.get('/admin/anonymization-audit-runs/latest', requireAdmin, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query('SELECT * FROM anonymization_audit_runs ORDER BY ran_at DESC LIMIT 1')
    );
    res.json({ latestRun: result.rows[0] || null });
  } catch (err) {
    console.error('GET /admin/anonymization-audit-runs/latest error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-9.4 nightly cron entrypoint, and also usable for a manual "run now"
 * console button. Not itself the CI gate (that calls the SQL function
 * directly, no HTTP round-trip, so a broken api/ deploy can't mask a real
 * audit failure) — this route exists for scheduled/manual runs that do go
 * through the API layer, same shape as every other admin action here.
 */
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
    console.error('POST /admin/anonymization-audit-runs/run error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * ============================================================================
 * Group F — Data Import & Sync (implementation-plan-group-e-f-g.md, Task F-0)
 * ============================================================================
 * Task F-0's scope decision, carried out here: every F-screen needs new
 * routes, but F3 (live inbound-email ingestion), F5 (a real bidirectional
 * sync engine) and F7 (a background IMAP poller) each need a job
 * runner/queue/webhook-receiver this single Express file can't host. Per
 * the plan's own recommendation, this pass builds the CRUD/status surface
 * for every F screen and explicitly does NOT build:
 *   - an SMTP/webhook receiver that ingests real inbound email (F3)
 *   - a background IMAP poller that actually reads a mailbox (F7)
 *   - a client-side offline-write-queue/conflict-resolution sync engine (F5)
 * Each is called out again on its own route below, not just here.
 */

/**
 * POST /forwarding-addresses — Task F3. Issues this profile's forwarding
 * address (`<local_part>@in.pandapay.app`, per 0006_ingest.sql's own
 * comment). Idempotent: a profile gets exactly one *active* address: if one
 * already exists, it's returned as-is rather than minting a second (mirrors
 * `rotated_from`'s existence in the schema — rotation is a distinct, later
 * action, not implicit on every POST).
 *
 * NOT built here: anything that actually delivers mail to this address.
 * `first_email_at`/`email_count` stay at their defaults forever without a
 * real inbound-email receiver (SMTP server or a provider webhook like
 * SendGrid/Mailgun inbound parse) wired up to write `inbound_emails` and
 * update this row — that's real infrastructure outside a single Express
 * route, flagged explicitly in the plan's Task F-0 and in this chunk's
 * PROGRESS.md entry. The F3 screen's "Waiting for first email…" status is
 * real UI over real (if permanently 'waiting') data, not a fake front end.
 */
app.post('/forwarding-addresses', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const existing = await client.query(
        `SELECT * FROM forwarding_addresses WHERE profile_id = $1 AND is_active LIMIT 1`,
        [req.userId]
      );
      if (existing.rows[0]) return existing.rows[0];

      // Short, URL-safe local_part — collision retried a few times rather
      // than trusting a single random draw against the unique constraint.
      for (let attempt = 0; attempt < 5; attempt += 1) {
        const localPart = `u${Math.random().toString(36).slice(2, 8)}`;
        try {
          const inserted = await client.query(
            `INSERT INTO forwarding_addresses (profile_id, local_part) VALUES ($1, $2) RETURNING *`,
            [req.userId, localPart]
          );
          return inserted.rows[0];
        } catch (err) {
          if (err.code === '23505') continue; // unique_violation on local_part — retry
          throw err;
        }
      }
      throw new Error('could not generate a unique forwarding address');
    });
    res.status(201).json({ forwardingAddress: result });
  } catch (err) {
    console.error('POST /forwarding-addresses error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/** GET /forwarding-addresses/me — F3's status-polling read (null if never issued). */
app.get('/forwarding-addresses/me', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT * FROM forwarding_addresses WHERE profile_id = $1 AND is_active ORDER BY created_at DESC LIMIT 1`,
        [req.userId]
      )
    );
    res.json({ forwardingAddress: result.rows[0] || null });
  } catch (err) {
    console.error('GET /forwarding-addresses/me error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /statement-imports — Task F2. Written only AFTER on-device parsing
 * has already happened (0006_ingest.sql's own comment: "the PDF itself and
 * its password NEVER reach this table... parsing is 100% on-device"). This
 * route only accepts the already-extracted, structured result — never a
 * file, never a password. See app/lib/features/import/statement_pdf_import_screen.dart
 * for the (stub/best-effort, explicitly scoped-down) on-device parser this
 * feeds from.
 */
app.post('/statement-imports', requireAuth, async (req, res) => {
  const { userCardId, statementFrom, statementTo, closingBalanceInr, pointsPosted, txnCount, reconciledCount, issuerFormatId } =
    req.body || {};
  if (!userCardId || typeof userCardId !== 'string') {
    return res.status(400).json({ error: 'userCardId is required' });
  }
  if (!statementFrom || !statementTo) {
    return res.status(400).json({ error: 'statementFrom and statementTo are required' });
  }
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `INSERT INTO statement_imports
           (profile_id, user_card_id, statement_from, statement_to, closing_balance_inr,
            points_posted, txn_count, reconciled_count, issuer_format_id)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
         RETURNING *`,
        [
          req.userId,
          userCardId,
          statementFrom,
          statementTo,
          closingBalanceInr ?? null,
          pointsPosted ?? null,
          txnCount ?? 0,
          reconciledCount ?? 0,
          issuerFormatId ?? null,
        ]
      )
    );
    res.status(201).json({ statementImport: result.rows[0] });
  } catch (err) {
    console.error('POST /statement-imports error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/** GET /statement-imports — F1's per-channel status + F2's own import history. */
app.get('/statement-imports', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT * FROM statement_imports WHERE profile_id = $1 ORDER BY imported_at DESC LIMIT 20`,
        [req.userId]
      )
    );
    res.json({ statementImports: result.rows });
  } catch (err) {
    console.error('GET /statement-imports error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /sms-import-batches — Task F4's missing one-time backup-file import
 * path. `sms_import_batches` exists with counters only (0006_ingest.sql) —
 * this route is the SUMMARY write after the client has already bulk-parsed
 * a backup file locally and called the EXISTING POST /transactions/from-sms
 * once per message (same parser as the live listener; no second parser
 * built, per the plan's explicit instruction), so this table's counts are a
 * true summary, not a guess.
 */
app.post('/sms-import-batches', requireAuth, async (req, res) => {
  const { messageCount, parsedCount, failedCount } = req.body || {};
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `INSERT INTO sms_import_batches (profile_id, message_count, parsed_count, failed_count)
         VALUES ($1, $2, $3, $4) RETURNING *`,
        [req.userId, messageCount ?? 0, parsedCount ?? 0, failedCount ?? 0]
      )
    );
    res.status(201).json({ smsImportBatch: result.rows[0] });
  } catch (err) {
    console.error('POST /sms-import-batches error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/** GET /sms-import-batches — F1/F4 history read. */
app.get('/sms-import-batches', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT * FROM sms_import_batches WHERE profile_id = $1 ORDER BY imported_at DESC LIMIT 20`,
        [req.userId]
      )
    );
    res.json({ smsImportBatches: result.rows });
  } catch (err) {
    console.error('GET /sms-import-batches error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /backup-status — Task F5, narrowed per the plan's own scoping
 * recommendation to backup/restore status only (no live client sync
 * engine — `change_log`/`sync_cursors` are untouched by this pass; a
 * "0 pending changes" sync figure would be fabricated without a real
 * engine behind it, which the plan explicitly says not to ship).
 * `backup_runs`/`restore_drills` (0009_platform_ops.sql) are ops-wide
 * tables with no `profile_id` — by design (they describe the whole
 * database's backup, not a per-user backup) — so the latest run is the
 * same for every caller; `sync_conflicts` IS profile-scoped and renders as
 * F5's conflict log ("never resolve silently without a record" — this
 * route only ever reads rows that already exist, never resolves anything).
 */
app.get('/backup-status', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const latestBackup = await client.query(`SELECT * FROM backup_runs ORDER BY ran_at DESC LIMIT 1`);
      const latestDrill = await client.query(`SELECT * FROM restore_drills ORDER BY ran_at DESC LIMIT 1`);
      const conflicts = await client.query(
        `SELECT * FROM sync_conflicts WHERE profile_id = $1 ORDER BY created_at DESC LIMIT 50`,
        [req.userId]
      );
      return {
        latestBackup: latestBackup.rows[0] || null,
        latestRestoreDrill: latestDrill.rows[0] || null,
        conflicts: conflicts.rows,
      };
    });
    res.json(result);
  } catch (err) {
    console.error('GET /backup-status error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /backup-runs — F5's manual "Back up now" action. Since
 * `backup_runs` is genuinely ops-wide (whole-database, not per-user), this
 * is a STUB that records a user-triggered request as a `kind: 'logical'`
 * run rather than actually invoking a real backup job (no such job exists
 * in this pass — that's real ops infrastructure, e.g. a
 * pg_dump/WAL-archiving pipeline, not an Express route). Flagged
 * explicitly, not silently faked as a full backup engine.
 */
app.post('/backup-runs', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `INSERT INTO backup_runs (kind, status, location) VALUES ('logical', 'success', 'user-triggered (stub — no real backup job wired up)')
         RETURNING *`
      )
    );
    res.status(201).json({ backupRun: result.rows[0] });
  } catch (err) {
    console.error('POST /backup-runs error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /export?scope=transactions|cards|all&format=csv|json — Task F6.
 * Reads only this caller's own data (RLS + explicit profile_id filter,
 * belt-and-braces, same discipline as every other route here) — an
 * "export everything" route is by definition a full PII/financial dump, so
 * this is one of the routes this pass ran owasp-mobile-security-checker's
 * proactive checklist against per CLAUDE.md: gated to `req.userId` only,
 * and the response is streamed straight back in the HTTP response body
 * (no temp file written to any on-device or server cache location).
 */
app.get('/export', requireAuth, async (req, res) => {
  const scope = ['transactions', 'cards', 'all'].includes(req.query.scope) ? req.query.scope : 'all';
  const format = req.query.format === 'csv' ? 'csv' : 'json';

  const toCsv = (rows) => {
    if (rows.length === 0) return '';
    const headers = Object.keys(rows[0]);
    const escape = (v) => {
      if (v === null || v === undefined) return '';
      const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
      return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    };
    return [headers.join(','), ...rows.map((r) => headers.map((h) => escape(r[h])).join(','))].join('\n');
  };

  try {
    const data = await withUserClient(req.userId, async (client) => {
      const out = {};
      if (scope === 'transactions' || scope === 'all') {
        const txns = await client.query(
          `SELECT t.id, t.user_card_id, t.amount_inr, t.occurred_at, t.merchant_name,
                  sc.name AS category_name, t.rail, t.status
             FROM transactions t
             LEFT JOIN spend_categories sc ON sc.id = t.category_id
            WHERE t.profile_id = $1
            ORDER BY t.occurred_at DESC`,
          [req.userId]
        );
        out.transactions = txns.rows;
      }
      if (scope === 'cards' || scope === 'all') {
        const cards = await client.query(
          `SELECT uc.id, uc.nickname, cp.name AS card_name, uc.is_default, uc.opened_on,
                  uc.statement_day, uc.due_day, uc.credit_limit_inr
             FROM user_cards uc
             LEFT JOIN card_products cp ON cp.id = uc.card_product_id
            WHERE uc.profile_id = $1`,
          [req.userId]
        );
        out.cards = cards.rows;
      }
      return out;
    });

    if (format === 'json') {
      res.setHeader('Content-Disposition', `attachment; filename="pandapay-export-${scope}.json"`);
      return res.json(data);
    }

    // CSV: 'all' concatenates each scope as its own labelled section rather
    // than inventing a combined-row shape that doesn't exist anywhere else
    // in this codebase.
    const sections = [];
    if (data.transactions) sections.push(`# transactions\n${toCsv(data.transactions)}`);
    if (data.cards) sections.push(`# cards\n${toCsv(data.cards)}`);
    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', `attachment; filename="pandapay-export-${scope}.csv"`);
    res.send(sections.join('\n\n'));
  } catch (err) {
    console.error('GET /export error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /imap-connections — Task F7. `imap_connections` is a genuinely new
 * table this pass added (0018_imap_connections.sql — no migration modeled
 * IMAP credentials before). The app password is encrypted at rest via
 * pgcrypto's `pgp_sym_encrypt` (extension already enabled,
 * 0001_extensions_and_enums.sql) keyed off `IMAP_ENCRYPTION_KEY`, an env
 * var never committed/logged — NOT plaintext, per this project's
 * payments-app security stance. This is still a stopgap: a single static
 * symmetric key in an env var is weaker than real envelope
 * encryption/KMS-managed key rotation, flagged explicitly as a follow-up
 * (see the migration's own comment and this chunk's PROGRESS.md entry) —
 * do not treat this as the final answer for credential-at-rest storage.
 * The password itself is never logged anywhere in this route.
 */
app.post('/imap-connections', requireAuth, async (req, res) => {
  const { email, appPassword, imapHost, imapPort, senderFilter } = req.body || {};
  if (!email || typeof email !== 'string' || !email.includes('@')) {
    return res.status(400).json({ error: 'a valid email is required' });
  }
  if (!appPassword || typeof appPassword !== 'string') {
    return res.status(400).json({ error: 'appPassword is required' });
  }
  if (!imapHost || typeof imapHost !== 'string') {
    return res.status(400).json({ error: 'imapHost is required' });
  }
  const encryptionKey = process.env.IMAP_ENCRYPTION_KEY;
  if (!encryptionKey) {
    // Fail loudly rather than silently falling back to plaintext storage.
    console.error('POST /imap-connections: IMAP_ENCRYPTION_KEY is not set');
    return res.status(500).json({ error: 'internal_error' });
  }
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `INSERT INTO imap_connections (profile_id, email, app_password_encrypted, imap_host, imap_port, sender_filter)
         VALUES ($1, $2, pgp_sym_encrypt($3, $4), $5, $6, $7)
         ON CONFLICT (profile_id, email) DO UPDATE
           SET app_password_encrypted = EXCLUDED.app_password_encrypted,
               imap_host = EXCLUDED.imap_host,
               imap_port = EXCLUDED.imap_port,
               sender_filter = EXCLUDED.sender_filter,
               is_active = true
         RETURNING id, profile_id, email, imap_host, imap_port, sender_filter, is_active, verified_at, last_poll_at, last_poll_status, created_at`,
        [req.userId, email, appPassword, encryptionKey, imapHost, imapPort ?? 993, senderFilter ?? null]
      )
    );
    // Never echo app_password_encrypted (or the plaintext) back to the client.
    res.status(201).json({ imapConnection: result.rows[0] });
  } catch (err) {
    console.error('POST /imap-connections error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/** GET /imap-connections/me — never selects app_password_encrypted. */
app.get('/imap-connections/me', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT id, profile_id, email, imap_host, imap_port, sender_filter, is_active, verified_at, last_poll_at, last_poll_status, created_at
           FROM imap_connections WHERE profile_id = $1 AND is_active ORDER BY created_at DESC LIMIT 1`,
        [req.userId]
      )
    );
    res.json({ imapConnection: result.rows[0] || null });
  } catch (err) {
    console.error('GET /imap-connections/me error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /imap-connections/:id/test — a STUB test-connection, per the plan's
 * explicit allowance: "test connection can be a stub that validates format
 * only, not a live IMAP handshake." A real implementation would open a TLS
 * socket to imap_host:imap_port and attempt a LOGIN with the decrypted app
 * password — genuinely live network I/O from an API route, not attempted
 * here. This only checks the stored fields are well-formed (host looks
 * like a hostname, port in range, email has an @) and, if so, marks
 * `verified_at`. Never decrypts/logs the password.
 */
app.post('/imap-connections/:id/test', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const existing = await client.query(
        `SELECT id, email, imap_host, imap_port FROM imap_connections WHERE id = $1 AND profile_id = $2`,
        [req.params.id, req.userId]
      );
      const conn = existing.rows[0];
      if (!conn) return null;

      const hostLooksValid = /^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/.test(conn.imap_host);
      const portLooksValid = Number.isInteger(conn.imap_port) && conn.imap_port > 0 && conn.imap_port < 65536;
      const emailLooksValid = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(conn.email);
      const formatOk = hostLooksValid && portLooksValid && emailLooksValid;

      if (!formatOk) {
        return { ok: false, connection: conn, reason: 'One or more fields look malformed — this is a format check only, not a live IMAP login.' };
      }
      const updated = await client.query(
        `UPDATE imap_connections SET verified_at = now() WHERE id = $1
         RETURNING id, email, imap_host, imap_port, sender_filter, is_active, verified_at, last_poll_at, last_poll_status`,
        [conn.id]
      );
      return { ok: true, connection: updated.rows[0] };
    });
    if (!result) return res.status(404).json({ error: 'not_found' });
    res.json(result);
  } catch (err) {
    console.error('POST /imap-connections/:id/test error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /issuer-emergency-contacts — G4 Emergency Card Info. Deliberately
 * PUBLIC (no requireAuth) and reads no per-user data: the whole point of
 * this table (0002_reference_data.sql's own comment: "must work offline +
 * logged out, so it ships to device") is that a signed-out, offline user
 * still needs to reach a lost-card hotline. The app fetches this once
 * whenever it has connectivity and caches the response on-device
 * (app/lib/data/emergency_contacts_repository.dart) so the G4 screen never
 * depends on a live call at the moment someone actually needs it.
 */
app.get('/issuer-emergency-contacts', async (req, res) => {
  try {
    const result = await withUserClient(null, (client) =>
      client.query(
        `SELECT iec.id, i.name AS issuer_name, i.slug AS issuer_slug, iec.label, iec.phone,
                iec.is_international, iec.is_collect_call, iec.block_procedure, iec.sort_order
         FROM issuer_emergency_contacts iec
         JOIN issuers i ON i.id = iec.issuer_id
         WHERE i.is_active
         ORDER BY i.name, iec.sort_order`
      )
    );
    res.json({ contacts: result.rows });
  } catch (err) {
    console.error('GET /issuer-emergency-contacts error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => console.log(`pandapay-api running at http://localhost:${PORT}`));
