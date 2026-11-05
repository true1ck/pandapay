'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { template } = require('./fixtures/template_draft');
const { submitCorrection } = require('../../src/sms_v2/corrections_route');

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const V2 = 'sms-shared-learning-v2';
const V3 = 'sms-shared-learning-v3';

test('opt-in v3 gates layouts and fixes, and revoking scrubs open fixes', { skip: !url }, async () => {
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: url });
  const profile = crypto.randomUUID();
  const withUser = async (operation) => {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL ROLE app_user');
      await client.query("SELECT set_config('app.user_id',$1,true)", [profile]);
      const out = await operation(client);
      await client.query('COMMIT');
      return out;
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  };
  const consent = (version, granted) => pool.query(
    "INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at) VALUES($1,'sms_shared_learning',$2,$3,clock_timestamp())",
    [profile, version, granted]);
  const granted = async () => (await pool.query('SELECT pandapay.sms_shared_learning_granted($1) AS ok', [profile])).rows[0].ok;
  const items = [{
    templateHash: template.template_hash, senderBrand: template.sender_brand,
    redactedBody: template.redacted_body, observedAt: new Date().toISOString(),
  }];
  const submit = () => withUser((client) => client.query(
    'SELECT * FROM pandapay.sms_v2_submit_templates($1::jsonb,true)', [JSON.stringify(items)]));
  const skeleton = 'Rs.<AMT> spent';
  const body = (sourceKey) => ({
    sourceKey, factIds: [], correctionKind: 'missing',
    corrected: { category: 'dining', merchantKey: 'SWIGGY', _template: {
      senderBrand: 'HDFCBK', hash: crypto.createHash('sha256').update('HDFCBK\n' + skeleton).digest('hex'),
      observedAt: '2026-11-01T12:00:00Z' } },
    redactedTemplate: skeleton,
    trace: { appVersion: '1', engineVersion: '2', bundleVersion: 0, ruleId: null, ruleVersion: null, stage: 'gate' },
  });
  try {
    await pool.query('INSERT INTO profiles(id) VALUES($1)', [profile]);
    assert.equal(await granted(), false, 'no record');

    // A v2 opt-in is not an opt-in to the v3 list of shared things.
    await consent(V2, true);
    assert.equal(await granted(), false, 'v2 grant');
    await assert.rejects(submit(), { code: '42501' });
    const v2Case = await withUser((client) => submitCorrection(client, profile, body('sms:v3:v2only'), { sharedLearningEligible: true }));
    const v2Row = (await pool.query('SELECT redacted_template,corrected,shared_learning_eligible FROM sms_v2_correction_cases WHERE case_id=$1', [v2Case.caseId])).rows[0];
    assert.equal(v2Row.redacted_template, null);
    assert.deepEqual(v2Row.corrected, {});
    assert.equal(v2Row.shared_learning_eligible, false);

    await consent(V3, true);
    assert.equal(await granted(), true, 'v3 grant');
    assert.equal((await submit()).rows.length, 1);
    const shared = await withUser((client) => submitCorrection(client, profile, body('sms:v3:granted'), { sharedLearningEligible: true }));
    const open = (await pool.query('SELECT redacted_template,template_hash,sender_brand,corrected,shared_learning_eligible FROM sms_v2_correction_cases WHERE case_id=$1', [shared.caseId])).rows[0];
    assert.equal(open.shared_learning_eligible, true);
    assert.equal(open.corrected.merchantKey, 'SWIGGY');
    assert.ok(open.redacted_template && open.template_hash && open.sender_brand);

    await consent(V3, false);
    assert.equal(await granted(), false, 'revoked');
    const scrubbed = (await pool.query(
      "SELECT redacted_template,template_hash,sender_brand,corrected,shared_learning_eligible FROM sms_v2_correction_cases WHERE profile_id=$1 AND status='open'", [profile])).rows;
    assert.ok(scrubbed.length >= 1);
    for (const row of scrubbed) {
      assert.equal(row.redacted_template, null);
      assert.equal(row.template_hash, null);
      assert.equal(row.sender_brand, null);
      assert.deepEqual(row.corrected, {});
      assert.equal(row.shared_learning_eligible, false);
    }
    // Revoking also removes the profile's layout submissions.
    assert.equal((await pool.query('SELECT 1 FROM sms_v2_template_submitters WHERE profile_id=$1', [profile])).rows.length, 0);
  } finally {
    await pool.query('DELETE FROM profiles WHERE id=$1', [profile]);
    await pool.query('DELETE FROM sms_v2_unknown_templates WHERE template_hash=$1', [template.template_hash]);
    await pool.end();
  }
});
