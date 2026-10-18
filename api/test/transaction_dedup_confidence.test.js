const test = require('node:test');
const assert = require('node:assert/strict');
const { evaluateDuplicate, bestDuplicate, referenceOf } = require('../src/transaction_dedup');
const row = { amount: 499, occurred: '2026-10-02T10:15:00Z', merchantName: 'Shop', source: 'sms', instrument: 'credit_card', userCardId: 'card', bankReference: 'ABC123456789' };
test('bank reference automatically consolidates differing descriptions across channels and within one channel', () => {
  for (const source of ['sms_bulk', 'statement', 'imported']) {
    assert.equal(evaluateDuplicate(row, { ...row, source, merchantName: 'Unknown merchant' }).automatic, true);
  }
});
test('conflicting reference, amount, account and card prevent automatic consolidation', () => {
  for (const change of [{bankReference:'XYZ123456789'}, {amount:499.5}, {userCardId:'another'}, {accountLast4:'9999'}]) {
    assert.equal(evaluateDuplicate({...row, accountLast4:'1234'}, {...row, source:'statement', ...change}), null);
  }
});
test('date-only amounts and merchant agreement remain reviewable without bank identity', () => {
  const result = evaluateDuplicate({...row, bankReference:null, occurred:'2026-10-02T00:00:00Z'}, {...row, bankReference:null, source:'statement'});
  assert.equal(result.automatic, false);
});
test('ambiguous reused reference requires review regardless of score', () => {
  const result = bestDuplicate(row, [{...row, id:'a', source:'statement'}, {...row, id:'b', source:'imported'}]);
  assert.equal(result.match.automatic, false);
  assert.match(result.match.reason, /multiple possible/);
});
test('only bank-labelled references are extracted; unknown merchants are not exact evidence', () => {
  assert.equal(referenceOf({merchantName:'Shop UTR: 123456789012'}), '123456789012');
  assert.equal(referenceOf({merchantName:'Invoice 123456789012'}), null);
  const result = evaluateDuplicate({...row, bankReference:null, merchantName:'Unknown'}, {...row, source:'statement', bankReference:null, merchantName:'Unknown'});
  assert.equal(result.automatic, false);
  assert.equal(result.merchantMatch, 'missing');
});
test('non-Latin merchants retain distinguishing evidence', () => {
  assert.equal(evaluateDuplicate({...row, bankReference:null, merchantName:'दुकान'}, {...row, source:'statement', bankReference:null, merchantName:'भोजन'}), null);
});
