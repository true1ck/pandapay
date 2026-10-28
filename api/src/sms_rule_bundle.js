/**
 * Versioned, evaluated, and restricted rule bundles for on-device SMS classification.
 *
 * Rules defined here are cross-platform regex rules with strict safety constraints
 * (ReDoS protection, max length, typed family contracts, safe field mapping).
 * Devices download active bundles and execute them on-device before falling back to AI.
 */

const crypto = require('crypto');

const SUPPORTED_FAMILIES = new Set([
  'posted_movement',
  'balance_snapshot',
  'bill_obligation',
  'mandate_lifecycle',
  'ignore_noise',
]);

const ALLOWED_FIELDS = new Set([
  // Posted movement
  'amount', 'amountPaise', 'merchant', 'last4', 'instrument', 'entryKind', 'reference',
  // Balance snapshot
  'availableBalance', 'availableBalancePaise', 'currentBalance', 'accountLast4', 'asOf',
  // Bill obligation
  'amountDue', 'amountDuePaise', 'minimumDue', 'dueDate', 'statementDate', 'billerName',
  // Mandate lifecycle
  'autopayLimit', 'mandateStatus', 'cadenceDays',
]);

const FINANCIAL_KEYWORDS = /\b(?:debited|credited|paid|spent|transferred|withdrawn|received|due date|amount due|available bal|avail bal)\b/i;

function countCaptureGroups(regexStr) {
  try {
    const re = new RegExp(`(?:${regexStr})|^$`);
    const match = ''.match(re);
    return match ? match.length - 1 : 0;
  } catch {
    return -1;
  }
}

function isSafeRegex(pattern) {
  if (typeof pattern !== 'string' || pattern.length > 250 || pattern.length === 0) {
    return false;
  }
  // Reject nested quantifiers like (a+)+, (.*)*, (x+)*
  if (/[+*?]\s*[+*?]/.test(pattern)) return false;
  if (/\([^)]*[+*]\)[+*]/.test(pattern)) return false;
  if (/\(\?:[^)]*[+*]\)[+*]/.test(pattern)) return false;
  // Reject multiple unbounded wildcards
  if (/\.\*.*?\.\*/.test(pattern)) return false;
  try {
    new RegExp(pattern);
    return true;
  } catch {
    return false;
  }
}

function validateRule(rule) {
  if (!rule || typeof rule !== 'object') return { valid: false, reason: 'rule_must_be_object' };
  if (typeof rule.id !== 'string' || !/^[a-zA-Z0-9_-]{3,64}$/.test(rule.id)) {
    return { valid: false, reason: 'invalid_rule_id' };
  }
  if (!SUPPORTED_FAMILIES.has(rule.family)) {
    return { valid: false, reason: `unsupported_family: ${rule.family}` };
  }
  if (typeof rule.senderPattern !== 'string' || rule.senderPattern.trim().length === 0 || rule.senderPattern.length > 100) {
    return { valid: false, reason: 'invalid_sender_pattern' };
  }
  if (!isSafeRegex(rule.regex)) {
    return { valid: false, reason: 'unsafe_or_invalid_regex' };
  }
  const groups = countCaptureGroups(rule.regex);
  if (groups < 0) {
    return { valid: false, reason: 'regex_failed_compilation' };
  }

  // Safety safeguard: ignore_noise must NEVER match financial keywords
  if (rule.family === 'ignore_noise') {
    if (FINANCIAL_KEYWORDS.test(rule.regex)) {
      return { valid: false, reason: 'ignore_noise_cannot_match_financial_keywords' };
    }
  } else {
    if (!rule.fieldMap || typeof rule.fieldMap !== 'object' || Array.isArray(rule.fieldMap)) {
      return { valid: false, reason: 'field_map_must_be_object' };
    }
    const entries = Object.entries(rule.fieldMap);
    if (entries.length === 0) {
      return { valid: false, reason: 'field_map_cannot_be_empty' };
    }
    for (const [field, groupIdx] of entries) {
      if (!ALLOWED_FIELDS.has(field)) {
        return { valid: false, reason: `forbidden_field_mapping: ${field}` };
      }
      if (!Number.isInteger(groupIdx) || groupIdx < 1 || groupIdx > groups) {
        return { valid: false, reason: `invalid_capture_group_index_${groupIdx}_for_${field} (total groups: ${groups})` };
      }
    }
  }

  const confidence = Number(rule.confidence);
  if (Number.isFinite(confidence) && (confidence < 0.5 || confidence > 1.0)) {
    return { valid: false, reason: 'confidence_out_of_range' };
  }

  // If rule includes evaluation cases, verify they pass
  if (Array.isArray(rule.evalCases) && rule.evalCases.length > 0) {
    const re = new RegExp(rule.regex, 'i');
    for (let c = 0; c < rule.evalCases.length; c++) {
      const tc = rule.evalCases[c];
      const matches = re.test(tc.text || '');
      if (matches !== Boolean(tc.expectedMatch)) {
        return {
          valid: false,
          reason: `evaluation_case_${c}_failed: expected match=${tc.expectedMatch}, got ${matches}`,
        };
      }
    }
  }

  return { valid: true };
}

function computeBundleHash({ bundleVersion, rules, minClientVersion = '1.0.0' }) {
  const normalizedRules = (rules || [])
    .map((r) => ({
      id: String(r.id),
      family: String(r.family),
      senderPattern: String(r.senderPattern).trim(),
      regex: String(r.regex),
      fieldMap: r.fieldMap || {},
      defaultFields: r.defaultFields || {},
      confidence: Number(r.confidence) || 0.98,
    }))
    .sort((a, b) => a.id.localeCompare(b.id));

  const canonical = JSON.stringify({
    bundleVersion: Number(bundleVersion) || 1,
    minClientVersion: String(minClientVersion),
    rules: normalizedRules,
  });
  return crypto.createHash('sha256').update(canonical).digest('hex');
}

function cohortBucket(profileId, candidateId) {
  const digest = crypto.createHash('sha256').update(`${profileId}:${candidateId}`).digest('hex');
  return Number.parseInt(digest.slice(0, 8), 16) % 100;
}

function candidateDelivery(row, profileId) {
  const stage = String(row.state);
  const percent = stage === 'limited' ? 5 : stage === 'expanded' ? 20 : stage === 'active' ? 100 : 0;
  const assigned = stage === 'shadow' || stage === 'active' || cohortBucket(profileId, row.candidate_id) < percent;
  if (!assigned) return null;
  const rule = {
    id: row.candidate_id,
    family: row.family,
    senderPattern: row.sender_pattern,
    regex: row.compiled_regex,
    fieldMap: row.field_map || {},
    defaultFields: row.default_fields || {},
    confidence: Number(row.confidence) || 0.98,
  };
  const bundleVersion = Number(row.bundle_version) || 1;
  const minClientVersion = String(row.min_client_ver || '1.0.0');
  const stageVersion = Number.isInteger(Number(row.stage_version)) && Number(row.stage_version) > 0
    ? Number(row.stage_version)
    : 1;
  return {
    candidateId: row.candidate_id,
    stage,
    stageVersion,
    mode: stage === 'shadow' ? 'shadow' : 'apply',
    bundleVersion,
    minClientVersion,
    sha256: computeBundleHash({ bundleVersion, rules: [rule], minClientVersion }),
    rules: [rule],
  };
}

function registerSmsRuleBundleRoutes(app, { requireAuth, requireAdmin, withUserClient }) {
  // Mobile client syncs active versioned rule bundle
  app.get('/sms/rules/active', requireAuth, async (req, res) => {
    const sinceVersion = Number.parseInt(req.query?.since_version, 10);
    try {
      const result = await withUserClient(req.userId, async (client) => {
        const consent = await client.query(
          `SELECT granted
             FROM public.user_consents
            WHERE profile_id = $1 AND purpose = 'sms_shared_learning'
            ORDER BY granted_at DESC, granted ASC, id DESC LIMIT 1`,
          [req.userId],
        );
        const smsLearningConsent = consent.rows?.[0]?.granted === true;
        const active = await client.query(
          `SELECT bundle_version, rules, sha256, published_at, min_client_ver
             FROM public.sms_rule_bundles
            WHERE is_active = true AND published_by IS NOT NULL
            ORDER BY bundle_version DESC
            LIMIT 1`,
        );
        const candidates = await client.query(
          `SELECT c.candidate_id, c.family, c.sender_pattern, c.template, c.compiled_regex,
                  c.field_map, c.default_fields, c.confidence, c.state, c.bundle_version,
                  c.min_client_ver, c.stage_version, a.rule_sha256 AS approved_sha256
             FROM public.sms_rule_candidates c
             JOIN public.sms_parser_candidate_approvals a
               ON a.candidate_id = c.candidate_id AND a.status = 'approved'
            WHERE c.state IN ('shadow', 'limited', 'expanded', 'active')
            ORDER BY candidate_id ASC`,
        );
        // Published generalized parser/category rules can be consumed by all
        // signed-in devices. Consent gates contributions and experiments, not
        // access to already evaluated shared product improvements.
        const categoryResult = await client.query(
          `SELECT merchant_key, category_slug, support_count, agreement_rate
             FROM pandapay.sms_approved_category_rules()
            ORDER BY merchant_key, category_slug`,
        );
        const categoryRules = (categoryResult.rows || []).map((item) => ({
          merchantKey: item.merchant_key,
          categorySlug: item.category_slug,
          supportCount: Number(item.support_count),
          agreementBp: Math.round(Number(item.agreement_rate) * 10000),
        })).sort((a, b) => a.merchantKey.localeCompare(b.merchantKey) ||
          a.categorySlug.localeCompare(b.categorySlug));
        if (!smsLearningConsent) {
          let revokedCandidateIds = candidates.rows.map((row) => row.candidate_id);
          try {
            const issued = await client.query(
              `SELECT DISTINCT candidate_id
                 FROM public.sms_rule_candidate_assignments
                WHERE profile_id = $1`,
              [req.userId],
            );
            revokedCandidateIds = [...new Set([
              ...revokedCandidateIds,
              ...(issued.rows || []).map((row) => row.candidate_id),
            ])];
          } catch (error) {
            console.warn('SMS opt-out candidate revocation lookup unavailable:', error.message || error);
          }
          return {
            active,
            candidateRules: [],
            categoryRules,
            revokedCandidateIds,
          };
        }

        // C9: a shared rule whose negative evidence (current explicit
        // corrections naming the rule) reaches the pause threshold stops being
        // served to NEW users. Profiles that already received the rule keep it
        // — their on-device correction remains the winning local override, and
        // pausing never modifies correction data. The static active bundle is
        // hash-verified by devices, so it is not per-user filtered here.
        let pausedRuleIds = new Set();
        let priorAssignmentIds = new Set();
        try {
          const paused = await client.query(
            'SELECT decision_rule_id FROM pandapay.sms_rule_negative_evidence() WHERE paused',
          );
          pausedRuleIds = new Set((paused.rows || []).map((row) => row.decision_rule_id));
        } catch (error) {
          // Additive migration: during a staggered deploy keep the previous
          // serving behavior instead of withholding every candidate rule.
          console.warn('SMS rule pause lookup unavailable:', error.message || error);
        }
        try {
          const issued = await client.query(
            `SELECT DISTINCT candidate_id
               FROM public.sms_rule_candidate_assignments
              WHERE profile_id = $1`,
            [req.userId],
          );
          priorAssignmentIds = new Set((issued.rows || []).map((row) => row.candidate_id));
        } catch (error) {
          console.warn('SMS prior candidate assignment lookup unavailable:', error.message || error);
        }

        const candidateRules = [];
        for (const row of candidates.rows) {
          const delivery = candidateDelivery(row, req.userId);
          if (!delivery || delivery.sha256 !== row.approved_sha256) continue;
          if (pausedRuleIds.has(row.candidate_id) && !priorAssignmentIds.has(row.candidate_id)) continue;
          let assignment;
          try {
            assignment = await client.query(
              `INSERT INTO public.sms_rule_candidate_assignments
               (candidate_id, profile_id, stage, stage_version, mode,
                bundle_version, min_client_version, rule_sha256)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
             ON CONFLICT (candidate_id, profile_id, stage_version)
             DO UPDATE SET revoked_at = NULL,
                           stage = EXCLUDED.stage,
                           mode = EXCLUDED.mode,
                           bundle_version = EXCLUDED.bundle_version,
                           min_client_version = EXCLUDED.min_client_version,
                           rule_sha256 = EXCLUDED.rule_sha256
             RETURNING assignment_id`,
              [
                delivery.candidateId,
                req.userId,
                delivery.stage,
                delivery.stageVersion,
                delivery.mode,
                delivery.bundleVersion,
                delivery.minClientVersion,
                delivery.sha256,
              ],
            );
          } catch (error) {
            // Roll out the additive migration before the API code. During a
            // staggered deploy, keep the global bundle usable and withhold
            // experimental candidates until assignment storage is ready.
            console.warn('SMS candidate assignment unavailable:', error.message || error);
            continue;
          }
          const assignmentId = assignment.rows?.[0]?.assignment_id;
          if (!assignmentId) continue;
          candidateRules.push({ ...delivery, assignmentId });
        }
        let revokedCandidateIds = [];
        try {
          const issued = await client.query(
            `SELECT DISTINCT candidate_id
               FROM public.sms_rule_candidate_assignments
              WHERE profile_id = $1`,
            [req.userId],
          );
          const deliveredIds = new Set(candidateRules.map((candidate) => candidate.candidateId));
          revokedCandidateIds = (issued.rows || [])
            .map((row) => row.candidate_id)
            .filter((candidateId) => !deliveredIds.has(candidateId));
        } catch (error) {
          // Assignment storage is additive. If it is unavailable, do not
          // guess which cached candidate rules are safe to remove.
          console.warn('SMS candidate revocation lookup unavailable:', error.message || error);
        }
        return { active, candidateRules, categoryRules, revokedCandidateIds };
      });
      const row = result.active.rows?.[0];
      const candidateRules = result.candidateRules || [];
      const categoryRulesVersion = 1;
      const categoryRulesMinClientVersion = '1.0.0';
      const categoryRules = result.categoryRules || [];
      const categoryRulesSha256 = crypto.createHash('sha256')
        .update(JSON.stringify({
          categoryRulesVersion,
          minClientVersion: categoryRulesMinClientVersion,
          categoryRules,
        }))
        .digest('hex');
      if (!row) {
        // No active bundles: tell device to roll back to version 0
        return res.status(200).json({
          bundleVersion: 0,
          rules: [],
          sha256: '',
          rolledBack: true,
          candidateRules,
          categoryRulesVersion,
          categoryRulesMinClientVersion,
          categoryRules,
          categoryRulesSha256,
          revokedCandidateIds: result.revokedCandidateIds || [],
        });
      }

      // If client has exactly this active version, it is up to date
      if (Number.isInteger(sinceVersion) && sinceVersion === row.bundle_version) {
        return res.status(200).json({
          upToDate: true,
          bundleVersion: row.bundle_version,
          candidateRules,
          categoryRulesVersion,
          categoryRulesMinClientVersion,
          categoryRules,
          categoryRulesSha256,
          revokedCandidateIds: result.revokedCandidateIds || [],
        });
      }

      // If client has a version GREATER than active version (meaning its version was rolled back!),
      // or less than active version: send the active bundle and indicate whether a rollback occurred
      res.status(200).json({
        bundleVersion: row.bundle_version,
        rules: row.rules,
        sha256: row.sha256,
        publishedAt: row.published_at,
        minClientVersion: row.min_client_ver,
        rolledBack: Number.isInteger(sinceVersion) && sinceVersion > row.bundle_version,
        candidateRules,
        categoryRulesVersion,
        categoryRulesMinClientVersion,
        categoryRules,
        categoryRulesSha256,
        revokedCandidateIds: result.revokedCandidateIds || [],
      });
    } catch (error) {
      console.error('GET /sms/rules/active error', error.message || error);
      res.status(500).json({ error: 'failed to fetch active SMS rules' });
    }
  });

  // Eligible category rules are proposals until an operator reviews them.
  app.get('/admin/sms-rules/category-proposals', requireAdmin, async (req, res) => {
    try {
      const proposals = await withUserClient(req.userId, async (client) => {
        const result = await client.query(
          `SELECT c.merchant_key, c.category_slug, c.support_count,
                  c.agreement_rate,
                  CASE WHEN a.category_slug = c.category_slug THEN a.status END AS status,
                  CASE WHEN a.category_slug = c.category_slug THEN a.reviewed_at END AS reviewed_at,
                  CASE WHEN a.category_slug = c.category_slug THEN a.reason END AS reason,
                  evidence.redacted_pattern
             FROM pandapay.sms_shared_category_rules() c
             LEFT JOIN public.sms_category_rule_approvals a
               ON a.merchant_key = c.merchant_key
             LEFT JOIN pandapay.sms_admin_category_evidence() evidence
               ON evidence.merchant_key = c.merchant_key
            ORDER BY c.merchant_key, c.category_slug LIMIT 500`,
        );
        return result.rows.map((row) => ({
          ...row,
          origin: 'user_category_corrections',
          evidence_strength: 'multi_user_confirmed',
          proposed_rule: { merchantKey: row.merchant_key, categorySlug: row.category_slug },
        }));
      });
      res.status(200).json({ proposals });
    } catch (error) {
      console.error('GET /admin/sms-rules/category-proposals error', error.message || error);
      res.status(500).json({ error: 'failed to fetch category proposals' });
    }
  });

  app.post('/admin/sms-rules/category-proposals/review', requireAdmin, async (req, res) => {
    const { merchantKey, categorySlug, decision, reason } = req.body || {};
    if (typeof merchantKey !== 'string' || merchantKey.length < 3 || merchantKey.length > 80 ||
        typeof categorySlug !== 'string' || !/^[a-z0-9_-]{1,64}$/.test(categorySlug) ||
        !['approved', 'rejected'].includes(decision) ||
        typeof reason !== 'string' || reason.trim().length < 5 || reason.length > 500) {
      return res.status(400).json({ error: 'invalid review request' });
    }
    try {
      const result = await withUserClient(req.userId, async (client) => {
        await client.query("SELECT pg_advisory_xact_lock(hashtext('sms_category_rule_approval'))");
        const eligible = await client.query(
          `SELECT merchant_key, category_slug, support_count, agreement_rate
             FROM pandapay.sms_shared_category_rules()
            WHERE merchant_key = $1 AND category_slug = $2`,
          [merchantKey, categorySlug],
        );
        const proposal = eligible.rows?.[0];
        if (!proposal) return { stale: true };
        await client.query(
          `INSERT INTO public.sms_category_rule_approvals
             (merchant_key, category_slug, status, reviewed_by, reason,
              support_count_at_review, agreement_rate_at_review)
           VALUES ($1,$2,$3,$4,$5,$6,$7)
           ON CONFLICT (merchant_key) DO UPDATE SET
             category_slug=excluded.category_slug, status=excluded.status,
             reviewed_by=excluded.reviewed_by, reviewed_at=now(),
             reason=excluded.reason,
             support_count_at_review=excluded.support_count_at_review,
             agreement_rate_at_review=excluded.agreement_rate_at_review`,
          [merchantKey, categorySlug, decision, req.userId, reason.trim(),
            proposal.support_count, proposal.agreement_rate],
        );
        await client.query(
          `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, after_value, reason)
           VALUES ($1, 'review_sms_category_rule', 'sms_category_rule_approvals', NULL, $2, $3)`,
          [req.userId, JSON.stringify({ merchantKey, categorySlug, decision,
            supportCount: proposal.support_count, agreementRate: proposal.agreement_rate }), reason.trim()],
        );
        return { stale: false };
      });
      if (result.stale) return res.status(409).json({ error: 'proposal_no_longer_eligible' });
      res.status(200).json({ ok: true, merchantKey, categorySlug, decision });
    } catch (error) {
      console.error('POST /admin/sms-rules/category-proposals/review error', error.message || error);
      res.status(500).json({ error: 'failed to review category proposal' });
    }
  });

  app.get('/admin/sms-rules/parser-proposals', requireAdmin, async (req, res) => {
    try {
      const proposals = await withUserClient(req.userId, async (client) => {
        const rows = await client.query(
          `SELECT c.candidate_id, c.family, c.sender_pattern, c.compiled_regex,
                  c.field_map, c.default_fields, c.confidence, c.state,
                  c.bundle_version, c.min_client_ver, c.stage_version,
                  c.stage_metrics, a.status, a.rule_sha256 AS approved_sha256,
                  a.reviewed_at, a.reason
             FROM public.sms_rule_candidates c
             LEFT JOIN public.sms_parser_candidate_approvals a
               ON a.candidate_id = c.candidate_id
            WHERE c.state IN ('evaluated', 'shadow', 'limited', 'expanded', 'active')
            ORDER BY c.created_at DESC LIMIT 200`,
        );
        return rows.rows.map((row) => ({
          candidateId: row.candidate_id, family: row.family,
          senderPattern: row.sender_pattern, regex: row.compiled_regex,
          fieldMap: row.field_map, defaultFields: row.default_fields,
          confidence: row.confidence, state: row.state,
          redactedPattern: String(row.template || '').replace(/\d+/g, '{n}').slice(0, 250),
          origin: 'learning_examples', evidenceStrength: 'multi_user_candidate',
          proposedRule: { family: row.family, senderPattern: row.sender_pattern,
            regex: row.compiled_regex, fieldMap: row.field_map },
          stageMetrics: row.stage_metrics, status: row.status || 'pending',
          reviewedAt: row.reviewed_at, reason: row.reason,
          currentRuleSha256: candidateDelivery({ ...row, state: 'shadow' }, req.userId)?.sha256,
          approvedSha256: row.approved_sha256,
        }));
      });
      res.status(200).json({ proposals });
    } catch (error) {
      console.error('GET /admin/sms-rules/parser-proposals error', error.message || error);
      res.status(500).json({ error: 'failed to fetch parser proposals' });
    }
  });

  app.post('/admin/sms-rules/parser-proposals/review', requireAdmin, async (req, res) => {
    const { candidateId, decision, reason, ruleSha256 } = req.body || {};
    if (typeof candidateId !== 'string' || candidateId.length < 1 || candidateId.length > 120 ||
        !['approved', 'rejected'].includes(decision) ||
        typeof reason !== 'string' || reason.trim().length < 5 || reason.length > 500 ||
        typeof ruleSha256 !== 'string' || !/^[0-9a-f]{64}$/.test(ruleSha256)) {
      return res.status(400).json({ error: 'invalid review request' });
    }
    try {
      const outcome = await withUserClient(req.userId, async (client) => {
        await client.query("SELECT pg_advisory_xact_lock(hashtext('sms_parser_candidate_approval'))");
        const result = await client.query(
          `SELECT candidate_id, family, sender_pattern, compiled_regex,
                  field_map, default_fields, confidence, state, bundle_version,
                  min_client_ver, stage_version
             FROM public.sms_rule_candidates WHERE candidate_id = $1`,
          [candidateId],
        );
        const row = result.rows?.[0];
        const currentHash = row ? candidateDelivery({ ...row, state: 'shadow' }, req.userId)?.sha256 : null;
        if (!currentHash || currentHash !== ruleSha256) return { stale: true };
        await client.query(
          `INSERT INTO public.sms_parser_candidate_approvals
             (candidate_id, status, reviewed_by, reason, rule_sha256)
           VALUES ($1,$2,$3,$4,$5)
           ON CONFLICT (candidate_id) DO UPDATE SET status=excluded.status,
             reviewed_by=excluded.reviewed_by, reviewed_at=now(),
             reason=excluded.reason, rule_sha256=excluded.rule_sha256`,
          [candidateId, decision, req.userId, reason.trim(), currentHash],
        );
        await client.query(
          `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, after_value, reason)
           VALUES ($1, 'review_sms_parser_candidate', 'sms_parser_candidate_approvals', NULL, $2, $3)`,
          [req.userId, JSON.stringify({ candidateId, decision, ruleSha256: currentHash }), reason.trim()],
        );
        return { stale: false };
      });
      if (outcome.stale) return res.status(409).json({ error: 'proposal_changed' });
      res.status(200).json({ ok: true, candidateId, decision });
    } catch (error) {
      console.error('POST /admin/sms-rules/parser-proposals/review error', error.message || error);
      res.status(500).json({ error: 'failed to review parser proposal' });
    }
  });

  // Admin bundle history. The device endpoint only returns the active bundle;
  // operators need to see what was published, by whom, and which older
  // versions remain active as rollback targets.
  app.get('/admin/sms-rules/bundles', requireAdmin, async (req, res) => {
    const limit = Math.min(Math.max(Number.parseInt(req.query?.limit, 10) || 50, 1), 200);
    try {
      const bundles = await withUserClient(req.userId, async (client) => {
        const result = await client.query(
          `SELECT bundle_version, sha256, is_active, min_client_ver, published_at,
                  jsonb_array_length(rules) AS rule_count
             FROM public.sms_rule_bundles
            ORDER BY bundle_version DESC
            LIMIT $1`,
          [limit],
        );
        return result.rows;
      });
      res.status(200).json({ bundles });
    } catch (error) {
      console.error('GET /admin/sms-rules/bundles error', error.message || error);
      res.status(500).json({ error: 'failed to fetch SMS rule bundles' });
    }
  });

  app.get('/admin/sms-rules/bundles/:bundleVersion', requireAdmin, async (req, res) => {
    const versionNum = Number.parseInt(req.params.bundleVersion, 10);
    if (!Number.isInteger(versionNum) || versionNum < 1) {
      return res.status(400).json({ error: 'bundleVersion must be a positive integer' });
    }
    try {
      const bundle = await withUserClient(req.userId, async (client) => {
        const result = await client.query(
          `SELECT bundle_version, rules, sha256, is_active, min_client_ver, published_at
             FROM public.sms_rule_bundles
            WHERE bundle_version = $1`,
          [versionNum],
        );
        return result.rows[0] || null;
      });
      if (!bundle) return res.status(404).json({ error: 'bundle version not found' });
      res.status(200).json({ bundle });
    } catch (error) {
      console.error('GET /admin/sms-rules/bundles/:bundleVersion error', error.message || error);
      res.status(500).json({ error: 'failed to fetch SMS rule bundle' });
    }
  });

  // Admin publishes evaluated, approved rule bundle
  app.post('/admin/sms-rules/publish', requireAdmin, async (req, res) => {
    const { bundleVersion, rules, minClientVersion = '1.0.0', reason } = req.body || {};
    const versionNum = Number.parseInt(bundleVersion, 10);
    if (!Number.isInteger(versionNum) || versionNum < 1) {
      return res.status(400).json({ error: 'bundleVersion must be a positive integer' });
    }
    if (typeof minClientVersion !== 'string' || minClientVersion.length < 1 || minClientVersion.length > 32) {
      return res.status(400).json({ error: 'minClientVersion must be a short string' });
    }
    if (reason !== undefined && (typeof reason !== 'string' || reason.length > 500)) {
      return res.status(400).json({ error: 'reason must be a short string' });
    }
    if (!Array.isArray(rules) || rules.length === 0) {
      return res.status(400).json({ error: 'rules must be a non-empty array' });
    }

    for (let i = 0; i < rules.length; i++) {
      const validation = validateRule(rules[i]);
      if (!validation.valid) {
        return res.status(400).json({ error: `rule[${i}] invalid: ${validation.reason}` });
      }
    }

    const sha256 = computeBundleHash({ bundleVersion: versionNum, rules, minClientVersion });

    try {
      const outcome = await withUserClient(req.userId, async (client) => {
        // Serialise admin publishes so two operators cannot both pass the
        // version check and then race the INSERT.
        await client.query("SELECT pg_advisory_xact_lock(hashtext('sms_rule_bundle_admin_publish'))");
        const latest = await client.query(
          `SELECT coalesce(max(bundle_version), 0)::int AS version,
                  coalesce(bool_or(bundle_version = $1), false) AS exists
             FROM public.sms_rule_bundles`,
          [versionNum],
        );
        const latestRow = latest.rows?.[0];
        if (latestRow?.exists === true) {
          return { conflict: true };
        }
        if (versionNum <= (latestRow?.version ?? 0)) {
          return { staleVersion: true, currentVersion: latestRow?.version ?? 0 };
        }
        // Enforce version immutability: cannot overwrite an existing version
        const insertRes = await client.query(
          `INSERT INTO public.sms_rule_bundles
             (bundle_version, rules, sha256, published_by, is_active, min_client_ver)
           VALUES ($1, $2, $3, $4, true, $5)
           ON CONFLICT (bundle_version) DO NOTHING
           RETURNING bundle_version`,
          [versionNum, JSON.stringify(rules), sha256, req.userId, minClientVersion],
        );
        if (insertRes.rowCount === 0) return { conflict: true };
        await client.query(
          `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, after_value, reason)
           VALUES ($1, 'publish_sms_rule_bundle', 'sms_rule_bundles', NULL, $2, $3)`,
          [req.userId, JSON.stringify({ bundleVersion: versionNum, sha256, minClientVersion, ruleCount: rules.length }), reason || null],
        );
        return { inserted: true };
      });

      if (outcome.staleVersion) {
        return res.status(409).json({
          error: 'bundle_version_not_newer',
          currentVersion: outcome.currentVersion,
        });
      }
      if (outcome.conflict) {
        return res.status(409).json({ error: 'bundle_version_already_exists' });
      }

      res.status(200).json({ ok: true, bundleVersion: versionNum, sha256 });
    } catch (error) {
      console.error('POST /admin/sms-rules/publish error', error.message || error);
      res.status(500).json({ error: 'failed to publish SMS rule bundle' });
    }
  });

  // Admin rolls back an active bundle version
  app.post('/admin/sms-rules/:bundleVersion/rollback', requireAdmin, async (req, res) => {
    const versionNum = Number.parseInt(req.params.bundleVersion, 10);
    if (!Number.isInteger(versionNum) || versionNum < 1) {
      return res.status(400).json({ error: 'bundleVersion must be a positive integer' });
    }
    const { reason } = req.body || {};
    if (reason !== undefined && (typeof reason !== 'string' || reason.length > 500)) {
      return res.status(400).json({ error: 'reason must be a short string' });
    }
    try {
      const outcome = await withUserClient(req.userId, async (client) => {
        const deactivated = await client.query(
          `UPDATE public.sms_rule_bundles
              SET is_active = false
            WHERE bundle_version = $1 AND is_active = true
            RETURNING bundle_version`,
          [versionNum],
        );
        if (deactivated.rowCount === 0) {
          const exists = await client.query(
            'SELECT is_active FROM public.sms_rule_bundles WHERE bundle_version = $1',
            [versionNum],
          );
          const found = (exists.rowCount ?? exists.rows?.length ?? 0) > 0;
          return { found, alreadyInactive: found };
        }
        // Keep the human-driven rollback consistent with the autonomous
        // worker: rules learned into this bundle must not keep reporting as
        // active once the bundle is withdrawn.
        const candidates = await client.query(
          `UPDATE public.sms_rule_candidates
              SET state = 'rolled_back',
                  stage_version = stage_version + 1,
                  stage_metrics = stage_metrics || jsonb_build_object(
                    'rollback_reason', $2::text, 'rolled_back_at', now()),
                  updated_at = now()
            WHERE bundle_version = $1 AND state <> 'rolled_back'
            RETURNING candidate_id`,
          [versionNum, reason || 'admin_rollback'],
        );
        const nextActive = await client.query(
          `SELECT bundle_version, sha256, min_client_ver, published_at
             FROM public.sms_rule_bundles
            WHERE is_active = true
            ORDER BY bundle_version DESC
            LIMIT 1`,
        );
        await client.query(
          `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
           VALUES ($1, 'rollback_sms_rule_bundle', 'sms_rule_bundles', NULL, $2, $3, $4)`,
          [
            req.userId,
            JSON.stringify({ bundleVersion: versionNum, isActive: true }),
            JSON.stringify({
              bundleVersion: versionNum,
              isActive: false,
              rolledBackCandidates: candidates.rowCount,
              activeBundleVersion: nextActive.rows[0]?.bundle_version ?? null,
            }),
            reason || null,
          ],
        );
        return { rolledBack: true, activeBundle: nextActive.rows[0] || null, rolledBackCandidates: candidates.rowCount };
      });
      if (!outcome.rolledBack) {
        return res.status(outcome.found ? 409 : 404).json({
          error: outcome.found ? 'bundle_already_inactive' : 'bundle version not found',
        });
      }
      res.status(200).json({
        ok: true,
        rolledBack: true,
        bundleVersion: versionNum,
        activeBundle: outcome.activeBundle,
        rolledBackCandidates: outcome.rolledBackCandidates,
      });
    } catch (error) {
      console.error('POST /admin/sms-rules/:bundleVersion/rollback error', error.message || error);
      res.status(500).json({ error: 'failed to rollback SMS rule bundle' });
    }
  });
}

module.exports = {
  SUPPORTED_FAMILIES,
  ALLOWED_FIELDS,
  validateRule,
  computeBundleHash,
  countCaptureGroups,
  isSafeRegex,
  candidateDelivery,
  registerSmsRuleBundleRoutes,
};
