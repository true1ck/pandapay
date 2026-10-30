/**
 * SMS intelligence Phase 5: durable single-item AI queue logic.
 *
 * Enforced here, not in ad-hoc handlers: one job per (profile, source),
 * acceptance replay-safe before insertion, lease with expiry and a
 * bounded attempt budget, per-item structured validation on the result path,
 * and a payload purge on completion or failure so raw bodies do not linger
 * server-side. AI results only fill fact slots that do not exist yet —
 * device facts and user overrides always outrank the model.
 */

const crypto = require('crypto');

const MAX_LEASE_ATTEMPTS = 6;
const LEASE_MINUTES = 10;

const ADVISORY_WARNING_RE = /\b(?:(?:do\s+not|don\'t|never)\s+share\b[\s\S]{0,60}?\b(?:otp|pin|cvv|password|passcode|details|secret|code)\b|bank\s+never\s+asks\s+for\b[\s\S]{0,60}?\b(?:otp|pin|cvv|password|details))\b[^\n]*/gi;

/** Refusal predicate for the automatic sensitive-field check. */
function payloadLooksSensitive(body) {
  const lower = String(body || '').replace(ADVISORY_WARNING_RE, '').toLowerCase();
  return (
    /\botp\b/.test(lower) ||
    /\bpin\b/.test(lower) ||
    /\bpass(?:word|code)\b/.test(lower) ||
    /\bcvv\b/.test(lower) ||
    /\bm[pn]\b/.test(lower)
  );
}

/** Keep useful amounts/dates while removing high-risk numeric identifiers. */
function redactBodyForAi(body) {
  return String(body || '')
    .replace(/https?:\/\/\S+/gi, '[URL]')
    .replace(/\b[A-Z0-9._%+-]+@[A-Z][A-Z0-9.-]*\b/gi, '[ADDRESS]')
    .replace(/\b(?:ref(?:erence)?|utr|rrn|txn(?: id)?|transaction id)\s*[:#-]?\s*[A-Z0-9-]{6,}\b/gi, '[REFERENCE]')
    // IDs are commonly printed with spaces or hyphens between digit groups.
    // Keep only the suffix while preserving ordinary short amounts and dates.
    .replace(/(?<!\d)(?:\d[ -]?){11,18}\d(?!\d)/g, (value) => {
      const digits = value.replace(/\D/g, '');
      return `XXXX${digits.slice(-4)}`;
    })
    .replace(/\b(iban|ifsc|routing|account|a\/c)\s*[:#-]?\s*([A-Z0-9]{8,})\b/gi,
      (_match, label, identifier) => `${label} XXXX${identifier.slice(-4)}`);
}

/**
 * Accepts one source (or refuses). Order matters: a replayed source returns
 * `reused` before inserts happen, so app retries, provider retries, and
 * double pushes never create a second job for the same source.
 */
async function acceptOneJob(client, profileId, {
  sourceKey, sender, body, occurredAt, retryFailed = false,
}) {
  if (payloadLooksSensitive(body)) {
    return { accepted: false, reason: 'payload_refused_sensitive' };
  }
  const existing = await findJobBySourceKey(
    client,
    profileId,
    sourceKey,
    retryFailed,
  );
  if (existing) {
    if (existing.status === 'failed' && retryFailed) {
      // An explicit device retry reuses the failed row and preserves its id.
      const smsFacts = require('./sms_facts');
      await client.query(
        `UPDATE ai_jobs
            SET status = 'queued', payload = $2, attempts = 0,
                lease_token = NULL, lease_expires_at = NULL,
                next_attempt_at = now(), updated_at = now()
          WHERE id = $1 AND status = 'failed'`,
        [
          existing.id,
          JSON.stringify({
            sender,
            body: redactBodyForAi(body),
            bodyHash: smsFacts.bodyHashOf(sender, body),
            occurredAt,
            kind: 'classify_sms',
          }),
        ],
      );
      await recordEvent(client, existing.id, profileId, 'requeued', {
        reason: 'explicit_device_retry',
      });
      return { accepted: true, jobId: existing.id, reused: false };
    }
    if (existing.status === 'done' && retryFailed &&
        Array.isArray(existing.result?.landed) && existing.result.landed.length === 0 &&
        Array.isArray(existing.result?.factTypes) && existing.result.factTypes.length === 0) {
      // An explicit retry may re-run a completed classification only when it
      // produced no facts. This lets the user retry after a safe abstention
      // while preserving idempotency for successful or partially successful
      // results.
      const smsFacts = require('./sms_facts');
      await client.query(
        `UPDATE ai_jobs
            SET status = 'queued', payload = $2, result = NULL, attempts = 0,
                lease_token = NULL, lease_expires_at = NULL,
                next_attempt_at = now(), updated_at = now()
          WHERE id = $1 AND status = 'done'`,
        [
          existing.id,
          JSON.stringify({
            sender,
            body: redactBodyForAi(body),
            bodyHash: smsFacts.bodyHashOf(sender, body),
            occurredAt,
            kind: 'classify_sms',
          }),
        ],
      );
      await recordEvent(client, existing.id, profileId, 'requeued', {
        reason: 'explicit_device_retry_after_empty_result',
      });
      return { accepted: true, jobId: existing.id, reused: false };
    }
    // A failed row is terminal for this pipeline revision. Silently reopening
    // it resets the worker attempt budget every time the app reconciles and
    // creates an unbounded failed -> queued -> failed loop. Explicit/versioned
    // replay is a separate operator or user action.
    return {
      accepted: existing.status !== 'failed',
      jobId: existing.id,
      reused: true,
      terminal: existing.status === 'failed',
      ...(existing.status === 'failed' ? { reason: 'job_terminal' } : {}),
    };
  }

  const sourceId = await ensureSourceRow(client, profileId, { sourceKey, sender, body });
  const smsFacts = require('./sms_facts');
  const inserted = await client.query(
    `INSERT INTO ai_jobs (profile_id, source_id, source_key, payload, status)
     VALUES ($1, $2, $3, $4, 'queued')
     ON CONFLICT DO NOTHING
     RETURNING id`,
    [
      profileId,
      sourceId,
      sourceKey,
      JSON.stringify({
        sender,
        body: redactBodyForAi(body),
        bodyHash: smsFacts.bodyHashOf(sender, body),
        occurredAt,
        kind: 'classify_sms',
      }),
    ],
  );
  if (inserted.rows.length === 0) {
    // Lost a race against a concurrent accept; the unique index decided.
    const winner = await findJobBySourceKey(client, profileId, sourceKey);
    return { accepted: true, jobId: winner.id, reused: true };
  }
  await recordEvent(client, inserted.rows[0].id, profileId, 'accepted', {});
  return { accepted: true, jobId: inserted.rows[0].id, reused: false };
}

async function findJobBySourceKey(client, profileId, sourceKey, lock = false) {
  const rows = await client.query(
    `SELECT id, status, result FROM ai_jobs WHERE profile_id = $1 AND source_key = $2${lock ? ' FOR UPDATE' : ''}`,
    [profileId, sourceKey],
  );
  return rows.rows[0] || null;
}

async function ensureSourceRow(client, profileId, { sourceKey, sender, body }) {
  const smsFacts = require('./sms_facts');
  const source = await client.query(
    `SELECT id FROM sms_sources WHERE profile_id = $1 AND source_key = $2`,
    [profileId, sourceKey],
  );
  if (source.rows.length > 0) return source.rows[0].id;
  const created = await client.query(
    `INSERT INTO sms_sources (profile_id, source_key, sender, body_hash)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (profile_id, source_key) DO NOTHING
     RETURNING id`,
    [profileId, sourceKey, sender, smsFacts.bodyHashOf(sender, body)],
  );
  if (created.rows.length > 0) return created.rows[0].id;
  const raced = await client.query(
    `SELECT id FROM sms_sources WHERE profile_id = $1 AND source_key = $2`,
    [profileId, sourceKey],
  );
  return raced.rows[0].id;
}

async function recordEvent(client, jobId, profileId, eventType, payload) {
  await client.query(
    `INSERT INTO ai_events (job_id, profile_id, event_type, payload)
     VALUES ($1, $2, $3, $4)`,
    [jobId, profileId, eventType, JSON.stringify(payload || {})],
  );
}

/**
 * Fair lease: oldest queueable job first; an expired lease rejoins the
 * queue, so a crashed or timed-out worker only burns an attempt when the
 * same job is re-claimed — the job identity never changes.
 */
async function leaseNextJob(client, workerToken, now = new Date()) {
  const leaseToken = crypto.randomBytes(32).toString('hex');
  const result = await client.query(
    'SELECT pandapay.ai_claim_next_job($1, $2, $3, $4) AS job',
    [leaseToken, now, LEASE_MINUTES, MAX_LEASE_ATTEMPTS],
  );
  const job = result.rows[0]?.job;
  if (!job || job.abandoned) return { leased: false, ...(job?.abandoned ? { abandoned: job.id } : {}) };
  return {
    leased: true,
    job,
  };
}

/** Extend only a currently live lease owned by this profile and token. */
async function heartbeatJob(client, jobId, profileId, leaseToken, now = new Date()) {
  const result = await client.query(
    `UPDATE ai_jobs
        SET lease_expires_at = $4 + make_interval(mins => $5), updated_at = now()
      WHERE id = $1 AND profile_id = $2 AND status = 'leased'
        AND lease_token = $3 AND lease_expires_at > $4
      RETURNING lease_expires_at`,
    [jobId, profileId, leaseToken, now, LEASE_MINUTES],
  );
  return result.rows[0] ? { renewed: true, leaseExpiresAt: result.rows[0].lease_expires_at } : { renewed: false };
}

/** Provider 429/timeout: back to the queue under the same job identity. */
async function releaseForRetry(client, jobId, profileId, reason, leaseToken, {
  now = new Date(),
  retryAfterMs,
} = {}) {
  const delayMs = Number.isFinite(retryAfterMs)
    ? Math.max(0, Math.min(retryAfterMs, 24 * 60 * 60 * 1000))
    : Math.min(60 * 60 * 1000, 1000 * (2 ** Math.max(0, (await getAttemptCount(client, jobId)) - 1)))
      * (0.5 + Math.random());
  const nextAttemptAt = new Date(now.getTime() + delayMs);
  const updated = await client.query(
    `UPDATE ai_jobs
        SET status = 'queued', lease_token = NULL, lease_expires_at = NULL,
            next_attempt_at = $3, updated_at = now()
      WHERE id = $1 AND status = 'leased' AND lease_token = $2
        AND lease_expires_at > $4
      RETURNING id`,
    [jobId, leaseToken, nextAttemptAt, now],
  );
  if (updated.rowCount === 0) return { released: false };
  await recordEvent(client, jobId, profileId, 'provider_retry', { reason });
  return { released: true, nextAttemptAt, delayMs };
}

async function getAttemptCount(client, jobId) {
  const result = await client.query('SELECT attempts FROM ai_jobs WHERE id = $1', [jobId]);
  return result.rows[0]?.attempts || 1;
}

/**
 * Result landing. Only fact slots that do not exist yet are written, so a
 * model result can never clobber device facts or user corrections; the
 * write rides the Phase 1 upsert, which the override read path governs.
 */
async function completeJobWithResult(client, {
  job,
  decision = null,
  facts,
  batchMetadata = {},
  applySpecialists = null,
  persistSubscriptionMandate = null,
  reviewRequired = null,
}) {
  const smsFacts = require('./sms_facts');
  const aiFactScoring = require('./ai_fact_scoring');
  const payload = job.payload || {};
  // Composite confidence gate: reviewRequired is derived from the model facts
  // and the redacted body. An explicit boolean from the caller still wins
  // (e.g. a replayed job that was already triaged).
  const assessment = aiFactScoring.assessFacts(facts, payload.body || '', payload.occurredAt || null);
  let effectiveReviewRequired = typeof reviewRequired === 'boolean'
    ? reviewRequired
    : assessment.reviewRequired;
  if (decision?.shouldConsider === false) {
    effectiveReviewRequired = false;
  }
  const existing = await smsFacts.loadSmsSourceFacts(client, job.profile_id, job.source_key);
  const existingFacts = existing ? existing.facts : [];
  const semanticParts = (fact) => {
    const value = fact.payload || {};
    return {
      factType: fact.factType,
      amountRole: value.amountRole || null,
      anchor: value.occurredAt || value.dueDate || value.asOfAt || value.proposedAt || null,
      instrument: value.instrument || null,
      account: value.accountLast4 || value.last4 || null,
    };
  };
  const semanticallySame = (left, right) => {
    const a = semanticParts(left);
    const b = semanticParts(right);
    if (a.factType !== b.factType || a.amountRole !== b.amountRole || a.anchor !== b.anchor) return false;
    if (a.instrument && b.instrument && a.instrument !== b.instrument) return false;
    if (a.account && b.account && a.account !== b.account) return false;
    return true;
  };
  const openFacts = smsFacts.assignDeterministicIndices(facts)
    .filter((fact) => !existingFacts.some((existingFact) => semanticallySame(existingFact, fact)));
  const maxExistingIndex = existingFacts.reduce(
    (max, fact) => Math.max(max, Number.isInteger(fact.factIndex) ? fact.factIndex : -1),
    -1,
  );

  let landed = [];
  if (openFacts.length > 0) {
    const upsert = await smsFacts.upsertSmsSourceFacts(client, job.profile_id, {
      sourceKey: job.source_key,
      sender: payload.sender || null,
      bodyHash: payload.bodyHash || smsFacts.bodyHashOf(payload.sender || '', payload.body || ''),
      // Append after the highest existing slot. Using the count is unsafe when
      // a source has a sparse set after a user correction or partial replay.
      indexOffset: maxExistingIndex + 1,
      facts: openFacts.map((fact) => ({
        factType: fact.factType,
        payload: fact.payload,
        provenance: { ...(fact.provenance || {}), channel: 'ai' },
        status: fact.status || 'active',
      })),
    });
    landed = upsert.factIds;
  }

  let specialists = null;
  if (typeof applySpecialists === 'function') {
    specialists = await applySpecialists(client, job.profile_id, { facts }, {
      occurred: job.occurred_at ? new Date(job.occurred_at) : null,
      persistSubscriptionMandate,
    });
  }

  await client.query(
    `UPDATE ai_jobs
        SET status = 'done', result = $2, payload = $3,
            lease_token = NULL, lease_expires_at = NULL, updated_at = now()
      WHERE id = $1`,
    [job.id, JSON.stringify({
      decision: decision || null,
      landed,
      specialists,
      reviewRequired: effectiveReviewRequired,
      confidenceScore: assessment.composite,
      scores: assessment.perFact,
      factTypes: facts.map((fact) => fact.factType),
    }), JSON.stringify({ purged: true })],
  );
  await recordEvent(client, job.id, job.profile_id, 'result', {
    landed: landed.length,
    skippedExisting: facts.length - openFacts.length,
    ...(batchMetadata.batchId ? { batchId: batchMetadata.batchId } : {}),
    ...(Number.isInteger(batchMetadata.batchSize) ? { batchSize: batchMetadata.batchSize } : {}),
  });
  return {
    decision: decision || null,
    landed,
    specialists,
    reviewRequired: effectiveReviewRequired,
    confidenceScore: assessment.composite,
  };
}

/**
 * A failed item is recorded as a redacted event and the server payload is
 * purged. The device already owns the original Needs Review context, so the
 * server must not create a second raw-text copy.
 */
async function failJob(client, jobId, profileId, reason, extra = {}) {
  await recordEvent(client, jobId, profileId, 'failed', { reason, ...extra });
  const updated = await client.query(
    `UPDATE ai_jobs
        SET status = 'failed', payload = $2, lease_token = NULL, lease_expires_at = NULL, updated_at = now()
      WHERE id = $1`,
    [jobId, JSON.stringify({
      purged: true,
      failReason: reason,
      // Validator messages contain field names and contract rules only; never
      // persist model output or SMS text in a failed job's diagnostic.
      ...(Array.isArray(extra.details)
        ? { failureDetails: extra.details.filter((item) => typeof item === 'string').slice(0, 5) }
        : {}),
    })],
  );
  return updated.rowCount > 0;
}

module.exports = {
  MAX_LEASE_ATTEMPTS,
  LEASE_MINUTES,
  payloadLooksSensitive,
  redactBodyForAi,
  acceptOneJob,
  leaseNextJob,
  heartbeatJob,
  releaseForRetry,
  completeJobWithResult,
  failJob,
};
