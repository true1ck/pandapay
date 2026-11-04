'use strict';

// Lane D: the request script the shipped (v1) Android app's traffic is modelled
// on. Used against a v1 server+schema and the v2 server+schema; answers are
// compared. Synthetic data only.

const { importSourceKey } = require('../../../src/import_source_key');

const SENDER = 'AX-SYNBNK';
const MSGS = {
  debit: { sender: SENDER, body: 'Rs.499.00 debited from A/c XX1234 on 19-10-26 to VPA synshop@upi (UPI Ref 123456789012). Not you? Call 1800000000 -SYNBNK', occurredAt: '2026-10-19T10:00:00Z' },
  credit: { sender: SENDER, body: 'Rs.1200.00 credited to A/c XX1234 on 21-10-26 by VPA synfriend@upi (UPI Ref 123456789013). -SYNBNK', occurredAt: '2026-10-21T10:00:00Z' },
  refund: { sender: SENDER, body: 'Refund of Rs.250.00 for your order has been credited to A/c XX1234 on 20-10-26. -SYNBNK', occurredAt: '2026-10-20T10:00:00Z' },
  otp: { sender: SENDER, body: 'Use 123456 as your OTP for login. Do not share it with anyone. -SYNBNK', occurredAt: '2026-10-22T10:00:00Z' },
};
const sourceKeyFor = (profileId, m) => importSourceKey(profileId, m.sender, m.body);

const HEX = (s) => require('node:crypto').createHash('sha256').update(s).digest('hex');

// Every request is made as the old app would: no X-App-Version header, legacy routes only.
async function legacyScript(call, profileId) {
  const steps = [];
  const rec = async (name, method, route, body) => {
    const r = await call(profileId, method, route, body);
    steps.push({ name, status: r.status, body: r.body ?? r.text });
    return r;
  };
  await rec('cards-empty', 'GET', '/user-cards');
  await rec('create-manual-spend', 'POST', '/transactions', { instrument: 'upi_bank', entryKind: 'spend', amountInr: 150, occurredAt: '2026-10-17T10:00:00Z', merchantName: 'SYNTHETIC CAFE', clientMutationId: 'lane-d-manual-0001' });
  await rec('create-manual-income', 'POST', '/transactions', { instrument: 'upi_bank', entryKind: 'income', amountInr: 900, occurredAt: '2026-10-16T10:00:00Z', merchantName: 'SYNTHETIC EMPLOYER', clientMutationId: 'lane-d-manual-0002' });
  await rec('create-bad-kind', 'POST', '/transactions', { instrument: 'upi_bank', entryKind: 'refund', amountInr: 10 });
  await rec('from-sms-batch', 'POST', '/transactions/from-sms/batch', { messages: Object.values(MSGS), appVersion: '1.0.0+1' });
  await rec('from-sms-batch-replay', 'POST', '/transactions/from-sms/batch', { messages: Object.values(MSGS), appVersion: '1.0.0+1' });
  await rec('sms-facts', 'POST', '/sms/facts', {
    sourceKey: HEX('lane-d-facts-source'), bodyHash: HEX('lane-d-facts-body'), sender: SENDER, occurredAt: '2026-10-23T10:00:00Z',
    facts: [{ factType: 'posted_movement', payload: { amountRole: 'posted', amountInr: 320, entryKind: 'spend', merchant: 'SYNTHETIC STORE', occurredAt: '2026-10-23T10:00:00.000Z', instrument: 'upi_bank' } }],
  });
  const list = await rec('transactions-list', 'GET', '/transactions');
  await rec('transactions-range', 'GET', '/transactions?from=2026-10-18&to=2026-10-21');
  await rec('transactions-search', 'GET', '/transactions?q=SYNTHETIC');
  const first = (list.body && list.body.transactions && list.body.transactions[0]) || null;
  if (first) {
    await rec('transaction-detail', 'GET', `/transactions/${first.id}`);
    await rec('transaction-note', 'PATCH', `/transactions/${first.id}/note`, { note: 'lane d note' });
    await rec('transaction-ignore', 'POST', `/transactions/${first.id}/ignore`, { reason: 'wrong_transaction' });
    await rec('transactions-deleted', 'GET', '/transactions?status=deleted');
    await rec('transaction-restore', 'POST', `/transactions/${first.id}/restore`, {});
  }
  await rec('transactions-list-after', 'GET', '/transactions');
  await rec('spend-by-category', 'GET', '/spend-by-category');
  await rec('spend-report-month', 'GET', '/spend-report?period=month&anchor=2026-10-20T00:00:00Z');
  await rec('spend-report-year', 'GET', '/spend-report?period=year&anchor=2026-10-20T00:00:00Z');
  await rec('home-summary', 'GET', '/home-summary');
  await rec('monthly-reports', 'GET', '/monthly-reports');
  await rec('budgets', 'GET', '/budgets');
  await rec('rules-active', 'GET', '/sms/rules/active');
  await rec('sms-import-state', 'GET', '/transactions/sms-import-state');
  await rec('sms-import-batches', 'GET', '/sms-import-batches');
  // user_consents carries two v2 triggers (template and correction cleanup on withdrawal)
  await rec('consent-grant', 'POST', '/consents', { purpose: 'sms_shared_learning', granted: true, policyVersion: '2026-10', sourceScreen: 'lane_d' });
  await rec('consent-revoke', 'POST', '/consents', { purpose: 'sms_shared_learning', granted: false, policyVersion: '2026-10', sourceScreen: 'lane_d' });
  await rec('consent-list', 'GET', '/consents');
  await rec('cards-after', 'GET', '/user-cards');
  return steps;
}

module.exports = { legacyScript, MSGS, SENDER, sourceKeyFor, HEX };
