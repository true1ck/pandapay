'use strict';

const crypto = require('node:crypto');
const config = require('./config');
const { withUserClient } = require('./db');
const { requireAuth, requireVerifiedSession } = require('./auth');
const { chooseWeightedPrize, formatDateInZone, normalizeInvitationCode } = require('./referral_rules');
const notificationService = require('./notification_service');

const PREVIEW_TTL_MS = 10 * 60 * 1000;

function canonicalizeEmail(value) {
  if (typeof value !== 'string') return null;
  const email = value.trim().toLowerCase();
  if (!email || email.length > 320 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;
  return email;
}

function canonicalizePhone(value) {
  if (typeof value !== 'string') return null;
  let phone = value.trim().replace(/[\s().-]/g, '');
  if (/^\d{10}$/.test(phone)) phone = `+91${phone}`;
  return /^\+[1-9]\d{1,14}$/.test(phone) ? phone : null;
}

function buildEligibilityClaims(verifiedContacts, secret = config.referralIdentityHmacKey,
  keyVersion = config.referralIdentityHmacKeyVersion) {
  if (!secret || Buffer.byteLength(secret) < 32) {
    throw new Error('referral_identity_not_configured');
  }
  const claims = [];
  for (const kind of ['email', 'phone']) {
    const contact = verifiedContacts?.[kind];
    if (contact?.verified !== true || typeof contact.value !== 'string') continue;
    const normalized = kind === 'email'
      ? canonicalizeEmail(contact.value)
      : canonicalizePhone(contact.value);
    if (!normalized) continue;
    const fingerprint = crypto.createHmac('sha256', secret)
      .update(`pandapay-referral-eligibility:${keyVersion}:${kind}:${normalized}`)
      .digest('hex');
    claims.push({ kind, keyVersion, fingerprint });
  }
  return claims;
}

function signPayload(payload, secret, purpose) {
  if (!secret || Buffer.byteLength(secret) < 32) throw new Error(`${purpose}_not_configured`);
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const signature = crypto.createHmac('sha256', secret)
    .update(`${purpose}.v1.${body}`)
    .digest('base64url');
  return `${body}.${signature}`;
}

function verifyPayload(token, secret, purpose, now = Date.now()) {
  if (typeof token !== 'string' || token.length > 4096 || !secret) return null;
  const [body, signature, extra] = token.split('.');
  if (!body || !signature || extra !== undefined) return null;
  const expected = crypto.createHmac('sha256', secret)
    .update(`${purpose}.v1.${body}`)
    .digest();
  let supplied;
  try {
    supplied = Buffer.from(signature, 'base64url');
  } catch (_) {
    return null;
  }
  if (supplied.length !== expected.length || !crypto.timingSafeEqual(supplied, expected)) return null;
  try {
    const payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
    if (!payload || !Number.isSafeInteger(payload.expiresAt) || payload.expiresAt <= now) return null;
    return payload;
  } catch (_) {
    return null;
  }
}

function publicValidationFingerprint(ip, secret = config.referralPreviewSecret) {
  if (!secret || Buffer.byteLength(secret) < 32) return null;
  return crypto.createHmac('sha256', secret)
    .update(`pandapay-invitation-validation-ip:v1:${ip || 'unknown'}`)
    .digest('hex');
}

function databaseError(res, error) {
  const code = typeof error?.message === 'string' && /^[a-z][a-z0-9_]{2,80}$/.test(error.message)
    ? error.message
    : 'internal_error';
  const status = error?.code === 'P0001'
    ? (['membership_required', 'session_invalid', 'account_suspended'].includes(code) ? 403 : 409)
    : 503;
  if (status >= 500) console.error('Referral operation failed', { code: error?.code || null, requestCode: code });
  return res.status(status).json({ error: code });
}

async function jsonRoutine(userId, sql, params = []) {
  return withUserClient(userId, async (client) => {
    const result = await client.query(sql, params);
    return result.rows[0]?.result ?? result.rows[0]?.value ?? null;
  });
}

function registerReferralRoutes(app) {
  app.get('/access-policy', async (_req, res) => {
    try {
      const policy = await jsonRoutine(null, 'SELECT promotions.get_access_policy() AS result');
      res.json({
        ...(policy || { admissionMode: 'unavailable', campaign: null }),
        productTermsVersion: config.productTermsVersion,
      });
    } catch (error) {
      databaseError(res, error);
    }
  });

  // Internal worker delivery is separately authenticated from user sessions.
  // The inbox insert is the durable result; FCM is best effort and can never
  // cause a reward event to be replayed or a credit to be issued twice.
  app.post('/internal/referral-outbox-event', async (req, res) => {
    if (!hasWorkerSecret(req.get('x-reward-worker-secret'), config.rewardWorkerInternalSecret)) {
      return res.status(config.rewardWorkerInternalSecret ? 401 : 503)
        .json({ accepted: false, error: 'worker_auth_unavailable' });
    }
    const event = normalizeWorkerEvent(req.body);
    if (!event) return res.status(400).json({ accepted: false, error: 'invalid_worker_event' });

    try {
      const result = await withUserClient(event.beneficiaryId, async (client) => {
        const member = await client.query(
          'SELECT promotions.current_user_is_member() AS is_member',
        );
        if (member.rows[0]?.is_member !== true) return { status: 'recipient_unavailable' };

        const preference = await client.query(
          'SELECT category_milestones AS enabled FROM notification_preferences WHERE profile_id = $1',
          [event.beneficiaryId],
        );
        if (preference.rowCount > 0 && preference.rows[0].enabled === false) {
          return { status: 'muted' };
        }

        const copy = workerEventCopy(event.eventType);
        const dedupeKey = `referral-outbox:${event.eventKey}`;
        const inserted = await client.query(
          `INSERT INTO notifications
             (profile_id, category, severity, title, body, deep_link, dedupe_key)
           VALUES ($1, 'milestones', $2, $3, $4, '/account', $5)
           ON CONFLICT (profile_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING
           RETURNING id`,
          [event.beneficiaryId, copy.severity, copy.title, copy.body, dedupeKey],
        );
        return { status: inserted.rowCount === 0 ? 'duplicate' : 'created', ...copy, dedupeKey };
      });

      if (result.status === 'recipient_unavailable') {
        return res.status(409).json({ accepted: false, error: 'recipient_unavailable' });
      }
      if (result.status === 'created' && notificationService.isConfigured()) {
        notificationService.send({
          subscriberId: event.beneficiaryId,
          title: result.title,
          body: result.body,
          category: 'milestones',
          severity: result.severity,
          deepLink: '/account',
          dedupeKey: result.dedupeKey,
        }).catch((error) => {
          console.error('referral push delivery failed', { code: error?.code || 'notification_error' });
        });
      }
      return res.json({ accepted: true, inbox: result.status });
    } catch (error) {
      console.error('Referral outbox delivery failed', { code: error?.code || null });
      return res.status(503).json({ accepted: false, error: 'notification_storage_unavailable' });
    }
  });

  app.post('/invitations/validate', async (req, res) => {
    const fingerprint = publicValidationFingerprint(req.ip);
    if (!fingerprint) return res.status(503).json({ valid: false, error: 'invitation_service_unavailable' });
    try {
      const allowed = await jsonRoutine(null,
        'SELECT promotions.consume_invitation_validation($1) AS result', [fingerprint]);
      if (allowed !== true) return res.status(429).json({ valid: false, error: 'rate_limited' });
    } catch (error) {
      return databaseError(res, error);
    }

    const code = normalizeInvitationCode(req.body?.code);
    if (!code) return res.status(200).json({ valid: false, error: 'invitation_unavailable' });

    try {
      const preview = await jsonRoutine(null,
        'SELECT promotions.validate_invitation($1) AS result', [code]);
      if (!preview?.valid) {
        return res.status(200).json({ valid: false, error: 'invitation_unavailable' });
      }
      const now = Date.now();
      const previewToken = signPayload({
        code,
        campaignVersion: preview.campaignVersion || null,
        termsVersion: preview.termsVersion || 'invite-access-v1',
        accessRevision: preview.accessRevision ?? null,
        rewardAvailable: preview.rewardAvailable === true,
        issuedAt: now,
        expiresAt: now + PREVIEW_TTL_MS,
      }, config.referralPreviewSecret, 'pandapay-invitation-preview');
      return res.json({ ...preview, previewToken, previewExpiresAt: new Date(now + PREVIEW_TTL_MS).toISOString() });
    } catch (error) {
      databaseError(res, error);
    }
  });

  app.get('/access', requireVerifiedSession, async (req, res) => {
    try {
      const state = await jsonRoutine(req.userId,
        'SELECT promotions.current_access_state() AS result');
      const actionByState = {
        active: 'continue',
        activation_pending: 'complete_profile',
        requires_invite: 'enter_invitation',
        paused: 'wait_for_access',
        suspended: 'contact_support',
        unauthenticated: 'sign_in',
      };
      res.json({ state, nextAction: actionByState[state] || 'contact_support' });
    } catch (error) {
      databaseError(res, error);
    }
  });

  app.post('/onboarding/complete', requireAuth, async (req, res) => {
    try {
      const completedAt = await withUserClient(req.userId, async (client) => {
        const result = await client.query(
          'SELECT promotions.complete_current_user_onboarding() AS completed_at',
        );
        return result.rows[0]?.completed_at || null;
      });
      return res.json({ completed: true, completedAt });
    } catch (error) {
      return databaseError(res, error);
    }
  });

  app.get('/referrals/v2', requireAuth, async (req, res) => {
    const rawYear = req.query.year;
    const year = rawYear === undefined
      ? Number(formatDateInZone(new Date()).slice(0, 4))
      : Number(rawYear);
    if (!Number.isSafeInteger(year) || year < 2000 || year > 2200) {
      return res.status(400).json({ error: 'invalid_year' });
    }
    try {
      const result = await jsonRoutine(req.userId,
        'SELECT promotions.get_referrals_v2($1) AS result', [year]);
      res.json(result || { year, referrals: [] });
    } catch (error) {
      databaseError(res, error);
    }
  });

  app.get('/referrals/mine', requireAuth, async (req, res) => {
    try {
      const result = await jsonRoutine(req.userId,
        'SELECT promotions.get_my_referral() AS result');
      res.json(result || { referral: null });
    } catch (error) {
      databaseError(res, error);
    }
  });

  app.post('/referrals/code', requireAuth, async (req, res) => {
    try {
      const code = await jsonRoutine(req.userId,
        'SELECT promotions.ensure_current_invitation_code() AS result');
      if (typeof code !== 'string') return res.status(503).json({ error: 'referral_code_unavailable' });
      res.json({ code, shareLink: `https://pandapay.app/i/${encodeURIComponent(code)}` });
    } catch (error) {
      databaseError(res, error);
    }
  });

  app.get('/rewards', requireAuth, async (req, res) => {
    try {
      const result = await jsonRoutine(req.userId,
        'SELECT promotions.get_my_rewards() AS result');
      res.json(result || { rewards: [] });
    } catch (error) {
      databaseError(res, error);
    }
  });

  app.get('/rewards/:entitlementId/spin-config', requireAuth, async (req, res) => {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(req.params.entitlementId)) {
      return res.status(404).json({ error: 'reward_not_found' });
    }
    try {
      const configuration = await jsonRoutine(req.userId,
        'SELECT promotions.get_spin_configuration($1::uuid) AS result',
        [req.params.entitlementId]);
      if (!configuration) return res.status(404).json({ error: 'reward_not_found' });
      if (configuration.state !== 'ready') {
        return res.status(409).json({ error: 'reward_not_ready' });
      }
      return res.json(configuration);
    } catch (error) {
      return databaseError(res, error);
    }
  });

  app.post('/rewards/:entitlementId/spin', requireAuth, async (req, res) => {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(req.params.entitlementId)) {
      return res.status(404).json({ error: 'reward_not_found' });
    }
    try {
      const spin = await withUserClient(req.userId, async (client) => {
        const configuration = await client.query(
          'SELECT promotions.get_spin_configuration($1::uuid) AS config',
          [req.params.entitlementId],
        );
        const value = configuration.rows[0]?.config;
        if (!value) return null;
        const selected = chooseWeightedPrize({ [value.role]: value.distribution }, value.role);
        const result = await client.query(
          'SELECT promotions.commit_reward_spin($1::uuid, $2, $3::bigint) AS result',
          [req.params.entitlementId, selected.id, selected.amountPaise],
        );
        return result.rows[0]?.result || null;
      });
      if (!spin) return res.status(404).json({ error: 'reward_not_found' });
      return res.json({
        ...spin,
        state: spin.amountPaise === '0' ? 'completed' : 'credited',
      });
    } catch (error) {
      return databaseError(res, error);
    }
  });

  app.get('/subscription-credits', requireAuth, async (req, res) => {
    try {
      const snapshot = await jsonRoutine(req.userId,
        'SELECT promotions.get_credit_snapshot() AS result');
      res.json(snapshot || { currency: 'INR', availablePaise: '0', reservedPaise: '0', redemptionAvailable: false });
    } catch (error) {
      databaseError(res, error);
    }
  });

  app.get('/subscription-credits/ledger', requireAuth, async (req, res) => {
    const cursor = parseLedgerCursor(req.query.cursor);
    if (req.query.cursor && !cursor) return res.status(400).json({ error: 'invalid_cursor' });
    try {
      const result = await jsonRoutine(req.userId,
        'SELECT promotions.get_credit_ledger($1::timestamptz, $2::uuid, 50) AS result',
        [cursor?.occurredAt || null, cursor?.id || null]);
      res.json(result || { entries: [] });
    } catch (error) {
      databaseError(res, error);
    }
  });

  app.post('/engagement/check-in', requireAuth, async (req, res) => {
    const receipt = verifyPayload(req.body?.receiptToken, config.engagementReceiptSecret,
      'pandapay-engagement-receipt');
    const now = Date.now();
    if (!receipt || receipt.subject !== req.userId || receipt.action !== 'home_summary'
        || !Number.isSafeInteger(receipt.issuedAt) || receipt.issuedAt > now + 30_000
        || now - receipt.issuedAt > 15 * 60 * 1000
        || typeof receipt.receiptId !== 'string') {
      return res.status(400).json({ error: 'activity_receipt_invalid' });
    }
    try {
      const result = await jsonRoutine(req.userId,
        'SELECT promotions.record_engagement_day($1, $2, $3::timestamptz) AS result',
        [receipt.receiptId, receipt.action, new Date(receipt.issuedAt).toISOString()]);
      res.json(result || { recorded: false, qualified: false });
    } catch (error) {
      databaseError(res, error);
    }
  });
}

function hasWorkerSecret(suppliedValue, expectedValue) {
  if (typeof suppliedValue !== 'string' || typeof expectedValue !== 'string') return false;
  const supplied = Buffer.from(suppliedValue);
  const expected = Buffer.from(expectedValue);
  return supplied.length === expected.length && crypto.timingSafeEqual(supplied, expected);
}

function normalizeWorkerEvent(value) {
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || !['referral.joined', 'referral.qualified', 'reward.awarded', 'reward.spin.completed']
        .includes(value.eventType)
      || typeof value.eventKey !== 'string' || value.eventKey.length > 180
      || !uuid.test(value.beneficiaryId || '')) return null;
  return {
    eventType: value.eventType,
    eventKey: value.eventKey,
    beneficiaryId: value.beneficiaryId,
  };
}

function workerEventCopy(eventType) {
  if (eventType === 'reward.awarded') {
    return {
      title: 'Your referral reward is ready',
      body: 'Your subscription credits have been added. Open PandaPay to see your balance.',
      severity: 'good',
    };
  }
  if (eventType === 'reward.spin.completed') {
    return {
      title: 'Your reward spin is complete',
      body: 'Your result is saved. Open PandaPay to see what you received.',
      severity: 'info',
    };
  }
  if (eventType === 'referral.qualified') {
    return {
      title: 'Your referral reached Bamboo',
      body: 'Their activity milestone is complete. Open PandaPay to see your reward.',
      severity: 'good',
    };
  }
  return {
    title: 'A friend joined PandaPay',
    body: 'Their Bamboo progress has started. We’ll let you know when it qualifies.',
    severity: 'info',
  };
}

function createInvitationPreviewToken(preview, code, secret = config.referralPreviewSecret,
  now = Date.now()) {
  return signPayload({
    code,
    campaignVersion: preview.campaignVersion || null,
    termsVersion: preview.termsVersion || 'invite-access-v1',
    accessRevision: preview.accessRevision ?? null,
    rewardAvailable: preview.rewardAvailable === true,
    issuedAt: now,
    expiresAt: now + PREVIEW_TTL_MS,
  }, secret, 'pandapay-invitation-preview');
}

function verifyInvitationPreviewToken(token, secret = config.referralPreviewSecret, now = Date.now()) {
  const payload = verifyPayload(token, secret, 'pandapay-invitation-preview', now);
  if (!payload || normalizeInvitationCode(payload.code) !== payload.code
      || typeof payload.termsVersion !== 'string'
      || !Number.isSafeInteger(payload.issuedAt)
      || now - payload.issuedAt > PREVIEW_TTL_MS) return null;
  return payload;
}

function createEngagementReceipt(userId, calendarZone = 'Asia/Kolkata',
  secret = config.engagementReceiptSecret, now = Date.now(), ttlSeconds = 300) {
  if (!secret || Buffer.byteLength(secret) < 32) return null;
  const safeTtl = Number.isSafeInteger(ttlSeconds) ? Math.max(30, Math.min(ttlSeconds, 900)) : 300;
  return signPayload({
    subject: userId,
    receiptId: crypto.randomUUID(),
    action: 'home_summary',
    activityDate: formatDateInZone(new Date(now), calendarZone),
    issuedAt: now,
    expiresAt: now + safeTtl * 1000,
  }, secret, 'pandapay-engagement-receipt');
}

function parseLedgerCursor(value) {
  if (typeof value !== 'string' || value.length > 512) return null;
  try {
    const decoded = JSON.parse(Buffer.from(value, 'base64url').toString('utf8'));
    if (typeof decoded?.occurredAt !== 'string'
        || Number.isNaN(Date.parse(decoded.occurredAt))
        || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(decoded.id || '')) {
      return null;
    }
    return { occurredAt: new Date(decoded.occurredAt).toISOString(), id: decoded.id };
  } catch (_) {
    return null;
  }
}

function encodeLedgerCursor(occurredAt, id) {
  return Buffer.from(JSON.stringify({ occurredAt, id })).toString('base64url');
}

module.exports = {
  registerReferralRoutes,
  buildEligibilityClaims,
  canonicalizeEmail,
  canonicalizePhone,
  createInvitationPreviewToken,
  verifyInvitationPreviewToken,
  createEngagementReceipt,
  verifyPayload,
  publicValidationFingerprint,
  parseLedgerCursor,
  encodeLedgerCursor,
  hasWorkerSecret,
  normalizeWorkerEvent,
  workerEventCopy,
};
