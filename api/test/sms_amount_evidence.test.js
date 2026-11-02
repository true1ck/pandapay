const { test } = require('node:test');
const assert = require('node:assert/strict');
const cases = require('../../app/test/fixtures/sms_amount_roles.json');
const {paymentAmounts, paymentReviewReason, permitsPaymentAmount} = require('../src/sms_amount_evidence');
const {parseSmsAgainstPatterns,parseConservativeBankSpend,parseSms} = require('../src/sms_parser');
const {amountInPostedTransaction} = require('../src/ai_fact_evidence');
for(const row of cases) test(`monetary roles: ${row.id}`,()=>{
  assert.equal(!!paymentReviewReason(row.body),row.review);
  const amounts=paymentAmounts(row.body);
  assert.equal(amounts.length?Number(amounts[0][1].replace(/,/g,'')):null,row.paymentInr);
  const sms={sender:'VM-ICICIT-S',body:row.body};
  if(row.review) {
    assert.equal(parseSmsAgainstPatterns([],sms).ok,false);
    assert.equal(parseConservativeBankSpend(sms).ok,false);
    assert.equal(parseSms({regex:'.*INR ([\\d,.]+)',field_map:{amount:1}},sms).ok,false);
    assert.equal(amountInPostedTransaction(row.body,286388.46),false);
  } else if (row.paymentInr != null) {
    assert.equal(parseSmsAgainstPatterns([], sms).fields?.amountInr, row.paymentInr);
  }
});
test('configured rules cannot select a limit over an evidenced charge',()=>{
 const sms={sender:'ICICIT-S',body:'INR 500 spent using Card XX1234. Avl Limit: INR 100000.'};
 const result=parseSms({regex:'Avl Limit: INR ([\\d,.]+)',field_map:{amount:1}},sms);
 assert.equal(result.ok,false);
 assert.equal(permitsPaymentAmount(sms.body,100000),false);
 assert.equal(amountInPostedTransaction(sms.body,100000),false);
 assert.equal(amountInPostedTransaction(sms.body,500),true);
});

test('limit-change notices are rejected without a payment verb', () => {
  const sms = {
    sender: 'ICICIT-S',
    body: 'Dear Customer, we have changed the spend limit on your ICICI Bank Credit Card XX1234 from INR 100000 to INR 150000 on 2025-12-02.',
  };
  assert.equal(paymentReviewReason(sms.body), 'transaction_amount_not_evidenced');
  assert.deepEqual(paymentAmounts(sms.body), []);
  assert.equal(permitsPaymentAmount(sms.body, 100000), false);
  assert.equal(permitsPaymentAmount(sms.body, 150000), false);
  assert.equal(parseSmsAgainstPatterns([], sms).ok, false);
  assert.equal(parseConservativeBankSpend(sms).ok, false);
  assert.equal(parseSms({ regex: 'to INR ([\\d,.]+)', field_map: { amount: 1 } }, sms).ok, false);
  assert.equal(amountInPostedTransaction(sms.body, 150000), false);
});

test('a following bare balance label is not an expense amount', () => {
  for (const body of ['INR 100000 is your balance.', 'INR 100000 is your limit.', 'INR 100000 balance available.']) {
    assert.equal(permitsPaymentAmount(body, 100000), false);
    assert.equal(paymentReviewReason(body), 'transaction_amount_not_evidenced');
  }
  const genuine = 'INR 500 spent using card XX1234. Balance: INR 100000.';
  assert.equal(permitsPaymentAmount(genuine, 500), true);
  assert.equal(permitsPaymentAmount(genuine, 100000), false);
});
