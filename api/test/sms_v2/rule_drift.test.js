'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { compare } = require('../../scripts/sms_v2_rule_drift');

const rule = (id, pattern, extra = {}) => ({ id, version: 1, status: 'active', priority: 100, confidence: 0.9, senders: ['X'], family: 'f', match: { pattern, flags: 'i' }, emit: [{ factType: 'movement' }], ...extra });

test('a rule whose text changed is drifted; bookkeeping fields and key order are not', () => {
  const repo = new Map([
    ['SAME', { rule: rule('SAME', 'a'), file: 'a.json' }],
    ['EDITED', { rule: rule('EDITED', 'debited(?:\\s+for)?'), file: 'b.json' }],
    ['NEW', { rule: rule('NEW', 'n'), file: 'c.json' }],
  ]);
  const live = [
    { rule_id: 'SAME', version: 3, body: { ...rule('SAME', 'a'), version: 3, updatedAt: 'x', createdBy: 'import', match: { flags: 'i', pattern: 'a' } } },
    { rule_id: 'EDITED', version: 1, body: rule('EDITED', 'debited\\s+for') },
    { rule_id: 'GONE', version: 1, body: rule('GONE', 'g') },
  ];
  const r = compare(repo, live);
  assert.equal(r.same, 1);
  assert.deepEqual(r.drifted, [{ id: 'EDITED', file: 'b.json', liveVersion: 1, fields: ['match'] }]);
  assert.deepEqual(r.repoOnly, ['NEW']);
  assert.deepEqual(r.liveOnly, ['GONE']);
});
