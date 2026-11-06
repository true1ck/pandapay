'use strict';
// The owner's switch for the friends run: a tester's phone that cannot pass App Check can still be counted.
const test = require('node:test');
const assert = require('node:assert/strict');
const { startLoopHarness, registerAllLoopAdminRoutes, skip } = require('./helpers/loop_harness');
const { clearSettingsCache } = require('../../src/sms_v2/settings');

test('a tester counts only when the setting is on, and nobody else ever does', { skip }, async (t) => {
  const rig = await startLoopHarness({ profileCount: 2, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const [tester, other] = rig.profiles;
  await rig.pool.query('INSERT INTO sms_v2_testers(profile_id) VALUES($1)', [tester]);
  const counts = (profile) => rig.withUserClient(profile, async (client) =>
    (await client.query('SELECT pandapay.sms_v2_tester_counts() AS counts')).rows[0].counts);

  assert.equal(await counts(tester), false, 'off by default');
  const setting = (value) => rig.pool.query(
    `INSERT INTO sms_v2_settings(key,value,updated_by,reason) VALUES('testers_count_without_attestation',$1::jsonb,$2,'test')
     ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = clock_timestamp()`, [JSON.stringify(value), rig.admin]);
  await setting(true);
  clearSettingsCache();
  assert.equal(await counts(tester), true);
  assert.equal(await counts(other), false, 'a profile that is not a tester is never counted');
  await setting(false);
  assert.equal(await counts(tester), false, 'switching it off takes effect at once');

  // The console can read and change it like any other setting.
  const listed = await rig.asAdmin().get('/admin/sms/v2/settings');
  const row = listed.body.settings.find((entry) => entry.key === 'testers_count_without_attestation');
  assert.equal(row.default, false);
  assert.equal(row.type, 'bool');
});
