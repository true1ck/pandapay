require('dotenv').config();
const express = require('express');
const cors = require('cors');
const { withUserClient } = require('./db');
const { optionalAuth, requireAuth } = require('./auth');

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
                max(created_at) AS last_requested_at
           FROM card_requests
          GROUP BY issuer_name, product_name, network_guess
          ORDER BY sum(request_count) DESC, max(created_at) DESC`
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
                er.state, er.created_at
           FROM data_error_reports er
           JOIN card_products cp ON cp.id = er.card_product_id
          ORDER BY er.state = 'pending' DESC, er.created_at DESC`
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

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => console.log(`pandapay-api running at http://localhost:${PORT}`));
