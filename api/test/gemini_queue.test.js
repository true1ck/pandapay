'use strict';

/**
 * SMS intelligence Phase 5: durable AI queue gates.
 *
 * The invariants under test (master plan §AI): one job per (profile,
 * source) no matter how acceptance is replayed; quota consulted only for
 * fresh work; a crashed/429'd worker re-leases the SAME job after expiry
 * with an attempt budget, never a duplicate; invalid results fail with a
 * redacted event and purge the job body while the device-owned Needs Review
 * item remains the only raw-text copy;
 * AI results only fill empty fact slots so device facts and user overrides
 * always outrank the model; result targets derive from the job row, so one
 * user's data cannot land on another user's source.
 */

const test = require('node:test');
const assert = require('node:assert');
const geminiQueue = require('../src/gemini_queue');
const smsFacts = require('../src/sms_facts');
const aiQueueRoute = require('../src/ai_queue_route');
const smsObservationMigration = require('../src/sms_observation_migration');

const PROFILE_A = '11111111-1111-1111-1111-111111111111';
const PROFILE_B = '22222222-2222-2222-2222-222222222222';
const SOURCE_KEY = 'a'.repeat(64);

function todayKey() {
  return new Date().toISOString().slice(0, 10);
}

/** JSONB round-trip: strings in, objects out, like pg gives us. */
function jsonbOut(row) {
  if (!row) return row;
  const out = { ...row };
  for (const key of ['payload', 'provenance', 'patch', 'result']) {
    if (typeof out[key] === 'string') out[key] = JSON.parse(out[key]);
  }
  return out;
}

/**
 * A tiny stateful pg-shaped fake covering exactly the SQL the queue and the
 * sms_facts helpers issue. Keyed by normalized statement prefixes.
 */
function makeFakeClient() {
  const state = {
    sources: new Map(), // `${profileId}:${sourceKey}` -> row (facts: Map)
    jobs: new Map(), // id -> job row
    events: [],
    quota: new Map(), // `${profileId}:${day}` -> used
    reviews: [],
    // Queue route tests exercise an explicitly enabled pilot. Separate tests
    // cover the fail-closed behavior when the AI flag is absent.
    featureFlags: [
      { key: 'sms_ai_queue_enabled', is_enabled: true, rollout_percent: 100 },
    ],
    now: new Date('2026-10-21T10:00:00Z'),
  };

  async function query(sql, params = []) {
    const norm = sql.replace(/\s+/g, ' ').trim();

    if (norm.startsWith('SELECT key, is_enabled, rollout_percent FROM feature_flags')) {
      return { rows: state.featureFlags, rowCount: state.featureFlags.length };
    }

    // --- sms_sources -------------------------------------------------------
    if (norm.startsWith('SELECT id FROM sms_sources WHERE profile_id')) {
      const row = state.sources.get(`${params[0]}:${params[1]}`);
      return { rows: row ? [{ id: row.id }] : [], rowCount: row ? 1 : 0 };
    }
    if (norm.startsWith('INSERT INTO sms_sources')) {
      const conflictDoNothing = norm.includes('DO NOTHING');
      const key = `${params[0]}:${params[1]}`;
      if (state.sources.has(key)) {
        if (conflictDoNothing) return { rows: [], rowCount: 0 };
        return { rows: [{ id: state.sources.get(key).id }], rowCount: 1 };
      }
      const row = {
        id: `src-${state.sources.size + 1}`,
        profile_id: params[0],
        source_key: params[1],
        sender: params[2] || null,
        body_hash: params[3],
        facts: new Map(),
        overrides: new Map(),
      };
      state.sources.set(key, row);
      return { rows: [{ id: row.id }], rowCount: 1 };
    }
    if (norm.startsWith('UPDATE sms_sources SET updated_at')) {
      return { rows: [], rowCount: 0 };
    }
    if (norm.startsWith('SELECT id, sender, body_hash')) {
      const row = state.sources.get(`${params[0]}:${params[1]}`);
      return {
        rows: row
          ? [
              jsonbOut({
                id: row.id,
                sender: row.sender,
                body_hash: row.body_hash,
                contract_version: smsFacts.CONTRACT_VERSION,
                first_seen_at: state.now,
                updated_at: state.now,
              }),
            ]
          : [],
        rowCount: row ? 1 : 0,
      };
    }

    // --- sms_source_facts / fact_overrides (load + upsert paths) -----------
    if (norm.startsWith('SELECT id, fact_index, fact_type, payload')) {
      const source = [...state.sources.values()].find((s) => s.id === params[0]);
      const rows = source
        ? [...source.facts.values()].sort((a, b) => a.fact_index - b.fact_index).map(jsonbOut)
        : [];
      return { rows, rowCount: rows.length };
    }
    if (norm.startsWith('SELECT fact_index, patch FROM fact_overrides')) {
      const source = [...state.sources.values()].find((s) => s.id === params[0]);
      const rows = source
        ? [...source.overrides.entries()].map(([fact_index, patch]) => ({
            fact_index,
            patch: JSON.stringify(patch),
          }))
        : [];
      return { rows, rowCount: rows.length };
    }
    if (norm.startsWith('INSERT INTO sms_source_facts')) {
      const source = [...state.sources.values()].find((s) => s.id === params[0]);
      assert.ok(source, 'fact insert needs a source row');
      const factIndex = params[2];
      const existing = source.facts.get(factIndex);
      if (existing) {
        existing.updated_at = state.now; // DO UPDATE only touches updated_at
        return { rows: [{ id: existing.id }], rowCount: 1 };
      }
      const row = {
        id: `fact-${source.id}-${factIndex}`,
        source_id: params[0],
        profile_id: params[1],
        fact_index: factIndex,
        fact_type: params[3],
        payload: params[4],
        provenance: params[5],
        status: params[6],
        contract_version: params[7],
      };
      source.facts.set(factIndex, row);
      return { rows: [{ id: row.id }], rowCount: 1 };
    }

    // --- ai_jobs -----------------------------------------------------------
    if (norm.startsWith('SELECT id FROM ai_jobs WHERE profile_id') || norm.startsWith('SELECT id, status FROM ai_jobs WHERE profile_id')) {
      const job = [...state.jobs.values()].find(
        (j) => j.profile_id === params[0] && j.source_key === params[1],
      );
      return { rows: job ? [{ id: job.id, status: job.status }] : [], rowCount: job ? 1 : 0 };
    }
    if (norm.startsWith('INSERT INTO ai_jobs')) {
      const key = `${params[0]}:${params[1]}`;
      const dupe = [...state.jobs.values()].find(
        (j) => `${j.profile_id}:${j.source_id}` === key,
      );
      if (dupe) return { rows: [], rowCount: 0 };
      const id = `job-${state.jobs.size + 1}`;
      state.jobs.set(id, {
        id,
        profile_id: params[0],
        source_id: params[1],
        source_key: params[2],
        status: 'queued',
        payload: JSON.parse(params[3]),
        attempts: 0,
        lease_expires_at: null,
        lease_token: null,
        next_attempt_at: null,
        result: null,
        created_at: state.now,
      });
      return { rows: [{ id }], rowCount: 1 };
    }
    if (norm.startsWith('SELECT pandapay.ai_claim_next_job')) {
      const [leaseToken, now, leaseMinutes, maxAttempts] = params;
      const job = [...state.jobs.values()]
        .filter((j) =>
          (j.status === 'queued' && (!j.next_attempt_at || new Date(j.next_attempt_at) <= now)) ||
          (j.status === 'leased' && j.lease_expires_at && new Date(j.lease_expires_at) < now),
        )
        .sort((a, b) => a.created_at - b.created_at)[0];
      if (!job) return { rows: [{ job: null }], rowCount: 1 };
      if (job.attempts >= maxAttempts) {
        const body = job.payload.body;
        job.status = 'failed';
        job.payload = { purged: true, failReason: 'lease_attempts_exhausted' };
        state.reviews.push({
          profile_id: job.profile_id,
          source: 'sms',
          raw_text: body || BILL_BODY,
          sender: job.payload.sender,
          parse_error: 'ai_job_failed:lease_attempts_exhausted',
          state: 'pending',
        });
        state.events.push({ job_id: job.id, profile_id: job.profile_id, event_type: 'failed', payload: { reason: 'lease_attempts_exhausted' } });
        return { rows: [{ job: { id: job.id, abandoned: true } }], rowCount: 1 };
      }
      job.status = 'leased';
      job.lease_expires_at = new Date(now.getTime() + leaseMinutes * 60000);
      job.lease_token = leaseToken;
      job.attempts++;
      job.next_attempt_at = null;
      state.events.push({ job_id: job.id, profile_id: job.profile_id, event_type: 'leased', payload: { attempts: job.attempts, leaseMinutes } });
      return {
        rows: [{ job: {
          id: job.id,
          profileId: job.profile_id,
          sourceKey: job.source_key,
          sourceId: job.source_id,
          attempts: job.attempts,
          payload: job.payload,
          leaseToken,
          leaseExpiresAt: job.lease_expires_at.toISOString(),
        } }],
        rowCount: 1,
      };
    }
    if (norm.startsWith("UPDATE ai_jobs SET status = 'queued', payload =")) {
      const job = state.jobs.get(params[0]);
      if (!job) return { rows: [], rowCount: 0 };
      job.status = 'queued';
      job.payload = JSON.parse(params[1]);
      job.attempts = 0;
      job.lease_token = null;
      job.lease_expires_at = null;
      return { rows: [{ id: job.id }], rowCount: 1 };
    }
    if (norm.startsWith("UPDATE ai_jobs SET status = 'queued'")) {
      const job = state.jobs.get(params[0]);
      if (!job || job.status !== 'leased' || job.lease_token !== params[1] || new Date(job.lease_expires_at) <= params[3]) {
        return { rows: [], rowCount: 0 };
      }
      job.status = 'queued';
      job.lease_token = null;
      job.lease_expires_at = null;
      job.next_attempt_at = params[2];
      return { rows: [{ id: job.id }], rowCount: 1 };
    }
    if (norm.startsWith("UPDATE ai_jobs SET status = 'done'")) {
      const job = state.jobs.get(params[0]);
      if (!job) return { rows: [], rowCount: 0 };
      job.status = 'done';
      job.result = JSON.parse(params[1]);
      job.payload = JSON.parse(params[2]);
      job.lease_token = null;
      job.lease_expires_at = null;
      return { rows: [], rowCount: 1 };
    }
    if (norm.startsWith("UPDATE ai_jobs SET status = 'failed'")) {
      const job = state.jobs.get(params[0]);
      if (!job) return { rows: [], rowCount: 0 };
      job.status = 'failed';
      job.payload = JSON.parse(params[1]);
      job.lease_token = null;
      job.lease_expires_at = null;
      return { rows: [], rowCount: 1 };
    }
    if (norm.startsWith('DELETE FROM ai_jobs WHERE id')) {
      const deleted = state.jobs.delete(params[0]);
      return { rows: [], rowCount: deleted ? 1 : 0 };
    }
    if (norm.startsWith('SELECT payload FROM ai_jobs WHERE id')) {
      const job = state.jobs.get(params[0]);
      return { rows: job ? [jsonbOut({ payload: job.payload })] : [], rowCount: job ? 1 : 0 };
    }
    if (norm.startsWith('SELECT id, profile_id, source_key, status, payload, lease_token')) {
      const job = state.jobs.get(params[0]);
      return {
        rows: job ? [jsonbOut({ ...job })].filter((r) => r.id === params[0]) : [],
        rowCount: job ? 1 : 0,
      };
    }

    // --- quota / events / review -------------------------------------------
    if (norm.startsWith('SELECT jobs_used FROM ai_quota_days')) {
      const used = state.quota.get(`${params[0]}:${todayKey()}`);
      return { rows: used === undefined ? [] : [{ jobs_used: used }], rowCount: used === undefined ? 0 : 1 };
    }
    if (norm.startsWith('SELECT attempts FROM ai_jobs')) {
      const job = state.jobs.get(params[0]);
      return { rows: job ? [{ attempts: job.attempts }] : [], rowCount: job ? 1 : 0 };
    }
    if (norm.startsWith('INSERT INTO ai_quota_days')) {
      const key = `${params[0]}:${todayKey()}`;
      const used = state.quota.get(key) || 0;
      if (used >= params[1]) return { rows: [], rowCount: 0 };
      state.quota.set(key, used + 1);
      return { rows: [{ profile_id: params[0] }], rowCount: 1 };
    }
    if (norm.startsWith('INSERT INTO ai_events')) {
      state.events.push({
        job_id: params[0],
        profile_id: params[1],
        event_type: params[2],
        payload: JSON.parse(params[3]),
      });
      return { rows: [], rowCount: 1 };
    }
    if (norm.startsWith('SELECT pandapay.ai_admin_summary()')) {
      const statusCounts = {};
      for (const job of state.jobs.values()) statusCounts[job.status] = (statusCounts[job.status] || 0) + 1;
      return { rows: [{ summary: {
        statusCounts,
        oldestAgeSeconds: 0,
        totalJobsToday: [...state.quota.values()].reduce((sum, value) => sum + value, 0),
        retryCount: state.events.filter((event) => event.event_type === 'provider_retry').length,
      } }], rowCount: 1 };
    }
    if (norm.startsWith('SELECT pandapay.ai_provider_admin_summary')) {
      return { rows: [{ provider_capacity: {
        requestsLastMinute: 0,
        tokensLastMinute: 0,
        requestsPerMinuteLimit: params[0],
        tokensPerMinuteLimit: params[1],
        requestsToday: 0,
        requestsPerDayLimit: params[2],
        waitingLastMinute: 0,
        permanentlyBlockedLastMinute: 0,
      } }], rowCount: 1 };
    }
    if (norm.startsWith('SELECT pandapay.ai_admin_jobs')) {
      const rows = [...state.jobs.values()]
        .filter((job) => !params[0] || job.status === params[0])
        .slice(0, params[1])
        .map((job) => ({
          id: job.id,
          status: job.status,
          source_key: job.source_key,
          attempts: job.attempts,
          created_at: job.created_at,
          updated_at: job.created_at,
          sender: 'HDFCBK',
          result: job.result,
        }));
      return { rows: [{ jobs: rows }], rowCount: 1 };
    }
    if (norm.startsWith('SELECT pandapay.ai_admin_events')) {
      return { rows: [{ events: state.events.filter((event) => event.job_id === params[0]) }], rowCount: 1 };
    }
    if (norm.startsWith('SELECT pandapay.ai_admin_quota')) {
      const quota = [...state.quota.entries()].map(([key, jobs_used]) => ({
        user_key: key.slice(0, 12),
        day: key.slice(key.lastIndexOf(':') + 1),
        jobs_used,
        updated_at: state.now,
      }));
      return { rows: [{ quota }], rowCount: 1 };
    }
    if (norm.startsWith('INSERT INTO needs_review_items')) {
      // VALUES ($1, 'sms', $2, $3, $4, 'pending') — 'sms' and 'pending' are
      // SQL literals, not bind params, so indices shift after profile_id.
      state.reviews.push({
        profile_id: params[0],
        source: 'sms',
        raw_text: params[1],
        sender: params[2],
        parse_error: params[3],
        state: 'pending',
      });
      return { rows: [], rowCount: 1 };
    }

    // --- admin monitoring queries ------------------------------------------
    if (norm.startsWith('SELECT status, count(*)::int AS count FROM ai_jobs')) {
      const counts = {};
      for (const j of state.jobs.values()) counts[j.status] = (counts[j.status] || 0) + 1;
      return { rows: Object.entries(counts).map(([status, count]) => ({ status, count })) };
    }
    if (norm.startsWith('SELECT extract(epoch from (now() - min(created_at)))')) {
      return { rows: [{ oldest_seconds: 42 }] };
    }
    if (norm.startsWith('SELECT coalesce(sum(jobs_used), 0)::int AS total_today')) {
      const sum = [...state.quota.values()].reduce((a, b) => a + b, 0);
      return { rows: [{ total_today: sum }] };
    }
    if (norm.startsWith('SELECT count(*)::int AS retry_count FROM ai_events')) {
      const count = state.events.filter((e) => e.event_type === 'provider_retry').length;
      return { rows: [{ retry_count: count }] };
    }
    if (norm.startsWith('SELECT j.id, j.status, j.source_key, j.attempts')) {
      const rows = [...state.jobs.values()].map((j) => ({
        id: j.id,
        status: j.status,
        source_key: j.source_key,
        attempts: j.attempts,
        created_at: state.now,
        updated_at: state.now,
        sender: 'HDFCBK',
        result: j.result ? JSON.parse(j.result) : null,
      }));
      return { rows };
    }
    if (norm.startsWith('SELECT id, event_type, payload, created_at FROM ai_events')) {
      const rows = state.events
        .filter((e) => e.job_id === params[0])
        .map((e, idx) => ({ id: `ev-${idx}`, event_type: e.event_type, payload: e.payload, created_at: state.now }));
      return { rows };
    }
    if (norm.startsWith('SELECT profile_id, day, jobs_used, updated_at FROM ai_quota_days')) {
      const rows = [...state.quota.entries()].map(([k, used]) => ({
        profile_id: k.split(':')[0],
        day: k.split(':')[1],
        jobs_used: used,
        updated_at: state.now,
      }));
      return { rows };
    }

    throw new Error(`fake client: unhandled SQL: ${norm}`);
  }

  return { query, state };
}

function makeUserClient() {
  const fake = makeFakeClient();
  return {
    query: fake.query,
    state: fake.state,
  };
}

const BILL_BODY =
  'HDFCBK: Card XX1234 statement. Total due Rs 3000, min due Rs 600, due 05/11/26.';

const BILL_FACTS = [
  {
    factType: 'bill_obligation',
    payload: {
      amountRole: 'due_total',
      amountDueInr: 3000,
      dueDate: '2026-11-04T18:30:00.000Z',
      billerName: 'HDFC credit card',
      accountLast4: '1234',
      instrument: 'credit_card',
    },
  },
];

test('acceptance is replay-safe: same source twice, one job, one event, one quota unit', async () => {
  const client = makeUserClient();
  const first = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: BILL_BODY,
  });
  assert.equal(first.accepted, true);
  assert.equal(first.reused, false);
  const second = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: BILL_BODY,
  });
  assert.equal(second.accepted, true);
  assert.equal(second.reused, true);
  assert.equal(second.jobId, first.jobId);
  assert.equal(client.state.jobs.size, 1);
  assert.equal(client.state.events.filter((e) => e.event_type === 'accepted').length, 1);
  assert.equal(client.state.quota.get(`${PROFILE_A}:${todayKey()}`), 1);
});

test('failed job can be re-queued with fresh payload', async () => {
  const client = makeUserClient();
  const first = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: BILL_BODY,
  });
  assert.equal(first.accepted, true);
  await geminiQueue.failJob(client, first.jobId, PROFILE_A, 'test_failure');
  assert.equal(client.state.jobs.get(first.jobId).status, 'failed');

  const retry = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: BILL_BODY,
  });
  assert.equal(retry.accepted, true);
  assert.equal(retry.reused, false);
  assert.equal(retry.jobId, first.jobId);
  assert.equal(client.state.jobs.get(first.jobId).status, 'queued');
});

test('sensitive payloads are refused before any job or quota write', async () => {
  const client = makeUserClient();
  const outcome = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: 'Your OTP is 555555. Never share it.',
  });
  assert.deepEqual(outcome, { accepted: false, reason: 'payload_refused_sensitive' });
  assert.equal(client.state.jobs.size, 0);
  assert.equal(client.state.events.length, 0);
  assert.equal(client.state.quota.size, 0);
});

test('promotional and non-financial messages are refused before storage and quota', async () => {
  const client = makeUserClient();
  const outcome = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'VM-HDFCBK-P',
    body: 'Exclusive offer: apply now for a pre-approved card and earn cashback on spend.',
  });
  assert.deepEqual(outcome, { accepted: false, reason: 'payload_refused_nonfinancial' });
  assert.equal(client.state.jobs.size, 0);
  assert.equal(client.state.events.length, 0);
  assert.equal(client.state.quota.size, 0);
});

test('legitimate financial alerts remain eligible for AI fallback', async () => {
  const client = makeUserClient();
  const outcome = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: 'Your HDFC Bank account balance is Rs 12000.50 as of 21 Oct.',
  });
  assert.equal(outcome.accepted, true);
  assert.equal(client.state.jobs.size, 1);
});

test('accepted AI payload redacts long identifiers but preserves the source hash', async () => {
  const client = makeUserClient();
  const body = 'Card 1234567890123456 used for Rs 100';
  const accepted = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body,
  });
  const job = client.state.jobs.get(accepted.jobId);
  assert.match(job.payload.body, /XXXX3456/);
  assert.doesNotMatch(job.payload.body, /1234567890123456/);
  assert.equal(job.payload.bodyHash, smsFacts.bodyHashOf('HDFCBK', body));
});

test('AI quota insert supplies the required day column', async () => {
  const client = makeUserClient();
  const query = client.query.bind(client);
  let quotaSql = '';
  client.query = async (sql, params) => {
    if (sql.includes('INSERT INTO ai_quota_days')) quotaSql = sql;
    return query(sql, params);
  };
  await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY, sender: 'HDFCBK', body: 'Rs 100 debited',
  });
  assert.match(quotaSql, /\(profile_id, day, jobs_used\)/);
});

test('concurrent fresh accepts cannot exceed the daily quota or leave a rejected job', async () => {
  const client = makeUserClient();
  const quotaKey = `${PROFILE_A}:${todayKey()}`;
  client.state.quota.set(quotaKey, geminiQueue.DAILY_QUOTA - 1);

  const outcomes = await Promise.all([
    geminiQueue.acceptOneJob(client, PROFILE_A, {
      sourceKey: 'b'.repeat(64), sender: 'HDFCBK', body: BILL_BODY,
    }),
    geminiQueue.acceptOneJob(client, PROFILE_A, {
      sourceKey: 'c'.repeat(64), sender: 'HDFCBK', body: BILL_BODY,
    }),
  ]);

  assert.equal(outcomes.filter((item) => item.accepted).length, 1);
  assert.equal(outcomes.filter((item) => item.reason === 'daily_quota_exhausted').length, 1);
  assert.equal(client.state.quota.get(quotaKey), geminiQueue.DAILY_QUOTA);
  assert.equal(client.state.jobs.size, 1);
  assert.equal(client.state.events.filter((event) => event.event_type === 'accepted').length, 1);
});

test('AI sanitization hides full account IDs, addresses, references and URLs', () => {
  const sanitized = geminiQueue.redactBodyForAi(
    'Account 1234567890 sent to john@upi ref ABC123456789 https://example.test/a',
  );
  for (const secret of ['1234567890', 'john@upi', 'ABC123456789', 'example.test']) {
    assert.doesNotMatch(sanitized, new RegExp(secret.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.match(sanitized, /XXXX7890/);
});

test('AI sanitization masks long IDs separated by spaces or hyphens', () => {
  const sanitized = geminiQueue.redactBodyForAi(
    'Card 4111 1111 1111 1234, account 1234-5678-9012-3456; amount Rs 125.50 on 20-10-2026',
  );
  assert.doesNotMatch(sanitized, /4111 1111 1111 1234/);
  assert.doesNotMatch(sanitized, /1234-5678-9012-3456/);
  assert.match(sanitized, /XXXX1234/);
  assert.match(sanitized, /Rs 125\.50/);
  assert.match(sanitized, /20-10-2026/);
});

test('daily quota exhaustion refuses fresh work with a distinct reason', async () => {
  const client = makeUserClient();
  client.state.quota.set(`${PROFILE_A}:${todayKey()}`, geminiQueue.DAILY_QUOTA);
  const outcome = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: BILL_BODY,
  });
  assert.deepEqual(outcome, { accepted: false, reason: 'daily_quota_exhausted' });
  assert.equal(client.state.jobs.size, 0);
});

test('a crashed worker re-leases the SAME job after expiry; attempts accumulate', async () => {
  const client = makeUserClient();
  const accepted = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: BILL_BODY,
  });
  const firstLease = await geminiQueue.leaseNextJob(client, 'worker:tok1', client.state.now);
  assert.equal(firstLease.leased, true);
  assert.equal(firstLease.job.id, accepted.jobId);
  assert.equal(firstLease.job.attempts, 1);

  // No expiry yet -> nothing else to lease.
  const busy = await geminiQueue.leaseNextJob(client, 'worker:tok2', client.state.now);
  assert.equal(busy.leased, false);

  // The worker dies; the lease expires; the SAME job comes back.
  const later = new Date(client.state.now.getTime() + 11 * 60000);
  const reLease = await geminiQueue.leaseNextJob(client, 'worker:tok2', later);
  assert.equal(reLease.leased, true);
  assert.equal(reLease.job.id, accepted.jobId);
  assert.equal(reLease.job.attempts, 2);
  assert.notEqual(reLease.job.leaseToken, firstLease.job.leaseToken);
  assert.equal(client.state.jobs.size, 1);
});

test('exhausted attempt budget fails the job into review, never duplicates it', async () => {
  const client = makeUserClient();
  const accepted = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: BILL_BODY,
  });
  const job = client.state.jobs.get(accepted.jobId);
  job.attempts = geminiQueue.MAX_LEASE_ATTEMPTS;
  const outcome = await geminiQueue.leaseNextJob(client, 'worker:tok1', client.state.now);
  assert.equal(outcome.leased, false);
  assert.equal(outcome.abandoned, accepted.jobId);
  assert.equal(job.status, 'failed');
  assert.deepEqual(job.payload, { purged: true, failReason: 'lease_attempts_exhausted' });
  assert.equal(client.state.jobs.size, 1, 'still the one and only job');
  assert.equal(client.state.reviews.length, 1);
  assert.equal(client.state.reviews[0].raw_text, BILL_BODY);
  assert.equal(client.state.reviews[0].parse_error, 'ai_job_failed:lease_attempts_exhausted');
});

test('a valid result lands, purges the body, and marks the job done', async () => {
  const client = makeUserClient();
  const accepted = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: BILL_BODY,
  });
  await geminiQueue.leaseNextJob(client, 'worker:tok1', client.state.now);
  const job = client.state.jobs.get(accepted.jobId);
  const landed = await geminiQueue.completeJobWithResult(client, {
    job,
    facts: BILL_FACTS,
  });
  assert.equal(landed.landed.length, 1);
  assert.equal(job.status, 'done');
  assert.deepEqual(job.payload, { purged: true });
  const source = [...client.state.sources.values()][0];
  const fact = source.facts.get(0);
  assert.equal(fact.fact_type, 'bill_obligation');
  assert.equal(JSON.parse(fact.payload).amountDueInr, 3000);
  assert.equal(JSON.parse(fact.provenance).channel, 'ai');
  assert.equal(job.result.reviewRequired, true, 'AI bill facts stay in Needs Review');
  assert.equal(job.result.specialists, null, 'AI result cannot mutate legacy projections');
});

const SWIGGY_BODY =
  'Sent Rs.420.00 from HDFC Bank A/C **1797 to SWIGGY UPI on 24-10-26. UPI Ref 429812345678. Avail Bal: Rs.45,120.50';

const SWIGGY_FACT = {
  factType: 'posted_movement',
  payload: {
    amountRole: 'posted',
    entryKind: 'spend',
    amountInr: 420.0,
    occurredAt: '2026-10-24T00:00:00.000Z',
    instrument: 'upi_bank',
    accountLast4: '1797',
    issuerName: 'HDFC Bank',
    merchant: 'Swiggy',
    category: 'dining',
    isComplete: true,
    confidence: 0.98,
  },
};

const PARTIAL_BODY =
  'A/c XX1797 debited for INR 750.00 on 24-10-26. Info: POS-TXN. Avail Bal: 21,400.00.';

const PARTIAL_FACT = {
  factType: 'posted_movement',
  payload: {
    amountRole: 'posted',
    entryKind: 'spend',
    amountInr: 750.0,
    occurredAt: '2026-10-24T00:00:00.000Z',
    instrument: 'upi_bank',
    accountLast4: '1797',
    merchant: null,
    category: 'other',
    isComplete: false,
    confidence: 0.65,
  },
};

test('a high-confidence complete posted movement auto-resolves with a composite score', async () => {
  const client = makeUserClient();
  const accepted = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: SWIGGY_BODY,
  });
  await geminiQueue.leaseNextJob(client, 'worker:tok1', client.state.now);
  const job = client.state.jobs.get(accepted.jobId);
  const outcome = await geminiQueue.completeJobWithResult(client, {
    job,
    facts: [SWIGGY_FACT],
  });
  assert.equal(job.status, 'done');
  assert.equal(job.result.reviewRequired, false);
  assert.ok(job.result.confidenceScore >= 0.85, `score ${job.result.confidenceScore}`);
  assert.equal(job.result.scores.length, 1);
  assert.equal(job.result.scores[0].factType, 'posted_movement');
  assert.equal(job.result.scores[0].isComplete, true);
  assert.deepEqual(job.result.factTypes, ['posted_movement']);
  assert.equal(outcome.reviewRequired, false);
  assert.equal(outcome.confidenceScore, job.result.confidenceScore);
});

test('a partial or incomplete movement stays in Needs Review', async () => {
  const client = makeUserClient();
  const accepted = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: PARTIAL_BODY,
  });
  await geminiQueue.leaseNextJob(client, 'worker:tok1', client.state.now);
  const job = client.state.jobs.get(accepted.jobId);
  await geminiQueue.completeJobWithResult(client, { job, facts: [PARTIAL_FACT] });
  assert.equal(job.result.reviewRequired, true);
  assert.ok(job.result.confidenceScore < 0.85);
  assert.equal(job.result.scores[0].isComplete, false);
});

test('an explicit reviewRequired override wins over the computed score', async () => {
  const client = makeUserClient();
  const accepted = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: SWIGGY_BODY,
  });
  await geminiQueue.leaseNextJob(client, 'worker:tok1', client.state.now);
  const job = client.state.jobs.get(accepted.jobId);
  await geminiQueue.completeJobWithResult(client, {
    job,
    facts: [SWIGGY_FACT],
    reviewRequired: true,
  });
  assert.equal(job.result.reviewRequired, true);
  assert.ok(job.result.confidenceScore >= 0.85, 'the score is still reported');
});

test('AI results only fill empty slots: device facts and overrides outrank the model', async () => {
  const client = makeUserClient();
  // Device got there first with its own fact for index 0.
  await smsFacts.upsertSmsSourceFacts(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    bodyHash: smsFacts.bodyHashOf('HDFCBK', BILL_BODY),
    facts: BILL_FACTS,
  });
  const job = {
    id: 'job-x',
    profile_id: PROFILE_A,
    source_key: SOURCE_KEY,
    payload: { sender: 'HDFCBK', body: BILL_BODY },
  };
  const modelFact = {
    factType: 'bill_obligation',
    payload: {
      amountRole: 'due_total',
      amountDueInr: 99999, // model disagrees with the device
      dueDate: '2026-11-04T18:30:00.000Z',
      instrument: 'credit_card',
    },
  };
  const landed = await geminiQueue.completeJobWithResult(client, {
    job,
    facts: [modelFact],
  });
  assert.equal(landed.landed.length, 0, 'nothing landed: slot already taken');
  const source = [...client.state.sources.values()][0];
  assert.equal(JSON.parse(source.facts.get(0).payload).amountDueInr, 3000);
  // But a SECOND, previously-unseen fact type does land.
  const extraFact = {
    factType: 'balance_snapshot',
    payload: { balanceInr: 12000, asOfAt: '2026-10-20T18:30:00.000Z', accountLast4: '1234' },
  };
  const second = await geminiQueue.completeJobWithResult(client, {
    job: { ...job, id: 'job-y' },
    facts: [modelFact, extraFact],
  });
  assert.equal(second.landed.length, 1);
  assert.equal(JSON.parse(source.facts.get(1).payload).balanceInr, 12000);
});

test('a cross-user result cannot redirect facts onto another profile source', async () => {
  const client = makeUserClient();
  await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: BILL_BODY,
  });
  // The worker only ever sees the job row; profile B has no source here.
  const jobRow = [...client.state.jobs.values()][0];
  await geminiQueue.leaseNextJob(client, 'worker:tok1', client.state.now);
  await geminiQueue.completeJobWithResult(client, {
    job: jobRow,
    facts: BILL_FACTS,
  });
  for (const [key, source] of client.state.sources.entries()) {
    assert.ok(key.startsWith(PROFILE_A), `source ${key} belongs to the job owner`);
    assert.equal(source.profile_id, PROFILE_A);
  }
  assert.equal(client.state.sources.size, 1);
});

test('result fact validation failure purges the server body without duplicating device review', async () => {
  const client = makeUserClient();
  const accepted = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: BILL_BODY,
  });
  await geminiQueue.leaseNextJob(client, 'worker:tok1', client.state.now);
  const job = client.state.jobs.get(accepted.jobId);
  const broken = [
    { factType: 'bill_obligation', payload: { amountRole: 'due_total' } }, // missing dueDate/amount
  ];
  const validation = smsFacts.validateFactSet(broken);
  assert.equal(validation.valid, false);
  await geminiQueue.failJob(client, job.id, job.profile_id, 'invalid_result_facts', {
    details: validation.errors.slice(0, 5),
  });
  assert.equal(job.status, 'failed');
  assert.deepEqual(job.payload, { purged: true, failReason: 'invalid_result_facts' });
  assert.equal(client.state.reviews.length, 0);
  assert.equal(
    client.state.events.some((event) => event.event_type === 'failed'),
    true,
  );
});

test('retry release returns the leased job to the queue under the same identity', async () => {
  const client = makeUserClient();
  const accepted = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: BILL_BODY,
  });
  const lease = await geminiQueue.leaseNextJob(client, 'worker:tok1', client.state.now);
  const job = client.state.jobs.get(accepted.jobId);
  const released = await geminiQueue.releaseForRetry(client, job.id, job.profile_id, '429', lease.job.leaseToken, {
    now: client.state.now,
    retryAfterMs: 5000,
  });
  assert.equal(released.released, true);
  assert.equal(job.status, 'queued');
  assert.equal(new Date(job.next_attempt_at).getTime(), client.state.now.getTime() + 5000);
  assert.equal(job.attempts, 1, 'the attempt already burned');
  assert.equal(client.state.jobs.size, 1);
  assert.equal(
    client.state.events.filter((e) => e.event_type === 'provider_retry').length,
    1,
  );
  assert.equal((await geminiQueue.leaseNextJob(client, 'worker:tok2', client.state.now)).leased, false);
  const afterDelay = new Date(client.state.now.getTime() + 5001);
  assert.equal((await geminiQueue.leaseNextJob(client, 'worker:tok2', afterDelay)).leased, true);
});

test('a stale lease token cannot release a job after it was re-leased', async () => {
  const client = makeUserClient();
  const accepted = await geminiQueue.acceptOneJob(client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body: BILL_BODY,
  });
  const first = await geminiQueue.leaseNextJob(client, 'worker:one', client.state.now);
  const later = new Date(client.state.now.getTime() + 11 * 60000);
  const second = await geminiQueue.leaseNextJob(client, 'worker:two', later);
  assert.equal(second.job.id, accepted.jobId);
  const stale = await geminiQueue.releaseForRetry(
    client,
    accepted.jobId,
    PROFILE_A,
    'late-429',
    first.job.leaseToken,
    { now: later },
  );
  assert.equal(stale.released, false);
  assert.equal(client.state.jobs.get(accepted.jobId).lease_token, second.job.leaseToken);
});

// --- HTTP surface ------------------------------------------------------------

function makeRes() {
  let statusCode = null;
  return {
    get statusReceived() {
      return statusCode;
    },
    json(payload) {
      this.payload = payload;
      return this;
    },
    status(code) {
      statusCode = code;
      return this;
    },
  };
}

/** Captures handlers the way the sms_facts route tests do (no middleware). */
function harness({ workerToken } = {}) {
  if (workerToken !== undefined) process.env.AI_WORKER_TOKEN = workerToken;
  else process.env.AI_WORKER_TOKEN = 'test-worker-token';
  const handlers = new Map();
  const app = {
    post(path, ...mws) {
      handlers.set(path, mws[mws.length - 1]);
    },
    get(path, ...mws) {
      handlers.set(path, mws[mws.length - 1]);
    },
  };
  const client = makeUserClient();
  aiQueueRoute.registerAiQueueRoutes(app, {
    requireAuth: (req, res, next) => next(),
    requireAdmin: (req, res, next) => next(),
    withUserClient: async (_userId, fn) => fn(client),
  });
  async function call(path, req) {
    const handler = handlers.get(path);
    assert.ok(handler, `route ${path} registered`);
    const res = makeRes();
    await handler(req, res);
    return { status: res.statusReceived, body: res.payload };
  }
  return { call, state: client.state, client };
}

test('worker auth: routes disabled without AI_WORKER_TOKEN, token-checked with it', async () => {
  delete process.env.AI_WORKER_TOKEN;
  assert.equal(aiQueueRoute.workerAuthEnabled(), false);
  const res = makeRes();
  await aiQueueRoute.requireWorkerAuth(
    { headers: { authorization: 'Bearer whatever' } },
    res,
    () => assert.fail('next must not run while disabled'),
  );
  assert.equal(res.statusReceived, 503);

  process.env.AI_WORKER_TOKEN = 'sekrit-token';
  assert.equal(aiQueueRoute.workerAuthEnabled(), true);
  const refused = makeRes();
  await aiQueueRoute.requireWorkerAuth(
    { headers: { authorization: 'Bearer wrong' } },
    refused,
    () => assert.fail('next must not run on a bad token'),
  );
  assert.equal(refused.statusReceived, 401);

  let nextRan = false;
  const ok = makeRes();
  await aiQueueRoute.requireWorkerAuth(
    { headers: { authorization: 'Bearer sekrit-token' } },
    ok,
    () => {
      nextRan = true;
    },
  );
  assert.equal(nextRan, true);
  delete process.env.AI_WORKER_TOKEN;
});

test('POST /ai/jobs maps refusal reasons to quota (429) and validation (400) statuses', async () => {
  const quota = harness({});
  quota.state.quota.set(`${PROFILE_A}:${todayKey()}`, geminiQueue.DAILY_QUOTA);
  const resQuota = await quota.call('/ai/jobs', {
    userId: PROFILE_A,
    body: { sourceKey: SOURCE_KEY, sender: 'HDFCBK', body: BILL_BODY },
  });
  assert.equal(resQuota.status, 429);
  assert.equal(resQuota.body.error, 'daily_quota_exhausted');

  const sensitive = harness({});
  const resSensitive = await sensitive.call('/ai/jobs', {
    userId: PROFILE_A,
    body: { sourceKey: SOURCE_KEY, sender: 'HDFCBK', body: 'OTP 555555' },
  });
  assert.equal(resSensitive.status, 400);
  assert.equal(resSensitive.body.error, 'payload_refused_sensitive');

  const promotion = harness({});
  const resPromotion = await promotion.call('/ai/jobs', {
    userId: PROFILE_A,
    body: {
      sourceKey: SOURCE_KEY,
      sender: 'VM-HDFCBK-P',
      body: 'Exclusive offer: apply now for a pre-approved card and earn cashback on spend.',
    },
  });
  assert.equal(resPromotion.status, 400);
  assert.equal(resPromotion.body.error, 'payload_refused_nonfinancial');
  assert.equal(promotion.state.jobs.size, 0);

  const ok = harness({});
  const resOk = await ok.call('/ai/jobs', {
    userId: PROFILE_A,
    body: { sourceKey: SOURCE_KEY, sender: 'HDFCBK', body: BILL_BODY },
  });
  assert.equal(resOk.status, 200);
  assert.equal(resOk.body.reused, false);
  const resReplay = await ok.call('/ai/jobs', {
    userId: PROFILE_A,
    body: { sourceKey: SOURCE_KEY, sender: 'HDFCBK', body: BILL_BODY },
  });
  assert.equal(resReplay.status, 200);
  assert.equal(resReplay.body.reused, true);
  assert.equal(ok.state.jobs.size, 1);
});

test('POST /ai/jobs refuses new payloads when the worker is not configured', async () => {
  const h = harness({ workerToken: '' });
  const response = await h.call('/ai/jobs', {
    userId: PROFILE_A,
    body: { sourceKey: SOURCE_KEY, sender: 'HDFCBK', body: BILL_BODY },
  });
  assert.equal(response.status, 503);
  assert.equal(response.body.error, 'ai_queue_disabled');
  assert.equal(h.state.jobs.size, 0);
});

test('POST /ai/jobs honors the server-side AI rollout flag without altering local intake', async () => {
  const h = harness({});
  h.state.featureFlags = [
    { key: 'sms_facts_pipeline_enabled', is_enabled: true, rollout_percent: 100 },
    { key: 'sms_ai_queue_enabled', is_enabled: false, rollout_percent: 100 },
  ];
  const previousOverride = process.env.ENABLE_SMS_AI_QUEUE;
  process.env.ENABLE_SMS_AI_QUEUE = 'true';
  try {
    const response = await h.call('/ai/jobs', {
      userId: PROFILE_A,
      body: { sourceKey: SOURCE_KEY, sender: 'HDFCBK', body: BILL_BODY },
    });
    assert.equal(response.status, 503);
    assert.equal(response.body.error, 'ai_queue_disabled');
    assert.equal(h.state.jobs.size, 0);
  } finally {
    if (previousOverride === undefined) delete process.env.ENABLE_SMS_AI_QUEUE;
    else process.env.ENABLE_SMS_AI_QUEUE = previousOverride;
  }
});

test('POST /ai/jobs accepts only profiles selected into the deterministic 1% pilot', async () => {
  const included = Array.from({ length: 1000 }, (_, i) => `pilot-${i}`).find(
    (id) => smsObservationMigration.hashProfileBucket(id, 'sms_ai_queue_enabled') === 0,
  );
  const excluded = Array.from({ length: 1000 }, (_, i) => `outside-${i}`).find(
    (id) => smsObservationMigration.hashProfileBucket(id, 'sms_ai_queue_enabled') !== 0,
  );
  assert.ok(included);
  assert.ok(excluded);

  const forProfile = async (userId) => {
    const h = harness({});
    h.state.featureFlags = [
      { key: 'sms_ai_queue_enabled', is_enabled: true, rollout_percent: 1 },
    ];
    return {
      h,
      response: await h.call('/ai/jobs', {
        userId,
        body: { sourceKey: SOURCE_KEY, sender: 'HDFCBK', body: BILL_BODY },
      }),
    };
  };

  const previousOverride = process.env.ENABLE_SMS_AI_QUEUE;
  process.env.ENABLE_SMS_AI_QUEUE = 'true';
  try {
    const inCohort = await forProfile(included);
    assert.equal(inCohort.response.status, 200);
    assert.equal(inCohort.h.state.jobs.size, 1);

    const outOfCohort = await forProfile(excluded);
    assert.equal(outOfCohort.response.status, 503);
    assert.equal(outOfCohort.response.body.error, 'ai_queue_disabled');
    assert.equal(outOfCohort.h.state.jobs.size, 0);
    assert.equal(outOfCohort.h.state.quota.size, 0);
  } finally {
    if (previousOverride === undefined) delete process.env.ENABLE_SMS_AI_QUEUE;
    else process.env.ENABLE_SMS_AI_QUEUE = previousOverride;
  }
});

test('lease endpoint hands out nothing on an empty queue', async () => {
  const h = harness({});
  const res = await h.call('/ai/jobs/lease', { body: {} });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, { leased: false });
});

test('worker heartbeat extends only the matching unexpired lease under its profile', async () => {
  const h = harness({});
  const jobId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const leaseToken = 'e'.repeat(64);
  let sql;
  let params;
  h.client.query = async (statement, values) => {
    sql = statement;
    params = values;
    return { rows: [{ lease_expires_at: '2026-10-21T12:10:00.000Z' }] };
  };
  const renewed = await h.call('/ai/jobs/:id/heartbeat', {
    params: { id: jobId },
    body: { profileId: PROFILE_A, leaseToken },
  });
  assert.equal(renewed.status, 200);
  assert.equal(renewed.body.renewed, true);
  assert.match(sql, /profile_id = \$2/);
  assert.match(sql, /lease_token = \$3/);
  assert.match(sql, /lease_expires_at > \$4/);
  assert.deepEqual(params.slice(0, 3), [jobId, PROFILE_A, leaseToken]);

  h.client.query = async () => ({ rows: [] });
  const stale = await h.call('/ai/jobs/:id/heartbeat', {
    params: { id: jobId },
    body: { profileId: PROFILE_A, leaseToken: 'f'.repeat(64) },
  });
  assert.equal(stale.status, 409);
  assert.deepEqual(stale.body, { error: 'lease is stale' });
});

test('result endpoint refuses unknown ids and malformed fact arrays', async () => {
  const h = harness({});
  const res404 = await h.call('/ai/jobs/:id/result', {
    params: { id: 'ghost' },
    body: { facts: BILL_FACTS, profileId: PROFILE_A },
  });
  assert.equal(res404.status, 404);

  const res400 = await h.call('/ai/jobs/:id/result', {
    params: { id: 'ghost' },
    body: { facts: 'not-an-array' },
  });
  assert.equal(res400.status, 400);
});

test('result endpoint requires the current lease token and job owner context', async () => {
  const h = harness({});
  const accepted = await h.call('/ai/jobs', {
    userId: PROFILE_A,
    body: { sourceKey: SOURCE_KEY, sender: 'HDFCBK', body: BILL_BODY },
  });
  const lease = await h.call('/ai/jobs/lease', { body: {} });
  assert.equal(lease.status, 200);
  assert.equal(lease.body.job.id, accepted.body.jobId);
  const stale = await h.call('/ai/jobs/:id/result', {
    params: { id: accepted.body.jobId },
    body: { facts: BILL_FACTS, profileId: PROFILE_A, leaseToken: 'old-token' },
  });
  assert.equal(stale.status, 409);
  assert.match(stale.body.error, /lease/);
});

test('valid AI result endpoint completes review-only without invoking projection specialists', async () => {
  for (const facts of [[], BILL_FACTS]) {
    const h = harness({});
    const accepted = await h.call('/ai/jobs', {
      userId: PROFILE_A,
      body: { sourceKey: SOURCE_KEY, sender: 'HDFCBK', body: BILL_BODY },
    });
    const lease = await h.call('/ai/jobs/lease', { body: {} });
    const job = h.state.jobs.get(accepted.body.jobId);
    job.lease_expires_at = new Date(Date.now() + 600000);
    const result = await h.call('/ai/jobs/:id/result', {
      params: { id: job.id },
      body: { profileId: PROFILE_A, leaseToken: lease.body.job.leaseToken, facts },
    });
    assert.equal(result.status, 200);
    assert.equal(job.status, 'done');
    assert.equal(job.result.reviewRequired, true);
    assert.equal(job.result.specialists, null);
    assert.deepEqual(job.payload, { purged: true });
    assert.equal(h.state.events.filter((event) => event.event_type === 'result').length, 1);
  }
});

test('result endpoint carries the computed auto-resolution decision and score', async () => {
  const h = harness({});
  const accepted = await h.call('/ai/jobs', {
    userId: PROFILE_A,
    body: { sourceKey: SOURCE_KEY, sender: 'HDFCBK', body: SWIGGY_BODY },
  });
  const lease = await h.call('/ai/jobs/lease', { body: {} });
  const job = h.state.jobs.get(accepted.body.jobId);
  job.lease_expires_at = new Date(Date.now() + 600000);
  const result = await h.call('/ai/jobs/:id/result', {
    params: { id: job.id },
    body: { profileId: PROFILE_A, leaseToken: lease.body.job.leaseToken, facts: [SWIGGY_FACT] },
  });
  assert.equal(result.status, 200);
  assert.equal(result.body.jobStatus, 'done');
  assert.equal(result.body.reviewRequired, false);
  assert.ok(result.body.confidenceScore >= 0.85);
  assert.equal(job.result.reviewRequired, false);
  assert.equal(job.result.specialists, null);
});

test('source status omits AI facts the user already confirmed or corrected', async () => {
  const h = harness({});
  const body = `${BILL_BODY} Available balance INR 5000 for A/c XX1234.`;
  const accepted = await geminiQueue.acceptOneJob(h.client, PROFILE_A, {
    sourceKey: SOURCE_KEY,
    sender: 'HDFCBK',
    body,
  });
  const job = h.state.jobs.get(accepted.jobId);
  const balanceFact = {
    factType: 'balance_snapshot',
    payload: {
      availableBalanceInr: 5000,
      asOfAt: '2026-10-20T18:30:00.000Z',
      accountLast4: '1234',
      instrument: 'upi_bank',
    },
  };
  await geminiQueue.completeJobWithResult(h.client, {
    job,
    facts: [...BILL_FACTS, balanceFact],
  });
  const source = [...h.state.sources.values()][0];
  const confirmedIndex = [...source.facts.values()].find(
    (fact) => fact.fact_type === 'bill_obligation',
  ).fact_index;
  source.overrides.set(confirmedIndex, { amountDueInr: 3000 });

  const query = h.client.query;
  h.client.query = async (sql, params) => {
    if (sql.replace(/\s+/g, ' ').trim().startsWith(
      'SELECT id, status, result, attempts, created_at, updated_at FROM ai_jobs',
    )) {
      return { rows: [{
        id: job.id,
        status: job.status,
        result: job.result,
        attempts: job.attempts,
        created_at: job.created_at,
        updated_at: job.created_at,
      }] };
    }
    return query(sql, params);
  };

  const response = await h.call('/ai/jobs/source/:sourceKey', {
    userId: PROFILE_A,
    params: { sourceKey: SOURCE_KEY },
  });
  assert.equal(response.status, 200);
  assert.deepEqual(response.body.suggestions.map((fact) => fact.factType), [
    'balance_snapshot',
  ]);
  assert.equal(response.body.suggestions[0].factIndex === confirmedIndex, false);
});

// Phase 6: Admin monitoring & Learning loop

test('admin monitoring endpoints return redacted metrics and timeline without raw body', async () => {
  const h = harness({});
  // Seed a job
  await h.call('/ai/jobs', {
    userId: PROFILE_A,
    body: { sourceKey: SOURCE_KEY, sender: 'HDFCBK', body: BILL_BODY },
  });

  // 1. Summary
  const summaryRes = await h.call('/admin/sms-ai/summary', {});
  assert.equal(summaryRes.status, 200);
  assert.equal(summaryRes.body.statusCounts.queued, 1);
  assert.equal(typeof summaryRes.body.oldestAgeSeconds, 'number');
  assert.equal(summaryRes.body.totalJobsToday, 1);
  assert.equal(summaryRes.body.providerCapacity.requestsPerMinuteLimit, 5);
  assert.equal(summaryRes.body.providerCapacity.requestsPerDayLimit, 20);

  // 2. Jobs list (no raw payload)
  const jobsRes = await h.call('/admin/sms-ai/jobs', { query: {} });
  assert.equal(jobsRes.status, 200);
  assert.equal(jobsRes.body.jobs.length, 1);
  const listed = jobsRes.body.jobs[0];
  assert.equal(listed.sender, 'HDFCBK');
  assert.equal(listed.payload, undefined, 'raw payload must NOT be exposed to admin');

  // 3. Event timeline
  const eventsRes = await h.call('/admin/sms-ai/jobs/:id/events', {
    params: { id: listed.id },
  });
  assert.equal(eventsRes.status, 200);
  assert.ok(eventsRes.body.events.length >= 1);
  assert.equal(eventsRes.body.events[0].event_type, 'accepted');

  // 4. Quota
  const quotaRes = await h.call('/admin/sms-ai/quota', {});
  assert.equal(quotaRes.status, 200);
  assert.ok(quotaRes.body.quota.length >= 1);
});

test('rule lifecycle: new account receives approved pattern, deactivation rolls it back', () => {
  const { parseSmsAgainstPatterns } = require('../src/sms_parser');
  const sampleSms = {
    sender: 'CUSTOMGW',
    body: 'Custom Gateway: Rs.350 paid to Merchant XYZ reference 98765.',
  };

  const pattern = {
    id: 'pat-1',
    channel: 'sms',
    sender_pattern: 'CUSTOMGW',
    regex: 'Custom Gateway: Rs\\.(\\d+) paid to Merchant ([A-Za-z ]+) reference (\\d+)',
    field_map: { amount: 1, merchant: 2, reference: 3 },
    version: 1,
    is_active: true,
  };

  // 1. New account with active pattern parses successfully
  const parsedActive = parseSmsAgainstPatterns([pattern], sampleSms);
  assert.equal(parsedActive.ok, true);
  assert.equal(parsedActive.fields.amountInr, 350);
  assert.equal(parsedActive.fields.merchant, 'XYZ');

  // 2. Bad rule rollback: deactivated pattern (is_active = false) is filtered out
  const activePatterns = [pattern].filter((p) => p.is_active);
  assert.equal(activePatterns.length, 1);

  // Rollback
  pattern.is_active = false;
  const rolledBackPatterns = [pattern].filter((p) => p.is_active);
  assert.equal(rolledBackPatterns.length, 0);

  // Deactivated rule no longer matches; built-in fallback also rejects due to no card marker
  const parsedRollback = parseSmsAgainstPatterns(rolledBackPatterns, sampleSms);
  assert.equal(parsedRollback.ok, false);
});
