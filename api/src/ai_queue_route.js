/**
 * SMS intelligence Phase 5: HTTP surface for the durable AI queue.
 *
 * Three actors, three guards:
 * - the app posts ONE source per /ai/jobs call (single-key gate); acceptance
 *   is replay-safe per (profile, source) and quota-gated per user per day;
 * - the worker (bearer token via AI_WORKER_TOKEN; routes are disabled when
 *   the env var is unset) leases one job at a time and posts per-item
 *   validated results; the device-owned Needs Review item remains the user
 *   fallback when a job fails;
 * - every result write derives its target from the JOB ROW, never from the
 *   request body, so no caller can redirect one user's facts onto another
 *   user's source.
 */

const geminiQueue = require('./gemini_queue');
const smsFacts = require('./sms_facts');
const smsObservationMigration = require('./sms_observation_migration');
const crypto = require('crypto');
const { verifyModelFacts } = require('./ai_fact_evidence');
const { providerLimits } = require('./ai_provider_quota_route');

function leaseTokenMatches(expected, supplied) {
  if (typeof expected !== 'string' || typeof supplied !== 'string') return false;
  const expectedBytes = Buffer.from(expected);
  const suppliedBytes = Buffer.from(supplied);
  return expectedBytes.length === suppliedBytes.length &&
    crypto.timingSafeEqual(expectedBytes, suppliedBytes);
}

function workerAuthEnabled() {
  return typeof process.env.AI_WORKER_TOKEN === 'string' && process.env.AI_WORKER_TOKEN.length > 0;
}

function requireWorkerAuth(req, res, next) {
  if (!workerAuthEnabled()) {
    return res.status(503).json({ error: 'ai worker routes disabled' });
  }
  const header = req.headers['authorization'] || '';
  const token = header.startsWith('Bearer ') ? header.slice('Bearer '.length) : '';
  // The worker secret is a long-lived credential. Use the same constant-time
  // comparison as per-job lease tokens so a remote caller cannot use response
  // timing to learn a valid token prefix.
  if (!leaseTokenMatches(process.env.AI_WORKER_TOKEN, token)) {
    return res.status(401).json({ error: 'worker token required' });
  }
  req.workerToken = `worker:${token.slice(0, 8)}`;
  next();
}

function registerAiQueueRoutes(app, {
  requireAuth,
  requireAdmin = requireAuth,
  withUserClient,
}) {
  async function aiQueueEnabled(client, profileId) {
    if (process.env.ENABLE_SMS_AI_QUEUE === 'true' || process.env.ENABLE_SMS_AI_QUEUE === '1') {
      return true;
    }
    const rows = await client.query(
      `SELECT key, is_enabled, rollout_percent
         FROM feature_flags
        WHERE key IN ('sms_facts_pipeline_enabled', 'sms_ai_queue_enabled')`,
    );
    return smsObservationMigration.resolveSmsIntelligenceFlags(rows.rows || [], profileId).aiQueueEnabled;
  }

  app.post('/ai/jobs', requireAuth, async (req, res) => {
    // Do not retain a user's redacted message when there is no configured
    // worker that can consume the durable queue. A missing worker credential
    // is a deployment/configuration state, not a transient job failure.
    if (!workerAuthEnabled()) {
      return res.status(503).json({ error: 'ai_queue_disabled' });
    }
    const { sourceKey, sender, body, occurredAt } = req.body || {};
    if (typeof sourceKey !== 'string' || !/^[0-9a-f]{64}$/.test(sourceKey)) {
      return res.status(400).json({ error: 'sourceKey must be a hex sha256' });
    }
    if (typeof sender !== 'string' || sender.length < 2 || sender.length > 40) {
      return res.status(400).json({ error: 'sender must be 2-40 chars' });
    }
    if (typeof body !== 'string' || body.length === 0 || body.length > 900) {
      return res.status(400).json({ error: 'body must be a non-empty message under 900 chars' });
    }
    try {
      const outcome = await withUserClient(req.userId, async (client) => {
        if (!(await aiQueueEnabled(client, req.userId))) {
          return { accepted: false, reason: 'ai_queue_disabled' };
        }
        return geminiQueue.acceptOneJob(client, req.userId, { sourceKey, sender, body, occurredAt });
      });
      if (!outcome.accepted) {
        const status = outcome.reason === 'daily_quota_exhausted' ? 429
          : outcome.reason === 'ai_queue_disabled' ? 503 : 400;
        return res.status(status).json({ error: outcome.reason });
      }
      res.status(200).json({ jobId: outcome.jobId, reused: outcome.reused === true });
    } catch (error) {
      console.error('POST /ai/jobs error', error.message || error);
      res.status(500).json({ error: 'ai job accept failed' });
    }
  });

  // Device reconciliation/status polling is keyed by the original source,
  // never by a caller-supplied job owner. The response excludes payloads and
  // lease credentials so it is safe for the signed-in device to inspect.
  app.get('/ai/jobs/source/:sourceKey', requireAuth, async (req, res) => {
    if (typeof req.params.sourceKey !== 'string' || !/^[0-9a-f]{64}$/.test(req.params.sourceKey)) {
      return res.status(400).json({ error: 'sourceKey must be a hex sha256' });
    }
    try {
      const job = await withUserClient(req.userId, async (client) => {
        const rows = await client.query(
          `SELECT id, status, result, attempts, created_at, updated_at
             FROM ai_jobs WHERE profile_id = $1 AND source_key = $2`,
          [req.userId, req.params.sourceKey],
        );
        const found = rows.rows[0];
        if (!found) return null;
        const source = found.status === 'done'
          ? await smsFacts.loadSmsSourceFacts(client, req.userId, req.params.sourceKey)
          : null;
        const suggestions = (source?.facts || [])
          .filter((fact) => fact.status === 'active' && fact.provenance?.channel === 'ai' && fact.overridden !== true)
          .map((fact) => ({
            factIndex: fact.factIndex,
            factType: fact.factType,
            payload: fact.payload,
          }));
        return { ...found, decision: found.result?.decision || null, suggestions };
      });
      if (!job) return res.status(404).json({ error: 'unknown source' });
      res.status(200).json({
        jobId: job.id,
        status: job.status,
        decision: job.decision || null,
        result: job.result || null,
        // Only validated structured facts, scoped to the authenticated owner.
        // The raw SMS and model prompt have already been purged from the job.
        suggestions: job.suggestions,
        attempts: job.attempts,
        createdAt: job.created_at,
        updatedAt: job.updated_at,
      });
    } catch (error) {
      console.error('GET /ai/jobs/source/:sourceKey error', error.message || error);
      res.status(500).json({ error: 'ai job status failed' });
    }
  });

  app.post('/ai/jobs/lease', requireWorkerAuth, async (req, res) => {
    try {
      const outcome = await withUserClient(null, (client) =>
        geminiQueue.leaseNextJob(client, req.workerToken),
      );
      res.status(200).json(outcome);
    } catch (error) {
      console.error('POST /ai/jobs/lease error', error.message || error);
      res.status(500).json({ error: 'lease failed' });
    }
  });

  // Capacity waits can outlast a worker's original lease. Renew only the
  // exact live lease, under the owning profile's RLS context; stale workers
  // cannot revive or extend a lease that another replica has reclaimed.
  app.post('/ai/jobs/:id/heartbeat', requireWorkerAuth, async (req, res) => {
    const { profileId, leaseToken } = req.body || {};
    if (typeof req.params.id !== 'string' || !/^[0-9a-f-]{36}$/i.test(req.params.id) ||
        typeof profileId !== 'string' || !/^[0-9a-f-]{36}$/i.test(profileId) ||
        typeof leaseToken !== 'string' || !/^[0-9a-f]{64}$/i.test(leaseToken)) {
      return res.status(400).json({ error: 'valid job, profile, and lease identifiers are required' });
    }
    try {
      const outcome = await withUserClient(profileId, (client) =>
        geminiQueue.heartbeatJob(client, req.params.id, profileId, leaseToken),
      );
      if (!outcome.renewed) return res.status(409).json({ error: 'lease is stale' });
      return res.status(200).json({ renewed: true, leaseExpiresAt: outcome.leaseExpiresAt });
    } catch (error) {
      console.error('POST /ai/jobs/:id/heartbeat error', error.message || error);
      return res.status(500).json({ error: 'lease heartbeat failed' });
    }
  });

  app.post('/ai/jobs/:id/result', requireWorkerAuth, async (req, res) => {
    const { decision, facts, leaseToken, profileId, batchId, batchSize } = req.body || {};
    if (!Array.isArray(facts) || facts.length > 20) {
      return res.status(400).json({ error: 'facts must be an array (max 20)' });
    }
    if (typeof profileId !== 'string' || !/^[0-9a-f-]{36}$/i.test(profileId)) {
      return res.status(400).json({ error: 'profileId from the leased job is required' });
    }
    try {
      const outcome = await withUserClient(profileId, async (client) => {
        const job = await fetchJobRow(client, req.params.id);
        if (!job) return { status: 404, error: 'unknown job' };
        if (job.status !== 'leased') {
          return { status: 409, error: `job is ${job.status}, not leased` };
        }
        if (!leaseTokenMatches(job.lease_token, leaseToken) || new Date(job.lease_expires_at) <= new Date()) {
          return { status: 409, error: 'lease is stale or belongs to another worker' };
        }
        const validation = smsFacts.validateFactSet(facts);
        if (!validation.valid) {
          await geminiQueue.failJob(client, job.id, job.profile_id, 'invalid_result_facts', {
            details: validation.errors.slice(0, 5),
          });
          return { status: 422, error: 'result facts refused', details: validation.errors };
        }
        const evidence = verifyModelFacts(facts, job.payload);
        if (!evidence.valid) {
          await geminiQueue.failJob(client, job.id, job.profile_id, 'unverified_result', {
            details: evidence.errors.slice(0, 5),
          });
          return { status: 422, error: 'result lacks SMS evidence', details: evidence.errors };
        }
        const completion = await geminiQueue.completeJobWithResult(client, {
          job,
          decision: decision || null,
          facts,
          batchMetadata: {
            ...(typeof batchId === 'string' && /^[0-9a-f-]{36}$/i.test(batchId) ? { batchId } : {}),
            ...(Number.isInteger(batchSize) && batchSize >= 1 && batchSize <= 4 ? { batchSize } : {}),
          },
          // AI output remains a review suggestion unless the composite score
          // gate is fully satisfied. Only device facts and explicit user
          // corrections may invoke the domain specialists.
        });
        return {
          status: 200,
          jobStatus: 'done',
          decision: completion.decision || null,
          reviewRequired: completion.reviewRequired,
          confidenceScore: completion.confidenceScore,
        };
      });
      res.status(outcome.status).json(outcome);
    } catch (error) {
      console.error('POST /ai/jobs/:id/result error', error.message || error);
      res.status(500).json({ error: 'result write failed' });
    }
  });

  app.post('/ai/jobs/:id/retry', requireWorkerAuth, async (req, res) => {
    const { reason, leaseToken, retryAfterMs, profileId } = req.body || {};
    if (typeof profileId !== 'string' || !/^[0-9a-f-]{36}$/i.test(profileId)) {
      return res.status(400).json({ error: 'profileId from the leased job is required' });
    }
    try {
      const outcome = await withUserClient(profileId, async (client) => {
        const job = await fetchJobRow(client, req.params.id);
        if (!job) return { status: 404, error: 'unknown job' };
        if (job.status !== 'leased') {
          return { status: 409, error: `job is ${job.status}, not leased` };
        }
        if (!leaseTokenMatches(job.lease_token, leaseToken)) {
          return { status: 409, error: 'lease belongs to another worker' };
        }
        const released = await geminiQueue.releaseForRetry(
          client,
          job.id,
          job.profile_id,
          String(reason || '429'),
          leaseToken,
          { retryAfterMs },
        );
        return released.released
          ? { status: 200, jobStatus: 'queued', nextAttemptAt: released.nextAttemptAt }
          : { status: 409, error: 'lease expired before retry was recorded' };
      });
      res.status(outcome.status).json(outcome);
    } catch (error) {
      console.error('POST /ai/jobs/:id/retry error', error.message || error);
      res.status(500).json({ error: 'retry release failed' });
    }
  });

  // Terminal provider failures must release the lease immediately. Otherwise
  // malformed output is retried only after lease expiry on every worker tick.
  app.post('/ai/jobs/:id/fail', requireWorkerAuth, async (req, res) => {
    const { profileId, leaseToken, reason } = req.body || {};
    if (typeof profileId !== 'string' || !/^[0-9a-f-]{36}$/i.test(profileId)) {
      return res.status(400).json({ error: 'profileId from the leased job is required' });
    }
    try {
      const outcome = await withUserClient(profileId, async (client) => {
        const job = await fetchJobRow(client, req.params.id);
        if (!job) return { status: 404, error: 'unknown job' };
        if (job.status !== 'leased' || !leaseTokenMatches(job.lease_token, leaseToken) ||
            new Date(job.lease_expires_at) <= new Date()) {
          return { status: 409, error: 'lease is stale' };
        }
        const safeReason = /^[a-z_]{1,64}$/.test(reason || '') ? reason : 'provider_failure';
        await geminiQueue.failJob(client, job.id, job.profile_id, safeReason);
        return { status: 200, jobStatus: 'failed' };
      });
      res.status(outcome.status).json(outcome);
    } catch (error) {
      console.error('POST /ai/jobs/:id/fail error', error.message || error);
      res.status(500).json({ error: 'failure write failed' });
    }
  });

  // ---- SMS AI admin monitoring endpoints -----------------------------------

  app.get('/admin/sms-ai/summary', requireAdmin, async (req, res) => {
    try {
      const summary = await withUserClient(req.userId, async (client) => {
        const { requestsPerMinute, tokensPerMinute, requestsPerDay } = providerLimits();
        const [result, capacity] = await Promise.all([
          client.query('SELECT pandapay.ai_admin_summary() AS summary'),
          client.query(
            'SELECT pandapay.ai_provider_admin_summary($1, $2, $3) AS provider_capacity',
            [requestsPerMinute, tokensPerMinute, requestsPerDay],
          ),
        ]);
        return { ...result.rows[0].summary, providerCapacity: capacity.rows[0].provider_capacity };
      });
      res.status(200).json(summary);
    } catch (error) {
      console.error('GET /admin/sms-ai/summary error', error.message || error);
      res.status(500).json({ error: 'failed to fetch summary' });
    }
  });

  app.get('/admin/sms-ai/jobs', requireAdmin, async (req, res) => {
    const { status, limit = 50 } = req.query || {};
    const rowLimit = Math.min(Math.max(parseInt(limit, 10) || 50, 1), 200);
    try {
      const jobs = await withUserClient(req.userId, async (client) => {
        const rows = await client.query('SELECT pandapay.ai_admin_jobs($1, $2) AS jobs', [status || null, rowLimit]);
        return rows.rows[0].jobs;
      });
      res.status(200).json({ jobs });
    } catch (error) {
      console.error('GET /admin/sms-ai/jobs error', error.message || error);
      res.status(500).json({ error: 'failed to fetch jobs' });
    }
  });

  app.get('/admin/sms-ai/jobs/:id/events', requireAdmin, async (req, res) => {
    try {
      const events = await withUserClient(req.userId, async (client) => {
        const rows = await client.query('SELECT pandapay.ai_admin_events($1::uuid) AS events', [req.params.id]);
        return rows.rows[0].events;
      });
      res.status(200).json({ events });
    } catch (error) {
      console.error('GET /admin/sms-ai/jobs/:id/events error', error.message || error);
      res.status(500).json({ error: 'failed to fetch events' });
    }
  });

  app.get('/admin/sms-ai/quota', requireAdmin, async (req, res) => {
    try {
      const quota = await withUserClient(req.userId, async (client) => {
        const rows = await client.query('SELECT pandapay.ai_admin_quota() AS quota');
        return rows.rows[0].quota;
      });
      res.status(200).json({ quota });
    } catch (error) {
      console.error('GET /admin/sms-ai/quota error', error.message || error);
      res.status(500).json({ error: 'failed to fetch quota' });
    }
  });

  app.post('/admin/sms-ai/dry-run', requireAdmin, async (req, res) => {
    const { observations } = req.body || {};
    if (!Array.isArray(observations)) {
      return res.status(400).json({ error: 'observations must be an array' });
    }
    try {
      const report = smsObservationMigration.dryRunObservations(observations);
      res.status(200).json({ report });
    } catch (error) {
      console.error('POST /admin/sms-ai/dry-run error', error.message || error);
      res.status(500).json({ error: 'failed to run dry-run' });
    }
  });

  app.get('/admin/sms-ai/rollout', requireAdmin, async (req, res) => {
    try {
      const config = await withUserClient(req.userId, async (client) => {
        const rows = await client.query(
          `SELECT key, is_enabled, rollout_percent, min_app_version, platforms
             FROM feature_flags
            WHERE key LIKE 'sms_%'`,
        );
        return smsObservationMigration.resolveSmsIntelligenceFlags(rows.rows || []);
      });
      res.status(200).json({ rollout: config });
    } catch (error) {
      console.error('GET /admin/sms-ai/rollout error', error.message || error);
      res.status(500).json({ error: 'failed to fetch rollout' });
    }
  });
}

async function fetchJobRow(client, jobId) {
  const rows = await client.query(
    `SELECT id, profile_id, source_key, status, payload, lease_token, lease_expires_at,
            attempts FROM ai_jobs WHERE id = $1 FOR UPDATE`,
    [jobId],
  );
  return rows.rows[0] || null;
}

module.exports = { registerAiQueueRoutes, requireWorkerAuth, workerAuthEnabled, leaseTokenMatches };
