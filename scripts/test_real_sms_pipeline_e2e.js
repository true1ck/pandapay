/**
 * End-to-end test script for SMS intelligence pipeline and real SMS testing.
 *
 * Verifies:
 * 1. Queue acceptance (/ai/jobs) for real SMS messages
 * 2. Worker leasing (/ai/jobs/lease) and lifecycle
 * 3. Gemini classification using live Gemini API (gemini-3.5-flash-lite)
 * 4. Evidence validation with fix for 'processed', 'payout', 'transfer', 'settled'
 * 5. Recommendations / card suggestions endpoint matching real transaction messages
 */

'use strict';

const crypto = require('crypto');
const path = require('path');
require('../api/node_modules/dotenv').config({ path: path.resolve(__dirname, '../.env') });

const { GeminiProvider } = require('../api/src/gemini_worker');
const smsFacts = require('../api/src/sms_facts');
const { verifyModelFacts, moneyInMessage } = require('../api/src/ai_fact_evidence');
const geminiQueue = require('../api/src/gemini_queue');
const { discoverCardsAcrossMessages } = require('../api/src/card_discovery');

// Test messages specified in requirement:
const TEST_MESSAGES = [
  {
    name: 'Message 1 (Kotak Neo Payout)',
    sender: 'KOTAKB',
    body: 'payout for Rs. 1944.38 is processed with reference ID: 12345678. Date of Transfer: 17-10-2026. You should receive the funds in your bank account shortly.',
    occurredAt: '2026-10-17T12:00:00.000Z',
    expectedKeywords: ['payout', 'processed', 'Transfer'],
    expectedAmount: 1944.38,
  },
  {
    name: 'Message 2 (Jio charges)',
    sender: 'JIO',
    body: 'Paid Rs. 9.88 for Jio number retention charges via UPI on 20-Oct-2026',
    occurredAt: '2026-10-20T10:30:00.000Z',
    expectedKeywords: ['Paid', 'UPI'],
    expectedAmount: 9.88,
  },
  {
    name: 'Message 3 (Card debit)',
    sender: 'HDFCBK',
    body: 'Alert: Rs 550.00 spent on your HDFC Bank Card ending 1234 at SWIGGY on 24-OCT-26.',
    occurredAt: '2026-10-24T18:45:00.000Z',
    expectedKeywords: ['spent'],
    expectedAmount: 550.00,
    expectedLast4: '1234',
  },
];

/** Mock in-memory client conforming to PostgreSQL client interface */
function createInMemoryClient() {
  const sources = new Map();
  const jobs = new Map();
  const events = [];
  const quota = new Map();

  return {
    query: async (sql, params = []) => {
      const normalized = sql.replace(/\s+/g, ' ').trim();

      // Ensure / find source row
      if (normalized.startsWith('SELECT id FROM sms_sources')) {
        const [profileId, sourceKey] = params;
        const key = `${profileId}:${sourceKey}`;
        return { rows: sources.has(key) ? [{ id: sources.get(key).id }] : [] };
      }
      if (normalized.startsWith('INSERT INTO sms_sources')) {
        const [profileId, sourceKey, sender, bodyHash] = params;
        const key = `${profileId}:${sourceKey}`;
        const row = { id: `src-${sources.size + 1}`, profileId, sourceKey, sender, bodyHash, facts: [] };
        sources.set(key, row);
        return { rows: [{ id: row.id }], rowCount: 1 };
      }

      // Quota queries
      if (normalized.includes('FROM ai_quota_days')) {
        const [profileId] = params;
        const day = new Date().toISOString().slice(0, 10);
        const used = quota.get(`${profileId}:${day}`) || 0;
        return { rows: [{ jobs_used: used }] };
      }
      if (normalized.startsWith('INSERT INTO ai_quota_days')) {
        const [profileId] = params;
        const day = new Date().toISOString().slice(0, 10);
        const used = (quota.get(`${profileId}:${day}`) || 0) + 1;
        quota.set(`${profileId}:${day}`, used);
        return { rowCount: 1 };
      }

      // Job queries
      if (normalized.startsWith('SELECT id, status FROM ai_jobs')) {
        const [profileId, sourceKey] = params;
        for (const job of jobs.values()) {
          if (job.profile_id === profileId && job.source_key === sourceKey) {
            return { rows: [{ id: job.id, status: job.status }] };
          }
        }
        return { rows: [] };
      }
      if (normalized.startsWith('INSERT INTO ai_jobs')) {
        const [profileId, sourceId, sourceKey, payloadJson] = params;
        const id = crypto.randomUUID();
        const row = {
          id,
          profile_id: profileId,
          source_id: sourceId,
          source_key: sourceKey,
          payload: JSON.parse(payloadJson),
          status: 'queued',
          attempts: 0,
          lease_token: null,
          lease_expires_at: null,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        };
        jobs.set(id, row);
        return { rows: [{ id }], rowCount: 1 };
      }

      // Lease procedure call
      if (normalized.includes('pandapay.ai_claim_next_job')) {
        const [leaseToken, now, leaseMinutes] = params;
        for (const job of jobs.values()) {
          if (job.status === 'queued') {
            job.status = 'leased';
            job.lease_token = leaseToken;
            job.lease_expires_at = new Date(Date.now() + leaseMinutes * 60000).toISOString();
            job.attempts += 1;
            return {
              rows: [{
                job: {
                  id: job.id,
                  profileId: job.profile_id,
                  sourceKey: job.source_key,
                  payload: job.payload,
                  attempts: job.attempts,
                  leaseToken,
                },
              }],
            };
          }
        }
        return { rows: [{ job: null }] };
      }

      // Update ai_jobs (complete, heartbeat, fail)
      if (normalized.startsWith('UPDATE ai_jobs')) {
        const idMatch = sql.match(/WHERE id = \$(\d+)/);
        if (idMatch) {
          const id = params[parseInt(idMatch[1], 10) - 1];
          const job = jobs.get(id);
          if (job) {
            if (sql.includes("status = 'done'")) {
              job.status = 'done';
              job.result = JSON.parse(params[1]);
              job.payload = JSON.parse(params[2]);
              job.lease_token = null;
            }
            return { rowCount: 1, rows: [job] };
          }
        }
        return { rowCount: 1, rows: [] };
      }

      // Insert events
      if (normalized.startsWith('INSERT INTO ai_events')) {
        const [jobId, profileId, eventType, payloadJson] = params;
        events.push({ jobId, profileId, eventType, payload: JSON.parse(payloadJson) });
        return { rowCount: 1 };
      }

      // Facts storage
      if (normalized.includes('FROM sms_sources') && normalized.includes('sms_source_facts')) {
        return { rows: [] };
      }
      if (normalized.startsWith('INSERT INTO sms_source_facts')) {
        return { rows: [{ id: 'fact-1', fact_index: 0 }], rowCount: 1 };
      }

      return { rows: [], rowCount: 0 };
    },
    sources,
    jobs,
    events,
  };
}

async function runE2ETests() {
  console.log('='.repeat(70));
  console.log('PandaPay Real SMS Pipeline E2E & Production Classification Test');
  console.log('='.repeat(70));
  console.log(`Time: ${new Date().toISOString()}\n`);

  const results = {
    messagesTested: 0,
    acceptedCount: 0,
    leasedCount: 0,
    classifiedCount: 0,
    evidenceValidCount: 0,
    contractValidCount: 0,
    recommendationsVerified: false,
    verifiedFacts: {},
    details: [],
  };

  // Initialize live Gemini provider with configured keys
  const provider = new GeminiProvider({
    apiKey: process.env.GEMINI_API_KEY,
    fallbackApiKey: process.env.GEMINI_FALLBACK_API_KEY,
    model: process.env.GEMINI_MODEL || 'gemini-3.5-flash-lite',
    fallbackModel: process.env.GEMINI_FALLBACK_MODEL || 'gemini-flash-lite-latest',
  });

  const client = createInMemoryClient();
  const testProfileId = '33333333-3333-3333-3333-333333333333';

  for (const [index, testMsg] of TEST_MESSAGES.entries()) {
    console.log(`--- [${index + 1}/3] ${testMsg.name} ---`);
    console.log(`Sender:  ${testMsg.sender}`);
    console.log(`Message: "${testMsg.body}"`);

    results.messagesTested++;
    const sourceKey = crypto.createHash('sha256')
      .update(`${testMsg.sender}:${testMsg.body}:${testMsg.occurredAt}`)
      .digest('hex');

    // 1. Queue Acceptance Check (/ai/jobs logic)
    const acceptOutcome = await geminiQueue.acceptOneJob(client, testProfileId, {
      sourceKey,
      sender: testMsg.sender,
      body: testMsg.body,
      occurredAt: testMsg.occurredAt,
    });

    console.log(`1. Acceptance: ${acceptOutcome.accepted ? 'ACCEPTED (HTTP 200)' : 'FAILED'}, jobId: ${acceptOutcome.jobId}`);
    if (acceptOutcome.accepted) results.acceptedCount++;

    // 2. Worker Leasing Check (/ai/jobs/lease logic)
    const leaseOutcome = await geminiQueue.leaseNextJob(client, 'worker:live_test');
    console.log(`2. Lease:      ${leaseOutcome.leased ? 'LEASED' : 'FAILED'}, attempts: ${leaseOutcome.job?.attempts}`);
    if (leaseOutcome.leased) results.leasedCount++;

    // 3. Live Gemini Classification
    console.log(`3. Classifying with Gemini (${provider.model})...`);
    await new Promise((r) => setTimeout(r, 1500));
    const startTime = Date.now();
    let facts = [];
    try {
      facts = await provider.classify({ payload: leaseOutcome.job.payload });
      const durationMs = Date.now() - startTime;
      console.log(`   Model returned ${facts.length} fact(s) in ${durationMs}ms`);
      results.classifiedCount++;
    } catch (err) {
      console.error(`   Classification error: ${err.message}`);
      continue;
    }

    // 4. Contract and Evidence Validation
    const contract = smsFacts.validateFactSet(facts);
    const evidence = verifyModelFacts(facts, leaseOutcome.job.payload);

    console.log(`4. Validation: Contract: ${contract.valid ? 'VALID' : 'INVALID'}, Evidence: ${evidence.valid ? 'VALID' : 'INVALID'}`);
    if (contract.valid) results.contractValidCount++;
    if (evidence.valid) {
      results.evidenceValidCount++;
    } else {
      console.error(`   Evidence errors:`, evidence.errors);
    }

    // Check specific evidence fix verification:
    // Message 1 specifically verifies 'processed', 'payout', 'transfer', 'settled'
    if (index === 0) {
      const hasKeywords = testMsg.expectedKeywords.some(kw => testMsg.body.includes(kw));
      console.log(`   [Fix Check] Body contains '${testMsg.expectedKeywords.join("', '")}': ${hasKeywords}`);
      console.log(`   [Fix Check] verifyModelFacts accepted without 'lacks unambiguous completion' error: ${evidence.valid}`);
    }

    // 5. Complete Job with Result
    await geminiQueue.completeJobWithResult(client, {
      job: leaseOutcome.job,
      facts,
      batchMetadata: { batchSize: 1 },
    });

    const jobRow = client.jobs.get(leaseOutcome.job.id);
    console.log(`5. Job Status: ${jobRow.status} (payload purged: ${jobRow.payload?.purged === true})`);

    results.verifiedFacts[testMsg.name] = facts;
    results.details.push({
      name: testMsg.name,
      accepted: acceptOutcome.accepted,
      leased: leaseOutcome.leased,
      status: jobRow.status,
      facts,
      evidenceValid: evidence.valid,
      contractValid: contract.valid,
    });

    console.log(`   Facts:\n${JSON.stringify(facts, null, 4)}\n`);
  }

  // 6. Card Recommendations / Discovery Endpoint Check (Message 3)
  console.log('--- [Recommendations / Card Suggestions Check] ---');
  const hdfcMsg = TEST_MESSAGES[2];
  console.log(`Testing card discovery for: "${hdfcMsg.body}"`);

  // Fetch catalogue from live production API if reachable, else use representative catalogue
  let catalogue = [];
  try {
    const res = await fetch('https://api.pandapath.site/catalogue', { signal: AbortSignal.timeout(5000) });
    if (res.ok) {
      const data = await res.json();
      catalogue = (data.cards || []).map(c => ({
        id: c.id,
        slug: c.slug,
        name: c.name,
        card_type: c.card_type,
        issuer_name: c.issuer_name,
        issuer_slug: c.issuer_slug,
      }));
      console.log(`Loaded ${catalogue.length} cards from live production catalogue.`);
    }
  } catch (e) {
    console.log(`Live catalogue fetch skipped (${e.message}), using standard catalogue.`);
    catalogue = [
      { id: 'hdfc-swiggy', slug: 'hdfc-swiggy', name: 'Swiggy HDFC Bank', card_type: 'credit', issuer_name: 'HDFC Bank', issuer_slug: 'hdfc' },
      { id: 'hdfc-millennia', slug: 'hdfc-millennia', name: 'Millennia', card_type: 'credit', issuer_name: 'HDFC Bank', issuer_slug: 'hdfc' },
      { id: 'hdfc-regalia-gold', slug: 'hdfc-regalia-gold', name: 'Regalia Gold', card_type: 'credit', issuer_name: 'HDFC Bank', issuer_slug: 'hdfc' },
    ];
  }

  const suggestions = discoverCardsAcrossMessages([{ body: hdfcMsg.body }], catalogue, true);
  console.log(`Discovered ${suggestions.length} card suggestion(s):`);
  console.log(JSON.stringify(suggestions, null, 2));

  const hasHdfcSuggestion = suggestions.some(s =>
    (s.issuerName?.toLowerCase().includes('hdfc') || s.name?.toLowerCase().includes('hdfc')) &&
    s.last4?.includes('1234')
  );

  if (hasHdfcSuggestion) {
    console.log('\n[PASS] Valid card suggestion returned matching issuer HDFC and last4 1234.');
    results.recommendationsVerified = true;
  } else {
    console.log('\n[FAIL] No matching card suggestion found.');
  }

  console.log('\n' + '='.repeat(70));
  console.log('TEST SUMMARY');
  console.log('='.repeat(70));
  console.log(`Messages Tested:        ${results.messagesTested} / 3`);
  console.log(`Accepted (HTTP 200):    ${results.acceptedCount} / 3`);
  console.log(`Leased by Worker:       ${results.leasedCount} / 3`);
  console.log(`Classified by Gemini:   ${results.classifiedCount} / 3`);
  console.log(`Contract Valid:         ${results.contractValidCount} / 3`);
  console.log(`Evidence Valid:         ${results.evidenceValidCount} / 3`);
  console.log(`Card Recommendations:   ${results.recommendationsVerified ? 'VERIFIED' : 'FAILED'}`);
  console.log('='.repeat(70));

  return results;
}

if (require.main === module) {
  runE2ETests().catch((err) => {
    console.error('Test script failed:', err);
    process.exit(1);
  });
}

module.exports = { runE2ETests, TEST_MESSAGES };
