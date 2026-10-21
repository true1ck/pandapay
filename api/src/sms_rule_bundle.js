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

function registerSmsRuleBundleRoutes(app, { requireAuth, requireAdmin, withUserClient }) {
  // Mobile client syncs active versioned rule bundle
  app.get('/sms/rules/active', requireAuth, async (req, res) => {
    const sinceVersion = Number.parseInt(req.query?.since_version, 10);
    try {
      const result = await withUserClient(req.userId, async (client) => {
        return client.query(
          `SELECT bundle_version, rules, sha256, published_at, min_client_ver
             FROM public.sms_rule_bundles
            WHERE is_active = true
            ORDER BY bundle_version DESC
            LIMIT 1`,
        );
      });
      const row = result.rows?.[0];
      if (!row) {
        // No active bundles: tell device to roll back to version 0
        return res.status(200).json({
          bundleVersion: 0,
          rules: [],
          sha256: '',
          rolledBack: true,
        });
      }

      // If client has exactly this active version, it is up to date
      if (Number.isInteger(sinceVersion) && sinceVersion === row.bundle_version) {
        return res.status(200).json({ upToDate: true, bundleVersion: row.bundle_version });
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
      });
    } catch (error) {
      console.error('GET /sms/rules/active error', error.message || error);
      res.status(500).json({ error: 'failed to fetch active SMS rules' });
    }
  });

  // Admin publishes evaluated, approved rule bundle
  app.post('/admin/sms-rules/publish', requireAdmin, async (req, res) => {
    const { bundleVersion, rules, minClientVersion = '1.0.0' } = req.body || {};
    const versionNum = Number.parseInt(bundleVersion, 10);
    if (!Number.isInteger(versionNum) || versionNum < 1) {
      return res.status(400).json({ error: 'bundleVersion must be a positive integer' });
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
        // Enforce version immutability: cannot overwrite an existing version
        const insertRes = await client.query(
          `INSERT INTO public.sms_rule_bundles
             (bundle_version, rules, sha256, published_by, is_active, min_client_ver)
           VALUES ($1, $2, $3, $4, true, $5)
           ON CONFLICT (bundle_version) DO NOTHING
           RETURNING bundle_version`,
          [versionNum, JSON.stringify(rules), sha256, req.userId, minClientVersion],
        );
        return insertRes.rowCount > 0;
      });

      if (!outcome) {
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
    try {
      const result = await withUserClient(req.userId, async (client) => {
        return client.query(
          `UPDATE public.sms_rule_bundles
              SET is_active = false
            WHERE bundle_version = $1
            RETURNING bundle_version`,
          [versionNum],
        );
      });
      if (result.rowCount === 0) {
        return res.status(404).json({ error: 'bundle version not found' });
      }
      res.status(200).json({ ok: true, rolledBack: true, bundleVersion: versionNum });
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
  registerSmsRuleBundleRoutes,
};
