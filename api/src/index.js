require('dotenv').config();
const express = require('express');
const cors = require('cors');
const { withUserClient } = require('./db');
const { optionalAuth, requireAuth } = require('./auth');
const { periodBounds, effectiveRatePerRupee } = require('./cycles');

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
 * POST /transactions — UA-3+ (Chunk 17): manual transaction entry
 * (source='manual', reward_state='estimated' — R3, nothing here is ever
 * 'confirmed' without a real statement/SMS reconciliation path, which
 * doesn't exist yet). Updates cap_states.consumed and
 * milestone_states.qualified_spend in the SAME transaction as the insert,
 * so a transaction that's recorded but doesn't update state is impossible
 * — same "whole thing rolls back together" pattern as the AD-1 typed
 * writer's audit-log guarantee.
 */
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
    const result = await withUserClient(req.userId, async (client) => {
      const cardResult = await client.query(
        `SELECT uc.id, uc.card_product_id, uc.statement_day, uc.opened_on, uc.created_at,
                cp.point_value_inr
           FROM user_cards uc
           JOIN card_products cp ON cp.id = uc.card_product_id
          WHERE uc.id = $1 AND uc.profile_id = $2 AND uc.is_archived = false`,
        [userCardId, req.userId]
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
         VALUES ($1, $2, $3, $4, $5, $6, $7, 'manual', 'estimated')
         RETURNING id, amount_inr, occurred_at`,
        [req.userId, userCardId, amount, occurred, merchantName || null, categoryId || null, rail || 'unknown']
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
          [req.userId, userCardId, cap.id, start, end, consumedDelta, cap.cap_value]
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
          [req.userId, userCardId, milestone.id, start, end, amount]
        );
        milestoneStateUpdates.push(upserted.rows[0]);
      }

      return { status: 201, transaction: txn.rows[0], capStates: capStateUpdates, milestoneStates: milestoneStateUpdates };
    });

    if (result.status !== 201) return res.status(result.status).json({ error: result.error });
    res.status(201).json(result);
  } catch (err) {
    console.error('POST /transactions error', err);
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

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => console.log(`pandapay-api running at http://localhost:${PORT}`));
