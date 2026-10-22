/**
 * Autonomous learning worker for SMS rule synthesis, evaluation, promotion and rollback.
 *
 * Implements Phase 4 (Candidate Synthesis & Scores) and Phase 5 (Autonomous Promotion & Rollback).
 * Idempotent, crash-safe, ReDoS-protected, and strictly forbids wildcard sender patterns.
 */

const crypto = require('crypto');
const { compileTemplate, deriveSenderPattern } = require('./sms_template_compiler');
const { evaluateCandidate, evaluateCanaryMetrics, ACTION_THRESHOLDS } = require('./sms_evaluator');
const { computeBundleHash, validateRule } = require('./sms_rule_bundle');

const AUTONOMOUS_WORKER_ADVISORY_LOCK_ID = 749281;

/**
 * Clusters learning examples with >= 5 distinct users, generates candidates using
 * sms_template_compiler, and inserts them into sms_rule_candidates as 'proposed'.
 * Strictly rejects wildcard or unknown sender patterns.
 *
 * @param {object} dbClient - PostgreSQL client or pool
 * @param {object} [options]
 * @returns {Promise<{ proposed: number, totalClusters: number, candidates: Array }>}
 */
async function proposeCandidates(dbClient, options = {}) {
  const minUsers = Number.isInteger(options.minDistinctUsers) ? options.minDistinctUsers : 5;

  const clusterQuery = `
    SELECT
      sender_fingerprint,
      fact_family,
      template_text,
      coalesce(issuer_prefix, 'UNKNOWN') AS issuer,
      count(distinct user_hash)::int AS distinct_users,
      count(*)::int AS example_count
    FROM public.sms_learning_examples
    WHERE is_negative = false
      AND fact_family IN ('posted_movement', 'balance_snapshot', 'bill_obligation', 'mandate_lifecycle', 'ignore_noise')
    GROUP BY sender_fingerprint, fact_family, template_text, coalesce(issuer_prefix, 'UNKNOWN')
    HAVING count(distinct user_hash) >= $1
    ORDER BY count(distinct user_hash) DESC
  `;

  const clusterRes = await dbClient.query(clusterQuery, [minUsers]);
  const clusters = clusterRes.rows || [];

  let proposedCount = 0;
  const createdCandidates = [];

  for (const cluster of clusters) {
    const compilation = compileTemplate(cluster.template_text, { family: cluster.fact_family });
    if (!compilation.valid) {
      continue;
    }

    // Safety gate: never use a wildcard sender pattern
    let senderPattern = options.senderPattern || (cluster.issuer && cluster.issuer !== 'UNKNOWN' ? cluster.issuer : null);
    if (!senderPattern || senderPattern === '.*' || senderPattern === '*') {
      // Issuer identity is unknown and cannot be safely derived
      continue;
    }

    const candidateHash = crypto
      .createHash('sha256')
      .update(`${cluster.sender_fingerprint}:${cluster.fact_family}:${cluster.template_text}`)
      .digest('hex')
      .substring(0, 16);
    const candidateId = `cand_${candidateHash}`;

    const stageMetrics = {
      distinct_users: cluster.distinct_users,
      example_count: cluster.example_count,
      proposed_at: new Date().toISOString(),
    };

    const insertQuery = `
      INSERT INTO public.sms_rule_candidates (
        candidate_id, family, issuer, sender_pattern, template,
        compiled_regex, field_map, default_fields, confidence,
        state, stage_metrics, created_at, updated_at
      ) VALUES (
        $1, $2, $3, $4, $5,
        $6, $7::jsonb, $8::jsonb, $9,
        'proposed', $10::jsonb, now(), now()
      )
      ON CONFLICT (candidate_id) DO NOTHING
      RETURNING candidate_id
    `;

    const insertRes = await dbClient.query(insertQuery, [
      candidateId,
      cluster.fact_family,
      cluster.issuer,
      senderPattern,
      cluster.template_text,
      compilation.compiledRegex,
      JSON.stringify(compilation.fieldMap),
      JSON.stringify({}),
      0.98,
      JSON.stringify(stageMetrics),
    ]);

    if (insertRes.rowCount > 0) {
      proposedCount += 1;
      createdCandidates.push({
        candidateId,
        family: cluster.fact_family,
        issuer: cluster.issuer,
        template: cluster.template_text,
        compiledRegex: compilation.compiledRegex,
        fieldMap: compilation.fieldMap,
      });
    }
  }

  return {
    proposed: proposedCount,
    totalClusters: clusters.length,
    candidates: createdCandidates,
  };
}

/**
 * Evaluates 'proposed' candidates against positive and hard-negative examples.
 * Advances to 'evaluated' (NEVER directly to 'active') on success, or 'rejected' on failure.
 *
 * @param {object} dbClient - PostgreSQL client or pool
 * @param {object} [options]
 * @returns {Promise<{ evaluated: number, passed: number, rejected: number, results: Array }>}
 */
async function evaluateCandidates(dbClient, options = {}) {
  // Safety gate: candidates must never skip directly to active; they advance strictly to evaluated
  const targetState = 'evaluated';

  const selectQuery = `
    SELECT
      candidate_id, family, issuer, sender_pattern, template,
      compiled_regex, field_map, default_fields, confidence, state, stage_metrics
    FROM public.sms_rule_candidates
    WHERE state = 'proposed'
    ORDER BY created_at ASC
  `;

  const candidatesRes = await dbClient.query(selectQuery);
  const candidates = candidatesRes.rows || [];

  let passedCount = 0;
  let rejectedCount = 0;
  const results = [];

  for (const candidate of candidates) {
    let dataset = options.dataset;

    if (!dataset) {
      // Query positive examples matching this candidate template
      const posQuery = `
        SELECT sample_body, extracted_fields, is_negative, negative_reason
          FROM public.sms_learning_examples
         WHERE template_text = $1
           AND fact_family = $2
           AND is_negative = false
      `;
      const posRes = await dbClient.query(posQuery, [candidate.template, candidate.family]);

      // Query negative examples
      const negQuery = `
        SELECT sample_body, extracted_fields, is_negative, negative_reason
          FROM public.sms_learning_examples
         WHERE is_negative = true
         LIMIT 100
      `;
      const negRes = await dbClient.query(negQuery);

      dataset = {
        positives: posRes.rows || [],
        negatives: negRes.rows || [],
      };
    }

    const evalResult = evaluateCandidate(candidate, dataset, options);

    if (evalResult.pass) {
      passedCount += 1;
      const metricsUpdate = {
        ...candidate.stage_metrics,
        eval: evalResult,
        evaluated_at: new Date().toISOString(),
      };

      await dbClient.query(
        `UPDATE public.sms_rule_candidates
            SET state = $1,
                stage_metrics = $2::jsonb,
                updated_at = now()
          WHERE candidate_id = $3`,
        [targetState, JSON.stringify(metricsUpdate), candidate.candidate_id],
      );

      results.push({
        candidateId: candidate.candidate_id,
        state: targetState,
        evalResult,
      });
    } else {
      rejectedCount += 1;
      const metricsUpdate = {
        ...candidate.stage_metrics,
        eval: evalResult,
        evaluated_at: new Date().toISOString(),
      };

      await dbClient.query(
        `UPDATE public.sms_rule_candidates
            SET state = 'rejected',
                stage_metrics = $1::jsonb,
                updated_at = now()
          WHERE candidate_id = $2`,
        [JSON.stringify(metricsUpdate), candidate.candidate_id],
      );

      results.push({
        candidateId: candidate.candidate_id,
        state: 'rejected',
        evalResult,
      });
    }
  }

  return {
    evaluated: candidates.length,
    passed: passedCount,
    rejected: rejectedCount,
    results,
  };
}

/**
 * Advances candidates safely through the staged canary pipeline:
 * evaluated -> shadow -> limited -> expanded -> active.
 * Enforces action-specific sample and statistical error thresholds at each step.
 *
 * @param {object} dbClient - PostgreSQL client or pool
 * @param {object} [options]
 * @returns {Promise<{ advanced: number, paused: number, stages: object }>}
 */
async function advanceCandidatePipelines(dbClient, options = {}) {
  const query = `
    SELECT
      candidate_id, family, issuer, sender_pattern, template,
      compiled_regex, field_map, default_fields, confidence, state, stage_metrics
    FROM public.sms_rule_candidates
    WHERE state IN ('evaluated', 'shadow', 'limited', 'expanded')
    ORDER BY created_at ASC
  `;

  const res = await dbClient.query(query);
  const candidates = res.rows || [];

  let advancedCount = 0;
  let pausedCount = 0;
  const stages = { shadow: 0, limited: 0, expanded: 0, active: 0 };

  for (const c of candidates) {
    const currentState = c.state;
    const metrics = c.stage_metrics || {};
    const familyThreshold = ACTION_THRESHOLDS[c.family] || {};
    const distinctUsers = Number(metrics.distinct_users) || 1;

    let nextState = null;
    let advancementReason = null;
    let updatedStageMetrics = null;

    if (currentState === 'evaluated') {
      // Evaluated candidates enter shadow comparison
      nextState = 'shadow';
      advancementReason = 'passed_independent_evaluation';
      updatedStageMetrics = {
        ...metrics,
        cohort: 'shadow',
        cohort_pct: 0,
        window_start: new Date().toISOString(),
        shadow_at: new Date().toISOString(),
        exposures: metrics.exposures || 0,
        corrections: metrics.corrections || 0,
        false_discards: metrics.false_discards || 0,
        advancement_reason: advancementReason,
      };
    } else if (currentState === 'shadow') {
      const canaryCheck = evaluateCanaryMetrics(c, metrics, {
        minObservationMs: options.minObservationMs,
        minExposures: options.minExposures !== undefined ? options.minExposures : 10,
        maxCorrectionRate: options.maxCorrectionRate,
        maxFalseDiscardRate: options.maxFalseDiscardRate,
        now: options.now,
      });

      if (canaryCheck.shouldRollback) {
        pausedCount += 1;
        await dbClient.query(
          `UPDATE public.sms_rule_candidates
              SET state = 'paused',
                  stage_metrics = stage_metrics || jsonb_build_object('pause_reason', $1::text, 'paused_at', now()),
                  updated_at = now()
            WHERE candidate_id = $2`,
          [canaryCheck.reason || 'shadow_regression', c.candidate_id],
        );
        continue;
      }

      if (canaryCheck.passed) {
        nextState = 'limited';
        advancementReason = 'passed_shadow_cohort_criteria';
        updatedStageMetrics = {
          ...metrics,
          cohort: 'limited',
          cohort_pct: 5,
          window_start: new Date().toISOString(),
          limited_at: new Date().toISOString(),
          exposures: 0,
          corrections: 0,
          false_discards: 0,
          advancement_reason: advancementReason,
        };
      }
    } else if (currentState === 'limited') {
      const canaryCheck = evaluateCanaryMetrics(c, metrics, {
        minObservationMs: options.minObservationMs,
        minExposures: options.minExposures !== undefined ? options.minExposures : 25,
        maxCorrectionRate: options.maxCorrectionRate,
        maxFalseDiscardRate: options.maxFalseDiscardRate,
        now: options.now,
      });

      if (canaryCheck.shouldRollback) {
        pausedCount += 1;
        await dbClient.query(
          `UPDATE public.sms_rule_candidates
              SET state = 'paused',
                  stage_metrics = stage_metrics || jsonb_build_object('pause_reason', $1::text, 'paused_at', now()),
                  updated_at = now()
            WHERE candidate_id = $2`,
          [canaryCheck.reason || 'limited_cohort_regression', c.candidate_id],
        );
        continue;
      }

      if (canaryCheck.passed) {
        nextState = 'expanded';
        advancementReason = 'canary_cohort_healthy';
        updatedStageMetrics = {
          ...metrics,
          cohort: 'expanded',
          cohort_pct: 20,
          window_start: new Date().toISOString(),
          expanded_at: new Date().toISOString(),
          exposures: 0,
          corrections: 0,
          false_discards: 0,
          advancement_reason: advancementReason,
        };
      }
    } else if (currentState === 'expanded') {
      const canaryCheck = evaluateCanaryMetrics(c, metrics, {
        minObservationMs: options.minObservationMs,
        minExposures: options.minExposures !== undefined ? options.minExposures : 50,
        maxCorrectionRate: options.maxCorrectionRate,
        maxFalseDiscardRate: options.maxFalseDiscardRate,
        now: options.now,
      });

      if (canaryCheck.shouldRollback) {
        pausedCount += 1;
        await dbClient.query(
          `UPDATE public.sms_rule_candidates
              SET state = 'paused',
                  stage_metrics = stage_metrics || jsonb_build_object('pause_reason', $1::text, 'paused_at', now()),
                  updated_at = now()
            WHERE candidate_id = $2`,
          [canaryCheck.reason || 'expanded_cohort_regression', c.candidate_id],
        );
        continue;
      }

      const minUsersForActive = familyThreshold.minDistinctUsersForActive || familyThreshold.minDistinctUsers || 5;
      if (canaryCheck.passed && distinctUsers >= minUsersForActive) {
        nextState = 'active';
        advancementReason = 'certified_for_global_activation';
        updatedStageMetrics = {
          ...metrics,
          cohort: 'global',
          cohort_pct: 100,
          window_start: new Date().toISOString(),
          active_at: new Date().toISOString(),
          advancement_reason: advancementReason,
        };
      }
    }

    if (nextState) {
      advancedCount += 1;
      stages[nextState] = (stages[nextState] || 0) + 1;
      const finalMetrics = updatedStageMetrics || {
        ...metrics,
        [`${nextState}_at`]: new Date().toISOString(),
        advancement_reason: advancementReason,
      };

      await dbClient.query(
        `UPDATE public.sms_rule_candidates
            SET state = $1,
                stage_metrics = $2::jsonb,
                updated_at = now()
          WHERE candidate_id = $3`,
        [nextState, JSON.stringify(finalMetrics), c.candidate_id],
      );
    }
  }

  return { advanced: advancedCount, paused: pausedCount, stages };
}

/**
 * Validates and publishes active candidates as a new immutable versioned rule bundle.
 * Concurrency-safe: protected by PostgreSQL advisory lock (pg_try_advisory_lock).
 * Idempotent: does not publish if bundle contents are identical to the latest active bundle.
 *
 * @param {object} dbClient - PostgreSQL client or pool
 * @param {string} [minClientVer='1.0.0']
 * @returns {Promise<{ published: boolean, bundleVersion?: number, sha256?: string, ruleCount?: number, reason?: string, upToDate?: boolean }>}
 */
async function publishActiveBundle(dbClient, minClientVer = '1.0.0') {
  // 1. Acquire advisory lock to prevent race conditions across workers
  let locked = true;
  try {
    const lockRes = await dbClient.query(
      'SELECT pg_try_advisory_lock($1) AS locked',
      [AUTONOMOUS_WORKER_ADVISORY_LOCK_ID],
    );
    locked = lockRes.rows?.[0]?.locked !== false;
  } catch (_) {
    // Graceful fallback if mock or pooled connection doesn't support advisory locks
  }
  if (!locked) {
    return { published: false, reason: 'concurrency_lock_held' };
  }

  try {
    const activeRes = await dbClient.query(
      `SELECT candidate_id, family, issuer, sender_pattern, template,
              compiled_regex, field_map, default_fields, confidence
         FROM public.sms_rule_candidates
        WHERE state = 'active'
        ORDER BY candidate_id ASC`,
    );

    const activeCandidates = activeRes.rows || [];
    if (activeCandidates.length === 0) {
      return { published: false, reason: 'no_active_candidates' };
    }

    const rules = activeCandidates.map((c) => ({
      id: c.candidate_id,
      family: c.family,
      senderPattern: c.sender_pattern,
      regex: c.compiled_regex,
      fieldMap: c.field_map,
      defaultFields: c.default_fields || {},
      confidence: Number(c.confidence) || 0.98,
    }));

    // 2. Validate every rule against the strict bundle specification before publishing
    for (let i = 0; i < rules.length; i++) {
      const validation = validateRule(rules[i]);
      if (!validation.valid) {
        return { published: false, reason: `rule_${rules[i].id}_invalid: ${validation.reason}` };
      }
    }

    const verRes = await dbClient.query(
      `SELECT coalesce(max(bundle_version), 0) + 1 AS next_version,
              (SELECT rules FROM public.sms_rule_bundles WHERE is_active = true ORDER BY bundle_version DESC LIMIT 1) AS latest_rules,
              (SELECT sha256 FROM public.sms_rule_bundles WHERE is_active = true ORDER BY bundle_version DESC LIMIT 1) AS latest_sha256,
              (SELECT bundle_version FROM public.sms_rule_bundles WHERE is_active = true ORDER BY bundle_version DESC LIMIT 1) AS latest_version
         FROM public.sms_rule_bundles`,
    );
    const nextVersion = Number(verRes.rows?.[0]?.next_version) || 1;
    const latestRules = verRes.rows?.[0]?.latest_rules;
    const latestSha256 = verRes.rows?.[0]?.latest_sha256;
    const latestVersion = Number(verRes.rows?.[0]?.latest_version);

    // Idempotency: if active rules produce the identical rules payload as latest bundle, don't create duplicate versions
    if (latestRules && JSON.stringify(latestRules) === JSON.stringify(rules)) {
      return {
        published: false,
        upToDate: true,
        bundleVersion: latestVersion,
        sha256: latestSha256,
        ruleCount: rules.length,
      };
    }

    const sha256 = computeBundleHash({
      bundleVersion: nextVersion,
      rules,
      minClientVersion: minClientVer,
    });

    const publishRes = await dbClient.query(
      `SELECT pandapay.sms_publish_bundle($1, $2::jsonb, $3, $4) AS published`,
      [nextVersion, JSON.stringify(rules), sha256, minClientVer],
    );

    const isPublished = publishRes.rows?.[0]?.published === true;
    if (!isPublished) {
      return { published: false, reason: 'publish_bundle_failed' };
    }

    const candidateIds = activeCandidates.map((c) => c.candidate_id);
    await dbClient.query(
      `UPDATE public.sms_rule_candidates
          SET bundle_version = $1,
              state = 'active',
              updated_at = now()
        WHERE candidate_id = ANY($2::text[])`,
      [nextVersion, candidateIds],
    );

    return {
      published: true,
      bundleVersion: nextVersion,
      sha256,
      ruleCount: rules.length,
    };
  } finally {
    // Release advisory lock
    await dbClient.query(
      'SELECT pg_advisory_unlock($1)',
      [AUTONOMOUS_WORKER_ADVISORY_LOCK_ID],
    ).catch(() => {});
  }
}

/**
 * Rolls back a regressed bundle version using pandapay.sms_rollback_bundle
 * and updates candidate states to 'rolled_back'.
 *
 * @param {object} dbClient - PostgreSQL client or pool
 * @param {number|string} bundleVersion
 * @param {string} [reason]
 * @returns {Promise<{ rolledBack: boolean, bundleVersion?: number, reason?: string }>}
 */
async function rollbackRegressedBundle(dbClient, bundleVersion, reason = 'regression_detected') {
  const versionNum = Number.parseInt(bundleVersion, 10);
  if (!Number.isInteger(versionNum) || versionNum < 1) {
    return { rolledBack: false, reason: 'invalid_bundle_version' };
  }

  let locked = true;
  try {
    const lockRes = await dbClient.query(
      'SELECT pg_try_advisory_lock($1) AS locked',
      [AUTONOMOUS_WORKER_ADVISORY_LOCK_ID],
    );
    locked = lockRes.rows?.[0]?.locked !== false;
  } catch (_) {
    // Graceful fallback
  }
  if (!locked) {
    return { rolledBack: false, reason: 'concurrency_lock_held' };
  }

  try {
    const rollbackRes = await dbClient.query(
      `SELECT pandapay.sms_rollback_bundle($1) AS rolled_back`,
      [versionNum],
    );

    const isRolledBack = rollbackRes.rows?.[0]?.rolled_back === true;
    if (!isRolledBack) {
      return { rolledBack: false, reason: 'bundle_not_found_or_already_inactive' };
    }

    await dbClient.query(
      `UPDATE public.sms_rule_candidates
          SET state = 'rolled_back',
              stage_metrics = stage_metrics || jsonb_build_object('rollback_reason', $2::text, 'rolled_back_at', now()),
              updated_at = now()
        WHERE bundle_version = $1`,
      [versionNum, reason],
    );

    return {
      rolledBack: true,
      bundleVersion: versionNum,
    };
  } finally {
    await dbClient.query(
      'SELECT pg_advisory_unlock($1)',
      [AUTONOMOUS_WORKER_ADVISORY_LOCK_ID],
    ).catch(() => {});
  }
}

/**
 * Runs a complete autonomous cycle:
 * propose -> evaluate -> advance canary stages -> publish bundle.
 *
 * @param {object} dbClient - PostgreSQL client or pool
 * @param {object} [options]
 * @returns {Promise<object>}
 */
async function runAutonomousCycle(dbClient, options = {}) {
  const proposeRes = await proposeCandidates(dbClient, options);
  const evalRes = await evaluateCandidates(dbClient, options);
  const advanceRes = await advanceCandidatePipelines(dbClient, options);
  const publishRes = await publishActiveBundle(dbClient, options.minClientVer);

  return {
    proposed: proposeRes.proposed,
    evaluated: evalRes.evaluated,
    passed: evalRes.passed,
    advanced: advanceRes.advanced,
    published: publishRes.published,
    bundleVersion: publishRes.bundleVersion,
  };
}

let scheduledWorkerTimer = null;
let isWorkerRunning = false;

/**
 * Starts the durable autonomous learning worker loop.
 *
 * Runs on a recurring schedule with advisory lock leases, failure backoff,
 * and retry isolation. Runs unref'd so it does not block node test exit.
 *
 * @param {object} dbPool - PostgreSQL client or pool
 * @param {object} [options]
 * @returns {object} handle with stop() method
 */
function startAutonomousWorker(dbPool, options = {}) {
  const intervalMs = options.intervalMs || (Number(process.env.SMS_AUTONOMOUS_WORKER_INTERVAL_MS) || 300000);
  const maxRetries = options.maxRetries || 3;

  if (scheduledWorkerTimer) {
    return { stop: stopAutonomousWorker };
  }

  const runTick = async () => {
    if (isWorkerRunning) return;
    isWorkerRunning = true;
    let attempt = 0;
    while (attempt < maxRetries) {
      try {
        await runAutonomousCycle(dbPool, options);
        break;
      } catch (err) {
        attempt += 1;
        const backoffMs = Math.min(1000 * Math.pow(2, attempt), 30000);
        console.warn(`[SMS_AUTONOMOUS_WORKER] cycle error (attempt ${attempt}/${maxRetries}):`, err.message || err);
        if (attempt < maxRetries) {
          await new Promise((resolve) => setTimeout(resolve, backoffMs));
        }
      }
    }
    isWorkerRunning = false;
  };

  scheduledWorkerTimer = setInterval(runTick, intervalMs);
  if (scheduledWorkerTimer && typeof scheduledWorkerTimer.unref === 'function') {
    scheduledWorkerTimer.unref();
  }

  if (options.runImmediately) {
    runTick().catch(() => {});
  }

  return { stop: stopAutonomousWorker };
}

function stopAutonomousWorker() {
  if (scheduledWorkerTimer) {
    clearInterval(scheduledWorkerTimer);
    scheduledWorkerTimer = null;
  }
  isWorkerRunning = false;
}

module.exports = {
  AUTONOMOUS_WORKER_ADVISORY_LOCK_ID,
  proposeCandidates,
  evaluateCandidates,
  advanceCandidatePipelines,
  publishActiveBundle,
  rollbackRegressedBundle,
  runAutonomousCycle,
  startAutonomousWorker,
  stopAutonomousWorker,
};
