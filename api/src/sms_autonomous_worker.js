/**
 * Autonomous learning worker for SMS rule synthesis, evaluation, promotion and rollback.
 *
 * Implements Phase 4 (Candidate Synthesis & Scores) and Phase 5 (Autonomous Promotion & Rollback).
 * Idempotent, crash-safe, and ReDoS-protected.
 */

const crypto = require('crypto');
const { compileTemplate } = require('./sms_template_compiler');
const { evaluateCandidate } = require('./sms_evaluator');
const { computeBundleHash } = require('./sms_rule_bundle');

/**
 * Clusters learning examples with >= 5 distinct users, generates candidates using
 * sms_template_compiler, and inserts them into sms_rule_candidates as 'proposed'.
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

    const candidateHash = crypto
      .createHash('sha256')
      .update(`${cluster.sender_fingerprint}:${cluster.fact_family}:${cluster.template_text}`)
      .digest('hex')
      .substring(0, 16);
    const candidateId = `cand_${candidateHash}`;

    const senderPattern = options.senderPattern || (cluster.issuer && cluster.issuer !== 'UNKNOWN' ? cluster.issuer : '.*');
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
 * Advances to 'active' (or 'shadow') on success, or 'rejected' on failure.
 *
 * @param {object} dbClient - PostgreSQL client or pool
 * @param {object} [options]
 * @returns {Promise<{ evaluated: number, passed: number, rejected: number, results: Array }>}
 */
async function evaluateCandidates(dbClient, options = {}) {
  const targetState = options.targetState || 'active';

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
 * Gathers active candidates, builds rule bundle, computes SHA-256 hash,
 * calls pandapay.sms_publish_bundle, and associates candidates with bundle_version.
 *
 * @param {object} dbClient - PostgreSQL client or pool
 * @param {string} [minClientVer='1.0.0']
 * @returns {Promise<{ published: boolean, bundleVersion?: number, sha256?: string, ruleCount?: number, reason?: string }>}
 */
async function publishActiveBundle(dbClient, minClientVer = '1.0.0') {
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

  const verRes = await dbClient.query(
    `SELECT coalesce(max(bundle_version), 0) + 1 AS next_version
       FROM public.sms_rule_bundles`,
  );
  const nextVersion = Number(verRes.rows?.[0]?.next_version) || 1;

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
}

/**
 * Rolls back a regressed bundle version using pandapay.sms_rollback_bundle
 * and updates candidate states to 'rolled_back'.
 *
 * @param {object} dbClient - PostgreSQL client or pool
 * @param {number|string} bundleVersion
 * @returns {Promise<{ rolledBack: boolean, bundleVersion?: number, reason?: string }>}
 */
async function rollbackRegressedBundle(dbClient, bundleVersion) {
  const versionNum = Number.parseInt(bundleVersion, 10);
  if (!Number.isInteger(versionNum) || versionNum < 1) {
    return { rolledBack: false, reason: 'invalid_bundle_version' };
  }

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
            updated_at = now()
      WHERE bundle_version = $1`,
    [versionNum],
  );

  return {
    rolledBack: true,
    bundleVersion: versionNum,
  };
}

module.exports = {
  proposeCandidates,
  evaluateCandidates,
  publishActiveBundle,
  rollbackRegressedBundle,
};
