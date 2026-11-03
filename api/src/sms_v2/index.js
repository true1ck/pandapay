'use strict';

// SMS pipeline v2 server entry point (WP-08).
//
//   require('./sms_v2').registerSmsV2(app, deps)
//
// deps (from src/index.js): requireAuth, requireAdmin, withUserClient,
// loadUserCardForState, applyTransactionState, reverseTransactionState.
// Tests may also pass requireSmsV2, requireMember, hooks, signer.
//
// Every route is always registered and answers 404 unless the
// `sms_pipeline_v2_enabled` flag is on. Other work packages plug in through the
// `hooks` object (read at request time, so a later assignment takes effect) and
// by adding one registration line below.

const { createRequireSmsV2, assertContractsPresent } = require('./guard');

function createHooks(overrides = {}) {
  const security = {
    checkRate: async () => true, // WP-13 replaces
    verifyAttestation: async () => true, // WP-13 replaces
    checkEntitlement: async () => true, // WP-13 replaces
    ...(overrides.security || {}),
  };
  return {
    aiResultsSince: async () => [], // WP-10
    correctionStatusSince: async () => [], // WP-12
    afterEventsStored: async () => {}, // WP-06 / WP-12; runs inside the batch transaction
    latestBundleVersion: async () => 0, // set to the WP-09 rule service below
    ...overrides,
    security,
  };
}

function registerSmsV2(app, deps) {
  // The server refuses to start without the contracts every route validates against.
  assertContractsPresent();
  const { jsonBodyParser, jsonBodyErrorHandler } = require('../request_limits');
  const { registerFactsRoute } = require('./facts_route');
  const { registerSyncRoute } = require('./sync_route');
  const { registerRules } = require('./rules_route');
  const { signerFromEnv } = require('./signer');

  const hooks = createHooks(deps.hooks);
  require('./security').installSecurity(hooks, deps);
  const withUserClient = deps.withUserClient;
  const requireSmsV2 = deps.requireSmsV2 || createRequireSmsV2({ withUserClient, readFlag: deps.readFlag, cacheMs: deps.flagCacheMs });
  const requireMember = deps.requireMember || deps.requireAuth;
  const cardState = {
    loadUserCardForState: deps.loadUserCardForState,
    applyTransactionState: deps.applyTransactionState,
    reverseTransactionState: deps.reverseTransactionState,
  };
  const shared = { requireSmsV2, requireMember, withUserClient, hooks };

  // The facts route reads its own (larger) body; everything else under these
  // prefixes uses the standard 100 KiB JSON parser. This registration sits ahead
  // of the global parser in src/index.js, and a flag-off request is turned away
  // before any body is read.
  registerFactsRoute(app, { ...shared, deps: cardState });
  registerSyncRoute(app, shared);
  app.use(['/sms/v2', '/admin/sms/v2'], requireSmsV2, jsonBodyParser, jsonBodyErrorHandler);

  // WP-09 rule service. A missing signing key must not stop the whole API from
  // booting while the flag is off; rule serving then answers 503 signing_unavailable.
  let signer = deps.signer;
  if (signer === undefined) {
    try {
      signer = signerFromEnv();
    } catch (err) {
      console.error('sms_v2 rule signing key unavailable; rule routes will answer 503');
      signer = null;
    }
  }
  // Security hooks are looked up per call, so a later WP-13 replacement reaches the rule routes too.
  const lazySecurity = {
    verifyAttestation: (req) => hooks.security.verifyAttestation(req),
    checkEntitlement: (req) => hooks.security.checkEntitlement(req),
    checkRate: (req, route, units) => hooks.security.checkRate(req, route, units),
  };
  const rules = registerRules(app, { ...deps, ...shared, hooks: { ...hooks, security: lazySecurity }, requireAdmin: deps.requireAdmin, signer });
  hooks.latestBundleVersion = rules.latestBundleVersion;

  // WP-10, WP-12 and WP-13 each add one registration line here.
  return { hooks };
}

module.exports = { registerSmsV2, createHooks };
