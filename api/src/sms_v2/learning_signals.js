'use strict';

// POST /sms/v2/learning-signals: anonymised shop signals from opted-in phones
// (learning-loop A5). Same order of checks as the layout route: contract, each
// item, intake switch, attestation, rate limit, then the database function that
// re-checks consent (the v3 opt-in), the daily cap and the key filters.
const { validateRequest } = require('./contracts');
const { SPEND_CATEGORIES } = require('../sms_facts');
const { intakeOpen } = require('./settings');

const KEY = /^[A-Z][A-Z0-9 &'.-]{1,59}$/;
const NAME = /^[A-Z][A-Z &'.-]{1,39}$/;
const denied = (value) => value === false || value?.ok === false;

// The code for an item that must not be stored, or null.
function signalError(item) {
  if (!KEY.test(item.merchantKey) || /\d{4,}/.test(item.merchantKey)) return 'signal_merchant_key_invalid';
  if (item.kind === 'category_choice' && !SPEND_CATEGORIES.includes(item.value)) return 'signal_category_invalid';
  if (item.kind === 'merchant_name' && (!NAME.test(item.value) || item.value === item.merchantKey)) return 'signal_name_invalid';
  if (item.kind === 'uncategorised' && item.value !== '') return 'signal_value_invalid';
  return null;
}

function createSignalStore({ withUserClient }) {
  return {
    submit(profileId, items, eligible) {
      return withUserClient(profileId, async (client) => {
        const result = await client.query('SELECT pandapay.sms_v2_submit_signals($1::jsonb,$2) AS n', [JSON.stringify(items), eligible === true]);
        return result.rows[0].n;
      });
    },
  };
}

function createSignalsHandler({ store, security }) {
  return async (req, res) => {
    const check = validateRequest('learning_signals', req.body);
    if (!check.ok) return res.status(400).json({ error: check.errors[0].code });
    for (const item of req.body.items) {
      const error = signalError(item);
      if (error) return res.status(400).json({ error });
    }
    try {
      if (!(await intakeOpen(security, req))) {
        res.set('Retry-After', '3600');
        return res.status(503).json({ error: 'learning_paused' });
      }
      if (denied(await security.verifyAttestation(req))) return res.status(403).json({ error: 'attestation_required' });
      if (denied(await security.checkRate(req, 'learning-signals', req.body.items.length))) {
        return res.status(429).json({ error: 'rate_limited' });
      }
      const accepted = await store.submit(req.userId, req.body.items, req.smsV2Security?.sharedLearningEligible === true);
      return res.status(202).json({ accepted });
    } catch (error) {
      if (error.code === '42501') return res.status(403).json({ error: 'sms_shared_learning_consent_required' });
      if (error.code === 'P0050') {
        res.set('Retry-After', '86400');
        return res.status(429).json({ error: 'signal_daily_cap' });
      }
      if (error.code === '22023' || error.code === '23514') return res.status(400).json({ error: 'signal_invalid' });
      console.error('sms_v2 learning signals unavailable', error.code || error.name);
      return res.status(503).json({ error: 'signals_unavailable' });
    }
  };
}

function registerLearningSignals(app, { requireSmsV2, requireMember, withUserClient, hooks }) {
  app.post('/sms/v2/learning-signals', requireSmsV2, requireMember,
    createSignalsHandler({ store: createSignalStore({ withUserClient }), security: hooks.security }));
}

module.exports = { signalError, createSignalStore, createSignalsHandler, registerLearningSignals };
