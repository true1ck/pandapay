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
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const cards = await client.query(
        `SELECT uc.id, uc.card_product_id, uc.nickname, uc.is_default, uc.sort_order,
                uc.created_at, cp.name AS card_name, cp.network, cp.is_upi_linkable
           FROM user_cards uc
           JOIN card_products cp ON cp.id = uc.card_product_id
          WHERE uc.is_archived = false
          ORDER BY uc.sort_order, uc.created_at`
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
        const milestoneStates = await client.query(
          `SELECT milestone_rule_id, qualified_spend FROM milestone_states
            WHERE user_card_id = $1 AND period_start <= CURRENT_DATE AND period_end >= CURRENT_DATE`,
          [card.id]
        );
        card.cap_states = capStates.rows;
        card.milestone_states = milestoneStates.rows;

        // Chunk 28: lifetime points-earned total (not period-scoped, unlike
        // caps/milestones — a points balance doesn't reset each cycle) and
        // the current-period fee-waiver progress, same "no row = no
        // progress yet" default as above.
        const pointsTotal = await client.query(
          `SELECT COALESCE(SUM(delta_points), 0) AS total_points FROM points_ledger WHERE user_card_id = $1`,
          [card.id]
        );
        card.total_points_earned = pointsTotal.rows[0].total_points;

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
  userCardId, amount, occurred, categoryId, rail, merchantName, source,
}) {
  const cardResult = await client.query(
    `SELECT uc.id, uc.card_product_id, uc.statement_day, uc.opened_on, uc.created_at,
            cp.point_value_inr
       FROM user_cards uc
       JOIN card_products cp ON cp.id = uc.card_product_id
      WHERE uc.id = $1 AND uc.profile_id = $2 AND uc.is_archived = false`,
    [userCardId, userId]
  );
  if (cardResult.rows.length === 0) return { status: 404, error: 'user_card not found' };
  const userCard = cardResult.rows[0];

  // The same rule the engine uses to pick a reward rule for a spend:
  // highest-priority (lowest number) match on category (or the
  // category-agnostic base rate). Needed to convert a spend amount into
  // an actual reward VALUE for reward_value-measure caps below.
  const matchingRule = await client.query(
    `SELECT unit, rate FROM reward_rules
      WHERE card_product_id = $1 AND (category_id IS NULL OR category_id = $2)
      ORDER BY priority ASC LIMIT 1`,
    [userCard.card_product_id, categoryId || null]
  );
  const rewardRate = matchingRule.rows[0]
    ? effectiveRatePerRupee(matchingRule.rows[0].unit, Number(matchingRule.rows[0].rate), Number(userCard.point_value_inr) || 0)
    : 0;

  const txn = await client.query(
    `INSERT INTO transactions
       (profile_id, user_card_id, amount_inr, occurred_at, merchant_name, category_id, rail, source, reward_state)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'estimated')
     RETURNING id, amount_inr, occurred_at`,
    [userId, userCardId, amount, occurred, merchantName || null, categoryId || null, rail || 'unknown', source || 'manual']
  );

  const capRules = await client.query(
    `SELECT id, period, cap_value, measure FROM cap_rules
      WHERE card_product_id = $1 AND (category_id IS NULL OR category_id = $2)`,
    [userCard.card_product_id, categoryId || null]
  );
  const capStateUpdates = [];
  for (const cap of capRules.rows) {
    // Chunk 17 fix (same bug class as Chunk 9's engine fix): a
    // reward_value cap's headroom is consumed by the REWARD earned on
    // this spend, not the spend itself; a txn_count cap is consumed by
    // 1 transaction, not any money amount at all. Only spend_amount
    // caps are consumed by the raw amount.
    let consumedDelta;
    if (cap.measure === 'reward_value') {
      consumedDelta = amount * rewardRate;
    } else if (cap.measure === 'txn_count') {
      consumedDelta = 1;
    } else {
      consumedDelta = amount;
    }

    const { start, end } = periodBounds(cap.period, occurred, { statementDay: userCard.statement_day });
    const upserted = await client.query(
      `INSERT INTO cap_states (profile_id, user_card_id, cap_rule_id, period_start, period_end, consumed, cap_value_snapshot)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (user_card_id, cap_rule_id, period_start)
       DO UPDATE SET consumed = cap_states.consumed + EXCLUDED.consumed, updated_at = now()
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
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (user_card_id, milestone_rule_id, period_start)
       DO UPDATE SET qualified_spend = milestone_states.qualified_spend + EXCLUDED.qualified_spend, updated_at = now()
       RETURNING milestone_rule_id, period_start, period_end, qualified_spend`,
      [userId, userCardId, milestone.id, start, end, amount]
    );
    milestoneStateUpdates.push(upserted.rows[0]);
  }

  // Points ledger: one entry per transaction, in the reward's own
  // native unit (points/miles/cashback-rupees), separate from the cap
  // machinery's INR-value accounting above. flat_points rules earn 0
  // per this helper (a fixed bonus isn't a per-transaction rate) so no
  // ledger noise is written for them.
  let pointsLedgerEntry = null;
  if (matchingRule.rows[0]) {
    const pointsPerRupee = effectivePointsPerRupee(matchingRule.rows[0].unit, Number(matchingRule.rows[0].rate));
    if (pointsPerRupee > 0) {
      const deltaPoints = amount * pointsPerRupee;
      const inserted = await client.query(
        `INSERT INTO points_ledger (profile_id, user_card_id, transaction_id, delta_points, reason, state, occurred_at)
         VALUES ($1, $2, $3, $4, $5, 'estimated', $6)
         RETURNING id, delta_points, reason, occurred_at`,
        [userId, userCardId, txn.rows[0].id, deltaPoints, `${matchingRule.rows[0].unit} earned on transaction`, occurred]
      );
      pointsLedgerEntry = inserted.rows[0];
    }
  }

  // Fee-waiver progress: same "which rules apply to this card" +
  // "accumulate qualified spend in the right period" shape as the cap
  // loop above, but against fee_waiver_rules/fee_waiver_states instead.
  // A category on fee_waiver_rules.excluded_categories doesn't count
  // toward the threshold at all (not even partially).
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
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (user_card_id, fee_waiver_rule_id, period_start)
       DO UPDATE SET qualified_spend = fee_waiver_states.qualified_spend + EXCLUDED.qualified_spend, updated_at = now()
       RETURNING id, fee_waiver_rule_id, period_start, period_end, qualified_spend, waived_at`,
      [userId, userCardId, rule.id, start, end, amount]
    );
    let state = upserted.rows[0];
    if (!state.waived_at && Number(state.qualified_spend) >= Number(rule.threshold_spend_inr)) {
      const marked = await client.query(
        `UPDATE fee_waiver_states SET waived_at = now() WHERE id = $1
         RETURNING id, fee_waiver_rule_id, period_start, period_end, qualified_spend, waived_at`,
        [state.id]
      );
      state = marked.rows[0];
    }
    feeWaiverStateUpdates.push(state);
  }

  return {
    status: 201,
    transaction: txn.rows[0],
    capStates: capStateUpdates,
    milestoneStates: milestoneStateUpdates,
    pointsLedgerEntry,
    feeWaiverStates: feeWaiverStateUpdates,
  };
}

app.post('/transactions', requireAuth, async (req, res) => {
  const { userCardId, amountInr, occurredAt, categoryId, rail, merchantName } = req.body || {};
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
        userCardId, amount, occurred, categoryId, rail, merchantName, source: 'manual',
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

app.get('/transactions', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT t.id, t.user_card_id, t.amount_inr, t.occurred_at, t.merchant_name,
                t.category_id, sc.name AS category_name, t.rail, t.status,
                cp.name AS card_name, uc.nickname AS card_nickname
           FROM transactions t
           LEFT JOIN user_cards uc ON uc.id = t.user_card_id
           LEFT JOIN card_products cp ON cp.id = uc.card_product_id
           LEFT JOIN spend_categories sc ON sc.id = t.category_id
          WHERE t.profile_id = $1 AND t.status = 'active'
          ORDER BY t.occurred_at DESC LIMIT 50`,
        [req.userId]
      )
    );
    res.json({ transactions: result.rows });
  } catch (err) {
    console.error('GET /transactions error', err);
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

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => console.log(`pandapay-api running at http://localhost:${PORT}`));
