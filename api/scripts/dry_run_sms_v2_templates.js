#!/usr/bin/env node
'use strict';
/**
 * Dev only (api/scripts/ is not in the image). Drafts SMS v2 rules for stored,
 * already redacted layouts with the same prompt and checks as the AI worker,
 * and writes nothing to the database. The output file holds layouts and
 * drafts, never message text, so it must live outside the repository.
 *
 * Owner's run against the rig database, with a PAID Gemini key (on the unpaid
 * tier Google may use inputs and human reviewers may read them):
 *
 *   ADMIN_API_DATABASE_URL=<rig admin_api_runtime URL> SMS_V2_JOB_ADMIN_ID=<owner admin_users.id> \
 *   GEMINI_API_KEY=... SMS_V2_AI_MODEL=... SMS_V2_AI_TPM=... \
 *   [SMS_V2_AI_INPUT_USD_PER_MILLION=... SMS_V2_AI_OUTPUT_USD_PER_MILLION=...] \
 *   node api/scripts/dry_run_sms_v2_templates.js --limit 50 --out <scratch dir>/ai-dry-run.json
 *
 * Every stored layout is read, `held` ones included (the rig has no App Check).
 * Rehearsal without a key or any AI call: `--provider fake` (every draft comes
 * back invalid; it checks the database, permissions and output). Fully offline:
 * add `--layouts <file.json>` (an array of {senderBrand, redactedBody}) instead
 * of the database.
 *
 * Evaluation before any prompt or model change (learning-loop B2): `--eval`
 * drafts again every layout whose AI draft the admin approved, with the current
 * prompt, and prints "N of M approved drafts reproduced". A draft is the same
 * when it emits the same fact types and amount roles. With `--layouts`, rows
 * carry the approved rule as `approvedDraft` and no database is used.
 */

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { redactionError } = require('../src/sms_v2/ai_templates');
const {
  workerConfig, buildPrompt, validateDraftSafely, createGeminiTemplateProvider,
} = require('../src/sms_v2/template_worker');

const REPO_ROOT = path.resolve(__dirname, '../..');
const USAGE = 'usage: node api/scripts/dry_run_sms_v2_templates.js --out <file outside the repository> '
  + '[--limit 20] [--provider gemini|fake] [--layouts <file.json>] [--admin-id <admin_users.id>]';

function realish(file) {
  // Resolve symlinks (for example /tmp -> /private/tmp) on the deepest existing parent.
  let dir = path.dirname(path.resolve(file));
  const rest = [path.basename(file)];
  while (!fs.existsSync(dir) && path.dirname(dir) !== dir) {
    rest.unshift(path.basename(dir));
    dir = path.dirname(dir);
  }
  return path.join(fs.realpathSync(dir), ...rest);
}

function parseArgs(argv) {
  const arg = (name) => {
    const i = argv.indexOf(`--${name}`);
    return i >= 0 ? argv[i + 1] : undefined;
  };
  const out = arg('out');
  if (!out) throw new Error(`--out <file outside the repository> is required\n${USAGE}`);
  const resolved = realish(out);
  const root = fs.realpathSync(REPO_ROOT);
  if (resolved === root || resolved.startsWith(root + path.sep)) {
    throw new Error('--out must be outside the repository: the file holds layouts and drafts');
  }
  const limit = Number(arg('limit') ?? '20');
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 200) throw new Error('--limit must be 1 to 200');
  const provider = arg('provider') ?? 'gemini';
  if (!['gemini', 'fake'].includes(provider)) throw new Error('--provider must be gemini or fake');
  return { out: resolved, limit, provider, layouts: arg('layouts'), adminId: arg('admin-id'), evalMode: argv.includes('--eval') };
}

// No network and no key: every draft is empty, so every layout reports errors.
function createFakeProvider() {
  return { async generate() { return { rule: '{}', inputTokens: 0, outputTokens: 0, totalTokens: 0 }; } };
}

const tokens = (value) => (Number.isSafeInteger(value) && value >= 0 ? value : 0);

async function draftOne({ template, examples, provider, config, validate }) {
  const out = { valid: false, errors: [], rule: null, attempts: 0, inputTokens: 0, outputTokens: 0 };
  let errors = [];
  for (let attempt = 1; attempt <= 2 && (attempt === 1 || errors.length); attempt++) {
    let prompt;
    try {
      prompt = buildPrompt(template, examples, errors);
    } catch {
      return { ...out, errors: ['template_redaction_required'] };
    }
    out.attempts = attempt;
    try {
      const response = await provider.generate({ prompt, model: config.model, maxOutputTokens: config.maxOutputTokens });
      const input = tokens(response?.inputTokens);
      out.inputTokens += input;
      out.outputTokens += Math.max(tokens(response?.outputTokens), tokens(response?.totalTokens) - input);
      out.rule = typeof response.rule === 'string' ? JSON.parse(response.rule) : response.rule;
      errors = await validate(out.rule, template, config.model);
    } catch {
      errors = ['provider_or_json_invalid'];
    }
  }
  return { ...out, valid: errors.length === 0, errors };
}

async function dryRun({ templates, examplesFor, provider, config, validate = validateDraftSafely, log = () => {} }) {
  const results = [];
  for (const template of templates) {
    const examples = await examplesFor(template);
    const drafted = await draftOne({ template, examples, provider, config, validate });
    const safe = redactionError(template.redacted_body) === null;
    results.push({
      templateHash: template.template_hash,
      senderBrand: template.sender_brand,
      aiStatus: template.ai_status ?? null,
      redactedBody: safe ? template.redacted_body : null,
      ...drafted,
    });
    // Metadata only on the console.
    log({ sender: template.sender_brand, status: template.ai_status ?? null, valid: drafted.valid, errors: drafted.errors });
  }
  const commonErrors = {};
  for (const r of results) for (const code of r.errors) commonErrors[code] = (commonErrors[code] || 0) + 1;
  const inputTokens = results.reduce((sum, r) => sum + r.inputTokens, 0);
  const outputTokens = results.reduce((sum, r) => sum + r.outputTokens, 0);
  const summary = {
    layouts: results.length,
    valid: results.filter((r) => r.valid).length,
    commonErrors,
    inputTokens,
    outputTokens,
    estimatedCostUsd: config.inputPrice === null || config.outputPrice === null
      ? null : (inputTokens * config.inputPrice + outputTokens * config.outputPrice) / 1e6,
  };
  return { results, summary };
}

// What a draft reads and emits, ignoring wording: the fact types in order, each
// with its amount roles. Two drafts with the same signature are the same draft.
function draftSignature(rule) {
  return JSON.stringify((rule?.emit || []).map((emit) => [emit.factType, (emit.amounts || []).map((a) => a.role).sort()]));
}

// Drafts every approved layout again and compares with the approved draft.
async function evalApproved({ approved, examplesFor, provider, config, validate = validateDraftSafely, log = () => {} }) {
  const results = [];
  for (const row of approved) {
    const template = { template_hash: row.template_hash, sender_brand: row.sender_brand, redacted_body: row.redacted_body };
    const drafted = await draftOne({ template, examples: await examplesFor(template), provider, config, validate });
    const reproduced = drafted.valid && draftSignature(drafted.rule) === draftSignature(row.ai_draft);
    results.push({
      templateHash: template.template_hash, senderBrand: template.sender_brand,
      reproduced, valid: drafted.valid, errors: drafted.errors, attempts: drafted.attempts,
      approvedSignature: draftSignature(row.ai_draft), newSignature: drafted.rule ? draftSignature(drafted.rule) : null,
    });
    log({ sender: template.sender_brand, reproduced, valid: drafted.valid, errors: drafted.errors });
  }
  return { results, summary: { approved: results.length, reproduced: results.filter((r) => r.reproduced).length } };
}

function templateHash(senderBrand, redactedBody) {
  return crypto.createHash('sha256').update(`${senderBrand}\n${redactedBody}`).digest('hex');
}

function loadLayoutsFile(file, limit) {
  const rows = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!Array.isArray(rows)) throw new Error('--layouts must hold a JSON array of {senderBrand, redactedBody}');
  return {
    templates: rows.slice(0, limit).map((row) => {
      const sender = row.senderBrand ?? row.sender_brand;
      const body = row.redactedBody ?? row.redacted_body;
      return {
        template_hash: row.templateHash ?? row.template_hash ?? templateHash(sender, body), sender_brand: sender, redacted_body: body, ai_status: null,
        ...(row.approvedDraft || row.ai_draft ? { ai_draft: row.approvedDraft ?? row.ai_draft } : {}),
      };
    }),
    examples: new Map(),
  };
}

// Reads layouts and example rules in one read-only transaction as the owner,
// then closes the database before any AI call.
async function loadLayoutsFromDb({ env, adminId, limit, PoolClass }) {
  const { openRuleAdminStore } = require('../src/sms_v2/admin_store');
  const { createAdminDbHelpers } = require('../src/admin/server');
  const { pool } = await openRuleAdminStore({ env, ...(PoolClass ? { PoolClass } : {}) });
  try {
    const { withAdminClient } = createAdminDbHelpers(pool);
    return await withAdminClient(adminId, 'learning.read', async (client) => {
      await client.query('SET TRANSACTION READ ONLY');
      const templates = (await client.query(
        `SELECT template_hash, sender_brand, redacted_body, ai_status FROM sms_v2_unknown_templates
          ORDER BY distinct_profiles DESC, seen_count DESC, first_seen, template_hash LIMIT $1`, [limit])).rows;
      const examples = new Map();
      for (const brand of new Set(templates.map((t) => t.sender_brand))) {
        examples.set(brand, (await client.query(
          "SELECT body FROM sms_v2_rules WHERE status='active' AND $1=ANY(senders) ORDER BY rule_id,version DESC LIMIT 5",
          [brand])).rows.map((row) => row.body));
      }
      return { templates, examples };
    });
  } finally {
    await pool.end();
  }
}

// Layouts whose AI draft the admin approved (Create draft), read-only.
async function loadApprovedFromDb({ env, adminId, limit, PoolClass }) {
  const { openRuleAdminStore } = require('../src/sms_v2/admin_store');
  const { createAdminDbHelpers } = require('../src/admin/server');
  const { pool } = await openRuleAdminStore({ env, ...(PoolClass ? { PoolClass } : {}) });
  try {
    const { withAdminClient } = createAdminDbHelpers(pool);
    return await withAdminClient(adminId, 'learning.read', async (client) => {
      await client.query('SET TRANSACTION READ ONLY');
      const approved = (await client.query(
        `SELECT template_hash, sender_brand, redacted_body, ai_draft FROM sms_v2_unknown_templates
          WHERE admin_decision = 'approved' AND ai_draft IS NOT NULL ORDER BY decided_at DESC, template_hash LIMIT $1`, [limit])).rows;
      const examples = new Map();
      for (const brand of new Set(approved.map((t) => t.sender_brand))) {
        examples.set(brand, (await client.query(
          "SELECT body FROM sms_v2_rules WHERE status='active' AND $1=ANY(senders) ORDER BY rule_id,version DESC LIMIT 200",
          [brand])).rows.map((row) => row.body));
      }
      return { approved, examples };
    });
  } finally {
    await pool.end();
  }
}

async function main(argv = process.argv, env = process.env, { log = console.log } = {}) {
  const args = parseArgs(argv);
  const fake = args.provider === 'fake';
  const config = workerConfig(fake
    ? { SMS_V2_AI_TPM: '1000000', ...env, SMS_V2_AI_MODEL: env.SMS_V2_AI_MODEL || 'dry-run-fake' }
    : env);
  const provider = fake ? createFakeProvider() : createGeminiTemplateProvider({ apiKey: env.GEMINI_API_KEY });
  if (args.evalMode) {
    let approved, examples = new Map();
    if (args.layouts) {
      approved = loadLayoutsFile(args.layouts, args.limit).templates.filter((row) => row.ai_draft);
    } else {
      const adminId = args.adminId || env.SMS_V2_JOB_ADMIN_ID;
      if (!adminId) throw new Error('SMS_V2_JOB_ADMIN_ID_required (or --admin-id)');
      ({ approved, examples } = await loadApprovedFromDb({ env, adminId, limit: args.limit }));
    }
    const evaluated = await evalApproved({
      approved, examplesFor: async (template) => examples.get(template.sender_brand) || [], provider, config,
      log: (entry) => log(JSON.stringify(entry)),
    });
    fs.writeFileSync(args.out, JSON.stringify({
      generatedAt: new Date().toISOString(), mode: 'eval', provider: args.provider, model: config.model, summary: evaluated.summary, results: evaluated.results,
    }, null, 2), { mode: 0o600 });
    fs.chmodSync(args.out, 0o600);
    log(`${evaluated.summary.reproduced} of ${evaluated.summary.approved} approved drafts reproduced${fake ? ' (fake provider: no AI call made)' : ''}. Review ${args.out}.`);
    return evaluated;
  }
  let source;
  if (args.layouts) {
    source = loadLayoutsFile(args.layouts, args.limit);
  } else {
    const adminId = args.adminId || env.SMS_V2_JOB_ADMIN_ID;
    if (!adminId) throw new Error('SMS_V2_JOB_ADMIN_ID_required (or --admin-id)');
    source = await loadLayoutsFromDb({ env, adminId, limit: args.limit });
  }
  const { results, summary } = await dryRun({
    templates: source.templates,
    examplesFor: async (template) => source.examples.get(template.sender_brand) || [],
    provider,
    config,
    log: (entry) => log(JSON.stringify(entry)),
  });
  fs.writeFileSync(args.out, JSON.stringify({
    generatedAt: new Date().toISOString(), provider: args.provider, model: config.model, summary, results,
  }, null, 2), { mode: 0o600 });
  fs.chmodSync(args.out, 0o600);
  log(`${summary.valid} of ${summary.layouts} drafts valid${fake ? ' (fake provider: no AI call made)' : ''}. Review ${args.out}.`);
}

if (require.main === module) {
  main().catch((error) => {
    console.error('dry run failed:', error.code || error.message);
    process.exit(1);
  });
}

module.exports = { parseArgs, dryRun, main, createFakeProvider, loadLayoutsFromDb, evalApproved, draftSignature, loadApprovedFromDb };
