'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { installLegacySupersede } = require('../../src/sms_v2/legacy_supersede');
test('legacy supersede composes before existing hooks and preserves transaction failures', async () => {
  const calls = [];
  const client = { query: async (_sql, args) => { calls.push(['supersede', args]); return { rowCount: 2 }; } };
  const event = { eventId: 'synthetic', legs: [{ factId: 'synthetic', role: 'debit_leg' }] };
  const hooks = { afterEventsStored: async (c,p,events) => { assert.equal(c,client); calls.push(['existing',p,events]); } };
  installLegacySupersede(hooks);
  await hooks.afterEventsStored(client,'profile',[event]);
  assert.deepEqual(calls.map(x=>x[0]), ['supersede','existing']);
  assert.equal(calls[0][1][0], 'profile');
  assert.deepEqual(JSON.parse(calls[0][1][1]), [{ event_id: 'synthetic', legs: event.legs }]);
  const failing = { afterEventsStored: async () => { throw new Error('existing hook failed'); } };
  installLegacySupersede(failing);
  await assert.rejects(failing.afterEventsStored(client,'profile',[event]), /existing hook failed/);
});
