const test = require('node:test');
const assert = require('node:assert/strict');
const cases = require('../../app/test/fixtures/local_sms_cases.json');
const { parseSmsAgainstPatterns } = require('../src/sms_parser');
for (const [index, fixture] of cases.entries()) {
  test(`mobile/server built-in SMS parity ${index}`, () => {
    const result = parseSmsAgainstPatterns([], { sender: 'VM-HDFCBK', body: fixture.body });
    assert.equal(result.ok ? result.fields.amountInr : null, fixture.amount);
    if (fixture.amount !== null) {
      assert.equal(result.fields.instrument, fixture.instrument);
      assert.equal(result.fields.entryKind, fixture.kind);
    }
  });
}
