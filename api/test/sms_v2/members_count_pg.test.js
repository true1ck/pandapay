'use strict';
// The owner's switch to roll AI drafts out to every registered member: with it on, a phone that cannot pass
// App Check still counts, and no list of accounts is needed. Off (the default), nothing changes.
const test = require('node:test');
const assert = require('node:assert/strict');
const { template } = require('./fixtures/template_draft');
const { startLoopHarness, registerAllLoopAdminRoutes, skip } = require('./helpers/loop_harness');
const { clearSettingsCache } = require('../../src/sms_v2/settings');
const { createTemplateStore } = require('../../src/sms_v2/ai_templates');

test('with members_count_without_attestation on, every consenting member counts; off, none does', { skip }, async (t) => {
  const rig = await startLoopHarness({ profileCount: 4, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const [a, b, c, d] = rig.profiles;
  for (const id of [a, b, d]) await rig.consent(id, true);
  const item = {
    templateHash: template.template_hash,
    senderBrand: template.sender_brand,
    redactedBody: template.redacted_body,
    observedAt: new Date().toISOString(),
  };
  const setting = async (value) => {
    await rig.pool.query(
      `INSERT INTO sms_v2_settings(key,value,updated_by,reason) VALUES('members_count_without_attestation',$1::jsonb,$2,'test')
       ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = clock_timestamp()`, [JSON.stringify(value), rig.admin]);
    clearSettingsCache();
  };
  // The decision itself, asked of the database (security.js asks this same function; the API remembers an
  // answer for a minute per account).
  const counts = (profile) => rig.withUserClient(profile, async (client) =>
    (await client.query('SELECT pandapay.sms_v2_tester_counts() AS counts')).rows[0].counts);
  const store = createTemplateStore({ withUserClient: rig.withUserClient });
  // What the API does with an unattested phone: submit with the database's answer.
  const send = async (profile) => store.submit(profile, [item], await counts(profile));
  const state = async () => (await rig.pool.query(
    `SELECT t.ai_status, s.profile_id::text AS profile, s.eligible
       FROM sms_v2_unknown_templates t JOIN sms_v2_template_submitters s USING(template_hash)
      ORDER BY s.profile_id`)).rows;

  // Off by default: an unattested member is held and not counted, exactly as before.
  assert.equal(await counts(a), false);
  assert.equal((await send(a)).length, 1);
  assert.deepEqual((await state()).map((r) => [r.ai_status, r.eligible]), [['held', false]]);

  // On: every member counts, with no list of accounts. Not only the one who already sent something.
  await setting(true);
  for (const member of [a, b, c, d]) assert.equal(await counts(member), true, 'no list: everyone counts');

  // A member whose first contact is after the switch is queued at once.
  assert.equal((await send(b)).length, 1);
  let rows = await state();
  assert.equal(rows.length, 2, 'one shared layout, two submitters');
  assert.equal(rows[0].ai_status, 'queued');
  assert.equal(rows.find((r) => r.profile === b).eligible, true);

  // The layout a sent before is the same shared row, now queued by b. a's own submission is still marked not
  // eligible until a sends it again once counted (the app does this by itself when it sees held layouts while
  // counted); then a is eligible too, and there is still a single layout.
  assert.equal(rows.find((r) => r.profile === a).eligible, false);
  assert.equal((await send(a)).length, 1);
  rows = await state();
  assert.equal(rows.length, 2);
  assert.equal(rows.find((r) => r.profile === a).eligible, true);
  assert.equal((await rig.pool.query('SELECT count(*)::int n FROM sms_v2_unknown_templates')).rows[0].n, 1);

  // Consent still decides: a member who did not agree to share is refused, counted or not.
  await assert.rejects(send(c), { code: '42501' });

  // Off again: the decision goes back to the old rule at once.
  await setting(false);
  for (const member of [a, b, c, d]) assert.equal(await counts(member), false);
});

test('the console lists the setting, off by default', { skip }, async (t) => {
  const rig = await startLoopHarness({ profileCount: 1, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const listed = await rig.asAdmin().get('/admin/sms/v2/settings');
  const row = listed.body.settings.find((entry) => entry.key === 'members_count_without_attestation');
  assert.equal(row.default, false);
  assert.equal(row.type, 'bool');
});
