'use strict';

const CLAIM_SQL = 'SELECT * FROM account_lifecycle.claim_due($1::integer)';
const CHECKPOINT_SQL='SELECT * FROM account_lifecycle.journal_checkpoint($1::boolean)';
const ADVANCE_SQL='SELECT account_lifecycle.advance_journal($1::text,$2::bigint,$3::text,$4::text)';
const FINISH_SQL = 'SELECT account_lifecycle.finish($1::uuid,$2::uuid,$3::boolean) AS acknowledged';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const validJob = job => job && UUID.test(job.request_id) && UUID.test(job.profile_id) && UUID.test(job.lease_token)
  && /^[1-9][0-9]{0,18}$/.test(String(job.generation)) && BigInt(job.generation) <= 9223372036854775807n;

/** One bounded batch, disabled until both source and database release gates are enabled.
 * Each apply is idempotent. A lost acknowledgement is safely retried after lease expiry.
 * No customer rows or backup files are physically removed by this worker.
 */
function createAccountLifecycleWorker({ pool, applyAuthDeletion, enabled = false, logger = console, now = Date.now, journal }) {
  let running = false;
  return async function runOnce() {
    if (!enabled) return { skipped: 'disabled', claimed: 0, completed: 0, failed: 0 };
    if (!pool || typeof pool.query !== 'function' || typeof pool.connect !== 'function' || typeof applyAuthDeletion !== 'function' || !journal?.append || !journal?.inspect) {
      throw new Error('Account lifecycle worker is not configured');
    }
    if (running) return { skipped: 'already_running', claimed: 0, completed: 0, failed: 0 };
    running = true;
    try {
      const started = now();
      const summary = { claimed: 0, completed: 0, failed: 0, deferred: 0 };
      // Claim immediately before each remote operation. Batch-wide leases can
      // expire behind a slow provider, so never hold 25 jobs while processing one.
      for (let index = 0; index < 25 && now() - started < 300_000; index += 1) {
        const client=await pool.connect();let job,discard;
        try {
          await client.query('BEGIN');
          await client.query("SET LOCAL idle_in_transaction_session_timeout='15000ms'");
          const dbCheckpoint=(await client.query(CHECKPOINT_SQL,[true])).rows[0];
          const checkpoint={...dbCheckpoint,sequence:Number(dbCheckpoint?.sequence)};
          const current=await journal.inspect();
          if(checkpoint.journal_id!==current.journal_id||checkpoint.sequence!==current.sequence||checkpoint.head!==current.head)throw Error('Lifecycle journal reconciliation required');
          const result=await client.query(CLAIM_SQL,[1]);
          if(!Array.isArray(result.rows)||result.rows.length>1||!result.rows.every(validJob))throw Error('Invalid lifecycle batch');
          job=result.rows[0];
          if(job){
            const next=await journal.append({request_id:job.request_id,user_id:job.profile_id,generation:String(job.generation)},checkpoint);
            if(next.journal_id!==checkpoint.journal_id||next.sequence!==checkpoint.sequence+1||!/^[a-f0-9]{64}$/.test(next.head))throw Error('Invalid journal acknowledgement');
            await client.query(ADVANCE_SQL,[checkpoint.journal_id,checkpoint.sequence,checkpoint.head,next.head]);
          }
          // External intent is durable before either database can commit
          // account denial. A crash before COMMIT creates a checkpoint mismatch
          // that blocks further work/readiness until quiesced journal replay.
          await client.query('COMMIT');
        }catch(error){try{await client.query('ROLLBACK');}catch(e){discard=e;}throw error;}
        finally{client.release(discard);}
        if(!job)break;
        summary.claimed += 1;
        let success = false;
        try {
          const response = await applyAuthDeletion({ request_id: job.request_id, user_id: job.profile_id, generation: String(job.generation) });
          success = response?.applied === true;
        } catch (_) { /* Fixed diagnostics below never contain account IDs or provider details. */ }
        const ack = await pool.query(FINISH_SQL, [job.request_id, job.lease_token, success]);
        if (success && ack.rows[0]?.acknowledged === true) summary.completed += 1;
        else summary.failed += 1;
      }
      if (summary.failed) logger.warn?.('Account lifecycle retry required');
      return summary;
    } finally { running = false; }
  };
}

function createAuthDeletionClient({ baseUrl, serviceSecret, fetchImpl = globalThis.fetch }) {
  const url = new URL(baseUrl);
  if (url.username || url.password || url.search || url.hash || !['http:', 'https:'].includes(url.protocol)) {
    throw new Error('Invalid auth lifecycle service URL');
  }
  // Deployment networking/TLS uses the same private origin and service secret
  // as current-session verification. It is never a client supplied destination.
  if (typeof serviceSecret !== 'string' || Buffer.byteLength(serviceSecret) < 32 || typeof fetchImpl !== 'function') {
    throw new Error('Auth lifecycle service is not configured');
  }
  const endpoint = new URL('internal/account/deletion/apply', url.href.endsWith('/') ? url : new URL(`${url.href}/`));
  return async job => {
    const response = await fetchImpl(endpoint.href, {
      method: 'POST', headers: { 'content-type': 'application/json', 'x-auth-service-secret': serviceSecret },
      body: JSON.stringify(job), signal: AbortSignal.timeout(4_000), redirect: 'error',
    });
    if (!response.ok) throw new Error('Auth lifecycle unavailable');
    const body = await response.json();
    if (body?.applied !== true) throw new Error('Auth lifecycle acknowledgement invalid');
    return { applied: true };
  };
}

module.exports = { createAccountLifecycleWorker, createAuthDeletionClient, CLAIM_SQL, FINISH_SQL, validJob, CHECKPOINT_SQL, ADVANCE_SQL };
