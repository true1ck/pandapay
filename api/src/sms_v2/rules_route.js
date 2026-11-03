'use strict';

// Phone-facing rule routes (WP-09) and the registration entry point for the
// whole rule service.
//
//   registerRules(app, deps)
//     deps.requireSmsV2   404 unless the sms_pipeline_v2_enabled flag is on (WP-08)
//     deps.requireMember  authenticates the caller and sets req.userId (falls back to deps.requireAuth)
//     deps.requireAdmin   existing admin authority check
//     deps.withUserClient RLS session helper from db.js (or deps.store for a custom store)
//     deps.hooks.security optional {verifyAttestation(req), checkEntitlement(req)}; default allow
//     deps.signer         optional; defaults to signerFromEnv() (throws in production without a key)
//   Returns {latestBundleVersion(profileId)} for the WP-08 sync hook.

const zlib = require('node:zlib');
const { signerFromEnv } = require('./signer');
const { cohortFor, bundleForServing } = require('./bundle_builder');
const { createPgStore } = require('./rules_store');
const { createStatsHandler } = require('./rule_stats');
const { registerRulesAdminRoutes } = require('./rules_admin_route');

const denied = (v) => v === false || (v && typeof v === 'object' && v.ok === false);

function createRulesHandler({ store, getSigner, security, now = () => new Date() }) {
  return async function rulesHandler(req, res) {
    const raw = req.query.since;
    const since = raw === undefined || raw === '' ? 0 : Number(raw);
    if (!Number.isInteger(since) || since < 0) return res.status(400).json({ error: 'since_invalid' });
    try {
      if (denied(await security.verifyAttestation(req))) return res.status(403).json({ error: 'attestation_required' });
      if (denied(await security.checkEntitlement(req))) return res.status(403).json({ error: 'entitlement_required' });
    } catch (err) {
      console.error('sms_v2 rules security hook failed', err && err.code);
      return res.status(503).json({ error: 'security_unavailable' });
    }
    const signer = getSigner();
    if (!signer) return res.status(503).json({ error: 'signing_unavailable' });
    let row;
    try {
      row = await store.tx(req.userId, async (s) => {
        const cohort = cohortFor(req.userId, await s.isTester(req.userId));
        return s.phoneBundle(cohort);
      });
    } catch (err) {
      console.error('sms_v2 rules lookup failed', err && err.code);
      return res.status(503).json({ error: 'rules_unavailable' });
    }
    if (!row) return res.status(404).json({ error: 'no_bundle' });
    if (row.bundleVersion <= since) return res.status(304).end();
    const signed = bundleForServing(row, signer, now());
    const etag = `"v${row.bundleVersion}-${signed.expiresAt}"`;
    if (req.headers['if-none-match'] === etag) return res.status(304).end();
    const gz = zlib.gzipSync(Buffer.from(JSON.stringify(signed), 'utf8'));
    res.status(200);
    res.set({ 'Content-Type': 'application/json; charset=utf-8', 'Content-Encoding': 'gzip', ETag: etag, 'Cache-Control': 'private, no-cache', Vary: 'Authorization' });
    return res.end(gz);
  };
}

function registerRules(app, deps) {
  const store = deps.store || createPgStore({ withUserClient: deps.withUserClient });
  const signer = deps.signer !== undefined ? deps.signer : signerFromEnv(); // throws in production without a key
  const getSigner = () => signer;
  const requireMember = deps.requireMember || deps.requireAuth;
  const security = {
    verifyAttestation: async () => true,
    checkEntitlement: async () => true,
    ...((deps.hooks && deps.hooks.security) || {}),
  };
  const now = deps.now || (() => new Date());

  app.get('/sms/v2/rules', deps.requireSmsV2, requireMember, createRulesHandler({ store, getSigner, security, now }));
  app.post('/sms/v2/rule-stats\\:batch', deps.requireSmsV2, requireMember, createStatsHandler({ store }));
  registerRulesAdminRoutes(app, { ...deps, store, getSigner, now });

  return {
    latestBundleVersion: async (profileId) => store.tx(profileId, async (s) => {
      const row = await s.phoneBundle(cohortFor(profileId, await s.isTester(profileId)));
      return row ? row.bundleVersion : 0;
    }),
  };
}

module.exports = { registerRules, createRulesHandler };
