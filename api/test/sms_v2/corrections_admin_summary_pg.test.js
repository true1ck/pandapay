'use strict';
// The admin's view of corrections: a pattern is ranked by how many DIFFERENT people hit it, with the mix of what
// was wrong, and the answer never carries an account id.
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { startLoopHarness, registerAllLoopAdminRoutes, skip } = require('./helpers/loop_harness');

const skeleton = '<AMT> spent at <W> on <DATE>';
const hash = crypto.createHash('sha256').update('HDFCBK\n' + skeleton).digest('hex');
const correction = (kind, stage, source) => ({
  sourceKey: source, factIds: [], correctionKind: kind,
  corrected: { category: 'dining', _template: { senderBrand: 'HDFCBK', hash, observedAt: '2026-11-01T12:00:00Z' } },
  redactedTemplate: skeleton,
  trace: { appVersion: '1', engineVersion: '2', bundleVersion: 0, ruleId: null, ruleVersion: null, stage },
});

test('the corrections list counts different people, shows what was wrong, and keeps account ids out', { skip }, async (t) => {
  const rig = await startLoopHarness({ profileCount: 5, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const [a, b, c, d, e] = rig.profiles;
  for (const profile of [a, b, c, d]) await rig.consent(profile, true);
  // e never opted in: the case is kept but carries nothing shared.
  const post = (profile, body) => rig.asUser(profile).post('/sms/v2/corrections', body);
  assert.equal((await post(a, correction('wrong_category', 'category', 'src-1'))).status, 200);
  assert.equal((await post(a, correction('wrong_category', 'category', 'src-2'))).status, 200, 'the same person twice');
  assert.equal((await post(b, correction('wrong_category', 'category', 'src-3'))).status, 200);
  assert.equal((await post(c, correction('missing', 'gate', 'src-4'))).status, 200);
  const lone = { ...correction('wrong_category', 'category', 'src-5'), redactedTemplate: undefined, corrected: {} };
  assert.equal((await post(e, lone)).status, 200);
  // One person alone on another pattern.
  const otherSkeleton = 'Paid <AMT> to <W>';
  const otherHash = crypto.createHash('sha256').update('HDFCBK\n' + otherSkeleton).digest('hex');
  const other = correction('wrong_category', 'category', 'src-6');
  other.redactedTemplate = otherSkeleton;
  other.corrected._template.hash = otherHash;
  assert.equal((await post(d, other)).status, 200);

  const answer = await rig.asAdmin().get('/admin/sms/v2/corrections?groupBy=template');
  assert.equal(answer.status, 200);
  const groups = answer.body.groups;
  const top = groups[0];
  assert.equal(top.key, hash, 'the pattern three different people hit comes first');
  assert.equal(top.summary.cases, 4);
  assert.equal(top.summary.distinctUsers, 3, 'two cases from the same person count once');
  assert.deepEqual(top.summary.mix, { wrong_category: 3, missing: 1 });
  assert.equal(groups.find((g) => g.key === otherHash).summary.distinctUsers, 1);
  assert.deepEqual(answer.body.totals.mix, { wrong_category: 5, missing: 1 });
  assert.equal(answer.body.totals.distinctUsers, 5);
  assert.equal(answer.body.totals.sharedCases, 5);
  assert.equal(answer.body.totals.privateCases, 1, 'the one who did not opt in shared nothing');
  assert.ok(!JSON.stringify(answer.body).includes(a), 'no account id in the answer');
});
