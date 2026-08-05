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

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => console.log(`pandapay-api running at http://localhost:${PORT}`));
