const { createStatementImportHandler } = require('./statement_import');
require('dotenv').config();
const crypto = require('crypto');
const express = require('express');
const cors = require('cors');
const config = require('./config');
const { withUserClient, pool } = require('./db');
const {
  optionalAuth,
  requireAuth,
  requireValidJwt,
  requireVerifiedSession,
  verifyMemberRequest,
  SessionVerificationError,
} = require('./auth');
const {
  registerReferralRoutes,
  createEngagementReceipt,
} = require('./referral_routes');
const { registerPortableBackupRoutes } = require('./portable_backup/routes');
const { registerPortableBackupRestoreRoutes } = require('./portable_backup/restore_routes');
const { periodBounds, effectiveRatePerRupee, effectivePointsPerRupee } = require('./cycles');
const { replayCurrentCapConsumption } = require('./card_state_reconciliation');
const {
  parseSmsAgainstPatterns,
  redactSmsShape,
  senderMatches,
  parseTransactionDate,
  parseSmsTransactionTimestamp,
  isBankAccountMessage,
} = require('./sms_parser');
const { parseSubscriptionMandate } = require('./subscription_parser');
const importResolvers = require('./import_resolvers');
const centralProjection = require('./central_financial_projection');
const { registerBillsProjectionRoutes } = require('./bills_projection_route');
const smsFactsRoute = require('./sms_facts_route');
const smsLearningFeedbackRoute = require('./sms_learning_feedback_route');
const smsRuleBundleRoute = require('./sms_rule_bundle');
const smsLearning = require('./sms_learning');
const { testImapLogin } = require('./imap_test');
const { extractLocalPart, scanPolicyKeywords } = require('./email_ingest');
const { discoverCardsAcrossMessages } = require('./card_discovery');
const nearbyGoogle = require('./nearby_google');
const { registerRuleFamilyRoutes, validateField } = require('./admin_rule_families');
const { registerAdminReferralOperationsRoutes } = require('./admin_referral_operations');
const aiQueueRoute = require('./ai_queue_route');
const aiProviderQuotaRoute = require('./ai_provider_quota_route');
const rewardMath = require('./reward_math');
const { registerSplitRoutes } = require('./transaction_splits');
const transactionTags = require('./transaction_tags');
const { registerUserMerchantCategoryRuleRoutes } = require('./user_merchant_category_rules');
const { AMOUNT_TOLERANCE_INR, MAX_CROSS_SOURCE_CANDIDATE_MS, bestDuplicate } = require('./transaction_dedup');
const { emailSourceKey } = require('./source_identity');
const spendReports = require('./spend_reports');
const { buildAssistantSpendingSummary } = require('./assistant_spending');
const {
  detectRecurringSeries,
  annualCost,
  engineStatus,
  nextExpectedAfter,
  merchantSeriesKey,
  isUsableSubscriptionName,
  isDisplayableSubscriptionRecord,
} = require('./recurring');
const { brandFor } = require('./brand_catalog');
const { buildMonthlyReport } = require('./monthly_report');
const { csvDocument } = require('./csv');
const { startImapPoller, fetchRecentMessages } = require('./imap_poller');
const { requestLogger, errorHandler } = require('./observability');
const { importSourceKey } = require('./import_source_key');
const { extractVpa, extractMcc } = require('./merchant_category');
const {
  MATCH_POLICY_VERSION,
  normalizeMerchantVpa,
  normalizeMerchantName,
  isGenericMerchantName,
  merchantMatch,
  classifyCandidate,
  resolveBulkIdempotencyRow,
} = require('./merchant_bulk_category');
const notificationService = require('./notification_service');
const { createTestNotificationLimiter } = require('./notification_test');
const {
  createNearbyDiscovery,
  normalizeCategory: normalizeNearbyDiscoveryCategory,
} = require('./nearby_discovery');
const {
  normalizeCardLast4,
  cardIdentityKey,
  findCardAddConflict,
} = require('./card_identity');

const testNotificationLimiter = createTestNotificationLimiter();
// Process-local cache and in-flight request coalescing keep repeated nearby
// searches from starting duplicate public-data lookups. This is intentionally
// independent of user data and never writes to merchant, spending, or SMS
// tables. A future multi-instance deployment can replace this provider with a
// shared cache without changing the mobile contract.
const nearbyDiscovery = createNearbyDiscovery();
// Bound each public OSM failover attempt for the Google-backed route so the
// fallback fits within the mobile client's foreground request deadline.
const nearbyGoogleFallback = createNearbyDiscovery({ timeoutMs: 2500 });

function uniqueSmsPatternIssuerId(patterns, sender) {
  const issuerIds = new Set(
    (patterns || [])
      .filter((pattern) => senderMatches(pattern.sender_pattern, sender))
      .map((pattern) => pattern.issuer_id)
      .filter(Boolean),
  );
  return issuerIds.size === 1 ? [...issuerIds][0] : null;
}

/**
 * Store an explicit mandate signal without turning the mandate-creation SMS
 * into a spend. The raw body is used only during this request to resolve the
 * category/card and is never written to the subscription row.
 */
async function persistSubscriptionMandate(client, userId, { parsed, body, occurred, patternIssuerId }) {
  if (!parsed?.ok || !parsed.fields?.merchant) return null;
  const fields = parsed.fields;
  const merchantKey = merchantSeriesKey(fields.merchant);
  if (!merchantKey) return null;

  if (parsed.lifecycle === 'cancelled') {
    const result = await client.query(
      `UPDATE recurring_series
          SET typical_amount_inr = CASE
                WHEN detection_source = 'mandate' THEN 0
                ELSE typical_amount_inr
              END,
              next_expected_on = CASE
                WHEN detection_source = 'mandate' THEN NULL
                ELSE next_expected_on
              END,
              is_active = CASE
                WHEN detection_source = 'mandate' THEN false
                ELSE is_active
              END,
              dismissed_at = CASE
                WHEN detection_source = 'mandate' THEN COALESCE(dismissed_at, now())
                ELSE dismissed_at
              END,
              lifecycle_status = CASE
                WHEN detection_source = 'mandate' THEN 'cancelled'
                ELSE lifecycle_status
              END,
              autopay_status = 'cancelled',
              mandate_reference = COALESCE($3, mandate_reference),
              mandate_cancelled_at = now(),
              cadence_confirmed = CASE
                WHEN detection_source = 'mandate' THEN false
                ELSE cadence_confirmed
              END,
              updated_at = now()
        WHERE profile_id = $1
          AND merchant_key = $2
          AND ($3::text IS NULL OR mandate_reference = $3 OR mandate_reference IS NULL)
        RETURNING id, detection_source`,
      [userId, merchantKey, fields.reference || null]
    );
    return result.rows[0] || null;
  }

  const card = await importResolvers.resolveUserCardForImport(client, userId, {
    last4: fields.last4,
    patternIssuerId,
    instrument: fields.instrument || 'credit_card',
  });
  const classification = importResolvers.resolveCategoryAssignmentForImport
    ? await importResolvers.resolveCategoryAssignmentForImport(client, userId, {
      merchantName: fields.merchant,
      vpa: fields.vpa || extractVpa(body),
      mcc: extractMcc(body),
      messageText: body,
    })
    : {
      categoryId: await importResolvers.resolveCategoryForImport(client, userId, {
        merchantName: fields.merchant,
        vpa: fields.vpa || extractVpa(body),
        mcc: extractMcc(body),
        messageText: body,
      }),
      userCategoryId: null,
    };
  const categoryId = classification.categoryId;
  const userCategoryId = classification.userCategoryId;

  /*
   * The subscription row carries both IDs for the same reason transactions
   * do: category_id is the built-in reporting/reward parent, while the
   * private ID is the user's own classification. Older databases can run
   * the API before this migration is applied, so deployment order still
   * matters; the migration is intentionally small and additive.
   */

  const seenOn = new Date(occurred).toISOString().slice(0, 10);
  // `amountInr` in the mandate parser is the authorization ceiling. It is
  // not a posted payment and cannot be used as a subscription price. The
  // legacy recurring_series table has no authorization-limit column, so the
  // typed facts projection remains the source of that ceiling and mandate
  // rows use the table's zero-valued amount only as a compatibility sentinel.
  const cadenceDays = fields.cadenceDays || 30;
  const typicalAmount = 0;
  const cadenceConfirmed = false;
  // A mandate activation does not prove that a renewal is due. Keep this
  // null even when the SMS names a cadence; the cadence is authorization
  // metadata until a posted payment or explicit service fact exists.
  const nextExpected = null;
  const result = await client.query(
    `INSERT INTO recurring_series
       (profile_id, merchant_key, display_name, category_id, user_category_id, user_card_id,
        payment_method, typical_amount_inr, cadence_days, occurrence_count,
        first_seen_on, last_seen_on, next_expected_on, detection_source,
        lifecycle_status, autopay_status, mandate_reference, mandate_started_on,
        cadence_confirmed)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 1, $10, $10, $11, 'mandate',
             'active', 'active', $12, $10, $13)
     ON CONFLICT (profile_id, merchant_key) DO UPDATE SET
       display_name = COALESCE(EXCLUDED.display_name, recurring_series.display_name),
       category_id = COALESCE(recurring_series.category_id, EXCLUDED.category_id),
       user_category_id = COALESCE(EXCLUDED.user_category_id, recurring_series.user_category_id),
       user_card_id = COALESCE(recurring_series.user_card_id, EXCLUDED.user_card_id),
       payment_method = COALESCE(EXCLUDED.payment_method, recurring_series.payment_method),
       typical_amount_inr = CASE
         WHEN recurring_series.detection_source = 'mandate' THEN 0
         ELSE recurring_series.typical_amount_inr
       END,
       cadence_days = CASE
         WHEN recurring_series.detection_source = 'mandate' THEN EXCLUDED.cadence_days
         ELSE recurring_series.cadence_days
       END,
       last_seen_on = CASE
         WHEN recurring_series.detection_source = 'mandate' THEN EXCLUDED.last_seen_on
         ELSE recurring_series.last_seen_on
       END,
       next_expected_on = CASE
         WHEN recurring_series.detection_source = 'mandate' THEN NULL
         ELSE recurring_series.next_expected_on
       END,
       detection_source = recurring_series.detection_source,
       lifecycle_status = CASE
         WHEN recurring_series.detection_source = 'mandate' THEN 'active'
         ELSE recurring_series.lifecycle_status
       END,
       autopay_status = CASE
         WHEN recurring_series.detection_source = 'mandate' THEN 'active'
         ELSE recurring_series.autopay_status
       END,
       mandate_reference = COALESCE(EXCLUDED.mandate_reference, recurring_series.mandate_reference),
       mandate_started_on = COALESCE(recurring_series.mandate_started_on, EXCLUDED.mandate_started_on),
       mandate_cancelled_at = CASE
         WHEN recurring_series.detection_source = 'mandate' THEN NULL
         ELSE recurring_series.mandate_cancelled_at
       END,
       cadence_confirmed = CASE
         WHEN recurring_series.detection_source = 'mandate' THEN false
         ELSE recurring_series.cadence_confirmed
       END,
       is_active = CASE
         WHEN recurring_series.detection_source = 'mandate' THEN true
         ELSE recurring_series.is_active
       END,
       dismissed_at = CASE
         WHEN recurring_series.detection_source = 'mandate' THEN NULL
         ELSE recurring_series.dismissed_at
       END,
       updated_at = now()
     RETURNING id, detection_source`,
    [
      userId,
      merchantKey,
      fields.merchant,
      categoryId,
      userCategoryId,
      card?.userCardId || null,
      fields.instrument || null,
      typicalAmount,
      cadenceDays,
      seenOn,
      nextExpected,
      fields.reference || null,
      cadenceConfirmed,
    ],
  );
  return result.rows[0] || null;
}

const app = express();
// Staging/production expose this process only through one nginx hop bound to
// loopback. Trust exactly that hop so IP-based abuse controls see the client
// address without trusting arbitrary forwarded chains from the internet.
app.set('trust proxy', 1);
app.use(cors());
app.use(express.json());
// optionalAuth first so the request log can record which user a line belongs
// to; requestLogger only writes on `finish`, so ordering costs nothing.
app.use(optionalAuth);
app.use(requestLogger);

app.get('/health', (req, res) => res.json({ ok: true }));

// Liveness stays dependency-free for the process supervisor. Readiness is the
// deployment/load-balancer probe: it must prove that this instance can reach
// the database before traffic is sent to it.
app.get('/ready', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ ok: true, database: 'ready' });
  } catch (err) {
    console.error('GET /ready error', err.message);
    res.status(503).json({ ok: false, database: 'unavailable' });
  }
});

registerReferralRoutes(app);
registerPortableBackupRoutes(app, { requireAuth, pool });
registerPortableBackupRestoreRoutes(app, { requireAuth, pool });
registerUserMerchantCategoryRuleRoutes(app, { requireAuth, withUserClient });

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
app.post('/profile', requireVerifiedSession, async (req, res) => {
  const body = req.body || {};
  if (req.verifiedSession?.guest) {
    return res.status(403).json({ error: 'membership_required' });
  }

  const invitationCode = typeof body.invitationCode === 'string'
    ? body.invitationCode.trim().toUpperCase()
    : '';
  const hasPreviewToken = typeof body.invitationPreviewToken === 'string'
    && body.invitationPreviewToken.length > 0;
  let preview = null;
  if (hasPreviewToken) {
    preview = require('./referral_routes').verifyInvitationPreviewToken(
      body.invitationPreviewToken,
    );
    if (!preview || (invitationCode && preview.code !== invitationCode)) {
      return res.status(400).json({ error: 'invitation_preview_invalid' });
    }
  } else if (invitationCode) {
    return res.status(400).json({ error: 'invitation_preview_required' });
  }

  const selectedCode = preview?.code || invitationCode || null;
  const acceptRewardTerms = body.acceptRewardTerms === true;
  const acceptAccessOnly = selectedCode
    ? body.acceptAccessOnly === true
    : true;
  if (selectedCode && !acceptRewardTerms && !acceptAccessOnly) {
    return res.status(400).json({ error: 'reward_choice_required' });
  }
  if (acceptRewardTerms && !preview?.rewardAvailable) {
    return res.status(409).json({ error: 'offer_changed' });
  }

  let identityClaims = [];
  if (acceptRewardTerms) {
    try {
      identityClaims = require('./referral_routes').buildEligibilityClaims(
        req.verifiedSession?.verifiedContacts,
      );
    } catch (_) {
      return res.status(503).json({ error: 'referral_identity_unavailable' });
    }
  }

  const acceptProductTerms = body.acceptProductTerms === true;
  const requestedProductTermsVersion = typeof body.productTermsVersion === 'string'
    ? body.productTermsVersion.trim()
    : '';
  if (acceptProductTerms && requestedProductTermsVersion !== config.productTermsVersion) {
    return res.status(409).json({ error: 'product_terms_changed' });
  }
  if (selectedCode && preview?.accessMode === 'invite_only' && !acceptProductTerms) {
    return res.status(400).json({ error: 'required_terms_missing' });
  }

  try {
    const activation = await withUserClient(req.userId, async (client) => {
      const result = await client.query(
        `SELECT promotions.activate_current_user(
           $1::text, $2::text, $3::text, $4::text, $5::text, $6::text,
           $7::text, $8::text, $9::boolean, $10::boolean, $11::jsonb,
           $12::text, $13::boolean
         ) AS activation`,
        [
          typeof body.displayName === 'string' ? body.displayName : null,
          typeof body.locale === 'string' ? body.locale : null,
          typeof body.currency === 'string' ? body.currency : null,
          req.verifiedSession?.verifiedContacts?.email?.verified === true
            ? req.verifiedSession.verifiedContacts.email.value : null,
          req.verifiedSession?.verifiedContacts?.phone?.verified === true
            ? req.verifiedSession.verifiedContacts.phone.value : null,
          selectedCode,
          preview?.campaignVersion || null,
          preview?.termsVersion || 'invite-access-v1',
          acceptRewardTerms,
          acceptAccessOnly,
          JSON.stringify(identityClaims),
          acceptProductTerms ? config.productTermsVersion : null,
          acceptProductTerms,
        ],
      );
      const profile = await client.query('SELECT * FROM profiles WHERE id = $1', [req.userId]);
      return { activation: result.rows[0]?.activation, profile: profile.rows[0] || null };
    });
    if (!activation.profile) return res.status(503).json({ error: 'profile_activation_incomplete' });
    return res.status(201).json(activation);
  } catch (err) {
    if (err.code === 'P0001') {
      const code = typeof err.message === 'string' && /^[a-z][a-z0-9_]{2,80}$/.test(err.message)
        ? err.message : 'activation_unavailable';
      return res.status(code === 'invitation_required' ? 403 : 409).json({ error: code });
    }
    console.error('POST /profile activation failed', { code: err.code || null });
    return res.status(503).json({ error: 'profile_activation_unavailable' });
  }
});

/**
 * GET /catalogue — public read of published cards (0011's
 * card_products_public_read policy: `to public using (true)`), no auth
 * required. Proves the anon-read path works too, not just owner rows.
 */
app.get('/catalogue', async (req, res) => {
  try {
    const result = await withUserClient(req.user || null, (client) =>
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
  try {
    await verifyMemberRequest(req);
    const isAdmin = await withUserClient(req.userId, async (client) => {
      const result = await client.query('SELECT pandapay.is_admin() AS is_admin');
      return result.rows[0].is_admin;
    });
    if (!isAdmin) {
      return res.status(403).json({ error: 'Admin access required' });
    }
    next();
  } catch (err) {
    if (err instanceof SessionVerificationError) {
      return res.status(err.status).json({ error: err.code });
    }
    console.error('requireAdmin error', err);
    res.status(503).json({ error: 'access_check_unavailable' });
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

registerAdminReferralOperationsRoutes(app, { withUserClient, requireAdmin });

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
 * POST /admin/issuers — get-or-create by slug. Needed so the bulk card
 * importer (api/scripts/import_card_pipeline.js) and any future console
 * "add a new card" flow can resolve an issuer without a human having
 * pre-seeded every possible slug first. Unlike a card slug (see
 * POST /admin/cards below), an issuer slug collision is expected and
 * harmless — CardPipeline's source data uses slugs like `sbi-card` where
 * this catalogue already has the same real-world issuer seeded as `sbi` —
 * so a conflict returns the EXISTING row rather than erroring.
 * admin_audit_log only gets an entry when a row was actually inserted.
 */
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
    console.error('POST /admin/issuers error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

const CARD_TYPES = ['credit', 'debit', 'prepaid', 'forex'];

/**
 * POST /admin/cards — create a new card_products row. Before this route,
 * the only card_products writes reachable through the admin API were
 * GET /admin/cards (browse) and POST /admin/cards/:id/status (change
 * status of a card that already exists) — every rule-family write in
 * admin_rule_families.js requires a card_product_id that already exists.
 * This closes that gap, for both the bulk importer
 * (api/scripts/import_card_pipeline.js) and a future console "add card"
 * button.
 *
 * `status` is deliberately NOT an accepted body field — every card created
 * here is hardcoded 'draft', and verified_at/verified_by are never touched
 * by this route. Reaching 'published' is only ever possible through
 * POST /admin/cards/:id/status's transition below, which is also where the
 * card_published_needs_verification CHECK constraint gets satisfied — so a
 * card created here has no path to 'published' without a human going
 * through that gate, matching this codebase's "AI extracts, human
 * verifies, never auto-published" rule everywhere else card data is
 * written (see extraction_proposals' table comment).
 *
 * A slug conflict is a 409, not a silent merge (unlike issuers above) —
 * two different card_products rows colliding on slug is worth a human's
 * attention, not an auto-resolution.
 *
 * Field-by-field validation reuses `validateField` from
 * admin_rule_families.js — the same typed-writer discipline as every other
 * admin route, never a raw JSON passthrough.
 */
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
    console.error('POST /admin/cards error', err);
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

// AD-1.1.2 tabbed rule-family editor — the other 8 rule tables
// v_admin_card_catalogue_export already reads (0022's migration comment).
// Only reward_rules (above) had a typed writer before this; every other
// family was read-only in the console until now. See
// admin_rule_families.js's header comment for the shared route shape.
const REWARD_UNITS = [
  'cashback_percent', 'points_per_100', 'points_per_150', 'points_per_200',
  'miles_per_100', 'flat_points', 'discount_percent',
];
const CAP_PERIODS = ['statement_cycle', 'calendar_month', 'quarter', 'half_year', 'annual', 'lifetime'];
const CAP_MEASURES = ['reward_value', 'spend_amount', 'txn_count'];
const BENEFIT_KINDS = [
  'lounge_domestic', 'lounge_international', 'golf', 'concierge', 'insurance_travel',
  'insurance_purchase', 'extended_warranty', 'dining_program', 'movie', 'fuel_surcharge',
  'roadside_assistance', 'other',
];
const MILESTONE_ANCHORS = ['card_anniversary', 'calendar_year', 'fiscal_year', 'statement_cycle'];

const adminRouteDeps = { withUserClient, requireAdmin };

registerRuleFamilyRoutes(app, adminRouteDeps, {
  urlSegment: 'cap-rules',
  tableName: 'cap_rules',
  auditEntity: 'cap_rule',
  fields: [
    { name: 'categoryId', column: 'category_id', type: 'string' },
    { name: 'benefitKind', column: 'benefit_kind', type: 'enum', values: BENEFIT_KINDS },
    { name: 'label', column: 'label', type: 'string', required: true },
    { name: 'measure', column: 'measure', type: 'enum', values: CAP_MEASURES, required: true },
    { name: 'period', column: 'period', type: 'enum', values: CAP_PERIODS, required: true },
    { name: 'capValue', column: 'cap_value', type: 'number', min: 0, required: true },
    { name: 'postCapUnit', column: 'post_cap_unit', type: 'enum', values: REWARD_UNITS },
    { name: 'postCapRate', column: 'post_cap_rate', type: 'number', min: 0 },
    { name: 'resetsOnDay', column: 'resets_on_day', type: 'integer', min: 1, max: 31 },
  ],
});

registerRuleFamilyRoutes(app, adminRouteDeps, {
  urlSegment: 'milestone-rules',
  tableName: 'milestone_rules',
  auditEntity: 'milestone_rule',
  fields: [
    { name: 'label', column: 'label', type: 'string', required: true },
    { name: 'period', column: 'period', type: 'enum', values: CAP_PERIODS },
    { name: 'thresholdSpendInr', column: 'threshold_spend_inr', type: 'number', min: 0, required: true },
    { name: 'rewardDescription', column: 'reward_description', type: 'string', required: true },
    { name: 'rewardValueInr', column: 'reward_value_inr', type: 'number', min: 0, required: true },
    { name: 'isRepeatable', column: 'is_repeatable', type: 'boolean' },
    { name: 'maxRepeats', column: 'max_repeats', type: 'integer', min: 0 },
    { name: 'anchor', column: 'anchor', type: 'enum', values: MILESTONE_ANCHORS },
  ],
});

registerRuleFamilyRoutes(app, adminRouteDeps, {
  urlSegment: 'fee-waiver-rules',
  tableName: 'fee_waiver_rules',
  auditEntity: 'fee_waiver_rule',
  fields: [
    { name: 'thresholdSpendInr', column: 'threshold_spend_inr', type: 'number', min: 0, required: true },
    { name: 'period', column: 'period', type: 'enum', values: CAP_PERIODS },
    { name: 'waivesFeeInr', column: 'waives_fee_inr', type: 'number', min: 0, required: true },
    { name: 'notes', column: 'notes', type: 'string' },
  ],
});

registerRuleFamilyRoutes(app, adminRouteDeps, {
  urlSegment: 'card-benefits',
  tableName: 'card_benefits',
  auditEntity: 'card_benefit',
  fields: [
    { name: 'kind', column: 'kind', type: 'enum', values: BENEFIT_KINDS, required: true },
    { name: 'label', column: 'label', type: 'string', required: true },
    { name: 'description', column: 'description', type: 'string' },
    { name: 'quotaCount', column: 'quota_count', type: 'integer', min: 0 },
    { name: 'quotaPeriod', column: 'quota_period', type: 'enum', values: CAP_PERIODS },
    { name: 'networkProgram', column: 'network_program', type: 'string' },
    { name: 'valueEstimateInr', column: 'value_estimate_inr', type: 'number', min: 0 },
  ],
});

registerRuleFamilyRoutes(app, adminRouteDeps, {
  urlSegment: 'redemption-options',
  tableName: 'redemption_options',
  auditEntity: 'redemption_option',
  fields: [
    { name: 'programName', column: 'program_name', type: 'string', required: true },
    { name: 'method', column: 'method', type: 'string', required: true },
    { name: 'valuePerPointInr', column: 'value_per_point_inr', type: 'number', min: 0, required: true },
    { name: 'minPoints', column: 'min_points', type: 'integer', min: 0 },
    { name: 'notes', column: 'notes', type: 'string' },
  ],
});

registerRuleFamilyRoutes(app, adminRouteDeps, {
  urlSegment: 'forex-rules',
  tableName: 'forex_rules',
  auditEntity: 'forex_rule',
  singlePerCard: true,
  fields: [
    { name: 'markupPercent', column: 'markup_percent', type: 'number', min: 0, required: true },
    { name: 'gstOnMarkup', column: 'gst_on_markup', type: 'boolean' },
    { name: 'waiverNotes', column: 'waiver_notes', type: 'string' },
  ],
});

registerRuleFamilyRoutes(app, adminRouteDeps, {
  urlSegment: 'fuel-surcharge-rules',
  tableName: 'fuel_surcharge_rules',
  auditEntity: 'fuel_surcharge_rule',
  singlePerCard: true,
  fields: [
    { name: 'surchargePercent', column: 'surcharge_percent', type: 'number', min: 0 },
    { name: 'waiverPercent', column: 'waiver_percent', type: 'number', min: 0 },
    { name: 'minTxnInr', column: 'min_txn_inr', type: 'number', min: 0 },
    { name: 'maxTxnInr', column: 'max_txn_inr', type: 'number', min: 0 },
    { name: 'monthlyWaiverCap', column: 'monthly_waiver_cap', type: 'number', min: 0 },
  ],
});

registerRuleFamilyRoutes(app, adminRouteDeps, {
  urlSegment: 'billing-cycle-rules',
  tableName: 'billing_cycle_rules',
  auditEntity: 'billing_cycle_rule',
  singlePerCard: true,
  fields: [
    { name: 'gracePeriodDays', column: 'grace_period_days', type: 'integer', min: 0 },
    { name: 'cycleNotes', column: 'cycle_notes', type: 'string' },
  ],
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

/** GET /user-categories — private categories belonging to the current user. */
app.get('/user-categories', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT id, slug, name, parent_category_id AS "parentCategoryId",
                parent_user_category_id AS "parentUserCategoryId", match_terms AS "matchTerms"
           FROM user_categories
          WHERE profile_id = $1
          ORDER BY created_at, name COLLATE "C"`,
        [req.userId],
      ),
    );
    res.json({ categories: result.rows });
  } catch (err) {
    console.error('GET /user-categories error', err);
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
        'SELECT min_supported_version, maintenance_mode, maintenance_message, sms_backup_import_enabled FROM app_status WHERE id = true'
      )
    );
    const row = result.rows[0];
    res.json({
      minSupportedVersion: row?.min_supported_version ?? '1.0.0',
      maintenanceMode: row?.maintenance_mode ?? false,
      maintenanceMessage: row?.maintenance_message ?? null,
      // Task S-1b's kill switch. Fails OPEN (true) on a missing row, matching
      // this route's existing "a DB hiccup must not itself block the app"
      // stance — the flag exists to withdraw a feature deliberately, not to
      // have it disappear because a query came back empty.
      smsBackupImportEnabled: row?.sms_backup_import_enabled ?? true,
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
    if (_merchantSearchCache.size >= _MERCHANT_SEARCH_CACHE_MAX_ENTRIES) {
      const oldestKey = _merchantSearchCache.keys().next().value;
      if (oldestKey) _merchantSearchCache.delete(oldestKey);
    }
    _merchantSearchCache.set(cacheKey, {
      merchants: result.rows,
      expiresAt: now + _MERCHANT_SEARCH_CACHE_TTL_MS,
    });

    res.json({ merchants: result.rows });
  } catch (err) {
    console.error('GET /merchants/nearby error', err);
    // Nearby is an optional discovery surface. Keep the public contract
    // usable during a database/provider outage so the app can render an
    // honest empty state and retry instead of showing a generic exception.
    res.json({
      source: 'unavailable',
      merchants: [],
      unavailable: true,
      message: 'Nearby merchant data is temporarily unavailable. Please retry.',
    });
  }
});

/** Authenticated, Google Maps-backed foreground discovery. Coordinates stay
 * in the POST body so request logs never contain a user's precise location. */
app.post('/merchants/nearby/google', requireValidJwt, async (req, res) => {
  const lat = req.body?.lat;
  const lng = req.body?.lng;
  const radiusM = req.body?.radiusM === undefined ? 2000 : req.body.radiusM;
  if (!Number.isFinite(lat) || lat < -90 || lat > 90) {
    return res.status(400).json({ error: 'lat must be between -90 and 90' });
  }
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) {
    return res.status(400).json({ error: 'lng must be between -180 and 180' });
  }
  if (radiusM !== 2000) {
    return res.status(400).json({ error: 'radiusM must be 2000' });
  }
  const googleApiKey = process.env.GOOGLE_PLACES_API_KEY;
  try {
    const result = await nearbyGoogle.discoverNearby({
      lat,
      lng,
      radiusM,
      googleApiKey,
      fallbackDiscover: (params) => nearbyGoogleFallback.discover(params),
    });
    if (result.degraded) {
      console.warn('POST /merchants/nearby/google using fallback provider', {
        requestId: req.requestId,
      });
    }
    res.json(result);
  } catch (err) {
    console.warn('POST /merchants/nearby/google unavailable', {
      requestId: req.requestId,
      googleFailure: err.googleFailure?.name || 'unavailable',
      fallbackFailure: err.cause?.name || 'unavailable',
    });
    res.status(503).json({
      error: 'nearby_discovery_unavailable',
      unavailable: true,
      message: 'Nearby merchant lookup is temporarily unavailable. Please retry.',
    });
  }
});

/**
 * POST /merchants/nearby/discover — free, read-only nearby place discovery.
 *
 * This is the primary discovery path for the Nearby screen. Results are
 * OpenStreetMap candidates only by default; they are never treated as VPA-verified
 * merchants and are never inserted into spending or payment data by this route. Coordinates
 * stay in the request body so they do not appear in URL access logs. The GET
 * handler remains for compatibility with older app builds. The paid Google
 * provider is deliberately opt-in here (`NEARBY_DISCOVERY_USE_GOOGLE=true`);
 * the authenticated `/merchants/nearby/google` route remains the explicit
 * Google-backed path. Merely setting a Google key must not make every normal
 * nearby refresh billable.
 */
const nearbyDiscoveryHandler = async (req, res) => {
  const input = req.method === 'GET' ? req.query : req.body || {};
  const lat = Number(input.lat);
  const lng = Number(input.lng);
  const radiusM = input.radiusM !== undefined ? Number(input.radiusM) : 2000;
  const categoryId = typeof input.categoryId === 'string' && input.categoryId.trim()
    ? input.categoryId.trim().toLowerCase()
    : null;

  if (!Number.isFinite(lat) || lat < -90 || lat > 90) {
    return res.status(400).json({ error: 'lat is required and must be between -90 and 90' });
  }
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) {
    return res.status(400).json({ error: 'lng is required and must be between -180 and 180' });
  }
  if (!Number.isFinite(radiusM) || radiusM <= 0 || radiusM > 5000) {
    return res.status(400).json({ error: 'radiusM must be a positive number, max 5000' });
  }
  if (categoryId && !normalizeNearbyDiscoveryCategory(categoryId)) {
    return res.status(400).json({ error: 'unsupported categoryId' });
  }

  try {
    const googleApiKey = process.env.GOOGLE_PLACES_API_KEY;
    const useGoogleForGenericDiscovery =
      process.env.NEARBY_DISCOVERY_USE_GOOGLE === 'true';
    if (googleApiKey && useGoogleForGenericDiscovery) {
      const result = await nearbyGoogle.discoverNearby({
        lat,
        lng,
        radiusM,
        categoryId,
        googleApiKey,
        fallbackDiscover: (params) => nearbyDiscovery.discover(params),
      });
      return res.json({
        source: result.source,
        attribution: result.source === 'google_places' ? 'Google Places' : '© OpenStreetMap contributors',
        degraded: result.degraded === true,
        merchants: result.merchants,
      });
    }

    const merchants = await nearbyDiscovery.discover({ lat, lng, radiusM, categoryId });
    res.json({
      source: 'openstreetmap',
      attribution: '© OpenStreetMap contributors',
      merchants,
    });
  } catch (err) {
    // Do not turn a provider outage into a false "no merchants nearby" result.
    console.warn('Nearby place discovery unavailable', err.message);
    res.status(503).json({
      error: 'nearby_discovery_unavailable',
      message: 'The public nearby-place provider is temporarily unavailable',
    });
  }
};
app.get('/merchants/nearby/discover', nearbyDiscoveryHandler);
app.post('/merchants/nearby/discover', nearbyDiscoveryHandler);

/**
 * POST /merchants/nearby/search — a manual place lookup for testing the
 * location flow without depending on the handset's current GPS fix. The route
 * prefers published PandaPay directory matches and otherwise returns OSM
 * candidates; neither path writes to payment data. `lat`/`lng` are optional
 * and only bias the external search toward the tester's current area.
 * Coordinates are carried in the request body to keep them out of URL logs;
 * GET remains supported for older app builds.
 */
const nearbyPlaceSearchHandler = async (req, res) => {
  const input = req.method === 'GET' ? req.query : req.body || {};
  const query = typeof input.q === 'string' ? input.q.trim() : '';
  const lat = input.lat === undefined ? undefined : Number(input.lat);
  const lng = input.lng === undefined ? undefined : Number(input.lng);
  const radiusM = input.radiusM !== undefined ? Number(input.radiusM) : 5000;

  if (query.length < 2 || query.length > 120) {
    return res.status(400).json({ error: 'q must be between 2 and 120 characters' });
  }
  if (lat !== undefined && (!Number.isFinite(lat) || lat < -90 || lat > 90)) {
    return res.status(400).json({ error: 'lat must be between -90 and 90' });
  }
  if (lng !== undefined && (!Number.isFinite(lng) || lng < -180 || lng > 180)) {
    return res.status(400).json({ error: 'lng must be between -180 and 180' });
  }
  if ((lat === undefined) !== (lng === undefined)) {
    return res.status(400).json({ error: 'lat and lng must be supplied together' });
  }
  if (!Number.isFinite(radiusM) || radiusM <= 0 || radiusM > 50000) {
    return res.status(400).json({ error: 'radiusM must be between 1 and 50000' });
  }

  try {
    // Prefer the first-party directory. It is faster, works when public map
    // providers are rate-limited, and gives the user a verified PandaPay
    // merchant whenever one matches the typed name. The external provider is
    // still used below for places that are not in our directory yet.
    let directoryRows = [];
    try {
      const directory = await withUserClient(null, (client) =>
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
          [`%${query}%`],
        ),
      );
      directoryRows = directory.rows;
    } catch (directoryError) {
      // Map search is still useful when the directory is temporarily down.
      // The outer route catch should only represent failure of every source.
      console.warn('Nearby search directory unavailable', directoryError.message);
    }
    if (directoryRows.length > 0) {
      return res.json({
        source: 'pandapay',
        attribution: 'PandaPay published merchant directory',
        merchants: directoryRows.map((row) => ({
          ...row,
          source: 'published',
        })),
      });
    }

    const merchants = await nearbyDiscovery.search({ query, lat, lng, radiusM });
    res.json({
      source: 'openstreetmap',
      attribution: '© OpenStreetMap contributors',
      merchants,
    });
  } catch (err) {
    console.warn('Nearby place search unavailable', err.message);
    // Returning a valid empty payload is deliberate: this endpoint is a
    // best-effort place search, not a payment-critical operation. The app
    // can now always complete the request and present a retryable empty state
    // without inventing a merchant when every source is down.
    res.json({
      source: 'unavailable',
      merchants: [],
      unavailable: true,
      message: 'The public place search provider is temporarily unavailable',
    });
  }
};
app.get('/merchants/nearby/search', nearbyPlaceSearchHandler);
app.post('/merchants/nearby/search', nearbyPlaceSearchHandler);

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
app.post('/data-error-reports', optionalAuth, async (req, res) => {
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
          req.userId || null,
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
 * display name. Exact VPA resolution is exposed separately below because
 * scanned QR flows need an identifier lookup rather than fuzzy text search.
 * Public read, same is_published-only filter as
 * GET /merchants/nearby, same q ILIKE pattern as GET /admin/merchants but
 * without the admin gate. Each row is shaped like a /merchants/nearby
 * candidate (minus distance_meters, since search has no origin point) so
 * the app can feed results into the same NearbyMerchantCandidate/
 * bestCardForMerchantProvider machinery nearby_merchants_screen.dart
 * already uses, rather than a third parallel "merchant result" shape.
 */
/**
 * Sync — plan Phase 4. The producer/consumer for `change_log`, `sync_cursors`
 * and `sync_conflicts`, which 0005_sync.sql designed and nothing ever wrote to.
 *
 * All of the resolution logic lives in migration 0034's functions rather than
 * here, deliberately: a conflict rule split between SQL and JavaScript is a
 * rule nobody can reason about, and this is the subsystem where 0005's header
 * warns that "silent data loss during sync is the fastest way to lose a
 * finance user". These routes are transport.
 */

/**
 * POST /sync/register-device — exchanges a platform + label for the device id
 * every other sync call needs. Idempotent when given a known id.
 */
app.post('/sync/register-device', requireAuth, async (req, res) => {
  const { platform, label, appVersion, deviceId } = req.body || {};
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(`SELECT pandapay.register_sync_device($1, $2, $3, $4, $5) AS device_id`, [
        req.userId,
        typeof platform === 'string' ? platform : 'web',
        typeof label === 'string' ? label : null,
        typeof appVersion === 'string' ? appVersion : null,
        typeof deviceId === 'string' && deviceId ? deviceId : null,
      ])
    );
    res.status(201).json({ deviceId: result.rows[0].device_id });
  } catch (err) {
    console.error('POST /sync/register-device error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /notification-devices — registers the current user's FCM token with
 * the private notification service. The PandaPay access token is the only
 * credential the mobile app sends here; the notification-service project key
 * stays on this API server.
 */
app.post('/notification-devices', requireAuth, async (req, res) => {
  const { token, platform, email, displayName, timezone } = req.body || {};
  if (typeof token !== 'string' || token.trim().length < 10 || token.length > 4096) {
    return res.status(400).json({ error: 'A valid FCM token is required' });
  }
  if (platform != null && (typeof platform !== 'string' || platform.length > 40)) {
    return res.status(400).json({ error: 'platform is invalid' });
  }
  try {
    const result = await notificationService.registerDevice({
      subscriberId: req.userId,
      token: token.trim(),
      platform,
      email,
      displayName,
      timezone,
    });
    if (!result.configured) {
      return res.status(503).json({
        error: 'notification_service_not_configured',
        message: 'Remote push delivery is not configured on the API',
      });
    }
    res.status(201).json(result);
  } catch (err) {
    console.error('POST /notification-devices error', err);
    if (err?.code === 'notification_service_timeout') {
      return res.status(504).json({
        error: 'notification_service_timeout',
        message: 'The notification provider did not respond in time. Registration will retry automatically.',
      });
    }
    if (err?.code === 'notification_service_auth_failed') {
      return res.status(503).json({
        error: 'notification_service_auth_failed',
        message: 'The notification provider rejected the API key configured on the PandaPay server.',
      });
    }
    res.status(502).json({
      error: err?.code === 'notification_service_unavailable'
        ? 'notification_service_unavailable'
        : 'notification_service_error',
      message: 'The notification provider could not register this device. Registration will retry automatically.',
    });
  }
});

/**
 * POST /notifications/test — requests one real remote push to the current
 * user's registered device(s).
 *
 * The recipient is always req.userId. No subscriber/device id is accepted
 * from the request body, so an authenticated user cannot target another
 * account. Unlike the normal notification route, this waits for the private
 * provider's response and reports configuration/provider failures honestly;
 * a 202 means the provider accepted the request, not that Android has already
 * displayed it.
 */
app.post('/notifications/test', requireAuth, async (req, res) => {
  if (!notificationService.isConfigured()) {
    return res.status(503).json({
      error: 'notification_service_not_configured',
      message: 'Remote push delivery is not configured on the API',
    });
  }

  const limit = testNotificationLimiter.check(req.userId);
  if (!limit.allowed) {
    res.set('Retry-After', String(limit.retryAfterSeconds));
    return res.status(429).json({
      error: 'test_notification_rate_limited',
      retryAfterSeconds: limit.retryAfterSeconds,
    });
  }

  try {
    const dedupeKey = `pandapay-test:${req.userId}:${crypto.randomUUID()}`;
    await notificationService.send({
      subscriberId: req.userId,
      title: 'PandaPay test notification',
      body: 'Push notifications are working on this account.',
      category: 'general',
      severity: 'info',
      deepLink: '/notifications',
      dedupeKey,
    });
    testNotificationLimiter.mark(req.userId);
    return res.status(202).json({
      ok: true,
      requested: true,
      message: 'Push notification accepted for delivery to your registered devices',
    });
  } catch (err) {
    console.error('POST /notifications/test error', err);
    if (err?.code === 'notification_no_devices') {
      return res.status(409).json({
        error: 'notification_device_not_registered',
        message: 'No registered push device was found for this account',
      });
    }
    if (err?.code === 'notification_service_timeout') {
      return res.status(504).json({
        error: 'notification_service_timeout',
        message: 'The notification provider did not respond in time. Try again shortly.',
      });
    }
    if (err?.code === 'notification_service_auth_failed') {
      return res.status(503).json({
        error: 'notification_service_auth_failed',
        message: 'The notification provider rejected the API key configured on the PandaPay server.',
      });
    }
    return res.status(502).json({
      error: 'notification_service_unavailable',
      message: 'The notification provider could not accept the test notification.',
    });
  }
});

/**
 * POST /sync/push — applies a batch of local changes.
 *
 * Each change is applied in its OWN transaction (a savepoint per item), not
 * one transaction for the batch. That is the important design decision here:
 * with a single transaction, one malformed change — a bad enum, a category id
 * that no longer exists — rolls back every other change in the batch, and the
 * client has no way to tell which one was at fault. It would retry the whole
 * batch, fail identically, and the user's edits would never sync again. A
 * per-item savepoint means one bad change is reported as one bad change.
 *
 * The response is per-change and ordered to match the request, so the client
 * can drop exactly what succeeded from its outbox and keep the rest.
 */
app.post('/sync/push', requireAuth, async (req, res) => {
  const { deviceId, changes } = req.body || {};
  if (!deviceId || typeof deviceId !== 'string') {
    return res.status(400).json({ error: 'deviceId is required' });
  }
  if (!Array.isArray(changes)) {
    return res.status(400).json({ error: 'changes must be an array' });
  }
  if (changes.length > 200) {
    return res.status(413).json({ error: 'too many changes in one push' });
  }

  try {
    const results = await withUserClient(req.userId, async (client) => {
      const out = [];
      for (const change of changes) {
        const { entity, entityId, op, payload, fieldClocks, clientSeq } = change || {};
        if (!entity || !entityId || !['insert', 'update', 'delete'].includes(op)) {
          out.push({ clientSeq: clientSeq ?? null, applied: false, reason: 'malformed' });
          continue;
        }
        await client.query('SAVEPOINT sync_item');
        try {
          if (entity === 'user_categories' && op === 'insert') {
            const categoryResult = await client.query(
              `SELECT out_applied, out_reason
                 FROM pandapay.sync_insert_user_category(
                   $1, $2, $3, $4, $5, $6::uuid, $7::uuid, $8::text[], $9::jsonb, $10)`,
              [
                req.userId,
                deviceId,
                entityId,
                typeof payload?.name === 'string' ? payload.name : null,
                typeof payload?.slug === 'string' ? payload.slug : null,
                typeof payload?.parent_category_id === 'string' ? payload.parent_category_id : null,
                typeof payload?.parent_user_category_id === 'string' ? payload.parent_user_category_id : null,
                Array.isArray(payload?.match_terms) ? payload.match_terms.filter((term) => typeof term === 'string') : [],
                JSON.stringify(fieldClocks || {}),
                Number.isFinite(clientSeq) ? clientSeq : 0,
              ]
            );
            const categoryRow = categoryResult.rows[0];
            await client.query('RELEASE SAVEPOINT sync_item');
            out.push({
              clientSeq: clientSeq ?? null,
              entityId,
              applied: categoryRow.out_applied,
              conflicts: 0,
              reason: categoryRow.out_reason,
            });
            continue;
          }
          if (entity === 'user_merchant_category_rules') {
            const ruleResult = await client.query(
              `SELECT out_applied, out_conflicts, out_reason
                 FROM pandapay.sync_apply_user_merchant_category_rule(
                   $1, $2, $3, $4, $5::jsonb, $6
                 )`,
              [
                req.userId,
                deviceId,
                entityId,
                op,
                JSON.stringify(payload || {}),
                Number.isFinite(clientSeq) ? clientSeq : 0,
              ],
            );
            const ruleRow = ruleResult.rows[0];
            await client.query('RELEASE SAVEPOINT sync_item');
            out.push({
              clientSeq: clientSeq ?? null,
              entityId,
              applied: ruleRow.out_applied,
              conflicts: ruleRow.out_conflicts,
              reason: ruleRow.out_reason,
            });
            continue;
          }
          const r = await client.query(
            `SELECT out_applied, out_conflicts, out_reason
               FROM pandapay.sync_apply_change($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb, $8)`,
            [
              req.userId,
              deviceId,
              entity,
              entityId,
              op,
              JSON.stringify(payload || {}),
              JSON.stringify(fieldClocks || {}),
              Number.isFinite(clientSeq) ? clientSeq : 0,
            ]
          );
          const row = r.rows[0];
          // Offline transaction edits use this RPC rather than PATCH. Enforce
          // the same split invariant before accepting the item; a failure
          // rolls back the entire item, including its sync log/reward state.
          if (row.out_applied && entity === 'transactions' && payload?.amount_inr != null) {
            const splitCheck = await client.query(
              `SELECT t.amount_inr, COALESCE((SELECT SUM(s.amount_inr)
                 FROM transaction_splits s WHERE s.transaction_id=t.id), 0) AS split_total
                 FROM transactions t WHERE t.id=$1 AND t.profile_id=$2 FOR UPDATE`,
              [entityId, req.userId]
            );
            const checked = splitCheck.rows[0];
            if (checked && Math.round(Number(checked.split_total) * 100) > Math.round(Number(checked.amount_inr) * 100)) {
              throw new Error('amount is less than saved split shares; edit or clear the split first');
            }
          }
          await client.query('RELEASE SAVEPOINT sync_item');
          out.push({
            clientSeq: clientSeq ?? null,
            entityId,
            applied: row.out_applied,
            conflicts: row.out_conflicts,
            reason: row.out_reason,
          });
        } catch (itemErr) {
          await client.query('ROLLBACK TO SAVEPOINT sync_item');
          // The message, not the stack: a constraint violation names the
          // column the client got wrong, which is exactly what it needs in
          // order to stop resending it.
          out.push({
            clientSeq: clientSeq ?? null,
            entityId,
            applied: false,
            reason: 'rejected',
            detail: itemErr.message,
          });
        }
      }
      return out;
    });

    res.json({
      results,
      appliedCount: results.filter((r) => r.applied).length,
    });
  } catch (err) {
    console.error('POST /sync/push error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /sync/pull?deviceId=…&since=…
 *
 * Returns changes made by OTHER devices only, oldest first, with the highest
 * `server_seq` in the batch. The client applies them and then acknowledges —
 * it does not treat receiving them as having applied them, which is why the
 * cursor is not advanced here.
 */
app.get('/sync/pull', requireAuth, async (req, res) => {
  const deviceId = req.query.deviceId;
  if (!deviceId) return res.status(400).json({ error: 'deviceId is required' });
  const since = Number.parseInt(req.query.since, 10) || 0;
  const limit = Number.parseInt(req.query.limit, 10) || 500;

  try {
    const result = await withUserClient(req.userId, async (client) => {
      const changes = await client.query(
        `SELECT * FROM pandapay.sync_pull($1, $2, $3, $4)`,
        [req.userId, deviceId, since, limit]
      );
      const conflicts = await client.query(
        `SELECT id, entity, entity_id, field, local_value, server_value, chosen_value, created_at
           FROM sync_conflicts
          WHERE profile_id = $1 AND NOT user_acknowledged
          ORDER BY created_at DESC LIMIT 50`,
        [req.userId]
      );
      return { changes: changes.rows, conflicts: conflicts.rows };
    });

    const rows = result.changes;
    res.json({
      changes: rows,
      conflicts: result.conflicts,
      // `hasMore` rather than making the client infer it from the row count:
      // a batch that happens to be exactly `limit` long is indistinguishable
      // from a full one otherwise, and guessing wrong strands the tail.
      hasMore: rows.length === Math.min(Math.max(limit, 1), 1000),
      latestServerSeq: rows.length > 0 ? Number(rows[rows.length - 1].server_seq) : since,
    });
  } catch (err) {
    console.error('GET /sync/pull error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/** POST /sync/ack — the client confirms it applied everything up to serverSeq. */
app.post('/sync/ack', requireAuth, async (req, res) => {
  const { deviceId, serverSeq } = req.body || {};
  if (!deviceId || !Number.isFinite(serverSeq)) {
    return res.status(400).json({ error: 'deviceId and serverSeq are required' });
  }
  try {
    await withUserClient(req.userId, (client) =>
      client.query(`SELECT pandapay.sync_ack($1, $2, $3)`, [req.userId, deviceId, serverSeq])
    );
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /sync/ack error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/** POST /sync/conflicts/:id/acknowledge — F5's "I've seen this" action. */
app.post('/sync/conflicts/:id/acknowledge', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `UPDATE sync_conflicts SET user_acknowledged = true
          WHERE id = $1 AND profile_id = $2 RETURNING id`,
        [req.params.id, req.userId]
      )
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'not_found' });
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /sync/conflicts/:id/acknowledge error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /analytics/events — plan Phase 2.2. Batched first-party product
 * telemetry (migration 0032).
 *
 * `optionalAuth`, not `requireAuth`, and that is the whole reason the
 * activation funnel is measurable at all: `app_opened`, `onboarding_started`
 * and `onboarding_completed` happen before an account exists. Those rows land
 * with a null profile_id and are never back-filled once the user signs up —
 * retroactively attaching pre-account activity to an identity is exactly the
 * move this design is avoiding.
 *
 * Batched because the alternative is a network round trip per tap on a mobile
 * connection, which costs the user battery and data to answer the company's
 * questions. The client buffers and flushes.
 *
 * Always answers 202, even for events it rejected. Telemetry must never be a
 * reason a user-facing action appears to fail, and the client has nothing
 * useful to do with "event 3 of 12 had an unknown name" — that is a
 * development-time mistake, visible in the accepted count and in the funnel
 * view showing a permanent zero, not a runtime error to surface to a person
 * trying to add a card.
 */
const ANALYTICS_MAX_BATCH = 50;

app.post('/analytics/events', async (req, res) => {
  const events = (req.body || {}).events;
  if (!Array.isArray(events)) {
    return res.status(400).json({ error: 'events must be an array' });
  }

  const batch = events.slice(0, ANALYTICS_MAX_BATCH);
  try {
    const accepted = await withUserClient(req.userId, async (client) => {
      let count = 0;
      for (const e of batch) {
        if (!e || typeof e.event !== 'string') continue;
        const result = await client.query(
          `SELECT pandapay.record_analytics_event($1, $2, $3::jsonb, $4, $5) AS ok`,
          [
            req.userId,
            e.event,
            JSON.stringify(e.props && typeof e.props === 'object' ? e.props : {}),
            typeof e.appVersion === 'string' ? e.appVersion : null,
            typeof e.platform === 'string' ? e.platform : null,
          ]
        );
        if (result.rows[0].ok) count += 1;
      }
      return count;
    });
    res.status(202).json({ accepted, received: batch.length });
  } catch (err) {
    console.error('POST /analytics/events error', err);
    // Still 202. A telemetry outage must not turn into client-visible errors
    // or a retry storm against an already-struggling database.
    res.status(202).json({ accepted: 0, received: batch.length });
  }
});

/**
 * POST /partner-clicks — plan Phase 2.3. Records that this user tapped
 * "Apply" on a card and returns the URL to open.
 *
 * Returns a URL for the client to open rather than issuing a 302, because the
 * caller is a mobile app: it hands the destination to the OS browser, and a
 * redirect the in-app HTTP client follows would just load the issuer's page
 * into a JSON parser. It also means the app can show the user the real
 * destination before leaving.
 *
 * The commercial terms never cross this boundary. `record_partner_click()`
 * returns the decorated URL and the token, and nothing about payout model or
 * amount — the app has no business knowing what a click is worth, and a value
 * shipped to a client is a value that can be read out of the binary.
 */
app.post('/partner-clicks', requireAuth, async (req, res) => {
  const { cardProductId, placement } = req.body || {};
  if (!cardProductId || typeof cardProductId !== 'string') {
    return res.status(400).json({ error: 'cardProductId is required' });
  }
  try {
    const row = await withUserClient(req.userId, async (client) => {
      const out = await client.query(
        `SELECT out_url, out_click_token FROM pandapay.record_partner_click($1, $2, $3)`,
        [req.userId, cardProductId, typeof placement === 'string' ? placement : null]
      );
      return out.rows[0];
    });
    // No row means the card has no apply_url. A 404 rather than an invented
    // destination — sending a user to a guessed issuer page would be worse
    // than telling the app there isn't one.
    if (!row) return res.status(404).json({ error: 'no_apply_url' });
    res.status(201).json({ url: row.out_url, clickToken: row.out_click_token });
  } catch (err) {
    console.error('POST /partner-clicks error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /partner-conversions/webhook — the affiliate network's postback.
 *
 * Authenticated by a shared secret, exactly like
 * `POST /inbound-emails/webhook`: there is no user JWT on this request, and
 * the caller is a third-party server. Uses the pool directly rather than
 * `withUserClient` for the same reason — there is no `app.user_id` to set,
 * and `partner_conversions` is admin-RLS, so this runs as the owner.
 *
 * `ON CONFLICT DO UPDATE` on (click_token, external_ref) rather than a plain
 * insert: affiliate networks retry postbacks, and they legitimately re-send
 * the same conversion when its status changes (pending → approved →
 * reversed). Treating a retry as a new conversion would inflate reported
 * revenue, which is the one number here nobody should be able to get wrong by
 * accident.
 *
 * An unknown click_token is accepted with 202 rather than rejected. It means
 * the token was never issued by us — a partner misconfiguration or a probe —
 * and answering 4xx would let a caller enumerate which tokens are real.
 */
app.post('/partner-conversions/webhook', async (req, res) => {
  const secret = config.partnerWebhookSecret;
  if (!secret) {
    console.error('POST /partner-conversions/webhook: PARTNER_WEBHOOK_SECRET is not configured');
    return res.status(503).json({ error: 'webhook_not_configured' });
  }
  const provided = req.get('x-partner-signature') || '';
  // Constant-time compare. The lengths must match first — timingSafeEqual
  // throws on a length mismatch, which would itself be a timing signal.
  const ok =
    provided.length === secret.length &&
    crypto.timingSafeEqual(Buffer.from(provided), Buffer.from(secret));
  if (!ok) return res.status(401).json({ error: 'invalid_signature' });

  const { clickToken, status, commissionInr, externalRef } = req.body || {};
  const ALLOWED = ['pending', 'approved', 'rejected', 'reversed'];
  if (!clickToken || typeof clickToken !== 'string') {
    return res.status(400).json({ error: 'clickToken is required' });
  }
  if (status && !ALLOWED.includes(status)) {
    return res.status(400).json({ error: `status must be one of ${ALLOWED.join(', ')}` });
  }

  try {
    const click = await pool.query(
      `SELECT partner_program_id FROM partner_clicks WHERE click_token = $1`,
      [clickToken]
    );
    if (click.rows.length === 0) {
      return res.status(202).json({ ok: true, matched: false });
    }

    await pool.query(
      `INSERT INTO partner_conversions
            (click_token, partner_program_id, status, commission_inr, external_ref, raw_payload)
          VALUES ($1, $2, $3, $4, $5, $6::jsonb)
     ON CONFLICT (click_token, external_ref) DO UPDATE
            SET status         = excluded.status,
                commission_inr = excluded.commission_inr,
                raw_payload    = excluded.raw_payload,
                reported_at    = now()`,
      [
        clickToken,
        click.rows[0].partner_program_id,
        status || 'pending',
        Number.isFinite(commissionInr) ? commissionInr : null,
        typeof externalRef === 'string' ? externalRef : null,
        JSON.stringify(req.body || {}),
      ]
    );
    res.status(202).json({ ok: true, matched: true });
  } catch (err) {
    console.error('POST /partner-conversions/webhook error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /acceptance-reports — plan Phase 2.1. "Did this card actually work
 * here?", the one dataset in this product that cannot be scraped, bought, or
 * inferred: it only exists because someone was standing at the till.
 *
 * Until migration 0029 there was no write path to `acceptance_reports` at all
 * — not in this file, not in the scraper, not even in the seeds — so the
 * console's acceptance-rate monitor, the publication gate, and
 * `GET /my-contributions` have all been reading permanently empty tables.
 *
 * Everything privacy-relevant happens inside
 * `pandapay.submit_acceptance_report()`, deliberately, and this route is thin
 * on purpose. It passes `req.userId` in; the function checks
 * `contributions_opt_in`, converts the id to a monthly-rotating salted hash,
 * enforces the daily quota, and stores only the hash. No profile id, no
 * amount, no timestamp finer than a date, and coordinates snapped to the 4dp
 * grid ever reach these tables — which is what keeps the deploy-blocking
 * `run_anonymization_audit()` gate green. Putting any of that logic here
 * instead would mean a future caller could skip it.
 *
 * 403 rather than 400 for `not_opted_in`: the request is well-formed, the
 * user simply hasn't agreed to contribute, and the client needs to tell those
 * apart to know whether to show the opt-in prompt.
 */
// CARD_NETWORKS is already declared above (POST /card-requests uses the same
// `card_network` enum); reusing it rather than shadowing keeps one definition
// of what the database will accept.
const ACCEPTANCE_RESULTS = ['accepted', 'declined', 'not_supported', 'unknown'];
const TXN_RAILS = ['upi_qr', 'swipe', 'online', 'contactless', 'atm', 'emi', 'unknown'];

app.post('/acceptance-reports', requireAuth, async (req, res) => {
  const { vpa, displayName, network, rail, result, gridLat, gridLng, appVersion } = req.body || {};

  if (!vpa || typeof vpa !== 'string') {
    return res.status(400).json({ error: 'vpa is required' });
  }
  if (!CARD_NETWORKS.includes(network)) {
    return res.status(400).json({ error: `network must be one of ${CARD_NETWORKS.join(', ')}` });
  }
  if (!TXN_RAILS.includes(rail)) {
    return res.status(400).json({ error: `rail must be one of ${TXN_RAILS.join(', ')}` });
  }
  if (!ACCEPTANCE_RESULTS.includes(result)) {
    return res.status(400).json({ error: `result must be one of ${ACCEPTANCE_RESULTS.join(', ')}` });
  }

  try {
    const row = await withUserClient(req.userId, async (client) => {
      const out = await client.query(
        `SELECT out_merchant_id, out_accepted, out_reason
           FROM pandapay.submit_acceptance_report($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
        [
          req.userId,
          vpa,
          typeof displayName === 'string' ? displayName : null,
          network,
          rail,
          result,
          Number.isFinite(gridLat) ? gridLat : null,
          Number.isFinite(gridLng) ? gridLng : null,
          typeof appVersion === 'string' ? appVersion : null,
        ]
      );
      return out.rows[0];
    });

    if (!row || !row.out_accepted) {
      const reason = (row && row.out_reason) || 'rejected';
      const status = reason === 'not_opted_in' ? 403 : reason === 'quota_exceeded' ? 429 : 400;
      return res.status(status).json({ error: reason });
    }
    res.status(201).json({ merchantId: row.out_merchant_id });
  } catch (err) {
    console.error('POST /acceptance-reports error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

// Server-side in-memory cache for merchant search queries
const _merchantSearchCache = new Map();
const _MERCHANT_SEARCH_CACHE_TTL_MS = 15 * 60 * 1000; // 15 minutes
const _MERCHANT_SEARCH_CACHE_MAX_ENTRIES = 500;

app.get('/merchants/search', async (req, res) => {
  const q = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  if (q.length === 0) {
    return res.status(400).json({ error: 'q is required' });
  }

  // Set HTTP Cache-Control header so clients/proxies can cache for 5 minutes
  res.set('Cache-Control', 'public, max-age=300');

  const cacheKey = `${req.user ? req.user.profile_id : 'anon'}:${q.toLowerCase()}`;
  const cached = _merchantSearchCache.get(cacheKey);
  const now = Date.now();
  if (cached && cached.expiresAt > now) {
    return res.json({ merchants: cached.merchants });
  }

  try {
    const result = await withUserClient(req.user || null, (client) =>
      client.query(
        `WITH published AS (
           SELECT m.id::text AS merchant_id, m.display_name, m.category_id::text, m.confidence::text,
                  l.grid_lat, l.grid_lng, 1 AS source_priority, m.confirmation_count
             FROM merchants m
             LEFT JOIN LATERAL (
               SELECT grid_lat, grid_lng FROM merchant_locations
                WHERE merchant_id = m.id ORDER BY confirmation_count DESC LIMIT 1
             ) l ON true
            WHERE m.is_published = true AND (m.display_name ILIKE $1 OR m.vpa ILIKE $1)
         ),
         user_txns AS (
           SELECT ('txn-' || md5(t.merchant_name)) AS merchant_id,
                  t.merchant_name AS display_name,
                  t.category_id::text,
                  'high'::text AS confidence,
                  NULL::numeric AS grid_lat,
                  NULL::numeric AS grid_lng,
                  2 AS source_priority,
                  COUNT(*)::int AS confirmation_count
             FROM transactions t
            WHERE t.merchant_name IS NOT NULL
              AND t.merchant_name ILIKE $1
            GROUP BY t.merchant_name, t.category_id
         ),
         category_rules AS (
           SELECT ('mcr-' || mcr.id::text) AS merchant_id,
                  initcap(mcr.pattern) AS display_name,
                  mcr.category_id::text,
                  'high'::text AS confidence,
                  NULL::numeric AS grid_lat,
                  NULL::numeric AS grid_lng,
                  3 AS source_priority,
                  5 AS confirmation_count
             FROM merchant_category_rules mcr
            WHERE mcr.is_active = true
              AND mcr.pattern ILIKE $1
         ),
         combined AS (
           SELECT * FROM published
           UNION ALL
           SELECT * FROM user_txns WHERE REGEXP_REPLACE(LOWER(display_name), '[^a-z0-9]', '', 'g') NOT IN (
             SELECT REGEXP_REPLACE(LOWER(display_name), '[^a-z0-9]', '', 'g') FROM published WHERE display_name IS NOT NULL
           )
           UNION ALL
           SELECT * FROM category_rules WHERE REGEXP_REPLACE(LOWER(display_name), '[^a-z0-9]', '', 'g') NOT IN (
             SELECT REGEXP_REPLACE(LOWER(display_name), '[^a-z0-9]', '', 'g') FROM published WHERE display_name IS NOT NULL
             UNION
             SELECT REGEXP_REPLACE(LOWER(display_name), '[^a-z0-9]', '', 'g') FROM user_txns WHERE display_name IS NOT NULL
           )
         )
         SELECT merchant_id, display_name, category_id, confidence, grid_lat, grid_lng
           FROM combined
          ORDER BY source_priority ASC, confirmation_count DESC
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
 * GET /merchants/resolve?vpa=... — exact published merchant lookup for QR
 * scans. This is public directory data only; no payment is initiated here.
 * Keeping this keyed by VPA lets the app use an acquiring-bank/MCC-backed
 * category when the QR contains no MCC or only a provider-generic name.
 */
app.get('/merchants/resolve', async (req, res) => {
  const vpa = typeof req.query.vpa === 'string'
    ? req.query.vpa.trim().toLowerCase()
    : '';
  if (vpa.length === 0 || vpa.length > 255 || !vpa.includes('@')) {
    return res.status(400).json({ error: 'valid vpa is required' });
  }

  try {
    const result = await withUserClient(null, (client) =>
      client.query(
        `SELECT m.id AS merchant_id, m.vpa, m.display_name, m.mcc,
                m.category_id, sc.name AS category_name, sc.slug AS category_slug,
                m.confidence, m.confidence_score, m.confirmation_count, m.is_p2p,
                m.mcc_operator_verified
           FROM merchants m
           LEFT JOIN spend_categories sc ON sc.id = m.category_id
          WHERE m.is_published = true AND m.vpa = $1
          LIMIT 1`,
        [vpa],
      ),
    );
    res.json({ merchant: result.rows[0] || null });
  } catch (err) {
    console.error('GET /merchants/resolve error', err);
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
                uc.created_at, uc.statement_day, uc.due_day,
                uc.statement_day_source, uc.due_day_source, uc.opened_on,
                uc.credit_limit_inr, uc.annual_fee_override_inr, uc.anniversary_on, uc.is_archived, uc.last4,
                uc.points_balance, uc.points_balance_state, uc.autopay_mode,
                cp.name AS card_name, cp.network, cp.card_type, cp.is_upi_linkable
           FROM user_cards uc
           JOIN card_products cp ON cp.id = uc.card_product_id
          WHERE ($1::boolean OR uc.is_archived = false)
          ORDER BY uc.sort_order, uc.created_at`,
        [includeArchived]
      );

      // Cap, milestone, points and fee-waiver data enrich the wallet, but
      // none is required to show the user's cards. Keep this repair and the
      // enrichment reads behind a savepoint: any SQL error aborts a Postgres
      // transaction, so a JS catch without rollback-to-savepoint would still
      // make the rest of this request fail at COMMIT.
      for (const card of cards.rows) {
        card.cap_states = [];
        card.milestone_states = [];
        card.total_points_earned = Number(card.points_balance || 0);
        card.fee_waiver_states = [];
      }

      await client.query('SAVEPOINT user_cards_enrichment');
      try {
        // Rebuild derived current-period cap state from the canonical ledger.
        // The SMS attribution repair remains an explicit reconciliation task.
        await reconcileCurrentCapStates(client, req.userId);

        for (const card of cards.rows) {
          const capStates = await client.query(
            `SELECT cap_rule_id, consumed, cap_value_snapshot FROM cap_states
              WHERE user_card_id = $1 AND period_start <= CURRENT_DATE AND period_end >= CURRENT_DATE`,
            [card.id]
          );
          const milestoneStates = await client.query(
            `SELECT milestone_rule_id, qualified_spend, period_end FROM milestone_states
              WHERE user_card_id = $1 AND period_start <= CURRENT_DATE AND period_end >= CURRENT_DATE`,
            [card.id]
          );
          card.cap_states = capStates.rows;
          card.milestone_states = milestoneStates.rows;

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
        await client.query('RELEASE SAVEPOINT user_cards_enrichment');
      } catch (enrichmentError) {
        await client.query('ROLLBACK TO SAVEPOINT user_cards_enrichment');
        await client.query('RELEASE SAVEPOINT user_cards_enrichment');
        console.warn('GET /user-cards enrichment unavailable', enrichmentError.message);
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
  const { cardProductId, nickname, last4 } = req.body || {};
  const normalizedLast4 = normalizeCardLast4(last4);
  if (!cardProductId || typeof cardProductId !== 'string') {
    return res.status(400).json({ error: 'cardProductId is required' });
  }
  // Four digits or nothing. Validated here as well as by the column CHECK so
  // the caller gets a clear 400 rather than a 500 from a constraint
  // violation — and so this route can never be the way a longer number
  // reaches a column that must only ever hold a matching key.
  if (normalizedLast4 !== null && !/^[0-9]{4}$/.test(normalizedLast4)) {
    return res.status(400).json({ error: 'last4 must be exactly 4 digits' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      // Serialize adds for the same account/product pair. The UI performs a
      // fast local duplicate check, but this transaction-level lock is the
      // authoritative guard for two scans/taps racing each other.
      await client.query(
        'SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))',
        [req.userId, cardProductId],
      );
      const card = await client.query(
        `SELECT id, issuer_id, card_type
           FROM card_products
          WHERE id = $1 AND status = 'published'`,
        [cardProductId]
      );
      if (card.rows.length === 0) return null;

      // Serialize physical-card adds as well as product adds. This closes the
      // race where two catalogue variants for the same bank card are tapped
      // at nearly the same time.
      await client.query(
        `SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))`,
        [`card-identity:${req.userId}:${card.rows[0].issuer_id || ''}:${card.rows[0].card_type || ''}:${normalizedLast4 || ''}`],
      );

      const existing = await client.query(
        `SELECT uc.id, uc.card_product_id, uc.nickname, uc.last4,
                uc.is_default, uc.sort_order, uc.created_at,
                 uc.is_archived, cp.name AS card_name,
                 cp.issuer_id, cp.card_type
           FROM user_cards uc
           JOIN card_products cp ON cp.id = uc.card_product_id
          WHERE uc.profile_id = $1 AND uc.is_archived = false
          ORDER BY uc.created_at ASC, uc.id ASC`,
        [req.userId],
      );
      const conflict = findCardAddConflict(existing.rows, {
        cardProductId,
        last4: normalizedLast4,
        issuerId: card.rows[0].issuer_id,
        cardType: card.rows[0].card_type,
      });
      if (conflict?.kind === 'already_present') {
        return { alreadyPresent: true, userCard: conflict.userCard };
      }
      if (conflict?.kind === 'link_existing') {
        const linked = await client.query(
          `UPDATE user_cards
              SET last4 = $1,
                  nickname = COALESCE(NULLIF($2, ''), nickname)
            WHERE id = $3 AND profile_id = $4 AND is_archived = false
            RETURNING id, card_product_id, nickname, last4, is_default, sort_order, created_at`,
          [normalizedLast4, nickname || null, conflict.userCard.id, req.userId],
        );
        if (linked.rows.length > 0) {
          await repairSmsHistory(client, req.userId, {
            reviewCrossSource: true, reviewCardId: linked.rows[0].id,
          });
          return { linkedExisting: true, userCard: linked.rows[0] };
        }
      }

      const inserted = await client.query(
        `INSERT INTO user_cards (profile_id, card_product_id, nickname, last4)
         VALUES ($1, $2, $3, $4)
         RETURNING id, card_product_id, nickname, last4, is_default, sort_order, created_at`,
        [req.userId, cardProductId, nickname || null, normalizedLast4]
      );
      // When SMS history arrived before the user added this card, repair
      // attribution in the same transaction so Spending stops showing the
      // matching suffix as "unlinked" immediately after card creation.
      // A camera/manual add has no reliable card suffix, so there is nothing
      // for repairSmsHistory to match and the full repair scan only adds
      // latency. Discovery/import paths that know the suffix still get the
      // immediate attribution repair.
      if (inserted.rows.length > 0 && normalizedLast4) {
        await repairSmsHistory(client, req.userId, {
          reviewCrossSource: true, reviewCardId: inserted.rows[0].id,
        });
      }
      return inserted.rows[0];
    });

    if (!result) return res.status(404).json({ error: 'card_product not found or not published' });
    if (result.alreadyPresent) {
      return res.status(409).json({
        error: 'card_already_added',
        message: 'This card is already in your wallet.',
        userCard: result.userCard,
      });
    }
    if (result.linkedExisting) {
      return res.status(200).json({ userCard: result.userCard, linkedExisting: true });
    }
    res.status(201).json({ userCard: result });
  } catch (err) {
    if (err && err.code === '23505' && err.constraint === 'uq_user_cards_active_identity') {
      return res.status(409).json({
        error: 'card_already_added',
        message: 'This physical card is already in your wallet.',
      });
    }
    console.error('POST /user-cards error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /user-cards/import — plan Phase 1.2. Hands a guest's on-device
 * wallet to the account they just created or signed into.
 *
 * Guest mode (`POST /auth/guest-login` in auth/) issues a random UUID with,
 * in that route's own words, "NO DATABASE RECORD" — a guest's cards live
 * only in the client's `local_user_cards` sqlite table. Until this route,
 * nothing carried them across, so a guest who spent time building a wallet
 * and then signed up watched it vanish at exactly the moment they committed
 * to the product. That is the single worst place in the funnel for silent
 * data loss, which is why this exists.
 *
 * IDEMPOTENT BY PHYSICAL CARD IDENTITY (issuer + instrument type + last four)
 * when catalogue metadata is available, with product + last four as the
 * fallback. It is not keyed by a client-supplied id. The client cannot
 * distinguish "the request timed out" from "the request succeeded and the
 * response was lost", so a retry has to be safe; and a guest id like
 * `local_1723...` means nothing to this database, so it can't be a dedupe
 * key without a new column to store it in. Instead, a card product the
 * profile already owns is skipped and reported as `already_present`.
 *
 * The honest cost of that choice: a user who genuinely holds two of the same
 * product gets one row, not two. That is a rare case, it is visible and
 * fixable in one tap from Add Card, and it is strictly better than the
 * alternative failure — a retry silently doubling someone's entire wallet,
 * which is neither visible nor obviously fixable.
 *
 * Partial success is a real outcome, reported per card rather than collapsed
 * into one status: an unpublished or unknown `cardProductId` (a guest can
 * hold a card that has since been unpublished) must not fail the other nine.
 */
app.post('/user-cards/import', requireAuth, async (req, res) => {
  const cards = (req.body || {}).cards;
  if (!Array.isArray(cards)) {
    return res.status(400).json({ error: 'cards must be an array' });
  }
  if (cards.length === 0) {
    return res.json({ results: [], importedCount: 0 });
  }
  if (cards.length > 100) {
    return res.status(413).json({ error: 'too many cards in one import' });
  }

  try {
    const results = await withUserClient(req.userId, async (client) => {
      // One read up front rather than a per-card existence query: the set of
      // products this profile already owns can't change inside the
      // transaction, and this also lets `isDefault` below be decided from
      // the true "did they have any cards at all before this import" state.
      const existing = await client.query(
        `SELECT uc.id, uc.card_product_id, uc.last4, uc.is_archived,
                cp.issuer_id, cp.card_type
           FROM user_cards uc
           JOIN card_products cp ON cp.id = uc.card_product_id
          WHERE uc.profile_id = $1 AND uc.is_archived = false`,
        [req.userId]
      );
      const existingCards = existing.rows;
      const owned = new Set(existingCards.map((r) => cardIdentityKey(r.card_product_id, r.last4)));
      const hadNoCards = existingCards.length === 0;

      const maxOrder = await client.query(
        `SELECT COALESCE(MAX(sort_order), 0) AS m FROM user_cards WHERE profile_id = $1`,
        [req.userId]
      );
      let nextOrder = Number(maxOrder.rows[0].m);
      let firstImportedId = null;
      const out = [];

      for (const card of cards) {
        const cardProductId = card && card.cardProductId;
        const localId = (card && card.localId) || null;
        const importedLast4 = normalizeCardLast4(card && card.last4);
        if (!cardProductId || typeof cardProductId !== 'string') {
          out.push({ localId, status: 'invalid' });
          continue;
        }
        if (importedLast4 !== null && !/^[0-9]{4}$/.test(importedLast4)) {
          out.push({ localId, cardProductId, status: 'invalid_last4' });
          continue;
        }
        const product = await client.query(
          `SELECT id, issuer_id, card_type
             FROM card_products
            WHERE id = $1 AND status = 'published'`,
          [cardProductId]
        );
        if (product.rows.length === 0) {
          out.push({ localId, cardProductId, status: 'unknown_product' });
          continue;
        }

        const identityKey = cardIdentityKey(cardProductId, importedLast4);
        const conflict = findCardAddConflict(existingCards, {
          cardProductId,
          last4: importedLast4,
          issuerId: product.rows[0].issuer_id,
          cardType: product.rows[0].card_type,
        });
        if (conflict?.kind === 'already_present' || owned.has(identityKey)) {
          out.push({
            localId,
            cardProductId,
            last4: importedLast4,
            status: 'already_present',
            userCard: conflict?.userCard || null,
          });
          continue;
        }
        if (conflict?.kind === 'link_existing') {
          const linked = await client.query(
            `UPDATE user_cards
                SET last4 = $1
              WHERE id = $2 AND profile_id = $3 AND is_archived = false
              RETURNING id, card_product_id, nickname, last4, is_default, is_archived, sort_order, created_at`,
            [importedLast4, conflict.userCard.id, req.userId],
          );
          if (linked.rows.length > 0) {
            existingCards.push({
              ...conflict.userCard,
              last4: importedLast4,
            });
            owned.add(identityKey);
            out.push({
              localId,
              cardProductId,
              last4: importedLast4,
              status: 'already_present',
              userCard: linked.rows[0],
            });
            continue;
          }
        }

        nextOrder += 1;
        const inserted = await client.query(
          `INSERT INTO user_cards (profile_id, card_product_id, nickname, last4, is_archived, sort_order)
                VALUES ($1, $2, $3, $4, $5, $6)
             RETURNING id, card_product_id, nickname, last4, is_default, is_archived, sort_order, created_at`,
          [
            req.userId,
            cardProductId,
            typeof card.nickname === 'string' && card.nickname.trim() !== '' ? card.nickname : null,
            importedLast4,
            card.isArchived === true,
            nextOrder,
          ]
        );
        if (card.isArchived !== true) owned.add(identityKey);
        existingCards.push({
          id: inserted.rows[0].id,
          card_product_id: cardProductId,
          last4: importedLast4,
          is_archived: card.isArchived === true,
          issuer_id: product.rows[0].issuer_id,
          card_type: product.rows[0].card_type,
        });
        if (firstImportedId === null && card.isArchived !== true) {
          firstImportedId = inserted.rows[0].id;
        }
        out.push({ localId, cardProductId, last4: importedLast4, status: 'imported', userCard: inserted.rows[0] });
      }

      // Default card: only ever set when the account had none before, and
      // only from the guest's own choice — never overriding a default an
      // existing account already has, which would silently change what the
      // Home screen recommends first for a returning user.
      if (hadNoCards && firstImportedId !== null) {
        const guestDefault = cards.find((c) => c && c.isDefault === true && c.cardProductId);
        let targetId = firstImportedId;
        if (guestDefault) {
          const match = out.find(
            (r) => r.status === 'imported' && r.cardProductId === guestDefault.cardProductId
          );
          if (match) targetId = match.userCard.id;
        }
        await client.query(
          `UPDATE user_cards SET is_default = (id = $2) WHERE profile_id = $1`,
          [req.userId, targetId]
        );
      }

      return out;
    });

    res.status(201).json({
      results,
      importedCount: results.filter((r) => r.status === 'imported').length,
    });
  } catch (err) {
    console.error('POST /user-cards/import error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /user-cards/:id/archive — R4: "archive, never delete." There is
 * deliberately no DELETE /user-cards/:id route.
 */
app.post('/user-cards/:id/archive', requireAuth, async (req, res) => {
  try {
    // Commit the user-visible card mutation independently. SMS-history repair
    // is valuable, but it is a secondary reconciliation pass and must not
    // turn a successful archive into a failed request if its larger scan hits
    // a transient database or data-shape problem.
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `UPDATE user_cards SET is_archived = true, archived_at = now()
          WHERE id = $1 AND profile_id = $2
          RETURNING id`,
        [req.params.id, req.userId]
      )
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'user_card not found' });

    try {
      await withUserClient(req.userId, (client) => repairSmsHistory(client, req.userId));
    } catch (repairError) {
      console.error('POST /user-cards/:id/archive repair warning', repairError);
    }
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /user-cards/:id/archive error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /user-cards/:id/default — design 23 "Card actions": set as default.
 * A dedicated route rather than a PATCH field because only one card per
 * profile may be default, so this is two statements (clear the old, set the
 * new) that must not half-apply — hence the explicit transaction, not the
 * generic single-UPDATE PATCH above.
 */
app.post('/user-cards/:id/default', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const owns = await client.query(
        `SELECT id FROM user_cards WHERE id = $1 AND profile_id = $2 AND is_archived = false`,
        [req.params.id, req.userId]
      );
      if (owns.rows.length === 0) return null;
      await client.query(`UPDATE user_cards SET is_default = false WHERE profile_id = $1 AND is_default = true`, [
        req.userId,
      ]);
      return client.query(
        `UPDATE user_cards SET is_default = true WHERE id = $1 AND profile_id = $2 RETURNING id, is_default`,
        [req.params.id, req.userId]
      );
    });
    if (!result) return res.status(404).json({ error: 'user_card not found' });
    res.json({ userCard: result.rows[0] });
  } catch (err) {
    console.error('POST /user-cards/:id/default error', err);
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
    const result = await withUserClient(req.userId, async (client) => {
      const target = await client.query(
        `SELECT uc.id, uc.last4, uc.is_archived, cp.issuer_id, cp.card_type
           FROM user_cards uc
           JOIN card_products cp ON cp.id = uc.card_product_id
          WHERE uc.id = $1 AND uc.profile_id = $2`,
        [req.params.id, req.userId],
      );
      if (target.rows.length === 0) return { notFound: true };
      const card = target.rows[0];
      if (!card.is_archived) return { alreadyActive: true };
      if (card.last4) {
        const conflict = await client.query(
          `SELECT uc.id, uc.card_product_id, uc.last4, cp.name AS card_name
             FROM user_cards uc
             JOIN card_products cp ON cp.id = uc.card_product_id
            WHERE uc.profile_id = $1
              AND uc.is_archived = false
              AND uc.id <> $2
              AND uc.last4 = $3
              AND cp.issuer_id = $4
              AND cp.card_type = $5
            LIMIT 1`,
          [req.userId, req.params.id, card.last4, card.issuer_id, card.card_type],
        );
        if (conflict.rows.length > 0) return { conflict: conflict.rows[0] };
      }
      return client.query(
        `UPDATE user_cards SET is_archived = false, archived_at = NULL
          WHERE id = $1 AND profile_id = $2
          RETURNING id`,
        [req.params.id, req.userId]
      );
    });
    if (result.notFound) return res.status(404).json({ error: 'user_card not found' });
    if (result.alreadyActive) return res.json({ ok: true });
    if (result.conflict) {
      return res.status(409).json({
        error: 'card_already_added',
        message: 'An active card with the same issuer, type, and last four is already in your wallet.',
        userCard: result.conflict,
      });
    }
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
  annualFeeOverrideInr: 'annual_fee_override_inr',
  autopayMode: 'autopay_mode',
  // Migration 0039: the matching key that lets an incoming bank SMS/email
  // be attached to this card without asking the user which one it was.
  last4: 'last4',
};

/** Mirrors the CHECK constraint in migration 0027. */
const AUTOPAY_MODES = ['off', 'minimum', 'full'];

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
  // Validated and normalized BEFORE the value list is built, since the loop
  // below copies straight out of `body` — a check placed after it would
  // have already let the raw value through.
  if ('last4' in body && body.last4 !== null && body.last4 !== '' && !/^[0-9]{4}$/.test(String(body.last4))) {
    return res.status(400).json({ error: 'last4 must be exactly 4 digits' });
  }
  // An empty string is how a cleared text field arrives; store it as NULL so
  // "no last4" is one value, not two.
  if (body.last4 === '') body.last4 = null;

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
  // A statement/due day typed here is user-owned: card_day_sources migration
  // — never overwritten by a later SMS heal while set. Clearing the day
  // clears its source with it (a NULL value is not owned by anyone).
  if ('statementDay' in body) {
    sets.push(body.statementDay === null ? `statement_day_source = NULL` : `statement_day_source = 'user'`);
  }
  if ('dueDay' in body) {
    sets.push(body.dueDay === null ? `due_day_source = NULL` : `due_day_source = 'user'`);
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
  if (body.annualFeeOverrideInr !== undefined && body.annualFeeOverrideInr !== null) {
    const fee = Number(body.annualFeeOverrideInr);
    if (!Number.isFinite(fee) || fee < 0) {
      return res.status(400).json({ error: 'annualFeeOverrideInr must be a non-negative number' });
    }
  }
  // Rejected here as a 400 rather than left to the CHECK constraint, which
  // would surface as an opaque 500. autopay_mode is NOT NULL, so an
  // explicit null is a client bug too, not "clear it".
  if ('autopayMode' in body && !AUTOPAY_MODES.includes(body.autopayMode)) {
    return res.status(400).json({ error: `autopayMode must be one of ${AUTOPAY_MODES.join(', ')}` });
  }

  values.push(req.params.id, req.userId);
  const idParam = values.length - 1;
  const profileParam = values.length;

  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `UPDATE user_cards SET ${sets.join(', ')}
          WHERE id = $${idParam} AND profile_id = $${profileParam} AND is_archived = false
          RETURNING id, nickname, credit_limit_inr, annual_fee_override_inr, statement_day, due_day, points_balance,
                    points_balance_state, autopay_mode, last4`,
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
  const { newBalance, expiresOn, reason } = req.body || {};
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

      const adjustmentReason = typeof reason === 'string' && reason.trim()
        ? reason.trim().slice(0, 160)
        : 'manual correction';
      const inserted = await client.query(
        `INSERT INTO points_ledger (profile_id, user_card_id, delta_points, reason, state, expires_on, occurred_at)
         VALUES ($1, $2, $3, $4, 'estimated', $5, now())
         RETURNING id, delta_points, reason, state, expires_on, occurred_at`,
        [req.userId, req.params.id, delta, adjustmentReason, expiresOn || null]
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
async function recordTransactionObservation(client, userId, transactionId, {
  source, sourceKey, observedAt, externalRef, payloadHash, metadata,
}) {
  await client.query(
    `INSERT INTO transaction_observations
       (profile_id, transaction_id, source, source_key, observed_at, external_ref, payload_hash, metadata)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)
     ON CONFLICT (profile_id, source, source_key) WHERE source_key IS NOT NULL
     DO UPDATE SET transaction_id = EXCLUDED.transaction_id,
                   observed_at = LEAST(transaction_observations.observed_at, EXCLUDED.observed_at),
                   external_ref = COALESCE(transaction_observations.external_ref, EXCLUDED.external_ref),
                   payload_hash = COALESCE(transaction_observations.payload_hash, EXCLUDED.payload_hash),
                   metadata = transaction_observations.metadata || EXCLUDED.metadata`,
    [
      userId,
      transactionId,
      source || 'manual',
      sourceKey || null,
      observedAt || new Date(),
      externalRef || null,
      payloadHash || null,
      JSON.stringify(metadata || {}),
    ]
  );
}

// Pair the two legs of an explicitly account-to-account movement without
// collapsing either ledger row. This is deliberately evidence-gated: an
// Pair only when both transaction legs share an exact bank reference and
// cross-reference the destination/account suffix. Suffixes and timing alone
// are not proof that both accounts belong to this user.
async function pairTransferObservation(client, userId, transactionId) {
  const current = await client.query(
    `SELECT t.id, t.amount_inr, t.occurred_at,
            o.metadata->>'transferKind' AS transfer_kind,
            o.metadata->>'accountLast4' AS account_last4,
            o.metadata->>'destinationAccountLast4' AS destination_account_last4,
            o.metadata->>'bankReference' AS bank_reference,
            o.metadata->>'transferGroupId' AS transfer_group_id
       FROM transactions t
       JOIN transaction_observations o
         ON o.transaction_id = t.id AND o.profile_id = t.profile_id
      WHERE t.id = $1 AND t.profile_id = $2
        AND o.source IN ('sms', 'sms_bulk')
      ORDER BY o.observed_at DESC
      LIMIT 1`,
    [transactionId, userId],
  );
  const row = current.rows[0];
  if (!row || !row.transfer_kind || !Number.isFinite(Number(row.amount_inr))) return null;
  // Pairing is idempotent. Exact source-key retries must not create a new
  // group and overwrite the evidence attached to an already matched pair.
  if (row.transfer_group_id) return null;
  const debitKinds = new Set(['account_to_account', 'account_to_account_candidate']);
  const creditKinds = new Set(['incoming_bank_transfer_candidate', 'unclassified_credit']);
  const isDebit = debitKinds.has(row.transfer_kind) && row.destination_account_last4;
  const isCredit = creditKinds.has(row.transfer_kind) && row.account_last4;
  if (!isDebit && !isCredit) return null;
  if (!row.bank_reference) return null;

  const candidates = await client.query(
    `SELECT t.id,
            o.metadata->>'transferKind' AS transfer_kind,
            o.metadata->>'accountLast4' AS account_last4,
            o.metadata->>'destinationAccountLast4' AS destination_account_last4,
            o.metadata->>'bankReference' AS bank_reference,
            o.metadata->>'transferGroupId' AS transfer_group_id
       FROM transactions t
       JOIN transaction_observations o
         ON o.transaction_id = t.id AND o.profile_id = t.profile_id
      WHERE t.profile_id = $1
        AND t.id <> $2
        AND t.status = 'active'
        AND t.entry_kind = 'transfer'
        AND t.amount_inr = $3
        AND t.occurred_at >= $4::timestamptz - interval '48 hours'
        AND t.occurred_at <= $4::timestamptz + interval '48 hours'
        AND o.source IN ('sms', 'sms_bulk')
        AND o.metadata->>'transferGroupId' IS NULL
        AND (
          ($5::text IS NOT NULL AND o.metadata->>'accountLast4' = $5)
          OR ($6::text IS NOT NULL AND o.metadata->>'destinationAccountLast4' = $6)
        )
      ORDER BY
        CASE WHEN $7::text IS NOT NULL AND o.metadata->>'bankReference' = $7 THEN 0 ELSE 1 END,
        abs(extract(epoch FROM (t.occurred_at - $4::timestamptz)))
      LIMIT 2`,
    [
      userId,
      transactionId,
      row.amount_inr,
      row.occurred_at,
      isDebit ? row.destination_account_last4 : null,
      isCredit ? row.account_last4 : null,
      row.bank_reference || null,
    ],
  );
  const counterpart = candidates.rows.find((candidate) => {
    const counterpartIsCredit = creditKinds.has(candidate.transfer_kind);
    const counterpartIsDebit = debitKinds.has(candidate.transfer_kind)
      && candidate.destination_account_last4;
    if (isDebit) {
      return counterpartIsCredit
        && candidate.account_last4 === row.destination_account_last4
        && candidate.bank_reference === row.bank_reference;
    }
    return counterpartIsDebit
      && candidate.destination_account_last4 === row.account_last4
      && candidate.bank_reference === row.bank_reference;
  });
  if (!counterpart || candidates.rows.length !== 1) return null;

  const transferGroupId = crypto.randomUUID();
  const metadata = JSON.stringify({
    transferGroupId,
    pairedTransactionId: counterpart.id,
    pairEvidence: 'bank_reference_and_account_suffix',
  });
  await client.query(
    `UPDATE transaction_observations
        SET metadata = metadata || $1::jsonb
      WHERE profile_id = $2 AND transaction_id IN ($3, $4)`,
    [metadata, userId, transactionId, counterpart.id],
  );
  return { transferGroupId, counterpartId: counterpart.id };
}

function clientMutationSourceKey(userId, source, clientMutationId) {
  return crypto
    .createHash('sha256')
    .update(`${userId}\u0000${source}\u0000client-mutation\u0000${clientMutationId}`)
    .digest('hex');
}

async function insertTransactionAndUpdateState(client, userId, {
  userCardId, amount, occurred, categoryId, userCategoryId, rail, merchantName, note, source,
  merchantVpa, mcc, sourceKey, backfill, instrument, entryKind, status, accountLast4,
  observationMetadata, observedAt,
}) {
  const resolvedInstrument = instrument || 'credit_card';
  const resolvedEntryKind = entryKind || 'spend';
  const resolvedStatus = ['active', 'ignored', 'deleted'].includes(status) ? status : 'active';
  const resolvedSource = source || 'manual';
  const resolvedAccountLast4 = /^\d{4}$/.test(String(accountLast4 || '').trim())
    ? String(accountLast4).trim()
    : null;

  // All transaction channels use this helper, so one profile-scoped
  // transaction lock closes the race where SMS and email arrive together,
  // both inspect an empty candidate window, and both become active. The lock
  // lasts only for this database transaction and is independent per user.
  await client.query(`SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))`, [
    `transaction-ingest:${userId}`,
  ]);

  // Source aliases keep retries idempotent after automatic consolidation.
  if (sourceKey) {
    const observed = await client.query(
      `SELECT t.* FROM transaction_observations o
         JOIN transactions t ON t.id = o.transaction_id AND t.profile_id = o.profile_id
        WHERE o.profile_id = $1 AND o.source = $2 AND o.source_key = $3
          AND t.source_key IS DISTINCT FROM $3 LIMIT 1`,
      [userId, resolvedSource, sourceKey]
    );
    if (observed.rows[0]) return { status: 200, duplicate: true, duplicateKind: 'exact_retry', transaction: observed.rows[0] };
  }

  // Only a credit-card SPEND moves card state.
  //
  // Migration 0040 opened this route to cash, debit, UPI-from-bank, income
  // and investments. None of those touch a card's cap, milestone, points or
  // fee-waiver counters — those describe one card's billing cycle, and a
  // cash purchase or a salary credit moves none of them. Income and
  // investments in particular must never accrue cap progress: they aren't
  // spend at all, and counting them would inflate every reward figure on
  // the card they happened to be filed against.
  // A card alert can be perfectly valid even when the user has not saved
  // that card yet (or its last four digits are missing). Keep the payment
  // instrument as credit_card so reports do not silently relabel it as
  // "Other". Only card-state side effects require a concrete user_card row.
  const movesCardState = resolvedStatus === 'active'
    && resolvedInstrument === 'credit_card'
    && resolvedEntryKind === 'spend'
    && Boolean(userCardId);

  const userCard = movesCardState ? await loadUserCardForState(client, userId, userCardId) : null;
  if (movesCardState && !userCard) return { status: 404, error: 'user_card not found' };

  // Migration 0036: `source_key` is the identity of an imported message
  // (hash of normalized sender+body, salted per profile). ON CONFLICT DO
  // NOTHING against the partial unique index is what makes re-importing the
  // same SMS backup file a no-op instead of a silent doubling of every
  // number. Manual transactions pass no key, so they're unaffected — the
  // index only covers non-null keys.
  const txn = await client.query(
    `INSERT INTO transactions
       (profile_id, user_card_id, amount_inr, occurred_at, merchant_name, merchant_vpa, mcc, category_id, user_category_id, rail, source, note, reward_state, source_key, instrument, entry_kind, status, state_applied, is_backfill, source_account_last4)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, 'estimated', $13, $14, $15, $16, false, $17, $18)
     ON CONFLICT (profile_id, source_key) WHERE source_key IS NOT NULL DO NOTHING
     RETURNING id, amount_inr, occurred_at, instrument, entry_kind, source, status, reward_state, source_account_last4, state_applied, is_backfill`,
    [userId, movesCardState ? userCardId : (userCardId || null), amount, occurred, merchantName || null, merchantVpa || null, mcc || null, categoryId || null, userCategoryId || null, rail || 'unknown', resolvedSource, note || null, sourceKey || null, resolvedInstrument, resolvedEntryKind, resolvedStatus, backfill === true, resolvedAccountLast4]
  );

  // Zero rows back means the unique index rejected it: this exact message
  // has already been imported. That's a success from the caller's point of
  // view — the transaction they asked for exists — but it must NOT re-run
  // the state machine, or a repeat import would still double cap and
  // milestone progress even though it inserted no row.
  if (txn.rowCount === 0) {
    // The same SMS may have been imported by an older build that downgraded
    // an unmatched credit-card alert to `other`. The source key correctly
    // prevents a second ledger row, but returning the stale attribution would
    // make the bug permanent. Refresh only stronger parser evidence here:
    // never alter amount/date, and never replace a named merchant — except
    // the stale generic `Money received` fallback, which a parser upgrade
    // may now name precisely (e.g. EMI repayments previously mislabelled as
    // generic credits). Amount/merchant are otherwise immutable on retries.
    const existing = await client.query(
      `SELECT t.*
         FROM transactions t
        WHERE t.profile_id = $1 AND t.source_key = $2
        LIMIT 1
        FOR UPDATE`,
      [userId, sourceKey]
    );
    if (!existing.rows[0]) throw new Error('source_key conflict without an existing transaction');
    const old = existing.rows[0];
    const lockResult = await client.query(
      `SELECT COALESCE(bool_or(metadata->>'classificationLocked' = 'true'), false) AS locked
         FROM transaction_observations
        WHERE profile_id = $1 AND transaction_id = $2`,
      [userId, old.id],
    );
    const classificationLocked = lockResult.rows[0]?.locked === true;
    const oldMovesCardState = old.instrument === 'credit_card'
      && old.entry_kind === 'spend'
      && Boolean(old.user_card_id);
    const shouldReclassify = !classificationLocked && old.entry_kind !== resolvedEntryKind;
    const oldCard = oldMovesCardState
      ? await loadUserCardForState(client, userId, old.user_card_id)
      : null;
    if (shouldReclassify && oldMovesCardState && old.state_applied !== false && !oldCard) {
      throw new Error('cannot reclassify applied card transaction without its card state');
    }
    if (oldMovesCardState && old.state_applied !== false && oldCard && shouldReclassify) {
      await reverseTransactionState(client, userId, oldCard, old);
    }
    const refreshedEntryKind = shouldReclassify ? resolvedEntryKind : old.entry_kind;
    const effectiveInstrument = old.instrument === 'other' ? resolvedInstrument : old.instrument;
    const refreshedMovesCardState = effectiveInstrument === 'credit_card'
      && refreshedEntryKind === 'spend'
      && Boolean(old.user_card_id || userCardId);
    const refreshed = await client.query(
      `UPDATE transactions t
          SET merchant_name = CASE
                -- Parser upgrade: replace only the stale generic credit label.
                WHEN t.merchant_name = 'Money received'
                     AND $8::text IS NOT NULL AND $8::text <> 'Money received'
                  THEN $8::text
                ELSE t.merchant_name
              END,
              instrument = CASE
                WHEN t.instrument::text IN ('other', '')
                 AND $3::text IN ('credit_card', 'debit_card', 'upi_bank', 'wallet')
                  THEN $3::txn_instrument
                ELSE t.instrument
              END,
              user_card_id = CASE
                WHEN t.user_card_id IS NULL AND $4::uuid IS NOT NULL
                  THEN $4::uuid
                ELSE t.user_card_id
              END,
              source_account_last4 = COALESCE(t.source_account_last4, $5),
              entry_kind = $6::txn_entry_kind,
              state_applied = CASE
                WHEN $7::boolean THEN false
                ELSE t.state_applied
              END
        WHERE t.id = $1 AND t.profile_id = $2
      RETURNING id, amount_inr, occurred_at, instrument, entry_kind, source, status, reward_state, source_account_last4, state_applied, is_backfill`,
      [old.id, userId, resolvedInstrument, userCardId || null, resolvedAccountLast4, refreshedEntryKind, Boolean(shouldReclassify), merchantName || null]
    );
    if (shouldReclassify && refreshedMovesCardState && !old.is_backfill) {
      const card = oldCard || (userCardId ? await loadUserCardForState(client, userId, userCardId) : null);
      if (!card) throw new Error('cannot apply reclassified card transaction without its card state');
      await applyTransactionState(client, userId, card, {
          txnId: old.id,
          userCardId: old.user_card_id || userCardId,
          amount: Number(old.amount_inr),
          occurred: old.occurred_at,
          categoryId: old.category_id,
          merchantName: old.merchant_name,
          rail: old.rail,
          sign: 1,
      });
      await client.query(`UPDATE transactions SET state_applied = true WHERE id = $1`, [old.id]);
    }
    await recordTransactionObservation(client, userId, refreshed.rows[0].id, {
      source: resolvedSource,
      sourceKey,
      observedAt: observedAt || occurred,
      // The stored row keeps its original occurred_at on an exact retry.
      // Do not claim second-level time precision for an older date-only row.
      metadata: { ...(observationMetadata || {}), transactionTimePrecise: undefined, exactRetry: true },
    });
    // Keep the extracted ingestion writer used by the duplicate-ingestion
    // tests self-contained; the production module always has this helper in
    // scope, while the test intentionally evaluates only this function.
    if (typeof pairTransferObservation === 'function') {
      await pairTransferObservation(client, userId, refreshed.rows[0].id);
    }
    return { status: 200, duplicate: true, duplicateKind: 'exact_retry', transaction: refreshed.rows[0] };
  }

  await recordTransactionObservation(client, userId, txn.rows[0].id, {
    source: resolvedSource,
    sourceKey,
    observedAt: observedAt || occurred,
    metadata: observationMetadata,
  });
  if (resolvedStatus !== 'active') {
    return { status: 201, transaction: txn.rows[0] };
  }
  if (typeof pairTransferObservation === 'function') {
    await pairTransferObservation(client, userId, txn.rows[0].id);
  }

  // smsextractionimple.md §0.1 D2: a backfilled historical message inserts
  // the transaction but must not touch cap/milestone/fee-waiver state.
  // Those counters describe the CURRENT cycle; feeding two years of
  // recovered history through them reports progress the user never actually
  // made this month. The row is still recorded, still visible in Activity,
  // and still counts for lifetime/analytics reads that derive from
  // `transactions` directly.
  //
  // Duplicate detection below still runs for a backfill — deliberately.
  // Importing an SMS backup and then a statement PDF covering the same
  // months is a completely ordinary sequence, and it is exactly the
  // cross-channel case D-5 exists to catch. Skipping it here would silence
  // the check precisely where it earns its keep.
  // Task D-5 (ui-spec D5 Duplicate Review, §5.8): runs on every insert
  // through this one shared helper, so both POST /transactions (manual)
  // and POST /transactions/from-sms get duplicate detection for free —
  // exactly the "same amount+merchant+date across channels" case the spec
  // describes (a bank SMS and a later statement import both recording the
  // same swipe is the canonical example).
  // Spending rows may use conservative cross-source matching. For income,
  // investments, and transfers the shared matcher requires an exact bank
  // reference so recurring same-amount transactions are not merged.
  const duplicates = await detectDuplicates(client, userId, {
        newTxnId: txn.rows[0].id,
        amount,
        occurred,
        merchantName,
        source: resolvedSource,
        userCardId: userCardId || null,
        accountLast4: resolvedAccountLast4,
        bankReference: observationMetadata?.bankReference,
        observedAt: observedAt || occurred,
        transactionTimePrecise: observationMetadata?.transactionTimePrecise === true,
        instrument: resolvedInstrument,
        entryKind: resolvedEntryKind,
      });

  // A probable second observation is retained but suppressed before any
  // reward/card state is applied. Every Insights query already counts only
  // status='active', so this establishes the count-once invariant across all
  // existing consumers without teaching each feature its own dedupe rule.
  if (duplicates.automatic) {
    await transactionTags.mergeTransactionTags(client, userId, txn.rows[0].id, duplicates.duplicateOf);
    await client.query(`UPDATE transactions SET status = 'ignored', note = $1 WHERE id = $2`,
      [`[automatically matched duplicate of ${duplicates.duplicateOf}]`, txn.rows[0].id]);
    await recordTransactionObservation(client, userId, duplicates.duplicateOf, {
      source: resolvedSource, sourceKey, observedAt: observedAt || occurred,
      externalRef: observationMetadata?.bankReference,
      metadata: { ...(observationMetadata || {}), automaticDuplicate: true, matchedRowId: txn.rows[0].id },
    });
    return { status: 200, duplicate: true, duplicateKind: 'high_confidence', transaction: duplicates.transaction, duplicateOf: duplicates.duplicateOf };
  }
  if (duplicates.candidateId) {
    const noteTag = `[pending duplicate of ${duplicates.duplicateOf}]`;
    const suppressed = await client.query(
      `UPDATE transactions SET status = 'ignored', note = $1
        WHERE id = $2
        RETURNING id, amount_inr, occurred_at, instrument, entry_kind, source, status, state_applied, is_backfill`,
      [note ? `${noteTag} ${note}` : noteTag, txn.rows[0].id]
    );
    return {
      status: 201,
      transaction: suppressed.rows[0],
      duplicate: true,
      duplicateKind: 'cross_source_candidate',
      duplicatePending: true,
      duplicateCandidateId: duplicates.candidateId,
      duplicateOf: duplicates.duplicateOf,
      backfilled: backfill === true,
    };
  }

  const stateUpdates = (backfill || !movesCardState)
    ? {}
    : await applyTransactionState(client, userId, userCard, {
        txnId: txn.rows[0].id, userCardId, amount, occurred, categoryId, sign: 1,
        merchantName, rail,
      });

  if (!backfill && movesCardState) {
    await client.query(`UPDATE transactions SET state_applied = true WHERE id = $1`, [txn.rows[0].id]);
    txn.rows[0].state_applied = true;
  }

  return {
    status: 201,
    transaction: txn.rows[0],
    backfilled: !!backfill,
    ...stateUpdates,
  };
}

/**
 * The one path a successfully-parsed bank message takes to become a
 * transaction, shared by POST /transactions/from-sms, its /batch sibling,
 * the forwarded-email webhook and POST /inbound-emails/:id/create-transaction.
 *
 * Everything those four used to duplicate — or, worse, not do at all — lives
 * here: resolving which card the message belongs to and resolving what kind of
 * spend it was. A valid spend is always inserted; if a credit-card alert has
 * no unambiguous card match, it is retained as a cardless transaction with
 * its detected payment instrument instead of blocking the user's spending
 * history behind a review queue.
 *
 * Every import route previously REQUIRED the caller to supply `userCardId`,
 * so no transaction was ever recorded without a person tapping a card for
 * that specific message. Now an unresolvable successful spend is recorded
 * immediately without a card association. This keeps Spending automatic and
 * avoids attaching it to the wrong card; later card enrichment can still use
 * the stored transaction metadata.
 *
 * Nothing is guessed: `resolveUserCardForImport` returns a card only when
 * the evidence is unambiguous. Attaching spend to the WRONG card is far
 * worse than attaching it to none — it corrupts that card's cap state, its
 * reward totals, and every recommendation made against it afterwards.
 */
async function importParsedMessage(client, userId, {
  parsed, patternIssuerId, sender, rawText, source, occurred, sourceKey, backfill, observedAt,
  explicitUserCardId, explicitCategoryId, rail, vpa, mcc, observationMetadata,
}) {
  const parsedVpa = vpa || extractVpa(parsed.fields.merchant) || extractVpa(rawText);
  const parsedMcc = mcc || parsed.fields.mcc || extractMcc(rawText);
  const accountIdentity = parsed.fields.accountLast4
    ? `${patternIssuerId || String(sender || '').toUpperCase() || 'legacy'}:${parsed.fields.accountLast4}`
    : null;
  const importMetadata = {
    ...(observationMetadata || {}),
    // Precision belongs to this parsed timestamp, not every canonical row
    // that later receives the observation through replay or duplicate merge.
    ...(observationMetadata?.transactionTimePrecise === true
      ? { transactionTimeMillis: new Date(occurred).getTime() } : {}),
    // A bank-account suffix is masked evidence for grouping only. It is not a
    // card last-4 and must never participate in physical-card resolution.
    ...(parsed.fields.accountLast4 ? { accountLast4: parsed.fields.accountLast4 } : {}),
    ...(parsed.fields.reference ? { bankReference: parsed.fields.reference } : {}),
    ...(parsed.fields.transferParty ? { transferParty: parsed.fields.transferParty } : {}),
    ...(parsed.fields.transferKind ? { transferKind: parsed.fields.transferKind } : {}),
    ...(parsed.fields.entryKind ? { parserEntryKind: parsed.fields.entryKind } : {}),
    ...(parsed.fields.destinationAccountLast4
      ? { destinationAccountLast4: parsed.fields.destinationAccountLast4 }
      : {}),
    ...(parsed.fields.accountLast4 && parsed.fields.availableBalanceInr != null
      ? { availableBalanceInr: parsed.fields.availableBalanceInr }
      : {}),
    ...(parsed.fields.accountLast4
      ? { isBankAccount: isBankAccountMessage(rawText, sender) }
      : {}),
    ...(parsed.fields.accountLast4 && sender
      ? { senderBank: sender }
      : {}),
    ...(accountIdentity ? { accountIdentity } : {}),
  };
  // A QR payment can produce either a credit-card alert or a bank-account
  // UPI debit alert. Account-number suffixes are not card last-4 digits and
  // must never be used to attach a cardless bank payment to the wrong card.
  // A remembered selection cannot establish type. A unique owned card with
  // the printed card suffix can, provided there is no bank-account evidence.
  let instrument = parsed.fields.instrument || 'other';
  const entryKind = parsed.fields.entryKind || 'spend';
  let userCardId = explicitUserCardId || null;
  let matchBasis = userCardId ? 'caller-supplied' : null;
  if (instrument === 'other' && parsed.fields.last4 && !parsed.fields.accountLast4
      && /\bcard\b/i.test(rawText)) {
    const resolved = await importResolvers.resolveUserCardForImport(client, userId, {
      last4: parsed.fields.last4, patternIssuerId, instrument: 'other',
    });
    userCardId = resolved?.userCardId || null;
    if (resolved) {
      instrument = resolved.instrument;
      matchBasis = resolved.basis;
    }
  }

  // A selected card is only an override for physical-card alerts. A bank
  // account UPI debit is deliberately cardless even if the settings screen
  // has a remembered card selected.
  const isPhysicalCard = instrument === 'credit_card' || instrument === 'debit_card';
  if (!isPhysicalCard) {
    userCardId = null;
    matchBasis = 'instrument-cardless';
  }

  // A caller-supplied card is still checked against the parser's physical
  // card type. This matters when the same last four digits exist on both a
  // debit and a credit card, or when an older app build remembered the wrong
  // selected card. Never let that override cross the credit/debit boundary.
  if (isPhysicalCard && userCardId) {
    const compatible = await importResolvers.userCardMatchesInstrument(
      client,
      userId,
      userCardId,
      instrument,
      parsed.fields.last4 || null,
      patternIssuerId || null,
    );
    if (!compatible) {
      userCardId = null;
      matchBasis = 'caller-card-type-mismatch';
    }
  }

  if (isPhysicalCard && !userCardId) {
    const resolved = await importResolvers.resolveUserCardForImport(client, userId, {
      last4: parsed.fields.last4,
      patternIssuerId,
      instrument,
    });
    if (resolved) {
      userCardId = resolved.userCardId;
      matchBasis = resolved.basis;
    }
  }

  if (instrument === 'credit_card' && !userCardId) {
    // Do not make the user classify normal spending and do not erase the
    // strongest payment-method evidence. A cardless credit-card transaction
    // is still useful for totals, trends, category reporting, and the
    // "Credit card (unmatched)" bucket. It can be linked later when the user
    // adds the card or corrects its last four digits.
    matchBasis = 'unresolved-cardless';
  }

  // An explicitly-supplied category always wins; otherwise resolve it.
  // Imported transactions used to land uncategorized ALWAYS, which both
  // emptied Insights ("Uncategorized" for the entire history) and priced
  // every import at the card's base rate, because reward matching is by
  // category and a null category can only ever match the base rule.
  const classification = explicitCategoryId
    ? { categoryId: explicitCategoryId, userCategoryId: null }
    : (importResolvers.resolveCategoryAssignmentForImport
      ? await importResolvers.resolveCategoryAssignmentForImport(client, userId, {
          merchantName: parsed.fields.merchant,
          vpa: parsedVpa,
          mcc: parsedMcc,
          messageText: rawText,
          entryKind,
          status: 'active',
          transferKind: parsed.fields.transferKind,
          isRefund: parsed.fields.transferKind === 'refund',
          isReversal: parsed.fields.transferKind === 'reversal',
        })
      : {
          categoryId: await importResolvers.resolveCategoryForImport(client, userId, {
            merchantName: parsed.fields.merchant,
            vpa: parsedVpa,
            mcc: parsedMcc,
            messageText: rawText,
            entryKind,
            status: 'active',
            transferKind: parsed.fields.transferKind,
            isRefund: parsed.fields.transferKind === 'refund',
            isReversal: parsed.fields.transferKind === 'reversal',
          }),
          userCategoryId: null,
        });
  const categoryId = classification.categoryId;

  const inserted = await insertTransactionAndUpdateState(client, userId, {
    userCardId,
    amount: parsed.fields.amountInr,
    occurred,
    categoryId,
    userCategoryId: classification.userCategoryId,
    // A bank-account instrument is not automatically a UPI-QR payment.
    // Mobile-banking/IMPS/NEFT alerts must stay on the unknown rail so card
    // reward rules cannot be applied to them by inference.
    rail: rail || parsed.fields.rail || (/\bupi\b/i.test(rawText) ? 'upi_qr' : 'unknown'),
    merchantName: parsed.fields.merchant || null,
    merchantVpa: parsedVpa,
    mcc: parsedMcc,
    source,
    sourceKey,
    backfill,
    instrument,
    entryKind,
    accountLast4: parsed.fields.accountLast4 || null,
    observationMetadata: importMetadata,
    observedAt,
  });

  return { ...inserted, matchBasis, resolvedCategoryId: categoryId, userCardId };
}

/**
 * Repairs rows created by pre-idempotency SMS imports without guessing over
 * legitimate purchases. This is deliberately a user-scoped, authenticated
 * operation and is called by the app during its normal inbox reconciliation.
 *
 * Two active SMS rows are safe to collapse only when they have the same
 * amount, normalized merchant, instrument, card, and exact transaction
 * timestamp, and at least one is a backfill row. That last condition keeps
 * two genuine live purchases at the same merchant from being silently
 * merged. The older/live row is retained; a backfill replay is ignored.
 */
async function reconcileArchivedCardReferences(client, userId) {
  // A replacement is safe only when the physical identity is unique on both
  // sides: issuer + instrument type + last four. If two active catalogue rows
  // could match, leave the transaction unresolved instead of assigning it to
  // an arbitrary reward product.
  const replacements = await client.query(
    `WITH candidates AS (
       SELECT archived.id AS archived_card_id, active.id AS active_card_id
         FROM user_cards archived
         JOIN card_products archived_product
           ON archived_product.id = archived.card_product_id
         JOIN user_cards active
           ON active.profile_id = archived.profile_id
          AND active.is_archived = false
          AND active.last4 = archived.last4
         JOIN card_products active_product
           ON active_product.id = active.card_product_id
        WHERE archived.profile_id = $1
          AND archived.is_archived = true
          AND archived.last4 ~ '^[0-9]{4}$'
          AND archived_product.issuer_id = active_product.issuer_id
          AND archived_product.card_type = active_product.card_type
          AND archived.id <> active.id
     ), unique_replacements AS (
       SELECT archived_card_id, (array_agg(active_card_id ORDER BY active_card_id))[1] AS active_card_id
         FROM candidates
        GROUP BY archived_card_id
       HAVING COUNT(*) = 1
     )
     SELECT archived_card_id, active_card_id
       FROM unique_replacements`,
    [userId],
  );

  let remappedTransactions = 0;
  let remappedReferences = 0;
  for (const replacement of replacements.rows) {
    const { archived_card_id: archivedCardId, active_card_id: activeCardId } = replacement;
    const transactions = await client.query(
      `UPDATE transactions
          SET user_card_id = $1, updated_at = now()
        WHERE profile_id = $2 AND user_card_id = $3
       RETURNING id`,
      [activeCardId, userId, archivedCardId],
    );
    remappedTransactions += transactions.rowCount;

    // These are references to the same historical instrument, not new
    // purchases. Move them with the transaction so every user-facing report
    // resolves to the active replacement card.
    const referenceUpdates = [
      ['points_ledger', 'user_card_id'],
      ['statement_imports', 'user_card_id'],
      ['lounge_usage', 'user_card_id'],
      ['recurring_series', 'user_card_id'],
      ['needs_review_items', 'suggested_card_id'],
      ['transactions', 'recommended_card_id'],
    ];
    for (const [table, column] of referenceUpdates) {
      const updated = await client.query(
        `UPDATE ${table}
            SET ${column} = $1
          WHERE profile_id = $2 AND ${column} = $3`,
        [activeCardId, userId, archivedCardId],
      );
      remappedReferences += updated.rowCount;
    }
    const splitReferences = await client.query(
      `UPDATE transaction_splits
          SET user_card_id = $1
        WHERE user_card_id = $2
          AND transaction_id IN (
            SELECT id FROM transactions WHERE profile_id = $3
          )`,
      [activeCardId, archivedCardId, userId],
    );
    remappedReferences += splitReferences.rowCount;

    // Derived rows belong to the old product's reward rules. Do not copy them
    // to a different product; current caps are rebuilt from the canonical
    // transaction ledger after the remap.
    for (const table of ['cap_states', 'milestone_states', 'fee_waiver_states']) {
      await client.query(
        `DELETE FROM ${table} WHERE profile_id = $1 AND user_card_id = $2`,
        [userId, archivedCardId],
      );
    }
  }

  if (remappedTransactions > 0) {
    await reconcileCurrentCapStates(client, userId);
  }

  return {
    replacementCards: replacements.rowCount,
    remappedTransactions,
    remappedReferences,
  };
}

// The parser uses the owner's profile name to recognize self transfers that
// address the user by name (UPI/QR "To SUJAY ..."). Mainly defensive: a
// missing profile row just yields null and the heuristic stays dormant.
async function profileDisplayName(db, userId) {
  try {
    const row = await db.query(
      'SELECT display_name FROM profiles WHERE id = $1 LIMIT 1',
      [userId],
    );
    return row.rows[0]?.display_name || null;
  } catch (_) {
    return null;
  }
}

async function repairSmsHistory(client, userId, { reviewCrossSource = false, reviewCardId = null } = {}) {
  const cardReplacement = await reconcileArchivedCardReferences(client, userId);
  // Parser upgrades retain their strongest decision in observation metadata.
  // Reconcile those rows before duplicate repair so a card-bill/transfer row
  // that was previously imported as spend cannot inflate totals or be merged
  // with a real purchase. User corrections are explicitly locked by PATCH
  // /transactions and are never changed here.
  const classificationEvidence = await client.query(
    `SELECT DISTINCT ON (t.id)
            t.id, t.user_card_id, t.amount_inr, t.occurred_at, t.category_id,
            t.merchant_name, t.rail, t.instrument, t.entry_kind,
            t.state_applied, t.is_backfill,
            o.metadata->>'transferKind' AS transfer_kind,
            o.metadata->>'parserEntryKind' AS parser_entry_kind
       FROM transactions t
       JOIN transaction_observations o
         ON o.transaction_id = t.id AND o.profile_id = t.profile_id
      WHERE t.profile_id = $1
        AND t.status = 'active'
        AND t.source IN ('sms', 'sms_bulk')
        AND (o.metadata->>'transferKind' IS NOT NULL OR o.metadata->>'parserEntryKind' IS NOT NULL)
        AND NOT EXISTS (
          SELECT 1 FROM transaction_observations locked_observation
           WHERE locked_observation.profile_id = t.profile_id
             AND locked_observation.transaction_id = t.id
             AND locked_observation.metadata->>'classificationLocked' = 'true'
        )
      ORDER BY t.id, o.observed_at DESC` ,
    [userId],
  );
  const transferKinds = new Set([
    'account_to_account', 'account_to_account_candidate', 'wallet_load',
    'card_bill', 'cash_withdrawal', 'loan_repayment', 'refund', 'reversal',
    'reward', 'loan_disbursement', 'investment_proceeds', 'cash_deposit',
    'gift_received', 'reimbursement', 'incoming_bank_transfer_candidate',
    'unclassified_credit', 'card_adjustment',
  ]);
  let classificationReclassified = 0;
  for (const row of classificationEvidence.rows) {
    const desiredKind = row.transfer_kind === 'fee' || row.transfer_kind === 'payment_to_person'
      ? 'spend'
      : transferKinds.has(row.transfer_kind)
      ? 'transfer'
      : ['spend', 'income', 'investment', 'transfer'].includes(row.parser_entry_kind)
      ? row.parser_entry_kind
      : null;
    if (!desiredKind || desiredKind === row.entry_kind) continue;

    const oldMovesCardState = row.instrument === 'credit_card'
      && row.entry_kind === 'spend'
      && Boolean(row.user_card_id);
    const oldCard = oldMovesCardState
      ? await loadUserCardForState(client, userId, row.user_card_id)
      : null;
    if (oldMovesCardState && row.state_applied !== false && !oldCard) {
      throw new Error('cannot repair classification without reversing its applied card state');
    }
    if (oldMovesCardState && row.state_applied !== false && oldCard) {
      await reverseTransactionState(client, userId, oldCard, row);
    }
    await client.query(
      `UPDATE transactions
          SET entry_kind = $1::txn_entry_kind,
              state_applied = false,
              updated_at = now()
        WHERE id = $2 AND profile_id = $3`,
      [desiredKind, row.id, userId],
    );
    const newMovesCardState = row.instrument === 'credit_card'
      && desiredKind === 'spend'
      && Boolean(row.user_card_id)
      && !row.is_backfill;
    if (newMovesCardState) {
      const card = oldCard || await loadUserCardForState(client, userId, row.user_card_id);
      if (card) {
        await applyTransactionState(client, userId, card, {
          txnId: row.id,
          userCardId: row.user_card_id,
          amount: Number(row.amount_inr),
          occurred: row.occurred_at,
          categoryId: row.category_id,
          merchantName: row.merchant_name,
          rail: row.rail,
          sign: 1,
        });
        await client.query(
          `UPDATE transactions SET state_applied = true WHERE id = $1 AND profile_id = $2`,
          [row.id, userId],
        );
      }
    }
    classificationReclassified += 1;
  }
  const duplicateRows = await client.query(
    `WITH groups AS (
       SELECT amount_inr, instrument, entry_kind, user_card_id, occurred_at,
              regexp_replace(lower(coalesce(merchant_name, '')), '[^a-z0-9]', '', 'g') AS merchant_key
         FROM transactions
        WHERE profile_id = $1
          AND status = 'active'
          AND entry_kind = 'spend'
          AND source IN ('sms', 'sms_bulk')
          AND merchant_name IS NOT NULL
        GROUP BY amount_inr, instrument, entry_kind, user_card_id, occurred_at,
                 regexp_replace(lower(coalesce(merchant_name, '')), '[^a-z0-9]', '', 'g')
       HAVING count(*) > 1
          AND count(*) FILTER (WHERE is_backfill) > 0
     ), ranked AS (
       SELECT t.id,
              first_value(t.id) OVER (
                PARTITION BY t.amount_inr, t.instrument, t.entry_kind,
                             t.user_card_id, t.occurred_at,
                             regexp_replace(lower(coalesce(t.merchant_name, '')), '[^a-z0-9]', '', 'g')
                ORDER BY t.is_backfill ASC, t.created_at ASC, t.id ASC
              ) AS keep_id
         FROM transactions t
         JOIN groups g
           ON g.amount_inr = t.amount_inr
          AND g.instrument = t.instrument
          AND g.entry_kind = t.entry_kind
          AND g.user_card_id IS NOT DISTINCT FROM t.user_card_id
          AND g.occurred_at = t.occurred_at
          AND g.merchant_key = regexp_replace(lower(coalesce(t.merchant_name, '')), '[^a-z0-9]', '', 'g')
        WHERE t.profile_id = $1
          AND t.status = 'active'
          AND t.source IN ('sms', 'sms_bulk')
     )
     UPDATE transactions t
        SET status = 'ignored',
            note = trim(concat('[automatic SMS replay of ', ranked.keep_id::text, '] ', coalesce(t.note, '')))
       FROM ranked
      WHERE t.id = ranked.id
        AND ranked.id <> ranked.keep_id
        AND t.status = 'active'
     RETURNING t.id, ranked.keep_id` ,
    [userId]
  );

  for (const row of duplicateRows.rows) {
    await transactionTags.mergeTransactionTags(client, userId, row.id, row.keep_id);
  }

  // Older builds only had exact body-hash replay protection. Repair the
  // resulting double alerts with the same deliberately narrow notification
  // rule used during new ingestion: one card, exact amount and merchant,
  // and delivery within 15 minutes. This does not use the calendar-only
  // transaction timestamp, so two real purchases on the same day survive.
  const notificationDuplicateRows = await client.query(
    `WITH sms_rows AS (
       SELECT t.id, t.amount_inr, t.user_card_id, t.occurred_at,
              regexp_replace(lower(coalesce(t.merchant_name, '')), '[^a-z0-9]', '', 'g') AS merchant_key,
              MIN(o.observed_at) AS observed_at
         FROM transactions t
         JOIN transaction_observations o
           ON o.transaction_id = t.id AND o.profile_id = t.profile_id
        WHERE t.profile_id = $1
          AND t.status = 'active'
          AND t.source IN ('sms', 'sms_bulk')
          AND t.entry_kind = 'spend'
          AND t.user_card_id IS NOT NULL
          AND o.source IN ('sms', 'sms_bulk')
        GROUP BY t.id, t.amount_inr, t.user_card_id, t.occurred_at, t.merchant_name
     ), pairs AS (
       SELECT CASE
                WHEN left_row.observed_at < right_row.observed_at THEN right_row.id
                WHEN left_row.observed_at > right_row.observed_at THEN left_row.id
                WHEN left_row.id < right_row.id THEN right_row.id
                ELSE left_row.id
              END AS ignore_id,
              CASE
                WHEN left_row.observed_at < right_row.observed_at THEN left_row.id
                WHEN left_row.observed_at > right_row.observed_at THEN right_row.id
                WHEN left_row.id < right_row.id THEN left_row.id
                ELSE right_row.id
              END AS keep_id
         FROM sms_rows left_row
         JOIN sms_rows right_row
           ON left_row.id < right_row.id
          AND left_row.amount_inr = right_row.amount_inr
          AND left_row.user_card_id = right_row.user_card_id
          AND left_row.merchant_key <> ''
          AND left_row.merchant_key = right_row.merchant_key
          AND abs(extract(epoch FROM (left_row.observed_at - right_row.observed_at))) <= 900
     )
     UPDATE transactions t
        SET status = 'ignored',
            note = trim(concat('[automatic SMS notification duplicate of ', pairs.keep_id::text, '] ', coalesce(t.note, '')))
       FROM pairs
      WHERE t.id = pairs.ignore_id AND t.status = 'active'
     RETURNING t.id, pairs.keep_id`,
    [userId]
  );

  for (const row of notificationDuplicateRows.rows) {
    await transactionTags.mergeTransactionTags(client, userId, row.id, row.keep_id);
  }

  // A card can be added after its SMS history was imported. Keep those rows
  // as card transactions while they are unmatched, then attach them as soon
  // as the saved card makes the match unambiguous. This repairs attribution
  // without inventing a card or asking the user to review every message.
  const cardlessRows = await client.query(
    `SELECT DISTINCT ON (t.id)
            t.id, t.instrument, t.entry_kind, t.amount_inr, t.occurred_at,
            t.category_id, t.merchant_name, t.rail, t.is_backfill,
            t.state_applied,
            o.metadata->>'cardLast4' AS card_last4,
            o.metadata->>'patternIssuerId' AS pattern_issuer_id
       FROM transactions t
       JOIN transaction_observations o ON o.transaction_id = t.id
      WHERE t.profile_id = $1
        AND t.status = 'active'
        AND t.source IN ('sms', 'sms_bulk')
        AND t.entry_kind = 'spend'
        AND t.instrument IN ('credit_card', 'debit_card')
        AND t.user_card_id IS NULL
        AND o.metadata->>'cardLast4' ~ '^[0-9]{4}$'
      ORDER BY t.id, o.observed_at DESC
      LIMIT 1000`,
    [userId]
  );

  let linkedCards = 0;
  for (const row of cardlessRows.rows) {
    const resolved = await importResolvers.resolveUserCardForImport(client, userId, {
      last4: row.card_last4,
      patternIssuerId: row.pattern_issuer_id || null,
      instrument: row.instrument,
    });
    if (!resolved) continue;

    const linked = await client.query(
      `UPDATE transactions
          SET user_card_id = $1
        WHERE id = $2 AND profile_id = $3 AND user_card_id IS NULL
      RETURNING id`,
      [resolved.userCardId, row.id, userId]
    );
    if (linked.rowCount === 0) continue;
    linkedCards += 1;

    // Historical backfills must never change the current card cycle. A live
    // credit-card spend, however, was intentionally held out of card state
    // while unmatched, so apply it exactly once after linking it now.
    if (row.instrument === 'credit_card'
        && row.entry_kind === 'spend'
        && !row.is_backfill
        && row.state_applied !== true) {
      const card = await loadUserCardForState(client, userId, resolved.userCardId);
      if (card) {
        await applyTransactionState(client, userId, card, {
          txnId: row.id,
          userCardId: resolved.userCardId,
          amount: Number(row.amount_inr),
          occurred: row.occurred_at,
          categoryId: row.category_id,
          merchantName: row.merchant_name,
          rail: row.rail,
          sign: 1,
        });
        await client.query(
          `UPDATE transactions SET state_applied = true WHERE id = $1 AND profile_id = $2`,
          [row.id, userId]
        );
      }
    }
  }

  const legacyRows = await client.query(
    `SELECT t.id, t.user_card_id, t.amount_inr, t.occurred_at,
            t.merchant_name, t.merchant_vpa, t.mcc, t.rail,
            t.instrument, t.entry_kind, t.state_applied,
            t.category_id, sc.slug AS category_slug, sc.name AS category_name
       FROM transactions t
       LEFT JOIN spend_categories sc ON sc.id = t.category_id
      WHERE t.profile_id = $1
        AND t.status = 'active'
        AND t.entry_kind = 'spend'
        AND (
          t.category_id IS NULL
          OR lower(coalesce(sc.slug, '')) IN ('uncategorized', 'unclassified')
          OR lower(coalesce(sc.name, '')) IN ('uncategorized', 'unclassified')
          -- Older imports were assigned the generic other bucket before
          -- merchant rules ran. Revisit that bucket too: a known merchant
          -- such as Kavlekar Petroleum can now be upgraded to Fuel, while
          -- genuinely unknown merchants remain Other.
          OR lower(coalesce(sc.slug, '')) = 'other'
        )
      ORDER BY t.occurred_at ASC, t.id ASC
      LIMIT 1000`,
    [userId]
  );

  let reclassified = 0;
  for (const row of legacyRows.rows) {
    const categoryId = await importResolvers.resolveCategoryForImport(client, userId, {
      merchantName: row.merchant_name,
      vpa: row.merchant_vpa,
      mcc: row.mcc ? String(row.mcc).trim() : null,
      messageText: null,
      // This maintenance pass repairs legacy rows; future rules must never
      // rewrite a transaction that was already saved.
      applyUserMerchantRule: false,
    });
    if (!categoryId || categoryId === row.category_id) continue;

    // Reclassification changes the reward rule that governs this spend.
    // Older code changed only category_id, leaving expected_value_inr,
    // cap_states, milestone_states and points_ledger priced as if the old
    // category were still active. That made a later MCC/VPA/merchant repair
    // silently leave a valid spend at the old base-rate reward (or leave a
    // newly excluded spend earning). Reverse and re-apply the same state
    // machine around the category update so every derived reward field stays
    // consistent. Backfill rows have state_applied=false and intentionally
    // remain historical-only; they get the category correction but do not
    // mutate the current cycle.
    let cardForState = null;
    const shouldRecompute = row.instrument === 'credit_card'
      && row.entry_kind === 'spend'
      && row.user_card_id
      && row.state_applied !== false;
    if (shouldRecompute) {
      cardForState = await loadUserCardForState(client, userId, row.user_card_id);
      if (cardForState) {
        await reverseTransactionState(client, userId, cardForState, row);
      }
    }

    await client.query(
      `UPDATE transactions SET category_id = $1 WHERE id = $2 AND profile_id = $3`,
      [categoryId, row.id, userId]
    );

    if (cardForState) {
      await applyTransactionState(client, userId, cardForState, {
        txnId: row.id,
        userCardId: row.user_card_id,
        amount: Number(row.amount_inr),
        occurred: row.occurred_at,
        categoryId,
        merchantName: row.merchant_name,
        rail: row.rail,
        sign: 1,
      });
    }
    reclassified += 1;
  }

  let crossSourceCandidatesCreated = 0;
  if (reviewCrossSource) {
    // Serialize historical scans so a second scan sees the first one's
    // reservations even when the surviving statement row is still active.
    await client.query("SELECT pg_advisory_xact_lock(hashtextextended('duplicate-review:' || $1::text, 0))", [userId]);
    // Legacy imports predate cross-channel duplicate detection. Compare active
    // SMS rows with statement/manual/import rows using the SMS delivery time
    // when present (the transaction date in many bank alerts is date-only).
    // Only create a review item here: the user can merge it or keep both.
    const crossSourceRows = await client.query(
      `SELECT t.id, t.amount_inr, t.occurred_at, t.merchant_name, t.source,
              t.user_card_id, t.instrument, t.entry_kind, t.source_account_last4,
              (SELECT COALESCE(o.external_ref, o.metadata->>'bankReference')
                 FROM transaction_observations o WHERE o.transaction_id = t.id AND o.profile_id = t.profile_id
                  AND COALESCE(o.external_ref, o.metadata->>'bankReference') IS NOT NULL LIMIT 1) AS bank_reference,
              (SELECT MIN(o.observed_at) FROM transaction_observations o
                WHERE o.transaction_id = t.id AND o.profile_id = t.profile_id
                  AND o.source IN ('sms', 'sms_bulk')
                  AND o.metadata->>'legacy' IS DISTINCT FROM 'true') AS observed_at,
              EXISTS (SELECT 1 FROM transaction_observations o
                WHERE o.transaction_id = t.id AND o.profile_id = t.profile_id
                  AND o.source IN ('sms', 'sms_bulk')
                  AND o.metadata->>'transactionTimePrecise' = 'true'
                  AND o.metadata->>'transactionTimeMillis' =
                      (extract(epoch FROM t.occurred_at) * 1000)::bigint::text) AS transaction_time_precise,
              t.category_id, t.rail, t.state_applied, t.is_backfill, t.note
         FROM transactions t
        WHERE t.profile_id = $1 AND t.status = 'active' AND t.entry_kind = 'spend'
          AND t.source IN ('sms', 'sms_bulk', 'statement', 'manual', 'imported')
          AND t.user_card_id IS NOT NULL
          AND ($2::uuid IS NULL OR t.user_card_id = $2::uuid)
          AND NOT EXISTS (
            SELECT 1 FROM duplicate_candidates d
             WHERE d.profile_id = t.profile_id AND d.state = 'pending'
               AND (d.txn_a_id = t.id OR d.txn_b_id = t.id)
          )
        ORDER BY t.occurred_at DESC, t.id
        LIMIT 5000
        FOR UPDATE OF t`,
      [userId, reviewCardId],
    );
    const smsHistoryRows = crossSourceRows.rows.filter((row) => ['sms', 'sms_bulk'].includes(row.source));
    const otherHistoryRows = crossSourceRows.rows.filter((row) => !['sms', 'sms_bulk'].includes(row.source));
    const reservedRows = new Set();
    for (const smsRow of smsHistoryRows) {
      const smsComparisonTime = new Date(
        smsRow.transaction_time_precise ? smsRow.occurred_at : (smsRow.observed_at || smsRow.occurred_at)
      ).getTime();
      const selected = bestDuplicate({
        amount: smsRow.amount_inr,
        occurred: smsRow.occurred_at,
        merchantName: smsRow.merchant_name,
        source: smsRow.source,
        userCardId: smsRow.user_card_id,
        instrument: smsRow.instrument,
        entryKind: smsRow.entry_kind,
        accountLast4: smsRow.source_account_last4,
        bankReference: smsRow.bank_reference,
        observedAt: smsRow.observed_at,
        transactionTimePrecise: smsRow.transaction_time_precise,
      }, otherHistoryRows.filter((row) => {
        if (reservedRows.has(row.id) || row.id === smsRow.id || row.user_card_id !== smsRow.user_card_id
            || Number(row.amount_inr) !== Number(smsRow.amount_inr)
            || row.instrument !== smsRow.instrument || row.entry_kind !== smsRow.entry_kind) return false;
        const candidateTime = new Date(row.occurred_at).getTime();
        return Number.isFinite(smsComparisonTime) && Number.isFinite(candidateTime)
          && Math.abs(smsComparisonTime - candidateTime) <= MAX_CROSS_SOURCE_CANDIDATE_MS;
      }));
      // Even a reference match stays reviewable during historical repair:
      // existing rows may already have user edits that should not be merged
      // without a decision.
      if (!selected) continue;
      const [txnA, txnB] = [smsRow.id, selected.candidate.id].sort();
      const inserted = await client.query(
        `INSERT INTO duplicate_candidates
           (profile_id, txn_a_id, txn_b_id, match_score, match_reason, suppressed_txn_id)
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (txn_a_id, txn_b_id) DO NOTHING
         RETURNING id`,
        [userId, txnA, txnB, selected.match.score, `Historical review: ${selected.match.reason}`, smsRow.id],
      );
      if (inserted.rowCount === 0) continue;
      reservedRows.add(smsRow.id);
      reservedRows.add(selected.candidate.id);

      // Keep totals and card state count-once while this pair awaits a decision.
      if (smsRow.instrument === 'credit_card' && !smsRow.is_backfill
          && smsRow.state_applied !== false) {
        const card = await loadUserCardForState(client, userId, smsRow.user_card_id);
        if (!card) throw new Error('cannot suppress historical duplicate without its active card');
        await reverseTransactionState(client, userId, card, smsRow);
      }
      await client.query(
        `UPDATE transactions
            SET status = 'ignored', state_applied = false,
                note = trim(concat('[pending duplicate of ', $1::text, '] ', coalesce(note, '')))
          WHERE id = $2 AND profile_id = $3 AND status = 'active'`,
        [selected.candidate.id, smsRow.id, userId],
      );
      crossSourceCandidatesCreated += 1;
    }
  }

  return {
    duplicateSuppressed: duplicateRows.rowCount + notificationDuplicateRows.rowCount,
    linkedCards,
    reclassified,
    classificationReclassified,
    remainingLegacyRows: Math.max(0, legacyRows.rowCount - reclassified),
    replacementCards: cardReplacement.replacementCards,
    remappedTransactions: cardReplacement.remappedTransactions,
    remappedReferences: cardReplacement.remappedReferences,
    crossSourceCandidatesCreated,
  };
}

/**
 * Rebuilds current-period cap consumption from active, card-linked spends.
 *
 * Cap state is derived data. A transaction can be linked to a card after it
 * was first imported, or an older app version can have recorded the ledger
 * row without applying the cap state. Reading the stale cap_states row in
 * that situation makes Spending and the card detail disagree. Replaying the
 * canonical ledger through reward_math keeps both surfaces aligned and also
 * repairs rows created before the current state machine was shipped.
 */
async function reconcileCurrentCapStates(client, userId) {
  // Serialize this repair with transaction ingestion/edit/reversal. The
  // repair is idempotent, but it deletes and rebuilds current-period rows, so
  // it must not interleave with a live cap update.
  await client.query(`SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))`, [
    `transaction-ingest:${userId}`,
  ]);

  const cards = await client.query(
    `SELECT uc.id, uc.card_product_id, uc.statement_day,
            cp.point_value_inr, cp.base_reward_unit, cp.base_reward_rate,
            cp.excluded_categories
       FROM user_cards uc
       JOIN card_products cp ON cp.id = uc.card_product_id
      WHERE uc.profile_id = $1 AND uc.is_archived = false`,
    [userId],
  );
  const today = await client.query(`SELECT CURRENT_DATE::text AS today`);
  const asOf = new Date(`${today.rows[0].today}T12:00:00.000Z`);
  let rebuiltCaps = 0;

  for (const card of cards.rows) {
    const rewardRules = await client.query(
      `SELECT id, category_id, merchant_pattern, rail, unit, rate,
              min_txn_inr, max_txn_inr, excluded_categories,
              effective_from, effective_to, priority
         FROM reward_rules WHERE card_product_id = $1`,
      [card.card_product_id],
    );
    const capRules = await client.query(
      `SELECT id, reward_rule_id, category_id, period, cap_value, measure,
              post_cap_unit, post_cap_rate
         FROM cap_rules WHERE card_product_id = $1`,
      [card.card_product_id],
    );
    if (capRules.rows.length === 0) continue;

    const replay = replayCurrentCapConsumption({
      card,
      rewardRules: rewardRules.rows,
      capRules: capRules.rows,
      transactions: [],
      asOf,
    });
    const periodStarts = [...replay.periods.values()].map((period) => period.start).sort();
    const earliestStart = periodStarts[0];
    const transactions = await client.query(
      `SELECT id, amount_inr, occurred_at, category_id, merchant_name, rail
         FROM transactions
        WHERE profile_id = $1
          AND user_card_id = $2
          AND status = 'active'
          AND instrument = 'credit_card'
          AND entry_kind = 'spend'
          AND COALESCE(is_backfill, false) = false
          AND occurred_at >= $3::date
          AND occurred_at < ($4::date + interval '1 day')
        ORDER BY occurred_at ASC, id ASC`,
      [userId, card.id, earliestStart, today.rows[0].today],
    );
    const result = replayCurrentCapConsumption({
      card,
      rewardRules: rewardRules.rows,
      capRules: capRules.rows,
      transactions: transactions.rows,
      asOf,
    });

    for (const cap of capRules.rows) {
      const period = result.periods.get(cap.id);
      await client.query(
        `DELETE FROM cap_states
          WHERE user_card_id = $1 AND cap_rule_id = $2 AND period_start = $3`,
        [card.id, cap.id, period.start],
      );
      const consumed = result.consumed.get(cap.id) || 0;
      if (consumed <= 0) continue;
      await client.query(
        `INSERT INTO cap_states
           (profile_id, user_card_id, cap_rule_id, period_start, period_end,
            consumed, cap_value_snapshot)
         VALUES ($1, $2, $3, $4, $5, $6, $7)`,
        [userId, card.id, cap.id, period.start, period.end, consumed, cap.cap_value],
      );
      rebuiltCaps += 1;
    }
  }

  return { rebuiltCaps };
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
async function detectDuplicates(client, userId, {
  newTxnId, amount, occurred, merchantName, source, userCardId, instrument, entryKind, accountLast4, bankReference, observedAt, transactionTimePrecise,
}) {
  await client.query("SELECT pg_advisory_xact_lock(hashtextextended('duplicate-review:' || $1::text, 0))", [userId]);
  const candidates = await client.query(
    `SELECT t.id, t.amount_inr, t.occurred_at, t.merchant_name, t.source, t.user_card_id, t.instrument, t.entry_kind, t.status, t.source_account_last4,
            (SELECT COALESCE(o.external_ref, o.metadata->>'bankReference')
               FROM transaction_observations o WHERE o.transaction_id = t.id AND o.profile_id = t.profile_id
                AND COALESCE(o.external_ref, o.metadata->>'bankReference') IS NOT NULL LIMIT 1) AS bank_reference,
            (SELECT MIN(o.observed_at)
               FROM transaction_observations o WHERE o.transaction_id = t.id AND o.profile_id = t.profile_id
                 AND o.source IN ('sms', 'sms_bulk')
                 AND o.metadata->>'legacy' IS DISTINCT FROM 'true') AS observed_at,
            EXISTS (SELECT 1 FROM transaction_observations o
               WHERE o.transaction_id = t.id AND o.profile_id = t.profile_id
                 AND o.source IN ('sms', 'sms_bulk')
                 AND o.metadata->>'transactionTimePrecise' = 'true'
                 AND o.metadata->>'transactionTimeMillis' =
                     (extract(epoch FROM t.occurred_at) * 1000)::bigint::text) AS transaction_time_precise
       FROM transactions t
      WHERE profile_id = $1 AND status = 'active' AND id != $2
        AND amount_inr BETWEEN $3::numeric - $6::numeric AND $3::numeric + $6::numeric
        AND entry_kind = $7
        AND occurred_at BETWEEN $4::timestamptz - ($5::bigint * interval '1 millisecond')
                            AND $4::timestamptz + ($5::bigint * interval '1 millisecond')`,
    [userId, newTxnId, amount, occurred, MAX_CROSS_SOURCE_CANDIDATE_MS, AMOUNT_TOLERANCE_INR, entryKind || 'spend']
  );

  const selected = bestDuplicate(
    { amount, occurred, merchantName, source, userCardId, instrument, entryKind, accountLast4, bankReference, observedAt, transactionTimePrecise },
    candidates.rows,
  );
  if (!selected) return { candidateId: null };
  if (selected.match.automatic) return { automatic: true, duplicateOf: selected.candidate.id, transaction: selected.candidate };
  const [txnA, txnB] = [newTxnId, selected.candidate.id].sort();
  const inserted = await client.query(
    `INSERT INTO duplicate_candidates
       (profile_id, txn_a_id, txn_b_id, match_score, match_reason, suppressed_txn_id)
     VALUES ($1, $2, $3, $4, $5, $6)
     ON CONFLICT (txn_a_id, txn_b_id) DO UPDATE
       SET match_score = GREATEST(duplicate_candidates.match_score, EXCLUDED.match_score),
           match_reason = EXCLUDED.match_reason,
           state = 'pending', resolution = NULL, resolved_at = NULL,
           suppressed_txn_id = EXCLUDED.suppressed_txn_id
     RETURNING id`,
    [userId, txnA, txnB, selected.match.score, selected.match.reason, newTxnId]
  );
  return { candidateId: inserted.rows[0].id, duplicateOf: selected.candidate.id };
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
  // base_reward_unit/base_reward_rate/excluded_categories added alongside
  // point_value_inr: reward_math.js resolves a null post-cap rate against
  // the card's base rate, and refuses to earn at all on an excluded
  // category, so both are now inputs to the state machine rather than
  // catalogue-display data the server never looked at.
  const result = await client.query(
    `SELECT uc.id, uc.card_product_id, uc.statement_day, uc.opened_on, uc.created_at,
            cp.point_value_inr, cp.base_reward_unit, cp.base_reward_rate,
            cp.excluded_categories
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
  txnId, userCardId, amount, occurred, categoryId, sign, merchantName, rail,
}) {
  // The full rule rows, not just (unit, rate): every constraint column here
  // is now enforced by src/reward_math.js's `ruleApplies`, which is the
  // same predicate the Dart engine runs. The old query selected two columns
  // and matched on `category_id IS NULL OR category_id = $2`, ignoring the
  // merchant/rail/min-txn/validity constraints the rule carried.
  const rewardRules = await client.query(
    `SELECT id, category_id, merchant_pattern, rail, unit, rate,
            min_txn_inr, max_txn_inr, excluded_categories,
            effective_from, effective_to, priority
       FROM reward_rules WHERE card_product_id = $1`,
    [userCard.card_product_id]
  );

  // Every cap on the card. Which one (if any) governs this transaction is
  // decided by `pickCapRule`, against the MATCHED rule or the transaction's
  // category — not by a SQL predicate in which `category_id IS NULL` acted
  // as a wildcard and let a rent payment consume a grocery cap.
  const capRules = await client.query(
    `SELECT id, reward_rule_id, category_id, period, cap_value, measure,
            post_cap_unit, post_cap_rate
       FROM cap_rules WHERE card_product_id = $1`,
    [userCard.card_product_id]
  );

  const card = {
    point_value_inr: userCard.point_value_inr,
    base_reward_unit: userCard.base_reward_unit,
    base_reward_rate: userCard.base_reward_rate,
    excluded_categories: userCard.excluded_categories || [],
  };
  const ctx = { amount, categoryId: categoryId || null, merchantName: merchantName || null, rail: rail || 'unknown', occurred };

  // Which cap this transaction would touch, and its state BEFORE this
  // transaction — cap blending needs the prior consumption, so the read has
  // to happen before the upsert below.
  const provisionalRule = rewardMath.pickRule(rewardRules.rows, ctx);
  const cardExcluded = !!categoryId && card.excluded_categories.includes(categoryId);
  const governingCap = provisionalRule && !cardExcluded
    ? rewardMath.pickCapRule(capRules.rows, provisionalRule, ctx)
    : null;

  const capStateUpdates = [];
  let capConsumedBefore = 0;
  let capPeriod = null;
  if (governingCap) {
    capPeriod = periodBounds(governingCap.period, occurred, { statementDay: userCard.statement_day });
    const existing = await client.query(
      `SELECT consumed FROM cap_states
        WHERE user_card_id = $1 AND cap_rule_id = $2 AND period_start = $3`,
      [userCardId, governingCap.id, capPeriod.start]
    );
    capConsumedBefore = existing.rows[0] ? Number(existing.rows[0].consumed) : 0;
  }

  // On a reversal the stored consumption already INCLUDES this
  // transaction, so blending against it would price the reversal as if the
  // cap were more used up than it was when the transaction landed. Backing
  // the transaction's own contribution out first is exact for spend and
  // transaction-count caps (their delta doesn't depend on cap state) and
  // approximate for reward-value caps, which is the same known,
  // already-documented limitation as a mid-cycle rule change: a reversal
  // cancels its original apply exactly only if the rules haven't moved.
  if (sign < 0 && governingCap) {
    const provisional = rewardMath.rewardPortions({
      card,
      rule: provisionalRule,
      capRule: governingCap,
      capConsumedBefore,
      amount,
    });
    capConsumedBefore = Math.max(0, capConsumedBefore - provisional.capConsumedDelta);
  }

  const reward = rewardMath.computeTransactionReward({
    card,
    rewardRules: rewardRules.rows,
    capRules: capRules.rows,
    capConsumedBefore,
    ctx,
  });

  if (governingCap && reward.capConsumedDelta !== 0) {
    const consumedDelta = reward.capConsumedDelta * sign;
    const upserted = await client.query(
      `INSERT INTO cap_states (profile_id, user_card_id, cap_rule_id, period_start, period_end, consumed, cap_value_snapshot)
       VALUES ($1, $2, $3, $4, $5, GREATEST(0::numeric, $6::numeric), $7)
       ON CONFLICT (user_card_id, cap_rule_id, period_start)
       DO UPDATE SET consumed = GREATEST(0::numeric, cap_states.consumed + $6::numeric), updated_at = now()
       RETURNING cap_rule_id, period_start, period_end, consumed, cap_value_snapshot`,
      [userId, userCardId, governingCap.id, capPeriod.start, capPeriod.end, consumedDelta, governingCap.cap_value]
    );
    capStateUpdates.push(upserted.rows[0]);
  }

  // A category the card excludes from earning is excluded from milestone
  // qualification too — issuers apply the same list to both, and counting
  // a rent payment toward a spend milestone on a card that pays nothing on
  // rent would show the user progress they haven't actually made.
  const milestoneRules = cardExcluded
    ? { rows: [] }
    : await client.query(
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
       VALUES ($1, $2, $3, $4, $5, GREATEST(0::numeric, $6::numeric))
       ON CONFLICT (user_card_id, milestone_rule_id, period_start)
       DO UPDATE SET qualified_spend = GREATEST(0::numeric, milestone_states.qualified_spend + $6::numeric), updated_at = now()
       RETURNING milestone_rule_id, period_start, period_end, qualified_spend`,
      [userId, userCardId, milestone.id, start, end, amount * sign]
    );
    milestoneStateUpdates.push(upserted.rows[0]);
  }

  // Write the estimated reward back onto the transaction.
  //
  // This was missing entirely, and the omission was invisible because every
  // route still returned 200: `rewardRate` was computed right here, used for
  // cap consumption and the points ledger, and then discarded without ever
  // touching `transactions.expected_value_inr`. That column is what
  // `GET /home-summary`, `GET /monthly-reports` and the missed-opportunity
  // screens all SUM over — so "rewards earned this month" was structurally
  // ₹0 for every user, forever, no matter how much they spent. Found by
  // logging a ₹2,000 spend against a 5%-cashback rule on a running stack and
  // watching the summary stay at zero.
  //
  // Applied on both signs so an edit or reversal recomputes rather than
  // leaving a stale figure: `sign < 0` runs during the reverse half of an
  // edit (PATCH) AND on a bare reversal with no re-apply (POST .../ignore) —
  // zeroing here, not skipping, is what keeps GET /transactions/:id honest
  // for an ignored transaction. A code review caught that this used to only
  // run `if (sign > 0)`, which was correct for PATCH's apply-after-reverse
  // pair but left the ignore route's reversal with no re-apply half at all,
  // so an ignored transaction kept showing its original nonzero expected
  // value/points even though cap/milestone/points-ledger state had already
  // been reversed — a real number on screen for a reward that no longer
  // existed anywhere else.
  //
  // CAP-AWARE as of the reward_math.js extraction. It used to be
  // `amount × nominal rate` with no cap blending at all, so once a cap was
  // exhausted the app went on recording 5% against spend that earned 1% —
  // "rewards earned this month" over-reported permanently and invisibly,
  // and Insights disagreed with the recommender that had been honest about
  // the same cap ten seconds earlier.
  const expectedValue = sign > 0 ? reward.valueInr : 0;
  const expectedPoints = sign > 0 ? reward.points : 0;
  await client.query(
    `UPDATE transactions
        SET expected_value_inr = $2, expected_points = $3, updated_at = now()
      WHERE id = $1`,
    [txnId, expectedValue, expectedPoints]
  );

  // Points ledger: one row per transaction (not bucketed) — apply inserts,
  // reverse deletes the row this exact transaction wrote. flat_points
  // rules earn 0 per this helper (a fixed bonus isn't a per-transaction
  // rate) so no ledger noise is written or needs deleting for them.
  //
  // The delta is the SAME cap-blended `reward.points` written above rather
  // than a second, independently-derived figure: the ledger and the
  // transaction row disagreeing about how many points one swipe earned is
  // exactly the kind of drift this whole module exists to remove.
  let pointsLedgerEntry = null;
  if (reward.points > 0 || sign < 0) {
    if (sign > 0) {
      const inserted = await client.query(
        `INSERT INTO points_ledger (profile_id, user_card_id, transaction_id, delta_points, reason, state, occurred_at)
         VALUES ($1, $2, $3, $4, $5, 'estimated', $6)
         RETURNING id, delta_points, reason, occurred_at`,
        [userId, userCardId, txnId, reward.points, 'points earned on transaction', occurred]
      );
      pointsLedgerEntry = inserted.rows[0];
    } else {
      await client.query(`DELETE FROM points_ledger WHERE transaction_id = $1`, [txnId]);
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
       VALUES ($1, $2, $3, $4, $5, GREATEST(0::numeric, $6::numeric))
       ON CONFLICT (user_card_id, fee_waiver_rule_id, period_start)
       DO UPDATE SET qualified_spend = GREATEST(0::numeric, fee_waiver_states.qualified_spend + $6::numeric), updated_at = now()
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
    // The stored merchant/rail, for the same reason the amount and category
    // come from the row rather than the caller: a merchant- or
    // rail-restricted rule must reverse against the rule that actually
    // applied. Omitting these would match a different rule on the way out
    // than on the way in and leave cap state permanently skewed.
    merchantName: txnRow.merchant_name,
    rail: txnRow.rail,
    sign: -1,
  });
}

/** Mirrors the txn_instrument / txn_entry_kind enums in migration 0040. */
const TXN_INSTRUMENTS = ['credit_card', 'debit_card', 'cash', 'upi_bank', 'wallet', 'other'];
const TXN_ENTRY_KINDS = ['spend', 'income', 'investment', 'transfer'];

app.post('/transactions', requireAuth, async (req, res) => {
  const {
    userCardId,
    amountInr,
    occurredAt,
    categoryId,
    userCategoryId,
    rail,
    merchantName,
    merchantVpa,
    mcc,
    note,
    clientMutationId,
  } = req.body || {};
  const instrument = (req.body || {}).instrument || 'credit_card';
  const entryKind = (req.body || {}).entryKind || 'spend';
  const amount = Number(amountInr);

  if (!TXN_INSTRUMENTS.includes(instrument)) {
    return res.status(400).json({ error: `instrument must be one of ${TXN_INSTRUMENTS.join(', ')}` });
  }
  if (!TXN_ENTRY_KINDS.includes(entryKind)) {
    return res.status(400).json({ error: `entryKind must be one of ${TXN_ENTRY_KINDS.join(', ')}` });
  }
  // A credit-card entry still requires a saved card because the database
  // treats that row as card spend. Debit-card entries may be cardless when
  // the user is logging a one-off purchase, but a supplied debit-card id is
  // retained and validated rather than silently discarded.
  if (instrument === 'credit_card' && (!userCardId || typeof userCardId !== 'string')) {
    return res.status(400).json({ error: 'userCardId is required for a credit-card transaction' });
  }
  if (!Number.isFinite(amount) || amount <= 0) {
    return res.status(400).json({ error: 'amountInr must be a positive number' });
  }
  if (userCategoryId !== undefined && userCategoryId !== null && (
    typeof userCategoryId !== 'string'
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userCategoryId)
  )) {
    return res.status(400).json({ error: 'userCategoryId must be a valid UUID' });
  }
  const occurred = occurredAt ? new Date(occurredAt) : new Date();
  if (Number.isNaN(occurred.getTime())) {
    return res.status(400).json({ error: 'occurredAt is not a valid date' });
  }
  if (clientMutationId !== undefined && (
    typeof clientMutationId !== 'string'
    || clientMutationId.length < 8
    || clientMutationId.length > 128
    || !/^[A-Za-z0-9._:-]+$/.test(clientMutationId)
  )) {
    return res.status(400).json({ error: 'clientMutationId must be 8-128 URL-safe characters' });
  }

  try {
    const result = await withUserClient(req.userId, async (client) => {
      if (userCardId && (instrument === 'credit_card' || instrument === 'debit_card')) {
        const compatible = await importResolvers.userCardMatchesInstrument(
          client,
          req.userId,
          userCardId,
          instrument,
        );
        if (!compatible) {
          return {
            status: 400,
            error: `userCardId does not match the ${instrument === 'debit_card' ? 'debit' : 'credit'}-card instrument`,
          };
        }
      }
      let userCategoryParentId = null;
      if (userCategoryId) {
        const category = await client.query(
          'SELECT parent_category_id FROM user_categories WHERE id = $1 AND profile_id = $2',
          [userCategoryId, req.userId],
        );
        if (category.rows.length === 0) {
          return { status: 400, error: 'user category not found' };
        }
        userCategoryParentId = category.rows[0].parent_category_id;
      }
      // QR/manual payments often arrive with a merchant name but without an
      // explicit category selection. Reuse the same conservative resolver as
      // SMS import so a known merchant is categorized before rewards and
      // spending reports are updated. An explicit category still wins.
      const classification = userCategoryId
        ? { categoryId: categoryId || userCategoryParentId, userCategoryId }
        : categoryId
        ? { categoryId, userCategoryId: null }
        : (importResolvers.resolveCategoryAssignmentForImport
            ? await importResolvers.resolveCategoryAssignmentForImport(client, req.userId, {
                merchantName,
                vpa: merchantVpa || null,
                mcc: mcc || null,
                messageText: null,
                entryKind,
                status: 'active',
              })
            : {
                categoryId: await importResolvers.resolveCategoryForImport(client, req.userId, {
                  merchantName,
                  vpa: merchantVpa || null,
                  mcc: mcc || null,
                  messageText: null,
                  entryKind,
                  status: 'active',
                }),
                userCategoryId: null,
              });
      return insertTransactionAndUpdateState(client, req.userId, {
        userCardId: instrument === 'credit_card' || instrument === 'debit_card'
          ? userCardId
          : null,
        amount,
        occurred,
        categoryId: classification.categoryId,
        userCategoryId: classification.userCategoryId,
        rail,
        merchantName,
        merchantVpa: merchantVpa || null,
        mcc: mcc || null,
        note,
        source: 'manual',
        sourceKey: clientMutationId
          ? clientMutationSourceKey(req.userId, 'manual', clientMutationId)
          : null,
        observationMetadata: {
          ...(clientMutationId ? { clientMutation: true } : {}),
          ...(Object.prototype.hasOwnProperty.call(req.body || {}, 'entryKind')
            ? { classificationLocked: true, classificationSource: 'user' }
            : {}),
        },
        instrument, entryKind,
      });
    });

    if (result.status !== 200 && result.status !== 201) {
      return res.status(result.status).json({ error: result.error });
    }
    res.status(result.status).json(result);
  } catch (err) {
    console.error('POST /transactions error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * Typed SMS facts and unresolved-message AI jobs share the existing source
 * identity and downstream specialists. AI results remain reviewable unless
 * a verified fact is safely materialized.
 */
smsFactsRoute.registerSmsFactsRoutes(app, {
  requireAuth,
  requireAdmin,
  withUserClient,
  persistSubscriptionMandate,
});
smsLearningFeedbackRoute.registerSmsLearningFeedbackRoute(app, {
  requireAuth,
  requireAdmin,
  withUserClient,
});
registerBillsProjectionRoutes(app, { requireAuth, withUserClient });
// The versioned rule bundle the device downloads and applies locally, so a
// parser improvement reaches a phone without an app release.
smsRuleBundleRoute.registerSmsRuleBundleRoutes(app, {
  requireAuth,
  requireAdmin,
  withUserClient,
});
aiQueueRoute.registerAiQueueRoutes(app, {
  requireAuth,
  requireAdmin,
  withUserClient,
  persistSubscriptionMandate,
});
aiProviderQuotaRoute.registerProviderQuotaRoute(app, {
  requireWorkerAuth: aiQueueRoute.requireWorkerAuth,
  withUserClient,
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
  const { sender, body, userCardId, occurredAt, categoryId, rail, appVersion, backfill } = req.body || {};
  if (!body || typeof body !== 'string' || !body.trim()) {
    return res.status(400).json({ error: 'body is required' });
  }
  // `userCardId` is now OPTIONAL. It used to be required, with the honest
  // explanation that the parser extracts amount/merchant/last4/date but not
  // which card the SMS is about — true, but the consequence was that no
  // transaction was ever captured without a human tapping a card for it,
  // one message at a time. src/import_resolvers.js now resolves it from
  // last4 or from the issuer behind the matched pattern. If it cannot be
  // sure, the spend is still recorded cardlessly so the user never has to
  // classify each SMS manually. A caller that DOES know the card still wins:
  // an explicit id is never second-guessed.
  if (userCardId !== undefined && userCardId !== null && typeof userCardId !== 'string') {
    return res.status(400).json({ error: 'userCardId must be a string when given' });
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

      const parsed = parseSmsAgainstPatterns(patterns.rows, {
  sender,
  body,
  ownUserName: await profileDisplayName(client, req.userId),
});
      const patternRow = patterns.rows.find((p) => p.id === parsed.patternId);
      const statementDaySync = await importResolvers.syncStatementDayFromSms(client, req.userId, {
        body,
        patternIssuerId: patternRow ? patternRow.issuer_id : uniqueSmsPatternIssuerId(patterns.rows, sender),
        observedAt: occurred,
        explicitUserCardId: userCardId,
      });
      const dueDaySync = await importResolvers.syncDueDayFromSms(client, req.userId, {
        body,
        observedAt: occurred,
        patternIssuerId: patternRow ? patternRow.issuer_id : uniqueSmsPatternIssuerId(patterns.rows, sender),
        explicitUserCardId: userCardId,
      });
      if (!parsed.ok) {
        // Limit alerts are not spend transactions, but an explicit credit
        // limit can still safely complete a card that has no limit yet.
        const limitSync = await importResolvers.syncCreditLimitFromSms(client, req.userId, {
          body,
          patternIssuerId: uniqueSmsPatternIssuerId(patterns.rows, sender),
        });
        const mandate = parseSubscriptionMandate({ sender, body });
        const mandateRow = mandate.ok
          ? await persistSubscriptionMandate(client, req.userId, {
              parsed: mandate,
              body,
              occurred,
              patternIssuerId: uniqueSmsPatternIssuerId(patterns.rows, sender),
            })
          : null;
        // Through the RPC, not a direct INSERT. `parser_failures` is
        // admin-only under RLS (0011), so the direct insert that used to be
        // here raised "new row violates row-level security policy" for every
        // real user — aborting this transaction and turning the documented
        // `200 { parsed: false }` into a 500 for anyone whose bank SMS didn't
        // match a pattern. See migration 0033's header; the RPC is SECURITY
        // DEFINER and also aggregates repeats into `occurrences` instead of
        // inserting a near-duplicate row per message.
        const failure = await client.query(
          `SELECT pandapay.record_parser_failure('sms', $1, $2, $3) AS id`,
          [sender || null, redactSmsShape(body), appVersion || null]
        );
        return {
          status: 200,
          parsed: false,
          reason: parsed.reason,
          creditLimitDetected: Boolean(limitSync),
          creditLimitUpdated: Boolean(limitSync?.updated),
          dueDateDetected: Boolean(dueDaySync),
          dueDayUpdated: Boolean(dueDaySync?.updated),
          statementDateDetected: Boolean(statementDaySync),
          statementDayUpdated: Boolean(statementDaySync?.updated),
          subscriptionMandateDetected: Boolean(mandateRow),
          subscriptionMandateId: mandateRow?.id || null,
          parserFailure: { id: failure.rows[0].id },
        };
      }

      // Bump the winning pattern's telemetry in the same transaction as the
      // insert it enabled — success_count/failure_count are evidently meant
      // to track a pattern's live hit rate, not just exist unused.
      if (parsed.patternId) {
        await client.query(
          `UPDATE parser_patterns SET success_count = success_count + 1, updated_at = now() WHERE id = $1`,
          [parsed.patternId]
        );
      }

      // The SMS's own date beats the request's, which beats now(). Banks
      // text about a swipe that already happened, sometimes hours later and
      // occasionally the next morning; filing it under the moment the
      // device happened to forward it puts spend in the wrong week and, at
      // a month boundary, the wrong month.
      const parsedTimestamp = parseSmsTransactionTimestamp(parsed.fields.date, body, occurred);
      const parsedDate = parsedTimestamp.date;
      // The request timestamp is the SMS-received time and is used for the
      // accounting date only when the bank's own date cannot be parsed. The
      // idempotency key deliberately does not use either timestamp: Android
      // can expose one message through broadcast and inbox with different
      // receive times.
      const effectiveOccurred = parsedDate || occurred;
      // Sender + body are available even when the caller has no provider
      // timestamp, so replay protection should not disappear in that case.
      const sourceKey = importSourceKey(req.userId, sender, body);

      await importResolvers.syncCreditLimitFromSms(client, req.userId, {
        body,
        patternIssuerId: patternRow ? patternRow.issuer_id : uniqueSmsPatternIssuerId(patterns.rows, sender),
      });

      const inserted = await importParsedMessage(client, req.userId, {
        parsed,
        patternIssuerId: patternRow ? patternRow.issuer_id : null,
        sender,
        rawText: body,
        source: 'sms',
        occurred: effectiveOccurred,
        sourceKey,
        backfill: backfill === true,
        observedAt: occurred,
        explicitUserCardId: userCardId,
        explicitCategoryId: categoryId || null,
        rail,
        observationMetadata: {
          transport: 'sms',
          ...(parsedTimestamp.precise ? { transactionTimePrecise: true } : {}),
          ...(parsed.fields.last4 ? { cardLast4: parsed.fields.last4 } : {}),
          ...(patternRow?.issuer_id ? { patternIssuerId: patternRow.issuer_id } : {}),
        },
      });

      if (inserted.needsReview) {
        // Parsed fine, but we can't say which card it belongs to. Filed for
        // the user to confirm rather than rejected — the old 400 threw away
        // a perfectly good transaction because one field was unknown.
        return {
          status: 200,
          ...inserted,
          patternId: parsed.patternId,
          dueDateDetected: Boolean(dueDaySync),
          dueDayUpdated: Boolean(dueDaySync?.updated),
          statementDateDetected: Boolean(statementDaySync),
          statementDayUpdated: Boolean(statementDaySync?.updated),
        };
      }

      if (inserted.status === 200 && inserted.duplicate) {
        // Already imported. Reported as its own outcome rather than folded
        // into `parsed: true`, so the client can tell the user "42 already
        // imported, skipped" instead of counting them again.
        return {
          status: 200,
          parsed: true,
          duplicate: true,
          transaction: inserted.transaction,
          patternId: parsed.patternId,
          dueDateDetected: Boolean(dueDaySync),
          dueDayUpdated: Boolean(dueDaySync?.updated),
          statementDateDetected: Boolean(statementDaySync),
          statementDayUpdated: Boolean(statementDaySync?.updated),
        };
      }
      if (inserted.status !== 201) return inserted;
      return {
        status: 201,
        parsed: true,
        patternId: parsed.patternId,
        dueDateDetected: Boolean(dueDaySync),
        dueDayUpdated: Boolean(dueDaySync?.updated),
        statementDateDetected: Boolean(statementDaySync),
        statementDayUpdated: Boolean(statementDaySync?.updated),
        ...inserted,
      };
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

/** Largest batch accepted by POST /transactions/from-sms/batch. */
const SMS_BATCH_LIMIT = 200;

/**
 * POST /transactions/from-sms/batch — smsextractionimple.md Task S-1a.
 *
 * The backup-file import used to make one HTTP round trip per message, in a
 * sequential loop, behind a static "Importing…" label. A five-thousand
 * message export was five thousand requests: slow enough that users kill
 * the app mid-import, and enough redundant TLS/auth/pattern-load work to
 * matter on the server too. Same per-message semantics as the single route
 * — this is a transport change, not a behaviour change.
 *
 * Deliberately NOT one big database transaction. A partial import is a
 * perfectly good outcome here (the messages that parsed are real
 * transactions the user wants kept), and `source_key` makes resuming safe:
 * re-sending a batch that half-succeeded skips what already landed. Rolling
 * the whole thing back on one bad message would throw away good data to
 * preserve a consistency property nobody needs.
 *
 * Patterns are loaded ONCE for the whole batch rather than per message,
 * which is most of the speedup.
 */
app.post('/transactions/from-sms/batch', requireAuth, async (req, res) => {
  const { messages, backfill, appVersion } = req.body || {};
  if (!Array.isArray(messages) || messages.length === 0) {
    return res.status(400).json({ error: 'messages must be a non-empty array' });
  }
  if (messages.length > SMS_BATCH_LIMIT) {
    return res.status(400).json({ error: `messages may not exceed ${SMS_BATCH_LIMIT} per request` });
  }

  try {
    const payload = await withUserClient(req.userId, async (client) => {
      const patterns = await client.query(
        `SELECT id, issuer_id, sender_pattern, regex, field_map
           FROM parser_patterns
          WHERE channel = 'sms' AND is_active = true
          ORDER BY version DESC`
      );

      const results = [];
      let dueDatesUpdated = 0;
      let statementDaysUpdated = 0;

      // Spend uploads are intentionally current-month-first, but billing
      // detection should prefer printed statement dates. A printed
      // generation or period-end date is self-dated and wins outright;
      // arrival-date fallbacks rank by the same previous-cycle preference as
      // before. use the current month only when no history is present.
      const now = new Date();
      const nowParts = new Intl.DateTimeFormat('en-CA', {
        timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit',
      }).formatToParts(now);
      const nowYear = Number(nowParts.find((part) => part.type === 'year')?.value);
      const nowMonth = Number(nowParts.find((part) => part.type === 'month')?.value);
      const nowMonthIndex = nowYear * 12 + nowMonth - 1;
      const statementCandidates = [];
      for (let i = 0; i < messages.length; i += 1) {
        const message = messages[i] || {};
        if (!message.body || typeof message.body !== 'string') continue;
        const occurred = message.occurredAt ? new Date(message.occurredAt) : null;
        if (!occurred || Number.isNaN(occurred.getTime())) continue;
        const detected = importResolvers.extractStatementDate(message.body, occurred);
        if (!detected) continue;
        const parts = new Intl.DateTimeFormat('en-CA', {
          timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit',
        }).formatToParts(occurred);
        const year = detected.explicit
          ? detected.date.getFullYear()
          : Number(parts.find((part) => part.type === 'year')?.value);
        const month = detected.explicit
          ? detected.date.getMonth() + 1
          : Number(parts.find((part) => part.type === 'month')?.value);
        const distance = nowMonthIndex - (year * 12 + month - 1);
        if (detected.explicit ? distance >= 0 : (distance === 1 || distance === 2)) {
          statementCandidates.push({ index: i, distance, explicit: detected.explicit, receivedAt: occurred.getTime() });
        }
      }
      statementCandidates.sort((a, b) => {
        const rank = (candidate) => candidate.explicit ? 0
          : candidate.distance === 1 ? 1
            : candidate.distance === 2 ? 2
              : 3;
        return rank(a) - rank(b)
          || Number(b.explicit) - Number(a.explicit)
          || a.receivedAt - b.receivedAt
          || a.index - b.index;
      });
      for (const candidate of statementCandidates) {
        const message = messages[candidate.index];
        const occurred = new Date(message.occurredAt);
        const synced = await importResolvers.syncStatementDayFromSms(client, req.userId, {
          body: message.body,
          patternIssuerId: uniqueSmsPatternIssuerId(patterns.rows, message.sender),
          observedAt: occurred,
          explicitUserCardId: message.userCardId,
        });
        if (synced?.updated) statementDaysUpdated += 1;
      }

      for (let i = 0; i < messages.length; i += 1) {
        const { sender, body, userCardId, occurredAt, categoryId, rail } = messages[i] || {};
        // userCardId is no longer required per message — see
        // [importParsedMessage]. A message whose card can't be resolved is
        // filed for review rather than rejected, which is what makes a
        // multi-thousand-message backfill possible without a tap per
        // message.
        if (!body || typeof body !== 'string' || !body.trim()) {
          results.push({ index: i, outcome: 'invalid', reason: 'body is required' });
          continue;
        }
        const occurred = occurredAt ? new Date(occurredAt) : null;
        if (!occurred || Number.isNaN(occurred.getTime())) {
          // No usable original timestamp means no reliable accounting date.
          // Reject rather than silently dating the message `now()` — that
          // default is the D2 bug this task exists to remove.
          results.push({ index: i, outcome: 'invalid', reason: 'occurredAt is required for a batch import' });
          continue;
        }

        const statementDateDetected = Boolean(
          importResolvers.extractStatementDate(body, occurred),
        );
        const parsed = parseSmsAgainstPatterns(patterns.rows, {
  sender,
  body,
  ownUserName: await profileDisplayName(client, req.userId),
});
        const patternRow = patterns.rows.find((p) => p.id === parsed.patternId);
        const dueDaySync = await importResolvers.syncDueDayFromSms(client, req.userId, {
          body,
          observedAt: occurred,
          patternIssuerId: patternRow ? patternRow.issuer_id : uniqueSmsPatternIssuerId(patterns.rows, sender),
          explicitUserCardId: userCardId,
        });
        if (dueDaySync?.updated) dueDatesUpdated += 1;
        if (!parsed.ok) {
          await importResolvers.syncCreditLimitFromSms(client, req.userId, {
            body,
            patternIssuerId: uniqueSmsPatternIssuerId(patterns.rows, sender),
          });
          const mandate = parseSubscriptionMandate({ sender, body });
          const mandateRow = mandate.ok
            ? await persistSubscriptionMandate(client, req.userId, {
                parsed: mandate,
                body,
                occurred,
                patternIssuerId: uniqueSmsPatternIssuerId(patterns.rows, sender),
              })
            : null;
          await client.query(
            `SELECT pandapay.record_parser_failure('sms', $1, $2, $3) AS id`,
            [sender || null, redactSmsShape(body), appVersion || null]
          );
          results.push({
            index: i,
            outcome: 'unparsed',
            reason: parsed.reason,
            dueDateDetected: Boolean(dueDaySync),
            dueDayUpdated: Boolean(dueDaySync?.updated),
            statementDateDetected,
            statementDayUpdated: false,
            subscriptionMandateDetected: Boolean(mandateRow),
            subscriptionMandateId: mandateRow?.id || null,
          });
          continue;
        }

        if (parsed.patternId) {
          await client.query(
            `UPDATE parser_patterns SET success_count = success_count + 1, updated_at = now() WHERE id = $1`,
            [parsed.patternId]
          );
        }

        await importResolvers.syncCreditLimitFromSms(client, req.userId, {
          body,
          patternIssuerId: patternRow ? patternRow.issuer_id : uniqueSmsPatternIssuerId(patterns.rows, sender),
        });
        // The bank's transaction date is the accounting date. Using the
        // received time here moves backfilled purchases into the wrong
        // week/month whenever a message arrives later than the purchase.
        const parsedTimestamp = parseSmsTransactionTimestamp(parsed.fields.date, body, occurred);
        const effectiveOccurred = parsedTimestamp.date || occurred;
        const inserted = await importParsedMessage(client, req.userId, {
          parsed,
          patternIssuerId: patternRow ? patternRow.issuer_id : null,
          sender,
          rawText: body,
          source: 'sms',
          occurred: effectiveOccurred,
          observedAt: occurred,
          sourceKey: importSourceKey(req.userId, sender, body),
          backfill: backfill === true,
          explicitUserCardId: userCardId,
          explicitCategoryId: categoryId || null,
          rail,
          observationMetadata: {
            transport: 'sms',
            ...(parsedTimestamp.precise ? { transactionTimePrecise: true } : {}),
            ...(parsed.fields.last4 ? { cardLast4: parsed.fields.last4 } : {}),
            ...(patternRow?.issuer_id ? { patternIssuerId: patternRow.issuer_id } : {}),
          },
        });

        if (inserted.needsReview) {
          results.push({
            index: i,
            outcome: 'needs_review',
            needsReviewItemId: inserted.needsReviewItemId,
            dueDateDetected: Boolean(dueDaySync),
            dueDayUpdated: Boolean(dueDaySync?.updated),
            statementDateDetected,
            statementDayUpdated: false,
          });
        } else if (inserted.status === 200 && inserted.duplicate) {
          results.push({
            index: i,
            outcome: 'duplicate',
            transactionId: inserted.transaction?.id,
            transaction: inserted.transaction,
            dueDateDetected: Boolean(dueDaySync),
            dueDayUpdated: Boolean(dueDaySync?.updated),
            statementDateDetected,
            statementDayUpdated: false,
          });
        } else if (inserted.status === 201) {
          results.push({
            index: i,
            outcome: 'imported',
            transactionId: inserted.transaction.id,
            dueDateDetected: Boolean(dueDaySync),
            dueDayUpdated: Boolean(dueDaySync?.updated),
            statementDateDetected,
            statementDayUpdated: false,
          });
        } else {
          results.push({
            index: i,
            outcome: 'error',
            reason: inserted.error,
            dueDateDetected: Boolean(dueDaySync),
            dueDayUpdated: Boolean(dueDaySync?.updated),
          });
        }
      }

      return {
        results,
        summary: {
          imported: results.filter((r) => r.outcome === 'imported').length,
          duplicate: results.filter((r) => r.outcome === 'duplicate').length,
          needsReview: results.filter((r) => r.outcome === 'needs_review').length,
          unparsed: results.filter((r) => r.outcome === 'unparsed').length,
          invalid: results.filter((r) => r.outcome === 'invalid').length,
          error: results.filter((r) => r.outcome === 'error').length,
          dueDatesUpdated,
          statementDaysUpdated,
        },
      };
    });

    res.status(200).json(payload);
  } catch (err) {
    console.error('POST /transactions/from-sms/batch error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /transactions/reconcile-sms — repair safe legacy SMS replays and
 * classify rows imported before merchant-category resolution was enabled.
 * This is intentionally idempotent and user-scoped; it never inserts a
 * transaction and it never merges two live purchases without a backfill row.
 */
app.post('/transactions/reconcile-sms', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      repairSmsHistory(client, req.userId, { reviewCrossSource: true }));
    res.json({ ...result, reconciliationVersion: 2 });
  } catch (err) {
    console.error('POST /transactions/reconcile-sms error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /transactions/sms-import-state — the small amount of server state the
 * Android inbox reconciler needs to detect a server-side data reset. The
 * client keeps its last successful inbox checkpoint locally; comparing this
 * count lets it recover with a full inbox scan when the account's imported
 * SMS observations were deleted, without rescanning the entire inbox on
 * every normal launch.
 */
app.get('/transactions/sms-import-state', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT COUNT(*)::int AS sms_observation_count,
                MAX(o.observed_at) AS latest_sms_observed_at
           FROM transaction_observations o
          WHERE o.profile_id = $1
            AND o.source IN ('sms', 'sms_bulk')`,
        [req.userId],
      ),
    );
    const row = result.rows[0] ?? {};
    res.json({
      smsObservationCount: Number(row.sms_observation_count ?? 0),
      latestSmsObservedAt: row.latest_sms_observed_at ?? null,
    });
  } catch (err) {
    console.error('GET /transactions/sms-import-state error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /account-summaries — masked bank accounts observed in SMS imports or
 * persisted on categorized cardless transactions. Only observations marked
 * as deposit/current/savings-bank evidence are eligible; an account-shaped
 * suffix from LIC, brokerage, demat, investment, or card alerts is not a
 * bank-account row.
 *
 * Account balances are only returned when an SMS explicitly included an
 * available/current balance. The balance timestamp is selected independently
 * from the latest SMS timestamp, so a newer transaction without a balance
 * cannot erase the last known balance snapshot.
 */
app.get('/account-summaries', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `WITH account_observations AS (
           SELECT o.metadata->>'accountLast4' AS account_last4,
                  o.metadata->>'patternIssuerId' AS issuer_id,
                  -- DLT channel prefixes ("AD-"/"AX-") and suffixes ("-S")
                  -- are transport metadata, not account identity. Fall back
                  -- to the channel-stripped bank code so legacy rows without
                  -- an issuer id still collapse into one account.
                  COALESCE(
                    o.metadata->>'accountIdentity',
                    o.metadata->>'patternIssuerId',
                    NULLIF(regexp_replace(
                             regexp_replace(
                               lower(o.metadata->>'senderBank'),
                               '^[a-z0-9]{2}-', ''
                             ),
                             '[-][a-z]$', ''
                           ), ''),
                    'legacy:' || (o.metadata->>'accountLast4')
                  ) AS account_identity,
                  NULLIF(o.metadata->>'senderBank', '') AS sender_bank,
                  CASE
                    WHEN o.metadata->>'availableBalanceInr' ~ '^[0-9]+(\\.[0-9]+)?$'
                    THEN (o.metadata->>'availableBalanceInr')::numeric
                    ELSE NULL
                  END AS available_balance_inr,
                  o.observed_at,
                  'sms' AS source_kind
             FROM transaction_observations o
             JOIN transactions t
               ON t.id = o.transaction_id
              AND t.profile_id = o.profile_id
             LEFT JOIN issuers oi
               ON oi.id::text = o.metadata->>'patternIssuerId'
             WHERE o.profile_id = $1
               AND o.source IN ('sms', 'sms_bulk')
               AND o.metadata->>'accountLast4' ~ '^[0-9]{4}$'
               AND t.instrument IN ('upi_bank', 'debit_card')
               AND t.entry_kind <> 'investment'
               AND COALESCE(o.metadata->>'isBankAccount', 'legacy') <> 'false'
               -- UPI-platform senders (SBIUPI & friends) quote the
               -- counterparty's masked account, never the user's own; they
               -- must not mint account rows regardless of parser verdict.
               AND lower(coalesce(o.metadata->>'senderBank', '')) !~ 'upi'
               -- Axio Pay Later identifiers are lending liabilities, not
               -- deposit-bank accounts. Keep historical true verdicts out.
               AND lower(coalesce(o.metadata->>'senderBank', '')) !~ 'axio'
               AND (
                o.metadata->>'isBankAccount' = 'true'
                OR (
                  o.metadata->>'isBankAccount' IS NULL
                  AND lower(coalesce(o.metadata->>'senderBank', '')) !~ '(lic|licind|dhan|dhanhq|paytm[-_ ]*money|trading|demat|broker|mutual|investment|portfolio|groww|zerodha|upstox|angel)'
                  AND lower(coalesce(oi.slug, '')) !~ '(lic|licind|dhan|dhanhq|paytm[-_ ]*money|trading|demat|broker|mutual|investment|portfolio|groww|zerodha|upstox|angel)'
                  AND lower(coalesce(oi.name, '')) !~ '(lic|licind|dhan|dhanhq|paytm[-_ ]*money|trading|demat|broker|mutual|investment|portfolio|groww|zerodha|upstox|angel)'
                  AND (
                    lower(coalesce(o.metadata->>'senderBank', '')) ~ '(bank|bnk|bk|upi|sbi|uco|axis|canara|canbnk|canbk|hdfc|kotak|union|equitas|eqt|pnb|icici|idbi|indus|yes|rbl|bob|boi|pytm|paytm|federal|aubank|citi|hsbc|dbs|scb)'
                    OR lower(coalesce(oi.slug, '')) ~ '(bank|bnk|bk|upi|sbi|uco|axis|canara|canbnk|canbk|hdfc|kotak|union|equitas|eqt|pnb|icici|idbi|indus|yes|rbl|bob|boi|pytm|paytm|federal|aubank|citi|hsbc|dbs|scb)'
                    OR lower(coalesce(oi.name, '')) ~ '(bank|bnk|bk|upi|sbi|uco|axis|canara|canbnk|canbk|hdfc|kotak|union|equitas|eqt|pnb|icici|idbi|indus|yes|rbl|bob|boi|pytm|paytm|federal|aubank|citi|hsbc|dbs|scb)'
                  )
                )
              )
         ), transaction_accounts AS (
           SELECT t.source_account_last4 AS account_last4,
                  NULL::text AS issuer_id,
                  ('legacy:' || t.source_account_last4) AS account_identity,
                  NULL::text AS sender_bank,
                  NULL::numeric AS available_balance_inr,
                  NULL::timestamptz AS observed_at,
                  'transaction' AS source_kind
             FROM transactions t
            WHERE t.profile_id = $1
              AND t.status = 'active'
              AND t.instrument IN ('upi_bank', 'debit_card')
              AND t.entry_kind <> 'investment'
              AND t.source_account_last4 ~ '^[0-9]{4}$'
              AND NOT EXISTS (
                SELECT 1
                  FROM transaction_observations existing_o
                 WHERE existing_o.profile_id = t.profile_id
                   AND existing_o.transaction_id = t.id
                   AND existing_o.metadata->>'accountLast4' = t.source_account_last4
              )
              AND EXISTS (
                SELECT 1
                  FROM transaction_observations bo
                  LEFT JOIN issuers bi
                    ON bi.id::text = bo.metadata->>'patternIssuerId'
                 WHERE bo.profile_id = t.profile_id
                   AND bo.transaction_id = t.id
                   AND bo.source IN ('sms', 'sms_bulk')
                    AND bo.metadata->>'accountLast4' = t.source_account_last4
                    AND COALESCE(bo.metadata->>'isBankAccount', 'legacy') <> 'false'
                    AND lower(coalesce(bo.metadata->>'senderBank', '')) !~ 'upi'
                    AND lower(coalesce(bo.metadata->>'senderBank', '')) !~ 'axio'
                    AND (
                     bo.metadata->>'isBankAccount' = 'true'
                     OR (
                       bo.metadata->>'isBankAccount' IS NULL
                       AND lower(coalesce(bo.metadata->>'senderBank', '')) !~ '(lic|licind|dhan|dhanhq|paytm[-_ ]*money|trading|demat|broker|mutual|investment|portfolio|groww|zerodha|upstox|angel)'
                       AND lower(coalesce(bi.slug, '')) !~ '(lic|licind|dhan|dhanhq|paytm[-_ ]*money|trading|demat|broker|mutual|investment|portfolio|groww|zerodha|upstox|angel)'
                       AND lower(coalesce(bi.name, '')) !~ '(lic|licind|dhan|dhanhq|paytm[-_ ]*money|trading|demat|broker|mutual|investment|portfolio|groww|zerodha|upstox|angel)'
                       AND (
                         lower(coalesce(bo.metadata->>'senderBank', '')) ~ '(bank|bnk|bk|upi|sbi|uco|axis|canara|canbnk|canbk|hdfc|kotak|union|equitas|eqt|pnb|icici|idbi|indus|yes|rbl|bob|boi|pytm|paytm|federal|aubank|citi|hsbc|dbs|scb)'
                         OR lower(coalesce(bi.slug, '')) ~ '(bank|bnk|bk|upi|sbi|uco|axis|canara|canbnk|canbk|hdfc|kotak|union|equitas|eqt|pnb|icici|idbi|indus|yes|rbl|bob|boi|pytm|paytm|federal|aubank|citi|hsbc|dbs|scb)'
                         OR lower(coalesce(bi.name, '')) ~ '(bank|bnk|bk|upi|sbi|uco|axis|canara|canbnk|canbk|hdfc|kotak|union|equitas|eqt|pnb|icici|idbi|indus|yes|rbl|bob|boi|pytm|paytm|federal|aubank|citi|hsbc|dbs|scb)'
                       )
                     )
                   )
              )
            GROUP BY t.source_account_last4
         ), account_sources AS (
           SELECT account_last4, issuer_id, account_identity, sender_bank,
                  available_balance_inr, observed_at, source_kind
             FROM account_observations
           UNION ALL
           SELECT account_last4, issuer_id, account_identity, sender_bank,
                  available_balance_inr, observed_at, source_kind
             FROM transaction_accounts
         ), account_rollup AS (
           SELECT account_last4,
                  account_identity,
                  (array_agg(issuer_id ORDER BY observed_at DESC)
                    FILTER (WHERE issuer_id IS NOT NULL))[1] AS issuer_id,
                  (array_agg(sender_bank ORDER BY observed_at DESC)
                    FILTER (WHERE sender_bank IS NOT NULL))[1] AS sender_bank,
                  (array_agg(available_balance_inr ORDER BY observed_at DESC)
                    FILTER (WHERE available_balance_inr IS NOT NULL))[1]
                    AS available_balance_inr,
                  (array_agg(observed_at ORDER BY observed_at DESC)
                    FILTER (WHERE available_balance_inr IS NOT NULL))[1]
                    AS latest_balance_sms_at,
                  MAX(observed_at) FILTER (WHERE source_kind = 'sms') AS latest_sms_at,
                  COUNT(*) FILTER (WHERE source_kind = 'sms') AS sms_count
             FROM account_sources
            GROUP BY account_last4, account_identity
         )
         SELECT r.account_last4,
                r.available_balance_inr,
                r.latest_balance_sms_at,
                r.latest_sms_at,
                r.sms_count,
                i.slug AS issuer_slug,
                i.name AS issuer_name,
                COALESCE(
                  i.short_name,
                  initcap(regexp_replace(
                             regexp_replace(
                               lower(r.sender_bank),
                               '^[a-z0-9]{2}-', ''
                             ),
                             '[-][a-z]$', ''
                           )),
                  r.sender_bank
                ) AS issuer_short_name,
                i.logo_url AS issuer_logo_url
           FROM account_rollup r
           LEFT JOIN issuers i ON i.id::text = r.issuer_id
          WHERE NOT EXISTS (
            SELECT 1 FROM user_cards uc
             WHERE uc.profile_id = $1 AND uc.last4 = r.account_last4
          )
            AND NOT EXISTS (
              SELECT 1 FROM transaction_observations card_o
               WHERE card_o.profile_id = $1
                 AND card_o.source IN ('sms', 'sms_bulk')
                 AND card_o.metadata->>'cardLast4' = r.account_last4
            )
          ORDER BY r.account_last4, r.account_identity`,
        [req.userId],
      ),
    );
    res.json({
      accounts: result.rows.map((row) => ({
        accountLast4: row.account_last4,
        availableBalanceInr: row.available_balance_inr == null
          ? null
          : Number(row.available_balance_inr),
        latestBalanceSmsAt: row.latest_balance_sms_at,
        latestSmsAt: row.latest_sms_at,
        smsCount: Number(row.sms_count ?? 0),
        issuerSlug: row.issuer_slug,
        issuerName: row.issuer_name,
        issuerShortName: row.issuer_short_name,
        issuerLogoUrl: row.issuer_logo_url,
      })),
    });
  } catch (err) {
    console.error('GET /account-summaries error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /transactions?from=&to=&cardId=&categoryId=&source=&q=&limit= — E10/E11/D1's shared gap
 * (implementation-plan-group-e-f-g.md: "third consumer of the same missing
 * query param — build it once"). All three are optional; omitting them
 * keeps the original "last 50, no filter" behaviour so existing callers
 * (the Activity tab) are unaffected. `from`/`to` are inclusive date
 * boundaries (YYYY-MM-DD), matched against occurred_at's date component so
 * a caller doesn't need to think about timezone-of-day edge cases.
 */
app.get('/transactions', requireAuth, async (req, res) => {
  let tagFilter;
  try { tagFilter = transactionTags.readTagFilter(req.query); }
  catch (error) { return res.status(400).json({ error: error.message }); }
  const { from, to, cardId, categoryId, userCategoryId, source, q, status = 'active' } = req.query;
  if (!['active', 'deleted'].includes(status)) {
    return res.status(400).json({ error: 'status must be active or deleted' });
  }
  // Keep transaction-list consumers aligned with spend reports even before a
  // background reconciliation has run. Only a unique archived -> active
  // physical-card match is eligible; ambiguity remains visible as unmatched.
  const canonicalCardId = 'COALESCE(replacement.active_card_id, t.user_card_id)';
  const statusCondition = status === 'deleted'
    ? `(t.status = 'deleted' OR (t.status = 'ignored' AND t.note LIKE '[ignored: transfer]%'))`
    : `(t.status = 'active' OR (t.status = 'ignored' AND (t.note LIKE '[ignored: refund]%' OR t.note LIKE '[ignored: reversal]%')))`;
  const conditions = [`t.profile_id = $1`, statusCondition];
  const params = [req.userId];
  // Task D-1's last missing filter: free-text search. activity_screen.dart
  // shipped without a search box because there was no server-side text
  // match to call, and filtering client-side would only ever have searched
  // the 50 rows already loaded rather than the user's history.
  //
  // ILIKE over merchant and note, not full-text search: these are short
  // free-text fields where users type fragments ("zep", "swig"), and
  // to_tsvector would tokenise those into non-matching lexemes. The `%`
  // wrappers are bound as a parameter value, never concatenated into SQL.
  if (typeof q === 'string' && q.trim().length > 0) {
    params.push(`%${q.trim()}%`);
    conditions.push(`(t.merchant_name ILIKE $${params.length} OR t.note ILIKE $${params.length})`);
  }
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
    conditions.push(`${canonicalCardId} = $${params.length}`);
  }
  // Task D-1: category/source filters (ui-spec D1 "Search + filters (date,
  // card, category, source, needs-review)") — needs-review isn't a
  // transactions-table filter at all (it's the separate parser_failures
  // queue, D4's territory), so it isn't one of this route's params.
  if (categoryId) {
    params.push(categoryId);
    conditions.push(`(
      t.category_id = $${params.length}
      OR t.user_category_id = $${params.length}
      OR EXISTS (
        SELECT 1
          FROM user_categories child_category
         WHERE child_category.id = t.user_category_id
           AND child_category.parent_user_category_id = $${params.length}
           AND child_category.profile_id = t.profile_id
      )
    )`);
  }
  if (userCategoryId) {
    params.push(userCategoryId);
    conditions.push(`(
      t.user_category_id = $${params.length}
      OR EXISTS (
        SELECT 1
          FROM user_categories child_category
         WHERE child_category.id = t.user_category_id
           AND child_category.parent_user_category_id = $${params.length}
           AND child_category.profile_id = t.profile_id
      )
    )`);
  }
  if (source) {
    params.push(source);
    conditions.push(`t.source = $${params.length}`);
  }
  // Activity is the canonical transaction-history surface. Do not silently
  // hide older incoming or outgoing movements behind an unfiltered "last 50"
  // cap; callers can still constrain the result with date/card/category/source
  // filters when they need a narrower view.
  const limitClause = '';

  try {
    const result = await withUserClient(req.userId, (client) =>
      transactionTags.tagQueryClient(client, req.userId, tagFilter).query(
        `WITH replacement_candidates AS (
          SELECT archived.id AS archived_card_id, active.id AS active_card_id
            FROM user_cards archived
            JOIN card_products archived_product ON archived_product.id = archived.card_product_id
            JOIN user_cards active
              ON active.profile_id = archived.profile_id
             AND active.is_archived = false
             AND active.last4 = archived.last4
            JOIN card_products active_product ON active_product.id = active.card_product_id
           WHERE archived.profile_id = $1
             AND archived.is_archived = true
             AND archived.last4 ~ '^[0-9]{4}$'
             AND archived_product.issuer_id = active_product.issuer_id
             AND archived_product.card_type = active_product.card_type
             AND archived.id <> active.id
        ), unique_replacements AS (
          SELECT archived_card_id, (array_agg(active_card_id ORDER BY active_card_id))[1] AS active_card_id
            FROM replacement_candidates
           GROUP BY archived_card_id
          HAVING COUNT(*) = 1
        )
        SELECT t.id, t.source_key, ${canonicalCardId} AS user_card_id, t.amount_inr, t.occurred_at, t.merchant_name,
                t.merchant_vpa::text AS merchant_vpa,
                t.category_id, t.user_category_id,
                ucat.parent_user_category_id AS parent_user_category_id,
                COALESCE(parent_sc.name, parent_uc.name, sc.name, ucat.name) AS category_name,
                CASE WHEN ucat.parent_category_id IS NOT NULL OR ucat.parent_user_category_id IS NOT NULL THEN ucat.name END AS subcategory_name,
                t.rail, t.status, t.source, t.note,
                t.instrument, t.entry_kind, t.reward_state,
                t.expected_value_inr,
                (SELECT MAX(o.observed_at)
                   FROM transaction_observations o
                  WHERE o.transaction_id = t.id
                    AND o.source IN ('sms', 'sms_bulk')) AS sms_received_at,
                COALESCE(t.source_account_last4,
                  (SELECT o.metadata->>'accountLast4'
                     FROM transaction_observations o
                    WHERE o.transaction_id = t.id
                      AND o.source IN ('sms', 'sms_bulk')
                    ORDER BY o.observed_at DESC
                    LIMIT 1)) AS account_last4,
                (SELECT o.metadata->>'cardLast4'
                   FROM transaction_observations o
                  WHERE o.transaction_id = t.id
                    AND o.source IN ('sms', 'sms_bulk')
                  ORDER BY o.observed_at DESC
                  LIMIT 1) AS card_last4,
                cp.name AS card_name, uc.nickname AS card_nickname
           FROM transactions t
           LEFT JOIN unique_replacements replacement ON replacement.archived_card_id = t.user_card_id
           LEFT JOIN user_cards uc ON uc.id = ${canonicalCardId}
           LEFT JOIN card_products cp ON cp.id = uc.card_product_id
           LEFT JOIN spend_categories sc ON sc.id = t.category_id
           LEFT JOIN user_categories ucat ON ucat.id = t.user_category_id AND ucat.profile_id = t.profile_id
           LEFT JOIN spend_categories parent_sc ON parent_sc.id = ucat.parent_category_id
           LEFT JOIN user_categories parent_uc ON parent_uc.id = ucat.parent_user_category_id AND parent_uc.profile_id = t.profile_id
          WHERE ${conditions.join(' AND ')}
          ORDER BY t.occurred_at DESC ${limitClause}`,
        params
      )
    );
    const rows = await withUserClient(req.userId, (client) => transactionTags.attachTags(client, req.userId, result.rows));
    res.json({ transactions: rows });
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
        `WITH replacement_candidates AS (
          SELECT archived.id AS archived_card_id, active.id AS active_card_id
            FROM user_cards archived
            JOIN card_products archived_product ON archived_product.id = archived.card_product_id
            JOIN user_cards active
              ON active.profile_id = archived.profile_id
             AND active.is_archived = false
             AND active.last4 = archived.last4
            JOIN card_products active_product ON active_product.id = active.card_product_id
           WHERE archived.profile_id = $2
             AND archived.is_archived = true
             AND archived.last4 ~ '^[0-9]{4}$'
             AND archived_product.issuer_id = active_product.issuer_id
             AND archived_product.card_type = active_product.card_type
             AND archived.id <> active.id
        ), unique_replacements AS (
          SELECT archived_card_id, (array_agg(active_card_id ORDER BY active_card_id))[1] AS active_card_id
            FROM replacement_candidates
           GROUP BY archived_card_id
          HAVING COUNT(*) = 1
        )
        SELECT t.id, COALESCE(replacement.active_card_id, t.user_card_id) AS user_card_id,
               t.amount_inr, t.occurred_at, t.merchant_name,
                t.category_id, t.user_category_id,
                ucat.parent_user_category_id AS parent_user_category_id,
                COALESCE(parent_sc.name, parent_uc.name, sc.name, ucat.name) AS category_name,
                CASE WHEN ucat.parent_category_id IS NOT NULL OR ucat.parent_user_category_id IS NOT NULL THEN ucat.name END AS subcategory_name,
                t.rail, t.status, t.source, t.note,
                t.instrument, t.entry_kind, t.reward_state,
                t.expected_value_inr,
                COALESCE(t.source_account_last4,
                  (SELECT o.metadata->>'accountLast4'
                     FROM transaction_observations o
                    WHERE o.transaction_id = t.id
                      AND o.source IN ('sms', 'sms_bulk')
                    ORDER BY o.observed_at DESC
                    LIMIT 1)) AS account_last4,
                (SELECT o.metadata->>'cardLast4'
                   FROM transaction_observations o
                  WHERE o.transaction_id = t.id
                    AND o.source IN ('sms', 'sms_bulk')
                  ORDER BY o.observed_at DESC
                  LIMIT 1) AS card_last4,
                (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'source', evidence.source,
                    'source_key', evidence.source_key,
                    'observed_at', evidence.observed_at,
                    'reference', evidence.external_ref
                  ) ORDER BY evidence.observed_at), '[]'::jsonb)
                   FROM transaction_observations evidence
                  WHERE evidence.transaction_id = t.id
                    AND evidence.profile_id = t.profile_id) AS observations,
                cp.name AS card_name, uc.nickname AS card_nickname
           FROM transactions t
           LEFT JOIN unique_replacements replacement ON replacement.archived_card_id = t.user_card_id
           LEFT JOIN user_cards uc ON uc.id = COALESCE(replacement.active_card_id, t.user_card_id)
           LEFT JOIN card_products cp ON cp.id = uc.card_product_id
           LEFT JOIN spend_categories sc ON sc.id = t.category_id
           LEFT JOIN user_categories ucat ON ucat.id = t.user_category_id AND ucat.profile_id = t.profile_id
           LEFT JOIN spend_categories parent_sc ON parent_sc.id = ucat.parent_category_id
           LEFT JOIN user_categories parent_uc ON parent_uc.id = ucat.parent_user_category_id AND parent_uc.profile_id = t.profile_id
          WHERE t.id = $1 AND t.profile_id = $2`,
        [req.params.id, req.userId]
      )
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'transaction not found' });
    const [transaction] = await withUserClient(req.userId, (client) => transactionTags.attachTags(client, req.userId, result.rows));
    res.json({ transaction });
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
        `SELECT id, txn_a_id, txn_b_id, match_score, match_reason, suppressed_txn_id, detected_at
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
      // Candidate creation uses the same transaction lock: no new edge may
      // appear after we enumerate the neighbors that this decision releases.
      await client.query("SELECT pg_advisory_xact_lock(hashtextextended('duplicate-review:' || $1::text, 0))", [req.userId]);
      const pair = await client.query(
        `SELECT id, txn_a_id, txn_b_id, suppressed_txn_id, state
           FROM duplicate_candidates WHERE id = $1 AND profile_id = $2 FOR UPDATE`,
        [req.params.id, req.userId]
      );
      if (pair.rows.length === 0) return null;
      const {
        txn_a_id: txnA,
        txn_b_id: txnB,
        suppressed_txn_id: suppressedTxnId,
        state,
      } = pair.rows[0];
      if (state !== 'pending') return { status: 409, error: `already resolved ('${state}')` };
      if (resolution !== 'kept_both' && keepTransactionId !== txnA && keepTransactionId !== txnB) {
        return { status: 400, error: 'keepTransactionId must be one of the pair' };
      }
      const dropId = resolution === 'kept_both' ? null : keepTransactionId === txnA ? txnB : txnA;
      // Live imports and older repairs can share a canonical row. Cancelling
      // those edges must release their suppressed rows, not just their cards.
      const neighbors = dropId ? await client.query(
        `SELECT id, suppressed_txn_id FROM duplicate_candidates
          WHERE profile_id = $1 AND state = 'pending' AND id <> $2
            AND (txn_a_id = $3 OR txn_b_id = $3)
          ORDER BY id FOR UPDATE`,
        [req.userId, req.params.id, dropId],
      ) : { rows: [] };
      const resolvedCandidateIds = [req.params.id, ...neighbors.rows.map((row) => row.id)];
      const suppressedIds = new Set([suppressedTxnId, ...neighbors.rows.map((row) => row.suppressed_txn_id)].filter(Boolean));

      const transactionRows = await client.query(
        `SELECT id, user_card_id, amount_inr, occurred_at, category_id, rail,
                merchant_name, status, note, instrument, entry_kind,
                state_applied, is_backfill,
                EXISTS (SELECT 1 FROM duplicate_candidates d
                         WHERE d.profile_id = t.profile_id AND d.state = 'pending'
                           AND d.suppressed_txn_id = t.id
                           AND NOT (d.id = ANY($3::uuid[]))) AS suppressed_elsewhere
           FROM transactions t
          WHERE profile_id = $1 AND id = ANY($2::uuid[])
          ORDER BY id
          FOR UPDATE`,
        [req.userId, [...new Set([txnA, txnB, ...suppressedIds])], resolvedCandidateIds]
      );
      const byId = new Map(transactionRows.rows.map((row) => [row.id, row]));
      if (!byId.has(txnA) || !byId.has(txnB)) {
        return { status: 409, error: 'one of the duplicate transactions no longer exists' };
      }

      const stripPendingNote = (value) => String(value || '')
        .replace(/^\[pending duplicate of [0-9a-f-]+\]\s*/i, '')
        .trim() || null;

      const activateIfSuppressed = async (transactionId) => {
        if (!transactionId || !suppressedIds.has(transactionId)) return;
        const txn = byId.get(transactionId);
        if (!txn || txn.status !== 'ignored' || txn.suppressed_elsewhere) return;
        const movesCardState = txn.instrument === 'credit_card' && txn.entry_kind === 'spend' && Boolean(txn.user_card_id);
        if (!txn.is_backfill && movesCardState && txn.state_applied !== true) {
          const card = await loadUserCardForState(client, req.userId, txn.user_card_id);
          if (!card) throw new Error('cannot activate duplicate: user card is missing or archived');
          await applyTransactionState(client, req.userId, card, {
            txnId: txn.id,
            userCardId: txn.user_card_id,
            amount: Number(txn.amount_inr),
            occurred: txn.occurred_at,
            categoryId: txn.category_id,
            merchantName: txn.merchant_name,
            rail: txn.rail,
            sign: 1,
          });
          txn.state_applied = true;
        }
        txn.status = 'active';
        txn.note = stripPendingNote(txn.note);
        await client.query(
          `UPDATE transactions SET status = 'active', note = $1, state_applied = $2 WHERE id = $3`,
          [txn.note, txn.state_applied === true, txn.id]
        );
      };

      const deactivateIfActive = async (transactionId, keptId) => {
        const txn = byId.get(transactionId);
        if (!txn || txn.status !== 'active') return;
        const movesCardState = txn.instrument === 'credit_card' && txn.entry_kind === 'spend' && Boolean(txn.user_card_id);
        // Null means a legacy active row written before the marker existed;
        // preserve the old safe assumption that its state was applied.
        if (movesCardState && txn.state_applied !== false) {
          const card = await loadUserCardForState(client, req.userId, txn.user_card_id);
          if (card) await reverseTransactionState(client, req.userId, card, txn);
        }
        const noteTag = `[${resolution}: duplicate of ${keptId}]`;
        await client.query(
          `UPDATE transactions SET status = 'ignored', note = $1, state_applied = false WHERE id = $2`,
          [txn.note ? `${noteTag} ${stripPendingNote(txn.note) || ''}`.trim() : noteTag, txn.id]
        );
      };

      if (resolution === 'kept_both') {
        await activateIfSuppressed(suppressedTxnId);
      } else {
        await transactionTags.mergeTransactionTags(client, req.userId, dropId, keepTransactionId);
        await deactivateIfActive(dropId, keepTransactionId);
        await activateIfSuppressed(keepTransactionId);

        // The surviving canonical row retains every channel observation.
        // No raw message is copied here; this is provenance reassignment.
        await client.query(
          `UPDATE transaction_observations SET transaction_id = $1 WHERE transaction_id = $2`,
          [keepTransactionId, dropId]
        );

        for (const row of neighbors.rows) {
          if (row.suppressed_txn_id !== dropId) await activateIfSuppressed(row.suppressed_txn_id);
        }
        // No duplicate decision was made about a neighbor's other spend.
        await client.query(
          `UPDATE duplicate_candidates
              SET state = 'resolved', resolution = 'kept_both', resolved_at = now(), suppressed_txn_id = NULL
            WHERE profile_id = $1 AND id = ANY($2::uuid[]) AND state = 'pending'`,
          [req.userId, neighbors.rows.map((row) => row.id)]
        );
      }

      const updated = await client.query(
        `UPDATE duplicate_candidates
            SET state = 'resolved', resolution = $1, resolved_at = now(), suppressed_txn_id = NULL
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
  const {
    amountInr, occurredAt, categoryId, userCategoryId, rail, merchantName, userCardId,
    instrument, entryKind,
  } = req.body || {};
  if (instrument !== undefined && !TXN_INSTRUMENTS.includes(instrument)) {
    return res.status(400).json({ error: `instrument must be one of ${TXN_INSTRUMENTS.join(', ')}` });
  }
  if (entryKind !== undefined && !TXN_ENTRY_KINDS.includes(entryKind)) {
    return res.status(400).json({ error: `entryKind must be one of ${TXN_ENTRY_KINDS.join(', ')}` });
  }
  if (amountInr !== undefined && (!Number.isFinite(Number(amountInr)) || Number(amountInr) <= 0)) {
    return res.status(400).json({ error: 'amountInr must be a positive number' });
  }
  if (occurredAt !== undefined && Number.isNaN(new Date(occurredAt).getTime())) {
    return res.status(400).json({ error: 'occurredAt is not a valid date' });
  }
  if (userCategoryId !== undefined && userCategoryId !== null && (
    typeof userCategoryId !== 'string'
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userCategoryId)
  )) {
    return res.status(400).json({ error: 'userCategoryId must be a valid UUID' });
  }

  try {
    const result = await withUserClient(req.userId, async (client) => {
      // FOR UPDATE: this row is about to be reversed-then-reapplied: two
      // concurrent edits interleaving their reverse/apply halves would
      // corrupt the bucketed cap/milestone totals in a way that's very
      // hard to detect after the fact. Locked for the lifetime of this
      // transaction, released on COMMIT/ROLLBACK by withUserClient.
      const existing = await client.query(
        `SELECT id, user_card_id, amount_inr, occurred_at, category_id, user_category_id, rail, merchant_name, status,
                instrument, entry_kind, state_applied, is_backfill
           FROM transactions WHERE id = $1 AND profile_id = $2 FOR UPDATE`,
        [req.params.id, req.userId]
      );
      if (existing.rows.length === 0) return { status: 404, error: 'transaction not found' };
      const old = existing.rows[0];
      if (old.status !== 'active') {
        return { status: 409, error: `cannot edit a transaction with status '${old.status}'` };
      }

      if (amountInr !== undefined) {
        const shares = await client.query(
          'SELECT COALESCE(SUM(amount_inr), 0) AS total FROM transaction_splits WHERE transaction_id = $1',
          [req.params.id]
        );
        if (Math.round(Number(shares.rows[0].total) * 100) > Math.round(Number(amountInr) * 100)) {
          return { status: 400, error: 'amount is less than saved split shares; edit or clear the split first' };
        }
      }

      let userCategoryParentId = null;
      if (userCategoryId !== undefined && userCategoryId !== null) {
        const category = await client.query(
          'SELECT parent_category_id FROM user_categories WHERE id = $1 AND profile_id = $2',
          [userCategoryId, req.userId],
        );
        if (category.rows.length === 0) {
          return { status: 400, error: 'user category not found' };
        }
        userCategoryParentId = category.rows[0].parent_category_id;
      }

      const oldMovesCardState = old.instrument === 'credit_card'
        && old.entry_kind === 'spend'
        && Boolean(old.user_card_id);
      const oldCard = oldMovesCardState
        ? await loadUserCardForState(client, req.userId, old.user_card_id)
        : null;
      if (oldMovesCardState && !oldCard) {
        return { status: 404, error: 'user_card for this transaction not found or archived' };
      }
      // state_applied=false is authoritative for new suppressed/backfill
      // rows. Null is a legacy row, for which the pre-migration safe
      // assumption remains that state was applied.
      if (old.state_applied !== false && oldMovesCardState) {
        await reverseTransactionState(client, req.userId, oldCard, old);
      }

      const newInstrument = instrument ?? old.instrument;
      const newEntryKind = entryKind ?? old.entry_kind;
      const newMovesCardState = newInstrument === 'credit_card'
        && newEntryKind === 'spend';
      const newUserCardId = newMovesCardState || newInstrument === 'debit_card'
        ? (userCardId !== undefined ? userCardId : old.user_card_id)
        : null;
      if (newInstrument === 'credit_card' && !newUserCardId) {
        return { status: 400, error: 'userCardId is required for a credit-card transaction' };
      }
      if (newUserCardId && (newInstrument === 'credit_card' || newInstrument === 'debit_card')) {
        const compatible = await importResolvers.userCardMatchesInstrument(
          client,
          req.userId,
          newUserCardId,
          newInstrument,
        );
        if (!compatible) {
          return {
            status: 400,
            error: `userCardId does not match the ${newInstrument === 'debit_card' ? 'debit' : 'credit'}-card instrument`,
          };
        }
      }

      const newValues = {
        userCardId: newUserCardId,
        amount: amountInr !== undefined ? Number(amountInr) : Number(old.amount_inr),
        occurred: occurredAt !== undefined ? new Date(occurredAt) : old.occurred_at,
        categoryId: userCategoryId !== undefined && userCategoryId !== null
          ? (categoryId || userCategoryParentId)
          : categoryId !== undefined ? categoryId : old.category_id,
        userCategoryId: userCategoryId !== undefined ? userCategoryId : old.user_category_id,
        rail: rail ?? old.rail,
        merchantName: merchantName !== undefined ? merchantName : old.merchant_name,
        instrument: newInstrument,
        entryKind: newEntryKind,
      };

      const newCard = newMovesCardState
        ? await loadUserCardForState(client, req.userId, newValues.userCardId)
        : null;
      if (newMovesCardState && !newCard) {
        return { status: 404, error: 'target user_card not found or archived' };
      }

      const updated = await client.query(
        `UPDATE transactions
            SET user_card_id = $1, amount_inr = $2, occurred_at = $3, category_id = $4,
                user_category_id = $5, rail = $6,
                merchant_name = $7, instrument = $8, entry_kind = $9
          WHERE id = $10
          RETURNING id, user_card_id, amount_inr, occurred_at, category_id, user_category_id,
                    rail, merchant_name, instrument, entry_kind, status`,
        [
          newValues.userCardId, newValues.amount, newValues.occurred, newValues.categoryId,
          newValues.userCategoryId, newValues.rail, newValues.merchantName,
          newValues.instrument, newValues.entryKind, old.id,
        ]
      );

      // A user-selected entry kind is an explicit classification correction.
      // Persist the lock in the privacy-safe observation metadata so a later
      // SMS replay or parser upgrade cannot silently overwrite it.
      if (entryKind !== undefined) {
        await client.query(
          `UPDATE transaction_observations
              SET metadata = metadata || '{"classificationLocked":true,"classificationSource":"user"}'::jsonb
            WHERE profile_id = $1 AND transaction_id = $2`,
          [req.userId, old.id],
        );
      }

      const stateUpdates = old.is_backfill || !newMovesCardState
        ? {}
        : await applyTransactionState(client, req.userId, newCard, {
            txnId: old.id, userCardId: newValues.userCardId, amount: newValues.amount,
            occurred: newValues.occurred, categoryId: newValues.categoryId, sign: 1,
            // The edited merchant/rail, not the old ones: rule matching reads
            // both now, so an edit that moves a transaction to a different
            // merchant has to re-apply against the rule that merchant earns at.
            merchantName: newValues.merchantName, rail: newValues.rail,
          });
      if (!old.is_backfill) {
        await client.query(`UPDATE transactions SET state_applied = true WHERE id = $1`, [old.id]);
      }

      return { status: 200, transaction: updated.rows[0], ...stateUpdates };
    });

    if (result.status !== 200) return res.status(result.status).json({ error: result.error });
    res.json(result);
  } catch (err) {
    console.error('PATCH /transactions/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

const BULK_CATEGORY_MAX_ROWS = 500;
const BULK_CATEGORY_PREVIEW_TTL_MINUTES = 15;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function bulkCategoryVersion(row) {
  const raw = row.version ?? row.updated_version ?? row.updated_at;
  const value = Number(raw instanceof Date ? raw.getTime() : raw);
  return Number.isFinite(value) ? Math.trunc(value) : null;
}

function sameCategoryIdentity(row, target) {
  return String(row.category_id || '') === String(target.categoryId || '')
    && String(row.user_category_id || '') === String(target.userCategoryId || '');
}

async function loadBulkTargetCategory(client, userId, { categoryId, userCategoryId }) {
  if (!categoryId && !userCategoryId) return { error: 'one target category is required' };
  if (categoryId && !UUID_RE.test(categoryId)) return { error: 'targetCategoryId must be a valid UUID' };
  if (userCategoryId && !UUID_RE.test(userCategoryId)) return { error: 'targetUserCategoryId must be a valid UUID' };

  if (userCategoryId) {
    const result = await client.query(
      `SELECT uc.id, uc.name, uc.parent_category_id, uc.parent_user_category_id,
              parent_sc.name AS parent_category_name, parent_uc.name AS parent_user_category_name
         FROM user_categories uc
         LEFT JOIN spend_categories parent_sc ON parent_sc.id = uc.parent_category_id
         LEFT JOIN user_categories parent_uc
           ON parent_uc.id = uc.parent_user_category_id AND parent_uc.profile_id = uc.profile_id
        WHERE uc.id = $1 AND uc.profile_id = $2`,
      [userCategoryId, userId],
    );
    if (result.rows.length === 0) return { error: 'target user category not found' };
    const row = result.rows[0];
    if (categoryId && String(categoryId) !== String(row.parent_category_id || '')) {
      return { error: 'targetCategoryId does not match the user category parent' };
    }
    return {
      categoryId: row.parent_category_id,
      userCategoryId: row.id,
      name: row.name,
      parentName: row.parent_category_name || row.parent_user_category_name || null,
    };
  }

  const result = await client.query(
    'SELECT id, name, slug FROM spend_categories WHERE id = $1',
    [categoryId],
  );
  if (result.rows.length === 0) return { error: 'target category not found' };
  return {
    categoryId: result.rows[0].id,
    userCategoryId: null,
    name: result.rows[0].name,
    slug: result.rows[0].slug,
  };
}

async function loadBulkTransaction(client, userId, id, { forUpdate = false } = {}) {
  const lock = forUpdate ? ' FOR UPDATE' : '';
  const result = await client.query(
    `SELECT t.id, t.profile_id, t.user_card_id, t.amount_inr, t.occurred_at,
            t.merchant_name, t.merchant_vpa::text AS merchant_vpa, t.category_id,
            t.user_category_id, t.rail, t.status, t.instrument, t.entry_kind,
            t.state_applied, t.is_backfill, t.is_split_parent, t.parent_txn_id,
            floor(extract(epoch from t.updated_at) * 1000)::bigint AS version,
            t.updated_at,
            sc.name AS category_name, sc.slug AS category_slug,
            ucat.name AS user_category_name,
            EXISTS (SELECT 1 FROM transaction_splits ts WHERE ts.transaction_id = t.id) AS has_splits
       FROM transactions t
       LEFT JOIN spend_categories sc ON sc.id = t.category_id
       LEFT JOIN user_categories ucat
         ON ucat.id = t.user_category_id AND ucat.profile_id = t.profile_id
      WHERE t.id = $1 AND t.profile_id = $2${lock}`,
    [id, userId],
  );
  return result.rows[0] || null;
}

function bulkCandidateResponse(row, classification) {
  return {
    id: row.id,
    occurredAt: row.occurred_at,
    amountInr: Number(row.amount_inr),
    merchantName: row.merchant_name,
    categoryId: row.category_id,
    userCategoryId: row.user_category_id,
    categoryName: row.user_category_name || row.category_name || null,
    selected: classification.selected,
    tier: classification.tier,
    reason: classification.reason,
    updatedAt: row.updated_at,
  };
}

/**
 * GET /transactions/:id/category-related-preview — builds a short-lived,
 * server-owned candidate set for the category review sheet. The merchant key
 * is always derived from the source row; the client cannot supply a name/VPA.
 */
app.get('/transactions/:id/category-related-preview', requireAuth, async (req, res) => {
  const targetCategoryId = req.query.targetCategoryId ? String(req.query.targetCategoryId) : null;
  const targetUserCategoryId = req.query.targetUserCategoryId ? String(req.query.targetUserCategoryId) : null;
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const target = await loadBulkTargetCategory(client, req.userId, {
        categoryId: targetCategoryId,
        userCategoryId: targetUserCategoryId,
      });
      if (target.error) return { status: 400, error: target.error };

      const source = await loadBulkTransaction(client, req.userId, req.params.id);
      if (!source) return { status: 404, error: 'transaction not found' };
      if (source.status !== 'active') return { status: 409, error: 'source transaction is not active' };

      const sourceVpa = normalizeMerchantVpa(source.merchant_vpa);
      const sourceName = normalizeMerchantName(source.merchant_name);
      const basis = sourceVpa ? 'vpa' : 'strict_name';
      if (!sourceVpa && isGenericMerchantName(sourceName)) {
        const emptyPreview = await client.query(
          `INSERT INTO transaction_category_bulk_previews
             (profile_id, source_transaction_id, target_category_id, target_user_category_id,
              match_basis, match_value, match_policy_version, source_version,
              candidates, candidate_count, selectable_count, overflow, expires_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, '[]'::jsonb, 0, 0, false,
                   now() + ($9::text || ' minutes')::interval)
           RETURNING id, expires_at, created_at`,
          [
            req.userId, source.id, target.categoryId, target.userCategoryId,
            basis, sourceName || '__generic__', MATCH_POLICY_VERSION,
            bulkCategoryVersion(source), BULK_CATEGORY_PREVIEW_TTL_MINUTES,
          ],
        );
        return {
          status: 200,
          preview: {
            previewId: emptyPreview.rows[0].id, expiresAt: emptyPreview.rows[0].expires_at,
            createdAt: emptyPreview.rows[0].created_at, sourceTransactionId: source.id,
            targetCategory: target, targetCategoryId: target.categoryId,
            targetUserCategoryId: target.userCategoryId, targetCategoryName: target.name,
            matchBasis: basis, matchValue: sourceName || '__generic__',
            candidates: [], totalCount: 0, selectableCount: 0, defaultSelectedCount: 0,
            overflow: false, canApply: false,
            reason: 'generic_merchant_name',
          },
        };
      }

      const keyParams = [req.userId, source.id, sourceVpa, sourceName];
      const matches = await client.query(
        `SELECT t.id, t.amount_inr, t.occurred_at, t.merchant_name,
                t.merchant_vpa::text AS merchant_vpa,
                t.category_id, t.user_category_id, t.status, t.entry_kind,
                t.instrument, t.is_split_parent, t.parent_txn_id,
                t.updated_at, floor(extract(epoch from t.updated_at) * 1000)::bigint AS version,
                sc.name AS category_name, sc.slug AS category_slug,
                ucat.name AS user_category_name,
                EXISTS (SELECT 1 FROM transaction_splits ts WHERE ts.transaction_id = t.id) AS has_splits
           FROM transactions t
           LEFT JOIN spend_categories sc ON sc.id = t.category_id
           LEFT JOIN user_categories ucat
             ON ucat.id = t.user_category_id AND ucat.profile_id = t.profile_id
          WHERE t.profile_id = $1 AND t.id <> $2
            AND (($3::text IS NOT NULL AND lower(btrim(t.merchant_vpa::text)) = $3)
              OR ($3::text IS NULL AND lower(regexp_replace(btrim(t.merchant_name), '\\s+', ' ', 'g')) = $4))
          ORDER BY t.occurred_at DESC, t.id DESC
          LIMIT ${BULK_CATEGORY_MAX_ROWS + 1}`,
        keyParams,
      );
      const count = await client.query(
        `SELECT count(*)::int AS total
           FROM transactions t
          WHERE t.profile_id = $1 AND t.id <> $2
            AND (($3::text IS NOT NULL AND lower(btrim(t.merchant_vpa::text)) = $3)
              OR ($3::text IS NULL AND lower(regexp_replace(btrim(t.merchant_name), '\\s+', ' ', 'g')) = $4))`,
        keyParams,
      );
      const allRows = matches.rows;
      const overflow = allRows.length > BULK_CATEGORY_MAX_ROWS;
      const rows = allRows.slice(0, BULK_CATEGORY_MAX_ROWS);
      const candidates = rows.map((row) => {
        const classification = classifyCandidate(row, source.id, target);
        return { row, classification };
      });
      const selectable = candidates.filter(({ classification }) => classification.tier !== 'ineligible');
      const snapshots = candidates.map(({ row, classification }) => ({
        id: row.id,
        version: bulkCategoryVersion(row),
        tier: classification.tier,
        selected: classification.selected,
      }));
      const inserted = await client.query(
        `INSERT INTO transaction_category_bulk_previews
           (profile_id, source_transaction_id, target_category_id, target_user_category_id,
            match_basis, match_value, match_policy_version, source_version,
            candidates, candidate_count, selectable_count, overflow, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10, $11, $12,
                 now() + ($13::text || ' minutes')::interval)
         RETURNING id, expires_at, created_at`,
        [
          req.userId, source.id, target.categoryId, target.userCategoryId,
          basis, sourceVpa || sourceName, MATCH_POLICY_VERSION,
          bulkCategoryVersion(source), JSON.stringify(snapshots), Number(count.rows[0].total),
          selectable.length, overflow, BULK_CATEGORY_PREVIEW_TTL_MINUTES,
        ],
      );
      return {
        status: 200,
        preview: {
          previewId: inserted.rows[0].id,
          expiresAt: inserted.rows[0].expires_at,
          createdAt: inserted.rows[0].created_at,
          sourceTransactionId: source.id,
          targetCategory: target,
          targetCategoryId: target.categoryId,
          targetUserCategoryId: target.userCategoryId,
          targetCategoryName: target.name,
          matchBasis: basis,
          matchValue: sourceVpa || sourceName,
          candidates: candidates.map(({ row, classification }) => bulkCandidateResponse(row, classification)),
          totalCount: Number(count.rows[0].total),
          selectableCount: selectable.length,
          defaultSelectedCount: candidates.filter(({ classification }) => classification.selected).length,
          overflow,
          canApply: !overflow && selectable.length > 0,
        },
      };
    });
    if (result.status !== 200) return res.status(result.status).json({ error: result.error });
    res.json(result.preview);
  } catch (err) {
    console.error('GET /transactions/:id/category-related-preview error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /transactions/category-bulk-apply — applies the exact selected rows
 * from a preview in one transaction, including reward/cap reverse and apply.
 */
app.post('/transactions/category-bulk-apply', requireAuth, async (req, res) => {
  const {
    previewId, selectedTransactionIds, targetCategoryId, targetUserCategoryId, idempotencyKey,
  } = req.body || {};
  if (!UUID_RE.test(String(previewId || ''))) return res.status(400).json({ error: 'previewId must be a valid UUID' });
  if (!Array.isArray(selectedTransactionIds)
      || selectedTransactionIds.length > BULK_CATEGORY_MAX_ROWS
      || selectedTransactionIds.some((id) => !UUID_RE.test(String(id)))) {
    return res.status(400).json({ error: `selectedTransactionIds must contain at most ${BULK_CATEGORY_MAX_ROWS} UUIDs` });
  }
  const selectedIds = [...new Set(selectedTransactionIds.map(String))];
  if (selectedIds.length !== selectedTransactionIds.length) return res.status(400).json({ error: 'selectedTransactionIds must be unique' });
  if (typeof idempotencyKey !== 'string' || idempotencyKey.trim().length < 8 || idempotencyKey.trim().length > 200) {
    return res.status(400).json({ error: 'idempotencyKey must be between 8 and 200 characters' });
  }
  if ((targetCategoryId && !UUID_RE.test(String(targetCategoryId)))
      || (targetUserCategoryId && !UUID_RE.test(String(targetUserCategoryId)))) {
    return res.status(400).json({ error: 'target category IDs must be valid UUIDs' });
  }

  const requestHash = crypto.createHash('sha256').update(JSON.stringify({
    previewId, selectedIds, targetCategoryId: targetCategoryId || null,
    targetUserCategoryId: targetUserCategoryId || null,
  })).digest('hex');

  try {
    const result = await withUserClient(req.userId, async (client) => {
      // Serialize attempts for this profile/key before checking or creating
      // the receipt. This avoids two retries doing the same state mutation and
      // lets us recover null-result markers left by the pre-fix 4xx path.
      await client.query(
        `SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))`,
        [`transaction-category-bulk:${req.userId}:${idempotencyKey.trim()}`],
      );
      const existingOperation = await client.query(
        `SELECT operation_id, request_hash, result
           FROM transaction_category_bulk_operations
          WHERE profile_id = $1 AND idempotency_key = $2 FOR UPDATE`,
        [req.userId, idempotencyKey.trim()],
      );
      const idempotency = resolveBulkIdempotencyRow(existingOperation.rows[0] || null, requestHash);
      if (idempotency.action === 'conflict') {
        return { status: 409, error: 'idempotency key was used for a different request' };
      }
      if (idempotency.action === 'replay') return { status: 200, result: idempotency.result };
      // A previous implementation committed this marker before validating the
      // preview and could strand retries forever with a null result. It never
      // represented a committed category mutation, and replacing it here is
      // safe after the matching request hash and advisory lock are confirmed.
      if (idempotency.action === 'replace_pending') {
        await client.query(
          `DELETE FROM transaction_category_bulk_operations
            WHERE profile_id = $1 AND operation_id = $2 AND result IS NULL`,
          [req.userId, idempotency.operationId],
        );
      }

      const previewResult = await client.query(
        `SELECT * FROM transaction_category_bulk_previews
          WHERE id = $1 AND profile_id = $2 FOR UPDATE`,
        [previewId, req.userId],
      );
      if (previewResult.rows.length === 0) return { status: 404, error: 'preview not found' };
      const preview = previewResult.rows[0];
      if (preview.status !== 'pending' || new Date(preview.expires_at).getTime() <= Date.now()) {
        return { status: 409, error: 'preview_stale' };
      }
      if (preview.match_policy_version !== MATCH_POLICY_VERSION) {
        return { status: 409, error: 'preview_policy_changed' };
      }
      if (preview.target_category_id !== (targetCategoryId || null)
          || preview.target_user_category_id !== (targetUserCategoryId || null)) {
        return { status: 409, error: 'preview target category mismatch' };
      }
      if (preview.overflow) return { status: 409, error: 'preview has more than 500 matching transactions; narrow the selection' };

      const snapshots = Array.isArray(preview.candidates) ? preview.candidates : [];
      const snapshotById = new Map(snapshots.map((row) => [String(row.id), row]));
      if (selectedIds.some((id) => !snapshotById.has(id))) {
        return { status: 409, error: 'selected transaction is not part of the preview' };
      }
      const target = await loadBulkTargetCategory(client, req.userId, {
        categoryId: targetCategoryId || null,
        userCategoryId: targetUserCategoryId || null,
      });
      if (target.error) return { status: 400, error: target.error };

      const lockIds = [...new Set([String(preview.source_transaction_id), ...selectedIds])].sort();
      const locked = await client.query(
        `SELECT t.id, t.profile_id, t.user_card_id, t.amount_inr, t.occurred_at,
                t.merchant_name, t.merchant_vpa::text AS merchant_vpa, t.category_id,
                t.user_category_id, t.rail, t.status, t.instrument, t.entry_kind,
                t.state_applied, t.is_backfill, t.is_split_parent, t.parent_txn_id,
                floor(extract(epoch from t.updated_at) * 1000)::bigint AS version,
                t.updated_at,
                sc.slug AS category_slug,
                EXISTS (SELECT 1 FROM transaction_splits ts WHERE ts.transaction_id = t.id) AS has_splits
           FROM transactions t
           LEFT JOIN spend_categories sc ON sc.id = t.category_id
          WHERE t.profile_id = $1 AND t.id = ANY($2::uuid[])
          ORDER BY t.id
          FOR UPDATE`,
        [req.userId, lockIds],
      );
      const rowsById = new Map(locked.rows.map((row) => [String(row.id), row]));
      const source = rowsById.get(String(preview.source_transaction_id));
      if (!source || bulkCategoryVersion(source) !== Number(preview.source_version)) {
        return { status: 409, error: 'preview_stale', conflicts: [preview.source_transaction_id] };
      }
      const sourceMatch = merchantMatch(source, source);
      if (sourceMatch.basis !== preview.match_basis || sourceMatch.value !== preview.match_value) {
        return { status: 409, error: 'preview_stale', conflicts: [source.id] };
      }
      const conflicts = [];
      // Apply in a deterministic order so concurrent operations acquire and
      // update derived cap/milestone state consistently.
      const applyIds = [...selectedIds].sort();
      for (const id of applyIds) {
        const row = rowsById.get(id);
        const snapshot = snapshotById.get(id);
        const match = merchantMatch(source, row || {});
        if (!row || bulkCategoryVersion(row) !== Number(snapshot.version)
            || !match.matched || row.status !== 'active' || row.entry_kind !== 'spend'
            || row.is_split_parent || row.parent_txn_id || row.has_splits) {
          conflicts.push(id);
        }
      }
      if (conflicts.length) return { status: 409, error: 'preview_stale', conflicts };

      // Validate all card-state dependencies before creating the receipt. A
      // missing/archived card is a client-visible 404 and must therefore leave
      // no committed null-result operation row behind.
      const stateCards = new Map();
      for (const id of applyIds) {
        const row = rowsById.get(id);
        if (sameCategoryIdentity(row, target)) continue;
        if (row.instrument === 'credit_card' && row.entry_kind === 'spend' && row.user_card_id) {
          await client.query(
            `SELECT id FROM user_cards
              WHERE id = $1 AND profile_id = $2
              FOR UPDATE`,
            [row.user_card_id, req.userId],
          );
          const card = await loadUserCardForState(client, req.userId, row.user_card_id);
          if (!card) return { status: 404, error: 'user_card for transaction not found or archived' };
          stateCards.set(id, card);
        }
      }

      // Create the idempotency receipt only after every validation above has
      // succeeded. Any later exception rolls the receipt back with the
      // category/state changes, so a 4xx can never strand a pending marker.
      const operationInsert = await client.query(
        `INSERT INTO transaction_category_bulk_operations
           (profile_id, idempotency_key, preview_id, request_hash, target_category_id, target_user_category_id)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING operation_id`,
        [req.userId, idempotencyKey.trim(), previewId, requestHash, targetCategoryId || null, targetUserCategoryId || null],
      );
      const operationId = operationInsert.rows[0].operation_id;

      const changed = [];
      const unchanged = [];
      for (const id of selectedIds) {
        const old = rowsById.get(id);
        if (sameCategoryIdentity(old, target)) {
          unchanged.push(id);
          continue;
        }
        const oldMovesCardState = old.instrument === 'credit_card'
          && old.entry_kind === 'spend' && Boolean(old.user_card_id);
        const oldCard = oldMovesCardState ? stateCards.get(id) : null;
        if (oldMovesCardState && !oldCard) throw new Error('user_card for transaction not found or archived');
        if (old.state_applied !== false && oldMovesCardState) {
          await reverseTransactionState(client, req.userId, oldCard, old);
        }
        await client.query(
          `UPDATE transactions
              SET category_id = $1, user_category_id = $2, updated_at = now()
            WHERE id = $3 AND profile_id = $4`,
          [target.categoryId || null, target.userCategoryId || null, old.id, req.userId],
        );
        const newCard = oldMovesCardState ? stateCards.get(id) : null;
        if (!old.is_backfill && oldMovesCardState) {
          await applyTransactionState(client, req.userId, newCard, {
            txnId: old.id, userCardId: old.user_card_id, amount: Number(old.amount_inr),
            occurred: old.occurred_at, categoryId: target.categoryId || null, sign: 1,
            merchantName: old.merchant_name, rail: old.rail,
          });
        }
        if (!old.is_backfill) await client.query('UPDATE transactions SET state_applied = true WHERE id = $1', [old.id]);
        await client.query(
          `INSERT INTO transaction_category_bulk_operation_items
             (profile_id, operation_id, transaction_id, old_category_id, old_user_category_id,
              new_category_id, new_user_category_id)
           VALUES ($1, $2, $3, $4, $5, $6, $7)`,
          [req.userId, operationId, old.id, old.category_id, old.user_category_id,
            target.categoryId || null, target.userCategoryId || null],
        );
        changed.push(old.id);
      }

      const operationResult = {
        operationId,
        previewId,
        targetCategory: target,
        changedCount: changed.length,
        unchangedCount: unchanged.length,
        changedTransactionIds: changed,
        unchangedTransactionIds: unchanged,
      };
      await client.query(
        `UPDATE transaction_category_bulk_operations
            SET result = $1::jsonb, completed_at = now()
          WHERE profile_id = $2 AND operation_id = $3`,
        [JSON.stringify(operationResult), req.userId, operationId],
      );
      await client.query(
        `UPDATE transaction_category_bulk_previews SET status = 'applied', applied_at = now()
          WHERE id = $1 AND profile_id = $2`,
        [previewId, req.userId],
      );
      return { status: 200, result: operationResult };
    });
    if (result.status !== 200) return res.status(result.status).json({ error: result.error, conflicts: result.conflicts });
    res.json(result.result);
  } catch (err) {
    console.error('POST /transactions/category-bulk-apply error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

const IGNORE_REASONS = ['refund', 'reversal', 'transfer', 'wrong_transaction'];

/**
 * PATCH /transactions/:id/note — design 18 "Add a note".
 *
 * Deliberately its own route rather than another field on
 * PATCH /transactions/:id. That route is a reverse-then-reapply of the
 * whole transaction: it takes a row lock, unwinds this transaction's
 * cap/milestone/points/fee-waiver contribution, rewrites the row, and
 * reapplies state. A note affects none of that, and routing a note edit
 * through it would make typing a comment recompute reward state — slow,
 * lock-contending, and a real risk of drift for zero benefit.
 *
 * Not filtered on `status = 'active'`: an ignored transaction is exactly
 * the kind you want to annotate ("this was the duplicate from the refund").
 */
app.patch('/transactions/:id/note', requireAuth, async (req, res) => {
  const { note } = req.body || {};
  if (note !== null && typeof note !== 'string') {
    return res.status(400).json({ error: 'note must be a string or null' });
  }
  if (typeof note === 'string' && note.length > 2000) {
    return res.status(400).json({ error: 'note must be 2000 characters or fewer' });
  }
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `UPDATE transactions SET note = $1
          WHERE id = $2 AND profile_id = $3
          RETURNING id, note`,
        [note === '' ? null : note, req.params.id, req.userId]
      )
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'transaction not found' });
    res.json({ transaction: result.rows[0] });
  } catch (err) {
    console.error('PATCH /transactions/:id/note error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /transactions/:id/splits — design 18 "Split this expense".
 *
 * The `transaction_splits` table has existed since migration 0004 with an
 * RLS policy scoping it through the parent transaction's owner, but no
 * route ever read or wrote it — the client-side doc-comment on
 * transaction_detail_screen.dart called that out as a real gap rather than
 * faking the feature. These two routes close it.
 */
registerSplitRoutes(app, { requireAuth, withUserClient });
transactionTags.registerTagRoutes(app, { requireAuth, withUserClient });

/**
 * POST /transactions/:id/ignore — Task C-0c (ui-spec D2 "mark ignored
 * (refund/reversal/transfer)"). Reverses this transaction's cap/milestone/
 * points/fee-waiver contribution (via [reverseTransactionState]) and sets
 * status='ignored' — or status='deleted' for the former transfer option —
 * while keeping the row for recovery. No dedicated ignore-reason column exists on `transactions`
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
        `SELECT id, user_card_id, amount_inr, occurred_at, category_id, rail, merchant_name,
                status, note, instrument, entry_kind, state_applied, is_backfill
           FROM transactions WHERE id = $1 AND profile_id = $2 FOR UPDATE`,
        [req.params.id, req.userId]
      );
      if (existing.rows.length === 0) return { status: 404, error: 'transaction not found' };
      const txn = existing.rows[0];
      if (txn.status !== 'active') {
        return { status: 409, error: `transaction is already '${txn.status}'` };
      }

      const movesCardState = txn.instrument === 'credit_card' && txn.entry_kind === 'spend' && Boolean(txn.user_card_id);
      if (movesCardState && txn.state_applied !== false) {
        const card = await loadUserCardForState(client, req.userId, txn.user_card_id);
        if (!card) return { status: 404, error: 'user_card for this transaction not found or archived' };
        await reverseTransactionState(client, req.userId, card, txn);
      }

      // The former transfer option is now the user's soft-delete action.
      // Keep the existing endpoint/reason for backwards compatibility while
      // giving deleted transactions their own status for history/restore.
      const deleted = reason === 'transfer';
      const noteTag = deleted ? '[deleted]' : `[ignored: ${reason}]`;
      const newNote = txn.note ? `${noteTag} ${txn.note}` : noteTag;
      const updated = await client.query(
        `UPDATE transactions SET status = $1, note = $2, state_applied = false
          WHERE id = $3 RETURNING id, status, note`,
        [deleted ? 'deleted' : 'ignored', newNote, txn.id]
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
 * POST /transactions/:id/restore — restore a soft-deleted transaction.
 * Re-applies card state before making the row active again so spending totals,
 * caps, milestones, points, and fee-waiver progress all move together.
 */
app.post('/transactions/:id/restore', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const existing = await client.query(
        `SELECT id, user_card_id, amount_inr, occurred_at, category_id, rail,
                merchant_name, status, note, instrument, entry_kind,
                state_applied, is_backfill
           FROM transactions
          WHERE id = $1 AND profile_id = $2
            AND (status = 'deleted' OR status = 'ignored')
          FOR UPDATE`,
        [req.params.id, req.userId]
      );
      if (existing.rows.length === 0) return { status: 404, error: 'deleted transaction not found' };
      const txn = existing.rows[0];
      const movesCardState = txn.instrument === 'credit_card' && txn.entry_kind === 'spend' && Boolean(txn.user_card_id);
      if (movesCardState && txn.state_applied !== true) {
        const card = await loadUserCardForState(client, req.userId, txn.user_card_id);
        if (!card) return { status: 404, error: 'user_card for this transaction not found or archived' };
        await applyTransactionState(client, req.userId, card, {
          txnId: txn.id,
          userCardId: txn.user_card_id,
          amount: Number(txn.amount_inr),
          occurred: txn.occurred_at,
          categoryId: txn.category_id,
          merchantName: txn.merchant_name,
          rail: txn.rail,
          sign: 1,
        });
      }

      const restoredNote = String(txn.note || '')
        .replace(/^\[(?:deleted|ignored(?::\s*[^\]]+)?)\]\s*/i, '')
        .trim() || null;
      const updated = await client.query(
        `UPDATE transactions
            SET status = 'active', note = $1, state_applied = $2
          WHERE id = $3 RETURNING id, status, note`,
        [restoredNote, movesCardState, txn.id]
      );
      return { status: 200, transaction: updated.rows[0] };
    });

    if (result.status !== 200) return res.status(result.status).json({ error: result.error });
    res.json(result);
  } catch (err) {
    console.error('POST /transactions/:id/restore error', err);
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
      //
      // `baseline_single_card_inr`, `extra_earned_inr` and
      // `value_missed_inr` have existed as columns since migration 0004 and
      // were always zero — this route used to write a literal apology into
      // `breakdown` instead of computing them. So the Savings Report could
      // only ever show spend and rewards: the two figures that need no
      // comparison to produce, and the two that say least. src/monthly_report.js
      // computes the counterfactuals properly, simulating each hypothetical
      // card's cap consumption across the month rather than treating every
      // alternative card as freshly-uncapped.
      const txnRows = await client.query(
        `SELECT id, user_card_id, amount_inr, occurred_at, merchant_name, category_id, rail,
                expected_value_inr
           FROM transactions
          WHERE profile_id = $1 AND status = 'active' AND entry_kind = 'spend'
            AND amount_inr > 0
            AND occurred_at >= $2::date AND occurred_at < ($2::date + interval '1 month')
          ORDER BY occurred_at ASC`,
        [req.userId, periodMonth]
      );

      const totalSpend = txnRows.rows.reduce((sum, t) => sum + Number(t.amount_inr), 0);
      // Keep this identical to Insights and /home-summary: rewards are the
      // stored transaction value, but only positive spend rows contribute.
      // A reversal/refund can legitimately carry a negative expected value;
      // it must not subtract from the earned-rewards headline or make two
      // screens disagree about the same month.
      const rewardsEarned = Math.min(
        totalSpend,
        txnRows.rows.reduce(
          (sum, t) => sum + Math.max(0, Number(t.expected_value_inr || 0)),
          0,
        ),
      );

      // The wallet as it stands, with each card's full rule set. Archived
      // cards are excluded, matching every other ranking path.
      const walletRows = await client.query(
        `SELECT uc.id AS user_card_id, cp.id AS card_product_id, cp.name AS card_name,
                uc.nickname, cp.point_value_inr, cp.base_reward_unit, cp.base_reward_rate,
                cp.excluded_categories
           FROM user_cards uc
           JOIN card_products cp ON cp.id = uc.card_product_id
          WHERE uc.profile_id = $1 AND uc.is_archived = false`,
        [req.userId]
      );

      const cards = [];
      for (const row of walletRows.rows) {
        const rules = await client.query(
          `SELECT id, category_id, merchant_pattern, rail, unit, rate, min_txn_inr, max_txn_inr,
                  excluded_categories, effective_from, effective_to, priority
             FROM reward_rules WHERE card_product_id = $1`,
          [row.card_product_id]
        );
        const caps = await client.query(
          `SELECT id, reward_rule_id, category_id, period, cap_value, measure,
                  post_cap_unit, post_cap_rate
             FROM cap_rules WHERE card_product_id = $1`,
          [row.card_product_id]
        );
        cards.push({ card: row, rewardRules: rules.rows, capRules: caps.rows });
      }

      const report = buildMonthlyReport({
        cards,
        txns: txnRows.rows,
        actualTotal: rewardsEarned,
        totalSpend,
      });

      const cardNameById = Object.fromEntries(
        walletRows.rows.map((r) => [r.user_card_id, r.nickname || r.card_name])
      );

      const upserted = await client.query(
        `INSERT INTO monthly_reports
           (profile_id, period_month, total_spend_inr, rewards_earned_inr,
            baseline_single_card_inr, extra_earned_inr, value_missed_inr, breakdown)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)
         ON CONFLICT (profile_id, period_month) DO UPDATE
           SET total_spend_inr = EXCLUDED.total_spend_inr,
               rewards_earned_inr = EXCLUDED.rewards_earned_inr,
               baseline_single_card_inr = EXCLUDED.baseline_single_card_inr,
               extra_earned_inr = EXCLUDED.extra_earned_inr,
               value_missed_inr = EXCLUDED.value_missed_inr,
               breakdown = EXCLUDED.breakdown,
               generated_at = now()
         RETURNING *`,
        [
          req.userId,
          periodMonth,
          totalSpend,
          rewardsEarned,
          report.baselineSingleCardInr,
          report.extraEarnedInr,
          report.valueMissedInr,
          JSON.stringify({
            optimalInr: report.optimalInr,
            baselineCardId: report.baselineCardId,
            baselineCardName: cardNameById[report.baselineCardId] || null,
            txnCount: txnRows.rows.length,
            topMissed: report.topMissed.map((m) => ({
              ...m,
              usedCardName: cardNameById[m.usedCardId] || null,
              betterCardName: cardNameById[m.betterCardId] || null,
            })),
          }),
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
 * GET /spend-by-category — trailing-window category totals, the one input
 * packages/pandapay_domain's CardAcquisitionRecommender needs that nothing
 * else already exposes (checked: /monthly-reports only sums a flat total,
 * no per-category breakdown).
 *
 * `months` defaults to 12 (the recommender's own annual-projection design)
 * but is accepted as a query param so a thin/new-user profile can be asked
 * for with a shorter window rather than the client special-casing "not
 * enough history" itself. `category_id` is returned as-is (the same
 * spend_categories UUID reward_rules.category_id and
 * RecommendationContext.categoryId already use everywhere else) — never a
 * slug — so the response plugs directly into SpendProfile without a
 * client-side lookup table. category_slug/category_name ride along purely
 * for display; the recommender itself never reads them. Excludes rows with
 * no category_id from the categorized breakdown into a single `uncategorized`
 * bucket (SpendProfile's own `null`-key "all other spends" convention) —
 * a transaction the parser couldn't categorize is still real spend a
 * candidate card's base rate should be projected against, not silently
 * dropped from the total.
 *
 * Same status='active' filter as /monthly-reports, for the same reason:
 * ignored/reversed/deleted transactions were never real spend.
 */
app.get('/spend-by-category', requireAuth, async (req, res) => {
  const monthsParam = req.query.months;
  const months = monthsParam ? Number(monthsParam) : 12;
  if (!Number.isInteger(months) || months < 1 || months > 60) {
    return res.status(400).json({ error: 'months must be an integer between 1 and 60' });
  }

  try {
    const result = await withUserClient(req.userId, async (client) => {
      const rows = await client.query(
        `SELECT COALESCE(t.category_id, ucat.parent_user_category_id, t.user_category_id) AS category_id,
                COALESCE(sc.slug, parent_uc.slug, ucat.slug) AS category_slug,
                COALESCE(parent_sc.name, parent_uc.name, sc.name, ucat.name) AS category_name,
                COALESCE(SUM(t.amount_inr), 0) AS total_spend_inr, COUNT(*) AS txn_count
           FROM transactions t
           LEFT JOIN spend_categories sc ON sc.id = t.category_id
           LEFT JOIN user_categories ucat ON ucat.id = t.user_category_id AND ucat.profile_id = t.profile_id
           LEFT JOIN spend_categories parent_sc ON parent_sc.id = ucat.parent_category_id
           LEFT JOIN user_categories parent_uc ON parent_uc.id = ucat.parent_user_category_id AND parent_uc.profile_id = t.profile_id
          WHERE t.profile_id = $1 AND t.status = 'active'
            AND t.entry_kind = 'spend'
            AND t.occurred_at >= now() - ($2 || ' months')::interval
          GROUP BY COALESCE(t.category_id, ucat.parent_user_category_id, t.user_category_id),
                   COALESCE(sc.slug, parent_uc.slug, ucat.slug),
                   COALESCE(parent_sc.name, parent_uc.name, sc.name, ucat.name)
          ORDER BY total_spend_inr DESC`,
        [req.userId, months]
      );
      return rows.rows.map((r) => ({
        categoryId: r.category_id, // null -> uncategorized/"all other spends"
        categorySlug: r.category_slug,
        categoryName: r.category_name,
        totalSpendInr: Number(r.total_spend_inr),
        txnCount: Number(r.txn_count),
      }));
    });
    res.json({ months, categories: result });
  } catch (err) {
    console.error('GET /spend-by-category error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /spend-report — everything the Trends screen shows, in one round trip.
 *
 * `?period=week|month|quarter|year` (default month), `?anchor=<ISO date>`
 * to look at a period other than the current one, or
 * `?period=custom&from=YYYY-MM-DD&to=YYYY-MM-DD` for an inclusive custom
 * calendar range. `?buckets=N` controls how many points the chart series
 * carries (default 12).
 *
 * One endpoint rather than five because every figure on that screen has to
 * agree with every other one — a category breakdown fetched a second after
 * the headline total, with a transaction landing in between, produces a
 * screen whose parts visibly contradict each other. All of these run inside
 * one `withUserClient` transaction, so they see one consistent snapshot.
 *
 * The previous period comes back alongside the current one because a spend
 * figure on its own says almost nothing: "₹42,000 this month" is only
 * meaningful next to what last month was.
 */
app.get('/spend-report', requireAuth, async (req, res) => {
  let tagFilter;
  try { tagFilter = transactionTags.readTagFilter(req.query); }
  catch (error) { return res.status(400).json({ error: error.message }); }
  const period = req.query.period || 'month';
  if (!spendReports.PERIODS.includes(period)) {
    return res.status(400).json({ error: `period must be one of ${spendReports.PERIODS.join(', ')}` });
  }
  const anchor = req.query.anchor ? new Date(req.query.anchor) : new Date();
  if (Number.isNaN(anchor.getTime())) {
    return res.status(400).json({ error: 'anchor is not a valid date' });
  }
  const buckets = req.query.buckets ? Number(req.query.buckets) : 12;
  if (!Number.isInteger(buckets) || buckets < 1 || buckets > 60) {
    return res.status(400).json({ error: 'buckets must be an integer between 1 and 60' });
  }
  if (period === 'custom') {
    try {
      spendReports.customPeriodBounds(req.query.from, req.query.to);
    } catch (err) {
      return res.status(400).json({ error: err.message });
    }
  }
  const requestedTimeZone = typeof req.query.tz === 'string' && req.query.tz.length > 0
    ? req.query.tz
    : 'Asia/Kolkata';

  try {
    const payload = await withUserClient(req.userId, async (rawClient) => {
      const client = transactionTags.tagQueryClient(rawClient, req.userId, tagFilter);
      // Validate against Postgres' timezone catalogue before using the zone
      // for calendar boundaries. An invalid device setting should degrade to
      // the product default, not turn the whole Insights screen into a 500.
      const tzOk = await client.query(`SELECT 1 FROM pg_timezone_names WHERE name = $1`, [requestedTimeZone]);
      const timeZone = tzOk.rowCount > 0 ? requestedTimeZone : 'Asia/Kolkata';
      const calendarOptions = { timeZone };
      const current = period === 'custom'
        ? spendReports.customPeriodBounds(req.query.from, req.query.to, calendarOptions)
        : spendReports.periodBounds(period, anchor, calendarOptions);
      const previous = period === 'custom'
        ? spendReports.previousCustomPeriodBounds(current)
        : spendReports.previousPeriodBounds(period, anchor, calendarOptions);

      const [totals, previousTotals, byCategory, bySubcategory, byMerchant, byCard, byInstrument, byCardCategory, series] = await Promise.all([
        spendReports.periodTotals(client, req.userId, current),
        spendReports.periodTotals(client, req.userId, previous),
        spendReports.spendByCategory(client, req.userId, current),
        spendReports.spendBySubcategory(client, req.userId, current),
        spendReports.spendByMerchant(client, req.userId, current),
        spendReports.spendByCard(client, req.userId, current),
        spendReports.spendByInstrument(client, req.userId, current),
        spendReports.spendByCardCategory(client, req.userId, current),
        period === 'custom'
          ? Promise.resolve([])
          : spendReports.spendSeries(client, req.userId, period, buckets, anchor, calendarOptions),
      ]);

      return {
        period,
        timeZone,
        periodStart: current.start,
        periodEnd: current.end,
        previousPeriodStart: previous.start,
        previousPeriodEnd: previous.end,
        elapsedFraction: spendReports.periodElapsedFraction(current, new Date()),
        totals,
        previousTotals,
        byCategory,
        bySubcategory,
        byMerchant,
        byCard,
        byInstrument,
        byCardCategory,
        series,
      };
    });
    res.json(payload);
  } catch (err) {
    console.error('GET /spend-report error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /assistant/spending-summary — narrow, read-only surface for system
 * assistants and future MCP/AppFunction adapters.
 *
 * This route deliberately reuses spend_reports' period boundaries and totals
 * so an assistant cannot disagree with the Trends screen about what counts as
 * spend. It returns no raw transaction, SMS, merchant, or card data.
 */
app.get('/assistant/spending-summary', requireAuth, async (req, res) => {
  let tagFilter;
  try { tagFilter = transactionTags.readTagFilter(req.query); }
  catch (error) { return res.status(400).json({ error: error.message }); }
  const period = req.query.period || 'month';
  if (!spendReports.PERIODS.includes(period) || period === 'custom') {
    return res.status(400).json({ error: `period must be one of ${spendReports.PERIODS.join(', ')}` });
  }
  const anchor = req.query.anchor ? new Date(req.query.anchor) : new Date();
  if (Number.isNaN(anchor.getTime())) {
    return res.status(400).json({ error: 'anchor is not a valid date' });
  }
  const requestedTimeZone = typeof req.query.tz === 'string' && req.query.tz.length > 0
    ? req.query.tz
    : 'Asia/Kolkata';

  try {
    const summary = await withUserClient(req.userId, async (rawClient) => {
      const client = transactionTags.tagQueryClient(rawClient, req.userId, tagFilter);
      const tzOk = await client.query(
        `SELECT 1 FROM pg_timezone_names WHERE name = $1`,
        [requestedTimeZone]
      );
      const timeZone = tzOk.rowCount > 0 ? requestedTimeZone : 'Asia/Kolkata';
      const bounds = spendReports.periodBounds(period, anchor, { timeZone });
      const totals = await spendReports.periodTotals(client, req.userId, bounds);
      const latestSms = await client.query(
        `SELECT MAX(o.observed_at) AS latest_sms_observed_at
           FROM transaction_observations o
           JOIN transactions t ON t.id = o.transaction_id
          WHERE t.profile_id = $1
            AND o.source IN ('sms', 'sms_bulk')`,
        [req.userId]
      );

      return buildAssistantSpendingSummary({
        period,
        timeZone,
        bounds,
        totals,
        latestSmsObservedAt: latestSms.rows[0]?.latest_sms_observed_at || null,
      });
    });
    res.json({ assistantSpendingSummary: summary });
  } catch (err) {
    console.error('GET /assistant/spending-summary error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /export/transactions.csv — a spend report someone can open in a
 * spreadsheet or hand to their accountant.
 *
 * `GET /export` already existed and returns the whole account as JSON —
 * right for a data-portability request, useless for "what did I spend last
 * quarter". This is the reporting counterpart: one row per transaction,
 * date-ranged, with the columns a person actually reconciles against.
 *
 * Deliberately NOT mounted at `/transactions/export.csv`: `GET
 * /transactions/:id` is registered earlier in this file and would match
 * `export.csv` as an id, so that path would 404 with a confusing
 * "transaction not found" rather than exporting anything.
 */
app.get('/export/transactions.csv', requireAuth, async (req, res) => {
  const { from, to } = req.query;
  try {
    const rows = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT t.occurred_at, t.amount_inr, t.merchant_name,
                COALESCE(parent_sc.name, parent_uc.name, sc.name, ucat.name) AS category_name,
                CASE WHEN ucat.parent_category_id IS NOT NULL OR ucat.parent_user_category_id IS NOT NULL THEN ucat.name END AS subcategory_name,
                cp.name AS card_name, uc.nickname AS card_nickname,
                t.instrument, t.entry_kind, t.rail, t.source, t.expected_value_inr, t.note
           FROM transactions t
           LEFT JOIN user_cards uc ON uc.id = t.user_card_id
           LEFT JOIN card_products cp ON cp.id = uc.card_product_id
           LEFT JOIN spend_categories sc ON sc.id = t.category_id
          LEFT JOIN user_categories ucat ON ucat.id = t.user_category_id AND ucat.profile_id = t.profile_id
          LEFT JOIN spend_categories parent_sc ON parent_sc.id = ucat.parent_category_id
          LEFT JOIN user_categories parent_uc ON parent_uc.id = ucat.parent_user_category_id AND parent_uc.profile_id = t.profile_id
          WHERE t.profile_id = $1 AND t.status = 'active'
            AND ($2::date IS NULL OR t.occurred_at >= $2::date)
            AND ($3::date IS NULL OR t.occurred_at < ($3::date + interval '1 day'))
          ORDER BY t.occurred_at DESC`,
        [req.userId, from || null, to || null]
      )
    );

    const header = [
      'Date', 'Amount (INR)', 'Merchant', 'Category', 'Subcategory', 'Card',
      'Paid with', 'Kind', 'Rail', 'Source', 'Rewards (INR)', 'Note',
    ];
    const taggedRows = await withUserClient(req.userId, (client) => transactionTags.attachTags(client, req.userId, rows.rows));
    header.push('Tags');
    const body = taggedRows.map((r) => [
      new Date(r.occurred_at).toISOString().slice(0, 10),
      Number(r.amount_inr).toFixed(2),
      r.merchant_name,
      r.category_name,
      r.subcategory_name,
      r.card_nickname || r.card_name,
      r.instrument,
      r.entry_kind,
      r.rail,
      r.source,
      Number(r.expected_value_inr || 0).toFixed(2),
      r.note,
      JSON.stringify(r.tags.map((tag) => tag.name)),
    ]);

    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader('Content-Disposition', 'attachment; filename="pandapay-transactions.csv"');
    res.send(csvDocument(header, body));
  } catch (err) {
    console.error('GET /export/transactions.csv error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

const BUDGET_SCOPES = ['overall', 'category', 'card', 'tag'];
const BUDGET_PERIODS = ['weekly', 'monthly', 'quarterly', 'yearly'];

/**
 * GET /budgets — every active budget with its CURRENT-period progress.
 *
 * Progress is computed here rather than returned as a bare limit for the
 * client to fill in, because "am I over?" depends on the period boundary,
 * and the period boundary depends on the budget's own `starts_on` anchor
 * (a weekly budget starting Thursday runs Thursday to Wednesday). Deriving
 * that on two clients independently is how they end up disagreeing.
 *
 * `projectedInr` extrapolates the current pace across the whole period.
 * It is explicitly a projection and is only meaningful alongside
 * `elapsedFraction`: 60% of a budget spent is alarming on day 3 and fine on
 * day 25, and a percentage without that context just makes people anxious.
 */
app.get('/budgets', requireAuth, async (req, res) => {
  try {
    const payload = await withUserClient(req.userId, async (client) => {
      const budgets = await client.query(
        `SELECT b.id, b.scope, b.scope_ref_id, b.period, b.amount_inr, b.starts_on,
                b.rollover, b.is_active,
                COALESCE(parent_sc.name, parent_uc.name, sc.name, ucat.name) AS category_name,
                CASE WHEN ucat.parent_category_id IS NOT NULL OR ucat.parent_user_category_id IS NOT NULL THEN ucat.name END AS subcategory_name,
                cp.name AS card_name, uc.nickname AS card_nickname,
                tt.name AS tag_name
           FROM budgets b
          LEFT JOIN transaction_tags tt ON b.scope = 'tag' AND tt.id=b.scope_ref_id AND tt.profile_id=b.profile_id
          LEFT JOIN spend_categories sc ON b.scope = 'category' AND sc.id = b.scope_ref_id
          LEFT JOIN user_categories ucat ON b.scope = 'category' AND ucat.id = b.scope_ref_id AND ucat.profile_id = b.profile_id
          LEFT JOIN spend_categories parent_sc ON parent_sc.id = ucat.parent_category_id
          LEFT JOIN user_categories parent_uc ON parent_uc.id = ucat.parent_user_category_id AND parent_uc.profile_id = b.profile_id
           LEFT JOIN user_cards uc ON b.scope = 'card' AND uc.id = b.scope_ref_id
           LEFT JOIN card_products cp ON cp.id = uc.card_product_id
          WHERE b.profile_id = $1 AND b.is_active
          ORDER BY b.scope, b.period`,
        [req.userId]
      );

      const now = new Date();
      const rows = [];
      for (const b of budgets.rows) {
        const bounds = spendReports.budgetPeriodBounds(b, now);
        const { spentInr, txnCount } = await spendReports.budgetSpend(client, req.userId, b, bounds);
        const amountInr = Number(b.amount_inr);
        const elapsed = spendReports.periodElapsedFraction(bounds, now);
        rows.push({
          id: b.id,
          scope: b.scope,
          scopeRefId: b.scope_ref_id,
          label: b.scope === 'overall'
            ? 'All spending'
            : b.scope === 'category'
              ? (b.subcategory_name
                ? `${b.category_name || 'Category'} · ${b.subcategory_name}`
                : (b.category_name || 'Category'))
              : b.scope === 'tag' ? (b.tag_name || 'Tag') : (b.card_nickname || b.card_name || 'Card'),
          period: b.period,
          amountInr,
          startsOn: b.starts_on,
          rollover: b.rollover,
          periodStart: bounds.start,
          periodEnd: bounds.end,
          spentInr,
          txnCount,
          remainingInr: amountInr - spentInr,
          consumedFraction: amountInr > 0 ? spentInr / amountInr : 0,
          elapsedFraction: elapsed,
          // Straight-line extrapolation of the pace so far. Null in the
          // first moments of a period, where dividing by a near-zero
          // elapsed fraction produces an enormous, meaningless number.
          projectedInr: elapsed > 0.05 ? spentInr / elapsed : null,
        });
      }
      return rows;
    });
    res.json({ budgets: payload });
  } catch (err) {
    console.error('GET /budgets error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /budgets — create or replace the budget for one target.
 *
 * Replacing rather than erroring on a duplicate: the partial unique index
 * allows only one ACTIVE budget per (scope, target, period), and a user
 * setting a monthly groceries budget when one already exists means "change
 * it", not "fail". The old row is DEACTIVATED, not deleted, so the
 * `budget_periods` history that references it survives.
 */
app.post('/budgets', requireAuth, async (req, res) => {
  const { scope, scopeRefId, period, amountInr, startsOn, rollover } = req.body || {};
  if (!BUDGET_SCOPES.includes(scope)) {
    return res.status(400).json({ error: `scope must be one of ${BUDGET_SCOPES.join(', ')}` });
  }
  if (!BUDGET_PERIODS.includes(period)) {
    return res.status(400).json({ error: `period must be one of ${BUDGET_PERIODS.join(', ')}` });
  }
  const amount = Number(amountInr);
  if (!Number.isFinite(amount) || amount <= 0) {
    return res.status(400).json({ error: 'amountInr must be a positive number' });
  }
  if (scope === 'overall' && scopeRefId) {
    return res.status(400).json({ error: 'an overall budget takes no scopeRefId' });
  }
  if (scope !== 'overall' && (!scopeRefId || typeof scopeRefId !== 'string')) {
    return res.status(400).json({ error: 'scopeRefId is required for a category or card budget' });
  }

  try {
    const result = await withUserClient(req.userId, async (client) => {
      // Validate the referent exists and, for a card, belongs to this user.
      // The column is deliberately not a foreign key (it points at two
      // different tables depending on scope), so this check is the only
      // thing standing between a typo and a budget that can never match
      // any spend.
      if (scope === 'category') {
        const found = await client.query(
          `SELECT id FROM spend_categories WHERE id = $1
           UNION ALL
           SELECT id FROM user_categories WHERE id = $1 AND profile_id = $2`,
          [scopeRefId, req.userId],
        );
        if (found.rows.length === 0) return { status: 404, error: 'category not found' };
      } else if (scope === 'tag') {
        const found = await client.query('SELECT id FROM transaction_tags WHERE id=$1 AND profile_id=$2 AND archived_at IS NULL', [scopeRefId,req.userId]);
        if (!found.rows.length) return { status:404,error:'tag not found' };
      } else if (scope === 'card') {
        const found = await client.query(
          `SELECT id FROM user_cards WHERE id = $1 AND profile_id = $2 AND is_archived = false`,
          [scopeRefId, req.userId]
        );
        if (found.rows.length === 0) return { status: 404, error: 'card not found' };
      }

      await client.query(
        `UPDATE budgets SET is_active = false
          WHERE profile_id = $1 AND is_active AND scope = $2 AND period = $3
            AND scope_ref_id IS NOT DISTINCT FROM $4`,
        [req.userId, scope, period, scopeRefId || null]
      );

      const inserted = await client.query(
        `INSERT INTO budgets (profile_id, scope, scope_ref_id, period, amount_inr, starts_on, rollover)
         VALUES ($1, $2, $3, $4, $5, COALESCE($6::date, CURRENT_DATE), COALESCE($7, false))
         RETURNING id, scope, scope_ref_id, period, amount_inr, starts_on, rollover, is_active`,
        [req.userId, scope, scopeRefId || null, period, amount, startsOn || null, rollover]
      );
      return { status: 201, budget: inserted.rows[0] };
    });

    if (result.status !== 201) return res.status(result.status).json({ error: result.error });
    res.status(201).json({ budget: result.budget });
  } catch (err) {
    console.error('POST /budgets error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * DELETE /budgets/:id — deactivates rather than deletes, so any
 * `budget_periods` history pointing at it stays readable. "Did I stay in
 * budget last March?" must not become unanswerable because the budget was
 * removed in April.
 */
app.delete('/budgets/:id', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `UPDATE budgets SET is_active = false
          WHERE id = $1 AND profile_id = $2 AND is_active
          RETURNING id`,
        [req.params.id, req.userId]
      )
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'budget not found' });
    res.json({ ok: true });
  } catch (err) {
    console.error('DELETE /budgets/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /recurring — the user's subscriptions, detected from their own
 * history and refreshed on read.
 *
 * Detection runs here rather than on a schedule because there is no cron
 * infrastructure in this product and inventing one for this would be a
 * larger commitment than the feature warrants. The read is bounded (24
 * months of spend for one profile, grouped in memory) and the result is
 * persisted, so a series survives between reads and can carry a user's
 * "I cancelled this" dismissal.
 *
 * Dismissed series are never resurrected. Re-detecting something the user
 * explicitly told us they cancelled — every single time they open the
 * screen — is the fastest way to make a feature feel broken.
 */
app.get('/recurring', requireAuth, async (req, res) => {
  try {
    const payload = await withUserClient(req.userId, async (client) => {
      const history = await client.query(
        `SELECT merchant_name, amount_inr, occurred_at, category_id, user_category_id, user_card_id, instrument
           FROM transactions
          WHERE profile_id = $1 AND status = 'active' AND entry_kind = 'spend'
            AND occurred_at >= now() - interval '24 months'
          ORDER BY occurred_at ASC`,
        [req.userId]
      );

      const detected = detectRecurringSeries(history.rows);

      const dismissed = await client.query(
        `SELECT merchant_key FROM recurring_series WHERE profile_id = $1 AND dismissed_at IS NOT NULL`,
        [req.userId]
      );
      const dismissedKeys = new Set(dismissed.rows.map((r) => r.merchant_key));

      for (const s of detected) {
        if (dismissedKeys.has(s.merchantKey)) continue;
        await client.query(
          `INSERT INTO recurring_series
             (profile_id, merchant_key, display_name, category_id, user_category_id, user_card_id,
              payment_method, typical_amount_inr, cadence_days, occurrence_count,
              first_seen_on, last_seen_on, next_expected_on)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
           ON CONFLICT (profile_id, merchant_key) DO UPDATE SET
             display_name = CASE WHEN recurring_series.user_edited THEN recurring_series.display_name ELSE EXCLUDED.display_name END,
             category_id = EXCLUDED.category_id,
             user_category_id = EXCLUDED.user_category_id,
             user_card_id = EXCLUDED.user_card_id,
             payment_method = COALESCE(EXCLUDED.payment_method, recurring_series.payment_method),
             typical_amount_inr = CASE WHEN recurring_series.user_edited THEN recurring_series.typical_amount_inr ELSE EXCLUDED.typical_amount_inr END,
             cadence_days = CASE WHEN recurring_series.user_edited THEN recurring_series.cadence_days ELSE EXCLUDED.cadence_days END,
             occurrence_count = EXCLUDED.occurrence_count,
             first_seen_on = COALESCE(recurring_series.first_seen_on, EXCLUDED.first_seen_on),
             last_seen_on = EXCLUDED.last_seen_on,
             next_expected_on = CASE
               WHEN recurring_series.user_edited
                 AND recurring_series.next_expected_on >= CURRENT_DATE
               THEN recurring_series.next_expected_on
               ELSE EXCLUDED.next_expected_on
             END,
             detection_source = CASE
               WHEN recurring_series.detection_source IN ('mandate', 'manual') THEN recurring_series.detection_source
               ELSE 'observed'
             END,
             autopay_status = CASE
               WHEN recurring_series.detection_source = 'mandate' THEN recurring_series.autopay_status
               ELSE COALESCE(recurring_series.autopay_status, 'unknown')
             END,
             is_active = CASE WHEN recurring_series.detection_source = 'mandate' AND recurring_series.is_active = false THEN false ELSE recurring_series.is_active END,
             cadence_confirmed = CASE
               WHEN recurring_series.user_edited THEN recurring_series.cadence_confirmed
               ELSE TRUE
             END,
             updated_at = now()`,
          [
            req.userId, s.merchantKey, s.displayName, s.categoryId, s.userCategoryId || null, s.userCardId,
            s.paymentMethod || null, s.typicalAmountInr, s.cadenceDays, s.occurrenceCount,
            s.firstSeenOn, s.lastSeenOn, s.nextExpectedOn,
          ]
        );
      }

      const stored = await client.query(
        `SELECT rs.id, rs.merchant_key, rs.display_name, rs.typical_amount_inr,
                rs.cadence_days, rs.occurrence_count, rs.first_seen_on, rs.last_seen_on,
                TO_CHAR(rs.next_expected_on, 'YYYY-MM-DD') AS next_expected_on,
                rs.category_id, rs.user_category_id, rs.user_card_id, rs.payment_method,
                rs.detection_source, rs.user_edited, rs.lifecycle_status,
                rs.autopay_status, rs.mandate_reference, rs.cadence_confirmed,
                COALESCE(parent_sc.name, parent_uc.name, sc.name, ucat.name) AS category_name,
                CASE WHEN ucat.parent_category_id IS NOT NULL OR ucat.parent_user_category_id IS NOT NULL THEN ucat.name END AS subcategory_name,
                cp.name AS card_name, uc.nickname AS card_nickname
           FROM recurring_series rs
           LEFT JOIN spend_categories sc ON sc.id = rs.category_id
           LEFT JOIN user_categories ucat ON ucat.id = rs.user_category_id AND ucat.profile_id = rs.profile_id
           LEFT JOIN spend_categories parent_sc ON parent_sc.id = ucat.parent_category_id
           LEFT JOIN user_categories parent_uc ON parent_uc.id = ucat.parent_user_category_id AND parent_uc.profile_id = rs.profile_id
           LEFT JOIN user_cards uc ON uc.id = rs.user_card_id
           LEFT JOIN card_products cp ON cp.id = uc.card_product_id
           WHERE rs.profile_id = $1
             AND rs.is_active
             AND rs.dismissed_at IS NULL
             AND rs.lifecycle_status = 'active'`,
        [req.userId]
      );

      // Explicit service facts (including a free or one-time plan) may not
      // have a repeated transaction row yet. Read those central projections
      // alongside the legacy recurring_series rows. The savepoint keeps an
      // older deployment usable until the additive projection migration has
      // reached every API instance.
      let centralSubscriptions = [];
      let centralSavepoint = false;
      try {
        await client.query('SAVEPOINT recurring_central_projection');
        centralSavepoint = true;
        let projectionRows = await client.query(
          `SELECT projection_key, status, projection, source_key
             FROM financial_projections
            WHERE profile_id = $1
              AND projection_kind = 'subscription'
              AND status NOT IN ('cancelled', 'ended', 'hidden')
            ORDER BY updated_at DESC`,
          [req.userId],
        );

        // The checkpoint includes sources that yield no domain projection,
        // so repeated page reads never reprocess the same historical SMS.
        const backfilled = await centralProjection.backfillFinancialProjections(client, req.userId);
        if (backfilled > 0) {
          projectionRows = await client.query(
            `SELECT projection_key, status, projection, source_key
               FROM financial_projections
              WHERE profile_id = $1
                AND projection_kind = 'subscription'
                AND status NOT IN ('cancelled', 'ended', 'hidden')
              ORDER BY updated_at DESC`,
            [req.userId],
          );
        }
        await client.query('RELEASE SAVEPOINT recurring_central_projection');
        centralSubscriptions = projectionRows.rows || [];
      } catch (error) {
        if (centralSavepoint) {
          await client.query('ROLLBACK TO SAVEPOINT recurring_central_projection').catch(() => {});
          await client.query('RELEASE SAVEPOINT recurring_central_projection').catch(() => {});
        }
        console.warn('central subscription read skipped:', error.message || error);
      }

      // The parser used to accept dates, account numbers, and labels such as
      // "MONTHLY" as merchants. Ignore those legacy rows at the read
      // boundary as well as fixing new ingestion, so an existing account is
      // corrected without a destructive migration.
      const legacyMandateRows = stored.rows
        .map((row) => centralProjection.legacyMandateSetupRow(row))
        .filter(Boolean);
      const validRows = stored.rows.filter(isDisplayableSubscriptionRecord).concat(legacyMandateRows);
      const now = new Date();
      const series = validRows.map((r) => {
        if (r.__legacyMandateSetup) {
          return {
            id: r.id,
            displayName: r.display_name,
            typicalAmountInr: null,
            cadenceDays: null,
            occurrenceCount: 0,
            firstSeenOn: null,
            lastSeenOn: null,
            nextExpectedOn: null,
            categoryId: r.category_id,
            userCategoryId: r.user_category_id,
            categoryName: r.category_name,
            subcategoryName: r.subcategory_name,
            cardId: r.user_card_id,
            paymentMethod: r.payment_method,
            cardName: r.card_nickname || r.card_name,
            detectionSource: 'mandate',
            isMandate: true,
            isUserEdited: r.user_edited,
            lifecycleStatus: 'candidate',
            autopayStatus: r.autopay_status || 'active',
            mandateReference: r.mandate_reference || null,
            cadenceConfirmed: false,
            setupConfirmed: true,
            engineStatus: 'candidate',
            annualCostInr: 0,
          };
        }
        const cadenceDays = r.cadence_days;
        // The renewal date is DERIVED at read, never trusted from storage:
        // a stored next_expected_on is a write-time snapshot that silently
        // expires the moment a charge fails to appear. Machine-detected
        // rows project from their last observed charge on calendar-month
        // semantics (a ₹1,999 charge on the 1st → the 1st of next month,
        // not last+30). Rows the user shaped keep the date they saved —
        // when that date lapses, engineStatus below flags it for review
        // rather than quietly projecting a future their data never showed.
        const derivedAnchor = r.last_seen_on || r.first_seen_on;
        // A `date` column arrives from the driver as a JS Date, so it is
        // normalized inside nextExpectedAfter; appending a time suffix to it
        // here produced an invalid date and took the whole screen down.
        const derivedNext = derivedAnchor
          ? nextExpectedAfter(derivedAnchor, cadenceDays, now)
          : null;
        const derivedDate = derivedNext
          ? derivedNext.toISOString().slice(0, 10)
          : null;
        const nextExpectedOn = r.user_edited
          ? (r.next_expected_on ?? derivedDate)
          : (derivedDate ?? r.next_expected_on);
        const status = engineStatus({
          cadence_days: cadenceDays,
          cadence_confirmed: r.cadence_confirmed,
          detection_source: r.detection_source,
          occurrence_count: r.occurrence_count,
          first_seen_on: r.first_seen_on,
          last_seen_on: r.last_seen_on,
          next_expected_on: r.user_edited ? r.next_expected_on : null,
        }, now);
        // Known-brand display names apply where the user has not already
        // fixed the string themselves ('OPENAILLC' → 'OpenAI').
        const brand = brandFor(r.display_name);
        return {
          id: r.id,
          displayName: !r.user_edited && brand ? brand.name : r.display_name,
          typicalAmountInr: Number(r.typical_amount_inr),
          cadenceDays,
          occurrenceCount: r.occurrence_count,
          firstSeenOn: r.first_seen_on,
          lastSeenOn: r.last_seen_on,
          nextExpectedOn,
          categoryId: r.category_id,
          userCategoryId: r.user_category_id,
          categoryName: r.category_name,
          subcategoryName: r.subcategory_name,
          cardId: r.user_card_id,
          paymentMethod: r.payment_method,
          cardName: r.card_nickname || r.card_name,
          detectionSource: r.detection_source || 'observed',
          isMandate: r.detection_source === 'mandate',
          isUserEdited: r.user_edited,
          lifecycleStatus: r.lifecycle_status || 'active',
          autopayStatus: r.autopay_status || (r.detection_source === 'mandate' ? 'active' : 'unknown'),
          mandateReference: r.mandate_reference || null,
          cadenceConfirmed: r.cadence_confirmed !== false,
          engineStatus: status,
          annualCostInr: annualCost({
            typicalAmountInr: Number(r.typical_amount_inr),
            cadenceDays,
          }),
        };
      });

      const existingServiceKeys = new Set(
        series.map((item) => merchantSeriesKey(item.displayName)),
      );
      const centralSubscriptionStatuses = new Set([
        'candidate', 'active', 'renewal_unverified', 'ended', 'payment_issue',
        'cancelled', 'paused', 'unknown',
      ]);
      for (const row of centralSubscriptions) {
        const projection = row.projection && typeof row.projection === 'object'
          ? row.projection
          : {};
        const displayName = String(projection.serviceName || '').trim();
        const serviceKey = merchantSeriesKey(displayName);
        if (!displayName || !serviceKey || existingServiceKeys.has(serviceKey)) continue;
        const numericAmount = (value) => (
          value !== null && value !== undefined && value !== '' && Number.isFinite(value)
            ? value
            : null
        );
        const statedAmount = numericAmount(projection.statedNextPaymentAmountInr);
        const postedAmount = numericAmount(projection.lastPostedPayment?.amountInr);
        const amount = statedAmount ?? postedAmount;
        const cadence = Number(projection.cadenceDays);
        const cadenceKnown = Number.isInteger(cadence) && cadence > 0;
        const nextDate = projection.statedNextPaymentDate
          || projection.estimatedNextPaymentDate
          || null;
        const rawStatus = String(row.status || projection.subscriptionStatus || 'unknown');
        const status = centralSubscriptionStatuses.has(rawStatus) ? rawStatus : 'unknown';
        const oneTime = projection.renewalMode === 'one_time';
        series.push({
          id: `projection:${row.projection_key}`,
          displayName,
          typicalAmountInr: amount,
          cadenceDays: cadenceKnown ? cadence : null,
          occurrenceCount: projection.lastPostedPayment ? 1 : 0,
          firstSeenOn: projection.lastPostedPayment?.occurredAt || null,
          lastSeenOn: projection.lastPostedPayment?.occurredAt || null,
          nextExpectedOn: nextDate,
          categoryId: null,
          userCategoryId: null,
          categoryName: null,
          subcategoryName: null,
          cardId: null,
          paymentMethod: null,
          detectionSource: 'central_projection',
          isMandate: false,
          isUserEdited: false,
          lifecycleStatus: status,
          autopayStatus: 'unknown',
          mandateReference: projection.mandateKey || null,
          sourceKey: row.source_key || null,
          cadenceConfirmed: cadenceKnown,
          setupConfirmed: projection.setupConfirmed === true,
          engineStatus: status === 'active' && (oneTime || cadenceKnown) ? 'confirmed' : status,
          annualCostInr: oneTime || !cadenceKnown || amount === null ? 0 : amount * (365 / cadence),
        });
        existingServiceKeys.add(serviceKey);
      }

      // Biggest annual cost first — the order someone reviewing their
      // subscriptions wants. Sorted here rather than in SQL so the same
      // calendar-bucket annual estimate drives ordering and display.
      series.sort((a, b) => b.annualCostInr - a.annualCostInr);

      return {
        series,
        // The headline counts subscriptions whose cycle is actually proven
        // and still billing. Guesses (needs_cadence), unused mandates and
        // possibly-stopped series don't belong in "your recurring spend".
        totalAnnualInr: series
          .filter((s) => s.engineStatus === 'confirmed')
          .reduce((sum, s) => sum + s.annualCostInr, 0),
      };
    });
    res.json(payload);
  } catch (err) {
    console.error('GET /recurring error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

app.post('/recurring', requireAuth, async (req, res) => {
  const { displayName, typicalAmountInr, cadenceDays, nextExpectedOn } = req.body || {};
  const autopayStatus = req.body?.autopayStatus || 'unknown';
  const name = typeof displayName === 'string' ? displayName.trim() : '';
  const amount = Number(typicalAmountInr);
  const cadence = Number(cadenceDays);
  const dateIsValid = typeof nextExpectedOn === 'string'
    && /^\d{4}-\d{2}-\d{2}$/.test(nextExpectedOn)
    && !Number.isNaN(Date.parse(`${nextExpectedOn}T00:00:00Z`))
    && new Date(`${nextExpectedOn}T00:00:00Z`).toISOString().slice(0, 10) === nextExpectedOn;

  if (!isUsableSubscriptionName(name) || name.length > 80 ||
      !Number.isFinite(amount) || amount <= 0 || amount > 10000000 ||
      ![30, 365].includes(cadence) ||
      !['active', 'cancelled', 'unknown'].includes(autopayStatus) ||
      !dateIsValid) {
    return res.status(400).json({ error: 'invalid_subscription' });
  }

  const merchantKey = merchantSeriesKey(name);
  if (!merchantKey) return res.status(400).json({ error: 'invalid_subscription' });

  try {
    const result = await withUserClient(req.userId, (client) => client.query(
      `INSERT INTO recurring_series
         (profile_id, merchant_key, display_name, typical_amount_inr,
          cadence_days, occurrence_count, first_seen_on, last_seen_on,
          next_expected_on, detection_source, user_edited, autopay_status)
       VALUES ($1, $2, $3, $4, $5, 0, NULL, NULL, $6, 'manual', true, $7)
       ON CONFLICT (profile_id, merchant_key) DO UPDATE SET
         display_name = EXCLUDED.display_name,
         typical_amount_inr = EXCLUDED.typical_amount_inr,
         cadence_days = EXCLUDED.cadence_days,
         next_expected_on = EXCLUDED.next_expected_on,
         detection_source = 'manual',
         user_edited = true,
         lifecycle_status = 'active',
         autopay_status = EXCLUDED.autopay_status,
         mandate_reference = NULL,
         mandate_started_on = NULL,
         mandate_cancelled_at = NULL,
         is_active = true,
         dismissed_at = NULL,
         updated_at = now()
       RETURNING id`,
      [req.userId, merchantKey, name, amount, cadence, nextExpectedOn, autopayStatus]
    ));
    res.status(201).json({ id: result.rows[0].id });
  } catch (err) {
    console.error('POST /recurring error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

app.patch('/recurring/:id', requireAuth, async (req, res) => {
  const { displayName, typicalAmountInr, cadenceDays, nextExpectedOn } = req.body || {};
  const autopayStatus = req.body?.autopayStatus;
  if (typeof displayName !== 'string' || displayName.trim().length < 2 || displayName.trim().length > 80 ||
      !Number.isFinite(Number(typicalAmountInr)) || Number(typicalAmountInr) <= 0 || Number(typicalAmountInr) > 10000000 ||
      !Number.isInteger(Number(cadenceDays)) || Number(cadenceDays) < 1 || Number(cadenceDays) > 3650 ||
      (autopayStatus !== undefined && !['active', 'cancelled', 'unknown'].includes(autopayStatus)) ||
      typeof nextExpectedOn !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(nextExpectedOn) || Number.isNaN(Date.parse(`${nextExpectedOn}T00:00:00Z`))) {
    return res.status(400).json({ error: 'invalid_subscription' });
  }
  try {
    const result = await withUserClient(req.userId, (client) => client.query(
      `UPDATE recurring_series SET display_name = $1, typical_amount_inr = $2,
              cadence_days = $3, next_expected_on = $4,
              autopay_status = COALESCE($5, autopay_status), user_edited = true,
              cadence_confirmed = true
        WHERE id = $6 AND profile_id = $7 AND dismissed_at IS NULL RETURNING id`,
      [displayName.trim(), Number(typicalAmountInr), Number(cadenceDays), nextExpectedOn, autopayStatus ?? null, req.params.id, req.userId]
    ));
    if (!result.rows.length) return res.status(404).json({ error: 'not_found' });
    res.json({ ok: true });
  } catch (err) {
    console.error('PATCH /recurring error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /recurring/:id/dismiss — "I cancelled this."
 *
 * Sets `dismissed_at` rather than deleting the row, which is what stops the
 * next detection run re-adding it. Deleting would make the dismissal last
 * exactly until the user next opened the screen.
 */
app.post('/recurring/:id/dismiss', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `UPDATE recurring_series SET dismissed_at = now(), is_active = false,
              lifecycle_status = 'hidden'
          WHERE id = $1 AND profile_id = $2
          RETURNING id`,
        [req.params.id, req.userId]
      )
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'not_found' });
    res.json({ ok: true });
  } catch (err) {
    console.error('POST /recurring/:id/dismiss error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /card-discovery — "find my cards", from forwarded bank email and/or
 * SMS bodies the device passes up.
 *
 * Design 30 offers "Find them in my SMS" as the fastest way to add cards.
 * Email is the other half of the same idea and is in some ways the better
 * one: it works on iOS, where no app may read SMS at all, and the user has
 * already opted into it by setting up a forwarding address.
 *
 * Two sources, one matcher (src/card_discovery.js), so the same card is
 * recognised identically in an SMS alert and a statement email.
 *
 * This returns SUGGESTIONS ONLY and adds nothing. Every candidate carries
 * the text that produced it so the user can see why it was suggested and
 * reject a wrong one — silently adding a card someone doesn't own would
 * then rank against a card they can't pay with.
 *
 * SMS bodies (`smsBodies`) are accepted in the request and used in memory
 * for this response only. They are never written to the database, matching
 * the on-device-only promise SmsConsentScreen makes to the user.
 */
app.post('/card-discovery', requireAuth, async (req, res) => {
  const { smsBodies } = req.body || {};
  if (smsBodies !== undefined && !Array.isArray(smsBodies)) {
    return res.status(400).json({ error: 'smsBodies must be an array of strings' });
  }
  try {
    const payload = await withUserClient(req.userId, async (client) => {
      const catalogue = await client.query(
        `SELECT id, slug, name, card_type, issuer_name, issuer_slug FROM v_card_catalogue_export`
      );

      // Only sender-verified bank mail is scanned. Anyone can send mail to a
      // forwarding address, and a stranger writing "HDFC Millennia" in an
      // email should not put a card in your wallet's suggestion list.
      const emails = await client.query(
        `SELECT subject, body_text AS body, sender
           FROM inbound_emails
          WHERE profile_id = $1 AND is_known_bank_sender
          ORDER BY received_at DESC
          LIMIT 200`,
        [req.userId]
      );

      const smsMessages = (smsBodies || [])
        .filter((b) => typeof b === 'string' && b.trim())
        .slice(0, 500)
        .map((body) => ({ body }));

      const owned = await client.query(
        `SELECT card_product_id
           FROM user_cards
          WHERE profile_id = $1 AND is_archived = false`,
        [req.userId]
      );
      const ownedIds = new Set(owned.rows.map((r) => r.card_product_id));

      const fromEmail = discoverCardsAcrossMessages(emails.rows, catalogue.rows);
      const fromSms = discoverCardsAcrossMessages(smsMessages, catalogue.rows, true);

      // Tag each suggestion with where it came from, so the UI can say
      // "found in your email" vs "found in your SMS" rather than an
      // unexplained list.
      const merged = new Map();
      for (const [source, hits] of [
        ['email', fromEmail],
        ['sms', fromSms],
      ]) {
        for (const hit of hits) {
          const existing = merged.get(hit.cardProductId);
          if (existing) {
            existing.sources.push(source);
            existing.score = Math.max(existing.score, hit.score);
            existing.messageCount += hit.messageCount;
            // A bank statement email can identify the product while the
            // device SMS carries the masked suffix. Preserve both pieces of
            // evidence when the two channels resolve to the same catalogue
            // row; otherwise the UI loses the suffix depending on which
            // source was merged first and the confirmed card cannot be saved
            // with its matching key.
            for (const evidence of hit.evidence || []) {
              if (!existing.evidence?.includes(evidence)) {
                existing.evidence = [...(existing.evidence || []), evidence];
              }
            }
            for (const last4 of hit.last4 || []) {
              if (!existing.last4?.includes(last4)) {
                existing.last4 = [...(existing.last4 || []), last4];
              }
            }
            if (existing.creditLimitInr == null && hit.creditLimitInr != null) {
              existing.creditLimitInr = hit.creditLimitInr;
            }
            existing.isAlreadyOwned = existing.isAlreadyOwned || ownedIds.has(hit.cardProductId);
          } else {
            merged.set(hit.cardProductId, {
              ...hit,
              sources: [source],
              // Keep an owned match in the response so the client can show
              // the successful detection and disable the add action. Hiding
              // it here made a previously detected card appear to vanish.
              isAlreadyOwned: ownedIds.has(hit.cardProductId),
            });
          }
        }
      }

      return {
        suggestions: [...merged.values()].sort((a, b) => b.score - a.score),
        scanned: { emails: emails.rowCount, sms: smsMessages.length },
      };
    });
    res.json(payload);
  } catch (err) {
    console.error('POST /card-discovery error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /referrals — design 25's Invite friends screen in one call: the
 * programme terms, this user's own code (minted on first read), and every
 * referral they've made.
 *
 * The terms come from the `referral_program` config row rather than being
 * baked into the app, because "Give ₹100, get ₹100" is a commercial
 * commitment the business changes without shipping a release. When
 * `is_active` is false the client shows the invite mechanics with no reward
 * claim at all — it never advertises money that isn't on offer.
 */
app.get('/referrals', requireAuth, async (req, res) => {
  try {
    const payload = await withUserClient(req.userId, async (client) => {
      const program = await client.query(`SELECT * FROM referral_program WHERE id = 1`);

      // Creation is owned by the access-controlled SECURITY DEFINER routine;
      // the app_user role cannot insert or mutate referral codes directly.
      const codeResult = await client.query(
        'SELECT promotions.ensure_current_invitation_code() AS code',
      );
      const code = codeResult.rows[0]?.code || null;

      const referrals = await client.query(
        `SELECT r.id, r.reward_state, r.created_at, r.qualified_at,
                COALESCE(NULLIF(btrim(r.referee_label), ''), 'Friend') AS label
           FROM referrals r
          WHERE r.referrer_id = $1
          ORDER BY r.created_at DESC`,
        [req.userId]
      );

      return { program: program.rows[0] || null, code, referrals: referrals.rows };
    });
    res.json(payload);
  } catch (err) {
    console.error('GET /referrals error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /notifications — design 19's inbox, newest first.
 *
 * Read-only over the `notifications` table (0024). Nothing is synthesised
 * here: if a notification wasn't delivered and recorded, it doesn't appear.
 * The client trims to the last seven calendar days in the device's own
 * timezone rather than the server guessing which local day a row belongs to.
 *
 * Only the last week is returned; older rows stay in the table but drop out
 * of the inbox (and the unread badge) so the list doesn't grow forever. The
 * SQL window carries a day of slack because the client trims to seven *local*
 * calendar days, which can start up to a day earlier than UTC's now() - 7d.
 */
app.get('/notifications', requireAuth, async (req, res) => {
  const limit = Math.min(Number.parseInt(req.query.limit, 10) || 50, 200);
  try {
    const rows = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT id, category, severity, title, body, deep_link, read_at, created_at
           FROM notifications
          WHERE profile_id = $1
            AND created_at > now() - interval '8 days'
          ORDER BY created_at DESC
          LIMIT $2`,
        [req.userId, limit]
      )
    );
    const unread = rows.rows.filter((r) => r.read_at === null).length;
    res.json({ notifications: rows.rows, unreadCount: unread });
  } catch (err) {
    console.error('GET /notifications error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /notifications/read — marks one notification read, or all of them
 * when no id is given (design 19's "Mark all read").
 *
 * `read_at` is only ever set, never cleared to a *later* time on re-read:
 * COALESCE keeps the first-read timestamp, which is the honest one.
 */
app.post('/notifications/read', requireAuth, async (req, res) => {
  const { id } = req.body || {};
  try {
    const result = await withUserClient(req.userId, (client) =>
      id
        ? client.query(
            `UPDATE notifications SET read_at = COALESCE(read_at, now())
              WHERE profile_id = $1 AND id = $2 RETURNING id`,
            [req.userId, id]
          )
        : client.query(
            `UPDATE notifications SET read_at = COALESCE(read_at, now())
              WHERE profile_id = $1 AND read_at IS NULL RETURNING id`,
            [req.userId]
          )
    );
    res.json({ updated: result.rowCount });
  } catch (err) {
    console.error('POST /notifications/read error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /notifications — records a delivery.
 *
 * Called by the app itself for the events it is the one to observe (a card
 * added, a streak reached) as well as by any server-side job. `dedupeKey`
 * makes it idempotent: re-evaluating "SBI Cashback due in 4 days" nightly
 * updates the one row instead of stacking copies, which is the whole reason
 * that unique index exists.
 *
 * The user's notification_preferences are honoured HERE rather than at read
 * time — a muted category should never have been written to the inbox in
 * the first place, and filtering on read would leave rows that silently
 * reappear if the preference is turned back on later.
 */
app.post('/notifications', requireAuth, async (req, res) => {
  const { category, severity, title, body, deepLink, dedupeKey, sendRemote = false } = req.body || {};
  if (!category || !title) {
    return res.status(400).json({ error: 'category and title are required' });
  }
  if (typeof sendRemote !== 'boolean') {
    return res.status(400).json({ error: 'sendRemote must be boolean' });
  }
  // 'streak' and 'card_added' have no preference column — they're in-app
  // consequences of the user's own action, not push-style interruptions.
  const PREFERENCE_COLUMN = {
    location: 'category_location',
    caps: 'category_caps',
    milestones: 'category_milestones',
    fee_waivers: 'category_fee_waivers',
    bills: 'category_bills',
    expiry: 'category_expiry',
    monthly_report: 'category_monthly_report',
    needs_review: 'category_needs_review',
    transactions: 'category_transactions',
    // Two categories, not one: "over budget" is a post-mortem and
    // "running ahead of pace" is still actionable, so someone who wants
    // the early warning shouldn't be forced to take the late one too.
    budget_warning: 'category_budget_warning',
    budget_exceeded: 'category_budget_exceeded',
  };
  try {
    const inserted = await withUserClient(req.userId, async (client) => {
      const column = PREFERENCE_COLUMN[category];
      if (column) {
        const pref = await client.query(
          `SELECT ${column} AS enabled FROM notification_preferences WHERE profile_id = $1`,
          [req.userId]
        );
        // No preferences row yet means the user has never opted out of
        // anything; 0019's own column defaults are the intent, so deliver.
        if (pref.rowCount > 0 && pref.rows[0].enabled === false) return null;
      }
      const result = await client.query(
        `INSERT INTO notifications (profile_id, category, severity, title, body, deep_link, dedupe_key)
         VALUES ($1, $2, COALESCE($3, 'info'), $4, $5, $6, $7)
         ON CONFLICT (profile_id, dedupe_key) WHERE dedupe_key IS NOT NULL
         DO UPDATE SET title = EXCLUDED.title,
                       body = EXCLUDED.body,
                       severity = EXCLUDED.severity,
                       deep_link = EXCLUDED.deep_link,
                       created_at = now(),
                       read_at = NULL
         RETURNING *`,
        [req.userId, category, severity, title, body || null, deepLink || null, dedupeKey || null]
      );
      return result.rows[0];
    });
    // 204 (not an error) when the user has that category muted — the caller
    // asked for a delivery and got a definitive "not delivered, by choice".
    if (!inserted) return res.status(204).end();

    // The inbox is the source of truth and has already committed. Remote FCM
    // delivery is best-effort: a temporary notification-service outage must
    // never turn a successful PandaPay notification into a failed product
    // action or make the app retry and duplicate the inbox row.
    if (sendRemote && notificationService.isConfigured()) {
      notificationService
        .send({
          subscriberId: req.userId,
          title: inserted.title,
          body: inserted.body,
          category: inserted.category,
          severity: inserted.severity,
          deepLink: inserted.deep_link,
          dedupeKey: inserted.dedupe_key,
        })
        .catch((err) => console.error('remote notification delivery failed', err));
    }
    res.status(201).json({ notification: inserted });
  } catch (err) {
    console.error('POST /notifications error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /admin/notifications/broadcast — queues one push announcement for all
 * registered notification-service subscribers. Normal users can only write
 * their own inbox row; only an authenticated PandaPay admin can fan out.
 */
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
    console.error('POST /admin/notifications/broadcast error', err);
    if (err?.code === 'notification_service_auth_failed') {
      return res.status(503).json({
        error: 'notification_service_auth_failed',
        message: 'The notification provider rejected the API key configured on the PandaPay server.',
      });
    }
    return res.status(502).json({ error: 'notification_service_unavailable' });
  }
});

/**
 * GET /home-summary — backs design 01's header strip, which shows three
 * figures side by side: rewards earned this month, rewards earned all time,
 * and a logging streak in days.
 *
 * Only the first of those was derivable client-side (GET /monthly-reports
 * returns the current month and nothing else), so the other two shipped as
 * nothing at all rather than as invented numbers. All three are real
 * aggregates over the same `transactions` rows /monthly-reports already
 * sums — no new tables, no new writes.
 *
 * `streakDays` counts back from the most recent day with at least one
 * active transaction, and is 0 unless that day is today or yesterday: a
 * streak that already lapsed is not a streak. Days are bucketed in the
 * request's IANA timezone (`?tz=`, default Asia/Kolkata) because "did I log
 * something today" is a local-calendar question — bucketing in UTC would
 * break the streak at 05:30 IST every night.
 */
app.get('/home-summary', requireAuth, async (req, res) => {
  const tz = typeof req.query.tz === 'string' && req.query.tz.length > 0 ? req.query.tz : 'Asia/Kolkata';
  const anchor = req.query.anchor ? new Date(req.query.anchor) : new Date();
  if (Number.isNaN(anchor.getTime())) {
    return res.status(400).json({ error: 'anchor is not a valid date' });
  }
  try {
    const summary = await withUserClient(req.userId, async (client) => {
      // Validate the timezone against Postgres' own catalogue before
      // interpolating it — AT TIME ZONE takes a string, and an unknown name
      // raises rather than falling back, which would 500 the whole header.
      const tzOk = await client.query(`SELECT 1 FROM pg_timezone_names WHERE name = $1`, [tz]);
      const zone = tzOk.rowCount > 0 ? tz : 'Asia/Kolkata';

      const totals = await client.query(
        `SELECT
           COALESCE(SUM(GREATEST(COALESCE(expected_value_inr, 0), 0)) FILTER (
             WHERE entry_kind = 'spend' AND amount_inr > 0
           ), 0) AS all_time,
           COALESCE(SUM(GREATEST(COALESCE(expected_value_inr, 0), 0)) FILTER (
             WHERE entry_kind = 'spend'
               AND amount_inr > 0
               AND occurred_at >= date_trunc('month', ($2::timestamptz AT TIME ZONE $3)) AT TIME ZONE $3
           ), 0) AS this_month,
           COUNT(*) FILTER (WHERE entry_kind = 'spend' AND amount_inr > 0) AS txn_count
         FROM transactions
         WHERE profile_id = $1 AND status = 'active'`,
        [req.userId, anchor.toISOString(), zone]
      );

      // Streak: number the run of consecutive local days ending at the most
      // recent logged day, using the classic date-minus-row_number gaps-and-
      // islands trick (every day in one unbroken run shares an anchor date).
      const streak = await client.query(
        `WITH days AS (
           SELECT DISTINCT (occurred_at AT TIME ZONE $2)::date AS d
             FROM transactions
            WHERE profile_id = $1 AND status = 'active' AND entry_kind = 'spend'
         ), islands AS (
           SELECT d, d - (ROW_NUMBER() OVER (ORDER BY d))::int AS anchor FROM days
         ), latest AS (
           SELECT anchor, MAX(d) AS last_day, COUNT(*)::int AS len
             FROM islands GROUP BY anchor ORDER BY last_day DESC LIMIT 1
         )
         SELECT len, last_day FROM latest`,
        [req.userId, zone]
      );

      let streakDays = 0;
      if (streak.rowCount > 0) {
        const today = await client.query(
          `SELECT ($2::timestamptz AT TIME ZONE $1)::date AS today`,
          [zone, anchor.toISOString()]
        );
        const gap = Math.round(
          (today.rows[0].today.getTime() - streak.rows[0].last_day.getTime()) / 86400000
        );
        if (gap <= 1) streakDays = streak.rows[0].len;
      }

      // A short-lived signed activity receipt is minted only after this
      // authenticated member's home summary has been assembled. The client
      // cannot choose its timestamp or activity date; the daily database
      // constraint still permits at most one credited day.
      const access = await client.query(
        'SELECT promotions.get_access_policy() AS policy',
      );
      const campaign = access.rows[0]?.policy?.campaign;

      return {
        rewardsThisMonthInr: Number(totals.rows[0].this_month),
        rewardsAllTimeInr: Number(totals.rows[0].all_time),
        transactionCount: Number(totals.rows[0].txn_count),
        streakDays,
        engagementReceipt: campaign?.version
          ? createEngagementReceipt(
            req.userId,
            campaign.calendarZone || 'Asia/Kolkata',
            config.engagementReceiptSecret,
            Date.now(),
            campaign.receiptLifetimeSeconds || 300,
          )
          : null,
      };
    });
    res.json({ homeSummary: summary });
  } catch (err) {
    console.error('GET /home-summary error', err);
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
    const result = await withUserClient(req.userId, async (client) => {
      const updated = await client.query(
        `UPDATE profiles SET contributions_opt_in = $2 WHERE id = $1 RETURNING contributions_opt_in`,
        [req.userId, optIn]
      );
      if (!optIn) await smsLearning.deleteLearningExamplesForUser(client, req.userId);
      return updated;
    });
    res.json({ profile: result.rows[0] || null });
  } catch (err) {
    console.error('POST /profile/contributions-opt-in error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * Plan Phase 3.2 (migration 0031). Kept in step with `user_consents`'
 * check constraint — the database is the enforcement, this list is the
 * early, friendly rejection.
 *
 * `aggregate_insights` and `partner_sharing` are recordable and revocable
 * here, and deliberately gate nothing yet: no export or partner pipeline
 * reads them, because none may lawfully exist until the Terms and Privacy
 * Policy stop being draft placeholder text and counsel has reviewed what is
 * actually being asked for (plan Phase 3.3). Offering the toggle before the
 * pipeline exists is the right order — collecting consent retroactively for
 * processing that already happened is not a thing.
 */
const CONSENT_PURPOSES = [
  'terms',
  'crowdsource',
  'marketing',
  'aggregate_insights',
  'partner_sharing',
  'sms_shared_learning',
];

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
    const result = await withUserClient(req.userId, async (client) => {
      if (purpose === 'sms_shared_learning') {
        // Match the feedback route's lock so revocation/purge cannot race an
        // in-flight contribution write under the previous grant.
        await client.query(
          'SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))',
          [`sms-shared-learning-consent:${req.userId}`],
        );
      }
      const inserted = await client.query(
        `INSERT INTO user_consents (profile_id, purpose, policy_version, granted, source_screen)
         VALUES ($1, $2, $3, $4, $5)
         RETURNING purpose, granted, granted_at, policy_version, source_screen`,
        [req.userId, purpose, policyVersion, granted, sourceScreen || null]
      );
      if (purpose === 'sms_shared_learning' && !granted) {
        await smsLearning.deleteLearningExamplesForUser(client, req.userId);
        await client.query(
          'DELETE FROM public.sms_ai_learning_proposals WHERE profile_id = $1',
          [req.userId],
        );
      }
      return inserted;
    });
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
  category_transactions: true,
  // Both default ON: unlike location and the monthly report (opt-in by
  // design), a budget is something the user explicitly set up, and having
  // set one then not hearing about it would be the surprising outcome.
  category_budget_warning: true,
  category_budget_exceeded: true,
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
 * GET /user-settings — plan Phase 1.1. The account-level preference blob a
 * newly-signed-in device pulls so it doesn't re-run onboarding and reset
 * every display preference the user already chose (migration 0028).
 *
 * Returns `{}` rather than 404 for a user who has never written any: "no
 * preferences stored" and "all preferences at their defaults" are the same
 * state, and making the client branch on 404 to reach that conclusion would
 * be a distinction without a difference.
 */
app.get('/user-settings', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query('SELECT settings, revision, updated_at FROM user_settings WHERE profile_id = $1', [
        req.userId,
      ])
    );
    const row = result.rows[0];
    res.json({
      settings: row ? row.settings : {},
      revision: row ? Number(row.revision) : 0,
      updatedAt: row ? row.updated_at : null,
    });
  } catch (err) {
    console.error('GET /user-settings error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * PUT /user-settings — merges the posted keys into the stored blob.
 *
 * A per-key MERGE (`settings || excluded.settings`), not a whole-blob
 * replace, and that choice is load-bearing rather than incidental. With
 * replace semantics, a phone that changed only the theme would post its own
 * full view of the blob and silently revert a text-scale change a tablet made
 * thirty seconds earlier — the exact silent-clobber class of bug
 * 0005_sync.sql's header warns about. Merging means each device only ever
 * overwrites the keys it actually touched, so the operation is commutative
 * and two devices editing different preferences both win.
 *
 * `null` for a key is a real value here, not an absence: it deletes the key
 * (jsonb `-`), which is how a client resets a preference to "never set" as
 * opposed to a stored default.
 *
 * Deliberately no schema validation of the keys. The server never reads them
 * (see 0028's table comment) — validating a namespace it doesn't interpret
 * would just mean a backend deploy every time the app adds a toggle. Size is
 * bounded instead, which is the property that actually protects the server.
 */
const USER_SETTINGS_MAX_BYTES = 16 * 1024;

app.put('/user-settings', requireAuth, async (req, res) => {
  const patch = req.body && req.body.settings;
  if (patch === null || typeof patch !== 'object' || Array.isArray(patch)) {
    return res.status(400).json({ error: 'settings must be a JSON object' });
  }
  if (Buffer.byteLength(JSON.stringify(patch), 'utf8') > USER_SETTINGS_MAX_BYTES) {
    return res.status(413).json({ error: 'settings payload too large' });
  }

  // Split the patch: real values are merged in, explicit nulls are removed.
  const nullKeys = Object.keys(patch).filter((k) => patch[k] === null);
  const setEntries = Object.fromEntries(Object.entries(patch).filter(([, v]) => v !== null));

  try {
    const result = await withUserClient(req.userId, async (client) => {
      const upserted = await client.query(
        `INSERT INTO user_settings (profile_id, settings)
              VALUES ($1, $2::jsonb)
         ON CONFLICT (profile_id) DO UPDATE
                SET settings   = user_settings.settings || excluded.settings,
                    revision   = user_settings.revision + 1,
                    updated_at = now()
          RETURNING settings, revision, updated_at`,
        [req.userId, JSON.stringify(setEntries)]
      );
      if (nullKeys.length === 0) return upserted.rows[0];

      const pruned = await client.query(
        `UPDATE user_settings
            SET settings   = settings - $2::text[],
                revision   = revision + 1,
                updated_at = now()
          WHERE profile_id = $1
      RETURNING settings, revision, updated_at`,
        [req.userId, nullKeys]
      );
      return pruned.rows[0];
    });

    res.json({
      settings: result.settings,
      revision: Number(result.revision),
      updatedAt: result.updated_at,
    });
  } catch (err) {
    console.error('PUT /user-settings error', err);
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
app.post('/support-tickets', optionalAuth, async (req, res) => {
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
        [req.userId || null, kind, message.trim(), diagnostics ? JSON.stringify(diagnostics) : null, appVersion || null]
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

/**
 * GET /admin/support-tickets — Admin queue for user feedback & support tickets.
 */
app.get('/admin/support-tickets', requireAdmin, async (req, res) => {
  const { state, kind } = req.query || {};
  try {
    const result = await withUserClient(req.userId, (client) => {
      const conditions = [];
      const params = [];
      if (state && ['pending', 'resolved', 'dismissed'].includes(state)) {
        params.push(state);
        conditions.push(`st.state = ${params.length}`);
      }
      if (kind && SUPPORT_TICKET_KINDS.includes(kind)) {
        params.push(kind);
        conditions.push(`st.kind = ${params.length}`);
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
    console.error('GET /admin/support-tickets error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /admin/support-tickets/:id/resolve — Mark a support ticket resolved with an optional operator response.
 */
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
    console.error('POST /admin/support-tickets/:id/resolve error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /admin/support-tickets/:id/dismiss — Dismiss a support ticket without publishing a change.
 */
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
    console.error('POST /admin/support-tickets/:id/dismiss error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

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
/**
 * ============================================================================
 * AD-3 Scraper source registry + AD-4 change-detection/diff-review
 * ============================================================================
 * Both were previously read-only-at-the-schema-level: `sources` existed
 * (0008_admin_console.sql, with its own `enabled_requires_tos_review` CHECK
 * constraint) and scrape_runs/page_snapshots/extraction_proposals were
 * written by scraper/pandapay_scraper's Python jobs and consumed
 * indirectly via GET /admin/alerts/:id's evidence+proposals join — but
 * there was no console-side screen to manage a source's ToS-review/
 * enabled flags, add a new candidate source, browse recent scrape runs,
 * or look at a page's raw snapshot history outside the context of an
 * already-created alert. These routes back that missing surface.
 */

/** GET /admin/sources — AD-3.1 source registry list. */
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
    console.error('GET /admin/sources error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /admin/sources — register a new candidate source. Always created
 * with tos_reviewed=false/is_enabled=false regardless of what's posted —
 * the DB CHECK constraint would reject is_enabled=true with
 * tos_reviewed=false anyway, but this route doesn't even give a caller
 * the chance to try; ToS review is a deliberate separate step (PATCH
 * below), same posture as scraper/CANDIDATE_SOURCES.md's existing 12
 * research-only rows.
 */
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
    console.error('POST /admin/sources error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * PATCH /admin/sources/:id — AD-3.2 the ToS-review + enable/disable
 * typed writer. tosReviewed/tosNote/isEnabled/crawlFrequencyDays are the
 * only writable fields — never base_url/kind/name here (those would
 * change what's actually being scraped, a "new source" action, not an
 * "update review status" one). The DB's own CHECK constraint
 * (enabled_requires_tos_review) is the actual last line of defense if
 * this validation is ever bypassed; this 400 is just a friendlier error
 * than a raw constraint-violation from Postgres.
 */
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
    console.error('PATCH /admin/sources/:id error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/** GET /admin/scrape-runs — AD-4.1 recent run history across every source. */
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
    console.error('GET /admin/scrape-runs error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /admin/source-pages/:id/snapshots — AD-4.2's side-by-side diff view
 * backend: the last 5 snapshots for one page, newest first, each with its
 * full extracted_text so the console can render old-vs-new side by side.
 * Not a computed line-diff (no diff library added for a console-only
 * read path) — the operator's own eyes do the comparison, same trust
 * model as reading the "evidence excerpt" everywhere else in this admin
 * flow (verbatim source text, never a summarized/interpreted version).
 */
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
    console.error('GET /admin/source-pages/:id/snapshots error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/** GET /admin/sources/:id/pages — the pages under one source, for picking which page's snapshot history to view. */
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
    console.error('GET /admin/sources/:id/pages error', err);
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
    console.error('GET /admin/data-quality-dashboard error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * AD-9 Anonymization Audit Automation.
 *
 * `pandapay.run_anonymization_audit()` (12 checks — six over the crowdsourced
 * merchant surface, six over SMS shared learning since
 * 20261028100000_sms_learning_anonymization_audit.sql) already existed in
 * db/supabase/migrations/0010_functions_and_views.sql — not
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
 * Task F-0's original scope decision (superseded for F3, still true for
 * F5/F7): every F-screen needs new routes, but F5 (a real bidirectional
 * sync engine) and F7 (a background IMAP poller) each need a job
 * runner/queue this single Express file can't host on its own. F3's
 * receiver (POST /inbound-emails/webhook, below) has since been built —
 * a plain webhook endpoint is exactly the kind of thing this file CAN
 * host, unlike a scheduled poller or a stateful sync engine. Still
 * explicitly NOT built:
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
 * The receiver that actually delivers mail to this address now exists:
 * POST /inbound-emails/webhook below writes to `inbound_emails` and
 * updates this row's `first_email_at`/`email_count` for real. What's
 * still outside this repo's scope is the DNS + provider-dashboard wiring
 * (SendGrid/Mailgun inbound parse, or a Cloudflare Email Worker) that
 * routes mail sent to `<local_part>@in.pandapay.app` to that webhook —
 * real infra setup for a given deployment, not something an Express route
 * can do for itself. Until that's configured in a given environment,
 * `first_email_at`/`email_count` stay at their defaults, which is still
 * an honestly-reported "waiting" status, not a fake one.
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
 * POST /inbound-emails/webhook — the real inbound-email receiver the
 * schema (0006_ingest.sql) and POST /forwarding-addresses' doc-comment
 * both flagged as missing. This is the HTTP-facing side of that pipeline:
 * point any provider's inbound-parse webhook (SendGrid Inbound Parse,
 * Mailgun Routes, Postmark Inbound) or a Cloudflare Email Worker that
 * forwards a parsed message as JSON at this URL, and it will actually
 * populate `inbound_emails` and `forwarding_addresses.email_count` for
 * real, closing the loop F3's UI has been honestly reporting as "waiting
 * forever" until now. The DNS/MX + provider-dashboard wiring to route
 * mail sent to *.in.pandapay.app here is real infrastructure setup
 * outside this repo — same class of action as the Play Store listing or
 * scraper legal review, not something an Express route can do for itself.
 *
 * No user/admin JWT exists on this path — the caller is a trusted mail
 * provider, not a person with an account. Auth is a shared secret
 * (INBOUND_EMAIL_WEBHOOK_SECRET) checked via the x-webhook-secret header,
 * constant-time compared. Anyone without the secret gets a flat 401
 * with no information about whether any given address exists.
 *
 * Expects a normalized payload: { to, from, subject, text }. Adapting a
 * specific provider's native payload shape (SendGrid's multipart form,
 * Mailgun's different field names, a Worker's raw MIME) to this shape is
 * a thin mapping step at the provider/Worker config level, deliberately
 * not coupled into this route.
 */
app.post('/inbound-emails/webhook', async (req, res) => {
  const configuredSecret = config.inboundEmailWebhookSecret;
  if (!configuredSecret) {
    console.error('POST /inbound-emails/webhook: INBOUND_EMAIL_WEBHOOK_SECRET is not set');
    return res.status(500).json({ error: 'internal_error' });
  }
  const providedSecret = req.get('x-webhook-secret') || '';
  const secretsMatch =
    providedSecret.length === configuredSecret.length &&
    crypto.timingSafeEqual(Buffer.from(providedSecret), Buffer.from(configuredSecret));
  if (!secretsMatch) {
    return res.status(401).json({ error: 'unauthorized' });
  }

  const { to, from, subject, text, messageId } = req.body || {};
  const localPart = extractLocalPart(to);
  if (!localPart) {
    return res.status(400).json({ error: 'to header did not contain a parseable address' });
  }
  const body = typeof text === 'string' ? text : '';

  try {
    const patternsResult = await pool.query(
      `SELECT id, issuer_id, sender_pattern, regex, field_map, version
         FROM parser_patterns WHERE channel = 'email' AND is_active = true ORDER BY version DESC`
    );
    const parsed = parseSmsAgainstPatterns(patternsResult.rows, { sender: from, body });
    const isKnownBankSender = patternsResult.rows.some((p) => senderMatches(p.sender_pattern, from));
    const policyKeywordHit = scanPolicyKeywords(`${subject || ''}\n${body}`);

    const rpcResult = await pool.query(
      `SELECT * FROM pandapay.ingest_inbound_email($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
      [
        localPart,
        from || null,
        subject || null,
        body || null,
        isKnownBankSender,
        parsed.ok,
        parsed.ok ? parsed.patternId : null,
        policyKeywordHit,
        parsed.ok ? null : redactSmsShape(body),
      ]
    );

    const row = rpcResult.rows[0];
    if (!row || !row.inbound_email_id) {
      // Unknown/inactive local_part — deliberately not distinguishable from
      // "accepted" in the response, so this endpoint never becomes an
      // address-enumeration oracle for an attacker probing local_parts.
      return res.status(202).json({ accepted: true });
    }

    // Turn the parsed mail into an actual transaction.
    const ownUserName = await profileDisplayName(pool, row.user_id);
    // Re-parse with the owner's profile name so self-transfer naming rules
    // see it. The first parse stays intake-only for the RPC signals.
    const classified = parseSmsAgainstPatterns(patternsResult.rows, {
      sender: from,
      body,
      ownUserName,
    });
    //
    // This route used to stop at "stored, parsed_ok = true" and go no
    // further, so a forwarded bank email became a row in `inbound_emails`
    // and nothing else — the user then had to open the app and tap
    // "create transaction" on each one individually. Email was, in effect,
    // a manual import channel dressed as an automatic one.
    //
    // Runs through withUserClient so RLS sees the owning profile: the RPC
    // above is SECURITY DEFINER precisely because this request carries no
    // user JWT, and the profile id it returns is the only thing that makes
    // an owner-scoped write possible here.
    //
    // Failures are swallowed on purpose. The mail is already safely stored
    // and the provider must get its 202 — returning 500 would make a mail
    // provider retry a message we already have, and the in-app
    // "create transaction" path still works as the fallback it always was.
    if (classified.ok) {
      try {
        await withUserClient(row.profile_id, async (client) => {
          const patternRow = patternsResult.rows.find((p) => p.id === classified.patternId);
          const occurred = parseTransactionDate(classified.fields.date) || new Date();
          const imported = await importParsedMessage(client, row.profile_id, {
            parsed: classified,
            patternIssuerId: patternRow ? patternRow.issuer_id : null,
            sender: from,
            rawText: body,
            source: 'email',
            occurred,
            // Same identity a re-forwarded copy of this mail would produce,
            // so a provider retry or a user forwarding twice can't double-count.
            sourceKey: emailSourceKey(row.profile_id, from, subject, body, messageId),
            backfill: false,
            observationMetadata: {
              transport: 'forwarded_email',
              ...(messageId ? {
                providerMessageIdHash: crypto.createHash('sha256').update(messageId).digest('hex'),
              } : {}),
            },
          });
          if ((imported.status === 200 || imported.status === 201) && imported.transaction) {
            await client.query(`UPDATE inbound_emails SET produced_txn_id = $1 WHERE id = $2`, [
              imported.transaction.id,
              row.inbound_email_id,
            ]);
            await client.query(`UPDATE transactions SET raw_source_ref = $1 WHERE id = $2`, [
              row.inbound_email_id,
              imported.transaction.id,
            ]);
          }
        });
      } catch (err) {
        console.error('POST /inbound-emails/webhook: auto-create transaction failed', err);
      }
    }

    res.status(202).json({ accepted: true, parsed: classified.ok });
  } catch (err) {
    console.error('POST /inbound-emails/webhook error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * GET /forwarding-addresses/verification — smsextractionimple.md Task F-8's
 * named blocker.
 *
 * Gmail will not start forwarding to a new address until you prove you own
 * it: it mails a confirmation code there and waits for you to enter it back
 * in Gmail's settings. That mail lands in `inbound_emails` like anything
 * else — and then sits there, because no route ever surfaced it. The result
 * was that a Gmail user (i.e. most users) could not finish setup at all,
 * with nothing on screen explaining why.
 *
 * Outlook and Yahoo send a click-through confirmation LINK rather than a
 * code, so this returns the link too when it finds one.
 *
 * Only mail from the providers' own confirmation senders is considered.
 * That matters: without the sender gate this would happily read a code out
 * of anything anyone sent to the address, which turns a setup helper into a
 * way to get arbitrary attacker-chosen text rendered in the user's app.
 */
const FORWARDING_CONFIRMATION_SENDERS = [
  { provider: 'gmail', pattern: /forwarding-noreply@google\.com/i },
  { provider: 'outlook', pattern: /(microsoft|outlook|live)\.com$/i },
  { provider: 'yahoo', pattern: /yahoo(-inc)?\.com$/i },
];

app.get('/forwarding-addresses/verification', requireAuth, async (req, res) => {
  try {
    const payload = await withUserClient(req.userId, async (client) => {
      const recent = await client.query(
        `SELECT id, sender, subject, body_text, received_at
           FROM inbound_emails
          WHERE profile_id = $1 AND received_at > now() - interval '7 days'
          ORDER BY received_at DESC
          LIMIT 50`,
        [req.userId]
      );

      for (const row of recent.rows) {
        const match = FORWARDING_CONFIRMATION_SENDERS.find((s) => s.pattern.test(row.sender || ''));
        if (!match) continue;

        const haystack = `${row.subject || ''}\n${row.body_text || ''}`;
        // Gmail's code is a 9-digit number. Bounded by \b on both sides so
        // a longer reference number isn't truncated into a false "code".
        const code = (haystack.match(/\b(\d{9})\b/) || [])[1] || null;
        const link = (haystack.match(/https:\/\/\S*(?:confirm|verify)\S*/i) || [])[0] || null;
        if (!code && !link) continue;

        return {
          verification: {
            provider: match.provider,
            code,
            link,
            receivedAt: row.received_at,
          },
        };
      }

      return { verification: null };
    });
    res.json(payload);
  } catch (err) {
    console.error('GET /forwarding-addresses/verification error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/** GET /inbound-emails/me — F3's "recent emails" list; never returns body_text (raw content stays server-side). */
app.get('/inbound-emails/me', requireAuth, async (req, res) => {
  try {
    const result = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT id, sender, subject, received_at, is_known_bank_sender, parsed_ok, produced_txn_id
           FROM inbound_emails WHERE profile_id = $1 ORDER BY received_at DESC LIMIT 50`,
        [req.userId]
      )
    );
    res.json({ inboundEmails: result.rows });
  } catch (err) {
    console.error('GET /inbound-emails/me error', err);
    res.status(500).json({ error: 'internal_error' });
  }
});

/**
 * POST /inbound-emails/:id/create-transaction — closes the loop for an
 * email that parsed successfully: re-runs the same channel='email' match
 * against the stored body (rather than trusting a client-supplied amount,
 * same non-fabrication stance as /transactions/from-sms) and, given a
 * caller-supplied userCardId (this route doesn't guess which of the
 * user's cards an email belongs to, same contract as every other
 * transaction-creation route), inserts the transaction and links it back
 * via raw_source_ref / produced_txn_id.
 */
app.post('/inbound-emails/:id/create-transaction', requireAuth, async (req, res) => {
  const { userCardId, categoryId, rail } = req.body || {};
  if (userCardId !== undefined && userCardId !== null && typeof userCardId !== 'string') {
    return res.status(400).json({ error: 'userCardId must be a string when given' });
  }
  try {
    const result = await withUserClient(req.userId, async (client) => {
      const emailRow = await client.query(
        `SELECT id, sender, subject, body_text, produced_txn_id, parsed_ok, received_at
           FROM inbound_emails WHERE id = $1 AND profile_id = $2`,
        [req.params.id, req.userId]
      );
      const email = emailRow.rows[0];
      if (!email) return { status: 404, error: 'not_found' };
      if (email.produced_txn_id) return { status: 409, error: 'already_converted_to_a_transaction' };

      const patterns = await client.query(
        `SELECT id, issuer_id, sender_pattern, regex, field_map
           FROM parser_patterns WHERE channel = 'email' AND is_active = true ORDER BY version DESC`
      );
      const parsed = parseSmsAgainstPatterns(patterns.rows, {
  sender: email.sender,
  body: email.body_text || '',
  ownUserName: await profileDisplayName(client, req.userId),
});
      if (!parsed.ok) {
        return { status: 422, error: 'could_not_parse_this_email', reason: parsed.reason };
      }

      // The transaction's own date, then the mail's arrival time, and only
      // then now(). This route used to pass a bare `new Date()` — the
      // moment the user happened to tap "create transaction", which could
      // be days after the purchase. That filed spend in the wrong week and,
      // worse, moved it outside the ±1-day window cross-channel duplicate
      // detection uses, so the matching bank SMS was never recognised as
      // the same swipe and the transaction got counted twice.
      const patternRow = patterns.rows.find((p) => p.id === parsed.patternId);
      const occurred = parseTransactionDate(parsed.fields.date) || email.received_at || new Date();

      const inserted = await importParsedMessage(client, req.userId, {
        parsed,
        patternIssuerId: patternRow ? patternRow.issuer_id : null,
        sender: email.sender,
        rawText: email.body_text || '',
        source: 'email',
        occurred,
        sourceKey: emailSourceKey(req.userId, email.sender, email.subject, email.body_text || '', null),
        explicitUserCardId: userCardId,
        explicitCategoryId: categoryId || null,
        rail,
        observationMetadata: { transport: 'stored_forwarded_email' },
      });
      if (inserted.needsReview) {
        return { status: 200, ...inserted };
      }
      if (inserted.status !== 200 && inserted.status !== 201) return inserted;

      await client.query(
        `UPDATE inbound_emails SET produced_txn_id = $1 WHERE id = $2`,
        [inserted.transaction.id, email.id]
      );
      await client.query(`UPDATE transactions SET raw_source_ref = $1 WHERE id = $2`, [email.id, inserted.transaction.id]);

      return { ...inserted, status: inserted.status };
    });
    if (result.status !== 200 && result.status !== 201) {
      return res.status(result.status).json({ error: result.error, reason: result.reason });
    }
    res.status(result.status).json(result);
  } catch (err) {
    console.error('POST /inbound-emails/:id/create-transaction error', err);
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
app.post('/statement-imports', requireAuth, createStatementImportHandler({
  withUserClient, importResolvers, clientMutationSourceKey, insertTransactionAndUpdateState,
}));

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
 * POST /backup-runs — F5's manual "Back up now".
 *
 * This used to insert a row claiming `status: 'success'` while performing no
 * backup at all, with a location string that admitted it was a stub. The row
 * was indistinguishable from a real one to anything reading the table, which
 * made `backup_runs` actively worse than an empty table: it was a clean
 * history of successes that would have held right up until someone needed a
 * restore.
 *
 * Real backups now exist as `db/scripts/backup.sh` (pg_dump, verified with
 * `pg_restore --list`, honestly recorded, pruned only after a verified
 * success) and `db/scripts/restore_drill.sh`. Those run on a schedule as ops
 * infrastructure — which is the right place for them, and genuinely not
 * something an Express route can be.
 *
 * So this route no longer pretends to trigger one. It reports the real state
 * of the backup system to the user, and 409s the manual trigger rather than
 * fabricating a success. "We can't do that from here, and here's when it last
 * actually happened" is honest and useful; a green tick that means nothing is
 * neither.
 */
app.post('/backup-runs', requireAuth, async (req, res) => {
  try {
    const latest = await withUserClient(req.userId, (client) =>
      client.query(
        `SELECT status, ran_at, size_bytes FROM backup_runs
          WHERE status = 'success' ORDER BY ran_at DESC LIMIT 1`
      )
    );
    res.status(409).json({
      error: 'manual_backup_not_supported',
      message:
        'Backups run automatically on a schedule and cannot be triggered from the app.',
      lastSuccessfulBackup: latest.rows[0] || null,
    });
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
          `SELECT t.id,
                  COALESCE(NULLIF(uc.nickname, ''), cp.name, t.instrument::text) ||
                    CASE WHEN uc.last4 IS NOT NULL THEN ' •••• ' || uc.last4 ELSE '' END AS source_account,
                  t.user_card_id, t.amount_inr, t.occurred_at, t.merchant_name,
                  t.category_id, t.user_category_id,
                  COALESCE(parent_sc.name, parent_uc.name, sc.name, ucat.name) AS category_name,
                  CASE WHEN ucat.parent_category_id IS NOT NULL OR ucat.parent_user_category_id IS NOT NULL THEN ucat.name END AS subcategory_name,
                  t.entry_kind, t.instrument, t.rail, t.source, t.expected_value_inr, t.note, t.status
             FROM transactions t
             LEFT JOIN user_cards uc ON uc.id = t.user_card_id AND uc.profile_id = t.profile_id
             LEFT JOIN card_products cp ON cp.id = uc.card_product_id
             LEFT JOIN spend_categories sc ON sc.id = t.category_id
             LEFT JOIN user_categories ucat ON ucat.id = t.user_category_id AND ucat.profile_id = t.profile_id
             LEFT JOIN spend_categories parent_sc ON parent_sc.id = ucat.parent_category_id
             LEFT JOIN user_categories parent_uc ON parent_uc.id = ucat.parent_user_category_id AND parent_uc.profile_id = t.profile_id
            WHERE t.profile_id = $1
            ORDER BY t.occurred_at DESC`,
          [req.userId]
        );
        out.transactions = await transactionTags.attachTags(client, req.userId, txns.rows);
        out.tags = (await client.query('SELECT id,name,color,archived_at,updated_at FROM transaction_tags WHERE profile_id=$1', [req.userId])).rows;
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
  const encryptionKey = config.imapEncryptionKey;
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
 * POST /imap-connections/:id/test — a real IMAP handshake (see
 * ./imap_test.js). Decrypts the stored app password server-side via
 * pgp_sym_decrypt, opens a TLS socket to imap_host:imap_port, and attempts
 * a LOGIN. The decrypted password lives only in this request's memory —
 * never logged, never echoed back to the client, and the query that
 * decrypts it is scoped to this user's own row (RLS + explicit
 * profile_id match). On success marks `verified_at`; on failure leaves it
 * untouched and returns the (non-sensitive) reason string from the IMAP
 * server or socket layer.
 *
 * Falls back to a format-only check when IMAP_ENCRYPTION_KEY isn't set,
 * so local/dev environments without the key configured don't hard-fail —
 * but production must have it set for this to mean anything.
 */
app.post('/imap-connections/:id/test', requireAuth, async (req, res) => {
  try {
    const encryptionKey = config.imapEncryptionKey;
    const result = await withUserClient(req.userId, async (client) => {
      const existing = await client.query(
        encryptionKey
          ? `SELECT id, email, imap_host, imap_port, pgp_sym_decrypt(app_password_encrypted, $3) AS app_password
               FROM imap_connections WHERE id = $1 AND profile_id = $2`
          : `SELECT id, email, imap_host, imap_port FROM imap_connections WHERE id = $1 AND profile_id = $2`,
        encryptionKey ? [req.params.id, req.userId, encryptionKey] : [req.params.id, req.userId]
      );
      const conn = existing.rows[0];
      if (!conn) return null;

      const hostLooksValid = /^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/.test(conn.imap_host);
      const portLooksValid = Number.isInteger(conn.imap_port) && conn.imap_port > 0 && conn.imap_port < 65536;
      const emailLooksValid = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(conn.email);
      const formatOk = hostLooksValid && portLooksValid && emailLooksValid;

      const safeConn = { id: conn.id, email: conn.email, imap_host: conn.imap_host, imap_port: conn.imap_port };

      if (!formatOk) {
        return { ok: false, connection: safeConn, reason: 'One or more fields look malformed.' };
      }
      if (!encryptionKey || !conn.app_password) {
        return { ok: false, connection: safeConn, reason: 'IMAP_ENCRYPTION_KEY not configured on this server — cannot decrypt the stored password to test it.' };
      }

      const loginResult = await testImapLogin({
        host: conn.imap_host,
        port: conn.imap_port,
        email: conn.email,
        password: conn.app_password,
      });

      if (!loginResult.ok) {
        return { ok: false, connection: safeConn, reason: loginResult.reason };
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

const PORT = config.port;
// Terminal error handler — must be registered after every route, or
// Express never reaches it. Catches anything the per-route try/catch
// blocks miss, including a rejected async handler under Express 5.
app.use(errorHandler);

const server = app.listen(PORT, () => console.log(`pandapay-api running at http://localhost:${PORT}`));

// The background IMAP poller (F7). Off unless IMAP_POLL_INTERVAL_MINUTES is
// set, so a development or test process never opens TLS connections to real
// mailboxes. See src/imap_poller.js for why it runs in-process rather than
// as a pg_cron job (pg_cron runs SQL and cannot open a socket) or a separate
// worker (new infrastructure to deploy, monitor and secure for one job), and
// how the advisory lock keeps exactly one instance polling when scaled out.
//
// Everything downstream of "a (sender, body) pair arrived" is the same
// importParsedMessage path SMS and forwarded email already take, so an IMAP
// discovery gets identical card resolution, categorisation, deduplication
// and reward treatment — there is no second implementation to keep in sync.
const stopImapPoller = startImapPoller(
  {
    pool,
    withUserClient,
    encryptionKey: config.imapEncryptionKey,
    parseSmsAgainstPatterns,
    importParsedMessage,
    importSourceKey,
    emailSourceKey,
    parseTransactionDate,
    fetchMessages: fetchRecentMessages,
  },
  { intervalMinutes: Number(process.env.IMAP_POLL_INTERVAL_MINUTES) || 0 }
);

let shuttingDown = false;
async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`pandapay-api shutting down (${signal})`);
  stopImapPoller();

  const forceExit = setTimeout(() => process.exit(1), 10000);
  forceExit.unref();
  try {
    await new Promise((resolve, reject) => {
      server.close((err) => (err ? reject(err) : resolve()));
    });
    await pool.end();
    clearTimeout(forceExit);
    process.exit(0);
  } catch (err) {
    console.error('pandapay-api graceful shutdown failed', err.message);
    process.exit(1);
  }
}

process.once('SIGTERM', () => shutdown('SIGTERM'));
process.once('SIGINT', () => shutdown('SIGINT'));
