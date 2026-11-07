'use strict';
// The phone's own requests after an edit, replayed against the real server routes on a fully migrated PostgreSQL.
//
// contracts/sms/v2/fixtures/phone_replay/requests.json is recorded from the app's own code (pipeline, corrections
// service, upload queue) by app/test/features/sms_v2/sync/phone_replay_fixture_test.dart. Before this test existed the
// app and the server were only tested apart, and a correction on a message the phone never uploads facts for (a
// wallet notice, a fund balance) or on a statement SMS "sent to ab***@gmail.com" was refused for good: the phone kept
// retrying and nothing said why. Every request here must be accepted, with the sharing opt-in on (the strictest case,
// because then the redacted template is checked too).
const test = require('node:test');
const assert = require('node:assert/strict');
const { startLoopHarness, registerAllLoopAdminRoutes, skip } = require('./helpers/loop_harness');
const recording = require('../../../contracts/sms/v2/fixtures/phone_replay/requests.json');

test('every request the phone sends for an edit is accepted by the server', { skip }, async (t) => {
  const rig = await startLoopHarness({ profileCount: recording.scenarios.length, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());

  for (const [index, scenario] of recording.scenarios.entries()) {
    const profile = rig.profiles[index];
    await rig.consent(profile, true);
    const phone = rig.asUser(profile, { verified: true });
    let corrections = 0;
    for (const request of scenario.requests) {
      const answer = await phone.post(request.path, request.body);
      assert.equal(answer.status, 200, `${scenario.name}: ${request.path} -> ${answer.status} ${JSON.stringify(answer.body)}`);
      if (request.path === '/sms/v2/facts:batch') {
        const refused = answer.body.results.filter((r) => r.status !== 'accepted' && r.status !== 'duplicate');
        assert.deepEqual(refused, [], `${scenario.name}: the server refused part of an upload`);
      } else {
        corrections += 1;
        assert.ok(answer.body.caseId, `${scenario.name}: a case id comes back`);
      }
    }
    assert.ok(corrections > 0, `${scenario.name}: the recording holds a correction`);
    const cases = (await rig.pool.query(
      'SELECT count(*)::int AS n, count(template_hash)::int AS templates FROM sms_v2_correction_cases WHERE profile_id=$1', [profile])).rows[0];
    assert.equal(cases.n, corrections, `${scenario.name}: every correction became a case`);
    const sentTemplates = scenario.requests.filter((r) => r.body.redactedTemplate).length;
    assert.equal(cases.templates, sentTemplates, `${scenario.name}: a template that was sent is kept`);
  }
});

test('the statement SMS keeps its template without any address in it', { skip }, () => {
  const statement = recording.scenarios.find((s) => s.name.startsWith('statement_sent_to_hidden_email'));
  const correction = statement.requests.find((r) => r.path === '/sms/v2/corrections').body;
  assert.ok(correction.redactedTemplate, 'the template is shared, not dropped');
  assert.doesNotMatch(correction.redactedTemplate, /@|https?:\/\/|\d/);
});

test('a correction never names a fact the phone does not upload', () => {
  for (const scenario of recording.scenarios) {
    const uploaded = new Set(scenario.requests
      .filter((r) => r.path === '/sms/v2/facts:batch')
      .flatMap((r) => r.body.items.flatMap((item) => item.facts.map((f) => f.factId))));
    for (const request of scenario.requests.filter((r) => r.path === '/sms/v2/corrections')) {
      for (const id of request.body.factIds) {
        assert.ok(uploaded.has(id), `${scenario.name}: fact ${id.slice(0, 8)} was never uploaded`);
      }
    }
  }
});
