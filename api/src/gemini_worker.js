/**
 * Gemini queue worker.
 *
 * The worker is deliberately stateless: it leases one durable job, sends a
 * redacted payload to Gemini, and posts the validated fact set back with the
 * lease token. A provider failure releases the same job with a bounded delay;
 * it never creates a second job or writes a second transaction.
 */

require('dotenv').config();

const crypto = require('crypto');
const DEFAULT_MODEL = process.env.GEMINI_MODEL || 'gemini-3.8-flash';
const DEFAULT_INTERVAL_MS = Number(process.env.AI_WORKER_INTERVAL_MS || 2000);
const DEFAULT_API_BASE_URL = process.env.AI_WORKER_API_BASE_URL || `http://127.0.0.1:${process.env.PORT || 4000}`;
const PROVIDER_TIMEOUT_MS = Math.max(1000, Number(process.env.AI_PROVIDER_TIMEOUT_MS || 20000));
const DEFAULT_BATCH_MAX = Math.min(4, Math.max(1, Number(process.env.AI_WORKER_BATCH_MAX || 4)));
const DEFAULT_BATCH_WINDOW_MS = Math.min(500, Math.max(0, Number(process.env.AI_WORKER_BATCH_WINDOW_MS || 300)));

class GeminiProviderError extends Error {
  constructor(message, { retryable = false, retryAfterMs = undefined, status = undefined } = {}) {
    super(message);
    this.name = 'GeminiProviderError';
    this.retryable = retryable;
    this.retryAfterMs = retryAfterMs;
    this.status = status;
  }
}

function retryAfterMsFromHeaders(headers) {
  const value = headers?.get?.('retry-after');
  if (!value) return undefined;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return Math.max(0, seconds * 1000);
  const date = Date.parse(value);
  return Number.isFinite(date) ? Math.max(0, date - Date.now()) : undefined;
}

function nextAdaptiveBatchSize(current, maximum, outcome) {
  const cap = Math.max(1, Math.min(4, Number(maximum) || 1));
  const size = Math.max(1, Math.min(cap, Number(current) || 1));
  if (outcome?.retried || outcome?.failed) return Math.max(1, Math.floor(size / 2));
  if (outcome?.completed) return Math.min(cap, size + 1);
  return size;
}

function parseModelJson(text) {
  const cleaned = String(text || '')
    .trim()
    .replace(/^```(?:json)?\s*/i, '')
    .replace(/\s*```$/i, '')
    .trim();
  try {
    return JSON.parse(cleaned);
  } catch (error) {
    throw new GeminiProviderError('Gemini returned invalid JSON', { retryable: false });
  }
}

function buildGeminiPrompt(job) {
  const payload = job?.payload || {};
  return [
    'Classify this bank SMS into typed financial facts for a personal finance app.',
    'The message has already been redacted. Never infer or invent missing digits.',
    'Return JSON only in the form {"facts":[...]}; return an empty facts array when uncertain.',
    'Each fact must use the app contract: factType, payload, provenance.',
    'Allowed factType values: posted_movement, pending_or_failed_attempt, balance_snapshot, bill_obligation, bill_payment, mandate_lifecycle, card_identity_hint, security_or_service_alert, promotion.',
    'Amounts must use the correct role: posted, due_total, due_minimum, outstanding, ceiling, or proposed.',
    'Do not treat a bill total, credit limit, or mandate ceiling as a posted movement.',
    `Sender: ${String(payload.sender || '')}`,
    `Occurred at: ${String(payload.occurredAt || '')}`,
    `SMS: ${String(payload.body || '')}`,
  ].join('\n');
}

function buildGeminiBatchPrompt(jobs) {
  return [
    'Classify each SMS independently. Return JSON only: {"items":[{"id":"<id>","facts":[...]}]}.',
    'Return exactly one item per supplied id, even when its facts array is empty.',
    'Never mix an amount, account or date from one item into another item.',
    ...jobs.map((job) => `ITEM ${job.id}\n${buildGeminiPrompt(job)}`),
  ].join('\n\n');
}

function estimateProviderTokens(jobs) {
  const promptChars = buildGeminiBatchPrompt(jobs).length;
  // Include room for the structured response and fixed prompt overhead. The
  // estimate intentionally errs high; the database reservation is a safety
  // gate, not a billing meter.
  return Math.min(20000, Math.max(1, Math.ceil(promptChars / 3) + jobs.length * 512));
}

async function reserveProviderCapacity({ jobs, apiBaseUrl, workerToken, fetchImpl, waitImpl, heartbeat }) {
  const estimatedTokens = estimateProviderTokens(jobs);
  for (;;) {
    const permit = await jsonRequest(fetchImpl, `${apiBaseUrl}/ai/provider/reserve`, workerToken, { estimatedTokens });
    if (permit.allowed === true) return permit;
    if (permit.permanentlyBlocked === true) {
      throw new GeminiProviderError('Provider token window is smaller than this request', { retryable: false });
    }
    const waitMs = Math.max(100, Math.min(60000, Number(permit.waitMs) || 1000));
    if (typeof heartbeat === 'function') await heartbeat(jobs);
    await waitImpl(waitMs);
  }
}

class GeminiProvider {
  constructor({
    apiKey = process.env.GEMINI_API_KEY,
    model = DEFAULT_MODEL,
    fetchImpl = globalThis.fetch,
    endpointBase = 'https://generativelanguage.googleapis.com/v1beta/models',
  } = {}) {
    if (typeof fetchImpl !== 'function') throw new Error('global fetch is required');
    this.apiKey = apiKey;
    this.model = model;
    this.fetchImpl = fetchImpl;
    this.endpointBase = endpointBase.replace(/\/$/, '');
  }

  async classify(job) {
    if (!this.apiKey) {
      throw new GeminiProviderError('GEMINI_API_KEY is not configured', { retryable: false });
    }
    let response;
    try {
      response = await this.fetchImpl(
      `${this.endpointBase}/${encodeURIComponent(this.model)}:generateContent`,
      {
        method: 'POST',
        signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
        headers: { 'content-type': 'application/json', 'x-goog-api-key': this.apiKey },
        body: JSON.stringify({
          contents: [{ role: 'user', parts: [{ text: buildGeminiPrompt(job) }] }],
          generationConfig: {
            responseMimeType: 'application/json',
          },
        }),
      },
      );
    } catch (_) {
      throw new GeminiProviderError('Gemini request failed or timed out', { retryable: true });
    }
    if (!response.ok) {
      let providerError = '';
      try { providerError = JSON.stringify(await response.json()); } catch (_) { /* no body */ }
      const quotaError = response.status === 403 && /quota|resource[_ -]?exhausted|rate.?limit/i.test(providerError);
      const retryable = response.status === 408 || response.status === 409 || response.status === 429 || response.status >= 500 || quotaError;
      const retryAfterMs = retryAfterMsFromHeaders(response.headers)
        ?? (quotaError ? 60 * 60 * 1000 : undefined);
      throw new GeminiProviderError(`Gemini HTTP ${response.status}`, {
        retryable,
        retryAfterMs,
        status: response.status,
      });
    }
    const data = await response.json();
    const text = data?.candidates?.[0]?.content?.parts?.map((part) => part.text || '').join('');
    const parsed = parseModelJson(text);
    if (!parsed || !Array.isArray(parsed.facts)) {
      throw new GeminiProviderError('Gemini response has no facts array', { retryable: false });
    }
    return parsed.facts;
  }

  async classifyBatch(jobs) {
    if (jobs.length === 1) return new Map([[jobs[0].id, await this.classify(jobs[0])]]);
    if (!this.apiKey) throw new GeminiProviderError('GEMINI_API_KEY is not configured');
    let response;
    try {
      response = await this.fetchImpl(
        `${this.endpointBase}/${encodeURIComponent(this.model)}:generateContent`,
        {
          method: 'POST',
          signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
          headers: { 'content-type': 'application/json', 'x-goog-api-key': this.apiKey },
          body: JSON.stringify({
            contents: [{ role: 'user', parts: [{ text: buildGeminiBatchPrompt(jobs) }] }],
            generationConfig: { responseMimeType: 'application/json' },
          }),
        },
      );
    } catch (_) {
      throw new GeminiProviderError('Gemini batch request failed or timed out', { retryable: true });
    }
    if (!response.ok) {
      let providerError = '';
      try { providerError = JSON.stringify(await response.json()); } catch (_) { /* no body */ }
      const quotaError = response.status === 403 && /quota|resource[_ -]?exhausted|rate.?limit/i.test(providerError);
      throw new GeminiProviderError(`Gemini HTTP ${response.status}`, {
        retryable: response.status === 408 || response.status === 409 || response.status === 429 || response.status >= 500 || quotaError,
        retryAfterMs: retryAfterMsFromHeaders(response.headers) ?? (quotaError ? 60 * 60 * 1000 : undefined),
        status: response.status,
      });
    }
    const data = await response.json();
    const parsed = parseModelJson(data?.candidates?.[0]?.content?.parts?.map((part) => part.text || '').join(''));
    if (!Array.isArray(parsed?.items)) throw new GeminiProviderError('Gemini batch has no items array');
    const expected = new Set(jobs.map((job) => job.id));
    const output = new Map();
    for (const item of parsed.items) {
      if (!expected.has(item?.id) || output.has(item.id) || !Array.isArray(item.facts)) {
        throw new GeminiProviderError('Gemini batch has an invalid item');
      }
      output.set(item.id, item.facts);
    }
    return output;
  }
}

async function jsonRequest(fetchImpl, url, token, body) {
  const response = await fetchImpl(url, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body || {}),
  });
  let data = {};
  try { data = await response.json(); } catch (_) { /* empty body */ }
  if (!response.ok) {
    const error = new Error(data.error || `worker endpoint HTTP ${response.status}`);
    error.status = response.status;
    error.retryAfterMs = retryAfterMsFromHeaders(response.headers);
    throw error;
  }
  return data;
}

async function runWorkerOnce({
  apiBaseUrl = DEFAULT_API_BASE_URL,
  workerToken = process.env.AI_WORKER_TOKEN,
  fetchImpl = globalThis.fetch,
  provider = new GeminiProvider(),
  maxBatch = DEFAULT_BATCH_MAX,
  batchWindowMs = DEFAULT_BATCH_WINDOW_MS,
  waitImpl = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  reserveCapacity = null,
} = {}) {
  if (!workerToken) throw new Error('AI_WORKER_TOKEN is not configured');
  if (provider instanceof GeminiProvider && !provider.apiKey) {
    throw new Error('GEMINI_API_KEY is not configured');
  }
  const base = apiBaseUrl.replace(/\/$/, '');
  const lease = await jsonRequest(fetchImpl, `${base}/ai/jobs/lease`, workerToken);
  if (!lease.leased) return { leased: false, ...(lease.abandoned ? { abandoned: lease.abandoned } : {}) };

  const jobs = [lease.job];
  if (typeof provider.classifyBatch === 'function' && maxBatch > 1) {
    if (batchWindowMs > 0) await new Promise((resolve) => setTimeout(resolve, batchWindowMs));
    while (jobs.length < maxBatch) {
      const next = await jsonRequest(fetchImpl, `${base}/ai/jobs/lease`, workerToken);
      if (!next.leased || jobs.some((job) => job.id === next.job.id)) break;
      jobs.push(next.job);
    }
  }
  const batchId = crypto.randomUUID();
  const settleFailure = async (job, error) => {
    if (error?.status === 422) return { jobId: job.id, failed: true };
    const retryable = error?.retryable === true || error?.status === 408 || error?.status === 409 || error?.status === 429 || error?.status >= 500;
    const route = retryable ? 'retry' : 'fail';
    const outcome = await jsonRequest(fetchImpl, `${base}/ai/jobs/${encodeURIComponent(job.id)}/${route}`, workerToken, {
      profileId: job.profileId,
      leaseToken: job.leaseToken,
      ...(retryable ? {
        reason: 'provider_retry',
        ...(Number.isFinite(error.retryAfterMs) ? { retryAfterMs: error.retryAfterMs } : {}),
      } : { reason: error instanceof GeminiProviderError ? 'invalid_provider_output' : 'invalid_result' }),
    });
    return { jobId: job.id, [retryable ? 'retried' : 'failed']: true, outcome };
  };
  try {
    if (typeof reserveCapacity === 'function') {
      await reserveCapacity({ jobs, estimatedTokens: estimateProviderTokens(jobs) });
    } else {
      await reserveProviderCapacity({
        jobs, apiBaseUrl: base, workerToken, fetchImpl, waitImpl,
        heartbeat: async (leasedJobs) => {
          for (const job of leasedJobs) {
            const renewed = await jsonRequest(
              fetchImpl,
              `${base}/ai/jobs/${encodeURIComponent(job.id)}/heartbeat`,
              workerToken,
              { profileId: job.profileId, leaseToken: job.leaseToken },
            );
            if (renewed.renewed !== true) {
              const error = new Error('worker lease heartbeat was refused');
              error.status = 409;
              throw error;
            }
          }
        },
      });
    }
    const byId = jobs.length > 1
      ? await provider.classifyBatch(jobs)
      : new Map([[jobs[0].id, await provider.classify(jobs[0])]]);
    const outcomes = [];
    for (const job of jobs) {
      if (!byId.has(job.id)) {
        outcomes.push(await settleFailure(job, new GeminiProviderError('Gemini omitted batch item')));
        continue;
      }
      try {
        const result = await jsonRequest(fetchImpl, `${base}/ai/jobs/${encodeURIComponent(job.id)}/result`, workerToken, {
          facts: byId.get(job.id), profileId: job.profileId, leaseToken: job.leaseToken,
          batchId, batchSize: jobs.length,
        });
        outcomes.push({ jobId: job.id, completed: true, result });
      } catch (error) {
        outcomes.push(await settleFailure(job, error));
      }
    }
    return { leased: true, completed: outcomes.every((item) => item.completed),
      retried: outcomes.some((item) => item.retried), failed: outcomes.some((item) => item.failed),
      jobId: jobs[0].id, batchSize: jobs.length, outcomes,
      ...(jobs.length === 1 ? { result: outcomes[0].result } : {}) };
  } catch (error) {
    const outcomes = [];
    for (const job of jobs) outcomes.push(await settleFailure(job, error));
    return { leased: true, completed: false, retried: outcomes.some((item) => item.retried),
      failed: outcomes.some((item) => item.failed), jobId: jobs[0].id, batchSize: jobs.length, outcomes };
  }
}

function startWorker(options = {}) {
  const intervalMs = Math.max(250, Number(options.intervalMs || DEFAULT_INTERVAL_MS));
  const configuredMaxBatch = Math.max(1, Math.min(4, Number(options.maxBatch || DEFAULT_BATCH_MAX)));
  let adaptiveBatchSize = 1;
  let stopped = false;
  let timer = null;
  const tick = async () => {
    if (stopped) return;
    try {
      const outcome = await runWorkerOnce({ ...options, maxBatch: adaptiveBatchSize });
      adaptiveBatchSize = nextAdaptiveBatchSize(adaptiveBatchSize, configuredMaxBatch, outcome);
    } catch (error) {
      console.error('Gemini worker tick failed:', error.message || error);
    } finally {
      if (!stopped) timer = setTimeout(tick, intervalMs);
    }
  };
  timer = setTimeout(tick, 0);
  return () => {
    stopped = true;
    if (timer) clearTimeout(timer);
  };
}

if (require.main === module) {
  if (!process.env.AI_WORKER_TOKEN || !process.env.GEMINI_API_KEY) {
    console.error('Gemini worker requires AI_WORKER_TOKEN and GEMINI_API_KEY');
    process.exitCode = 1;
  } else {
    startWorker();
  }
}

module.exports = {
  GeminiProvider,
  GeminiProviderError,
  buildGeminiPrompt,
  buildGeminiBatchPrompt,
  parseModelJson,
  nextAdaptiveBatchSize,
  estimateProviderTokens,
  reserveProviderCapacity,
  runWorkerOnce,
  startWorker,
};
