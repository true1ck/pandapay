const test = require('node:test');
const assert = require('node:assert/strict');
const { parseSmsAgainstPatterns } = require('../src/sms_parser');
const {
  transferIdentity, applySelfTransferRule, confirmSelfTransfer,
  saveSelfTransferRule, disableSelfTransferRule,
  confirmedSelfTransferRules, applySelfTransferRuleHistorically,
} = require('../src/self_transfer');

const sms = { sender: 'JX-HDFCBK-T', body: 'Sent Rs.10000.00\nFrom HDFC Bank A/C *1797\nTo slice small finance bank\nOn 01/11/26\nRef 123456789075' };
const parsed = () => parseSmsAgainstPatterns([], sms);
const destination = { accountLast4: '5799', bank: 'slcbnk' };

test('bank name alone remains spend; a personal confirmed relationship makes it neutral', () => {
  const original = parsed();
  assert.equal(original.fields.entryKind, 'spend');
  const rule = { ...transferIdentity(sms.sender, original.fields), destination };
  const result = applySelfTransferRule(original, sms.sender, [rule]);
  assert.equal(result.fields.entryKind, 'transfer');
  assert.equal(result.fields.destinationAccountLast4, '5799');
  assert.equal(result.fields.transferKind, 'account_to_account');
  assert.equal(result.fields.amountInr, 10000);
  assert.equal(original.fields.entryKind, 'spend');
  assert.match(result.fields.merchant, /Self-transfer/);
});

test('an unapplied migration leaves imports usable without aborting their transaction', async () => {
  const calls = [];
  const client = { query: async (sql) => {
    calls.push(sql);
    assert.match(sql, /to_regclass/);
    return { rows: [{ relation: null }] };
  } };
  assert.deepEqual(await confirmedSelfTransferRules(client, 'user-a'), []);
  assert.equal(calls.length, 1);
});

test('confirmation is scoped to the sender bank, source account and exact beneficiary', () => {
  const original = parsed();
  const rule = { ...transferIdentity(sms.sender, original.fields), destination };
  assert.equal(applySelfTransferRule(original, 'VM-HDFCBK-S', [rule]).fields.entryKind, 'transfer');
  for (const fields of [
    { accountLast4: '2226' }, { transferParty: 'slice small finance bank services' },
    { instrument: 'credit_card' }, { entryKind: 'income' },
  ]) {
    const input = { ...original, fields: { ...original.fields, ...fields } };
    assert.equal(applySelfTransferRule(input, sms.sender, [rule]), input);
  }
  assert.equal(applySelfTransferRule(original, 'VM-CANBNK-S', [rule]), original);
  assert.equal(applySelfTransferRule(original, sms.sender, [rule, { ...rule, destination: { bank: 'other', accountLast4: '2626' } }]), original);
  assert.equal(applySelfTransferRule(
    { ...original, fields: { ...original.fields, destinationAccountLast4: '2626' } },
    sms.sender,
    [rule],
  ).fields.entryKind, 'spend');
});

test('confirmation validates user-scoped source and destination evidence before writing a rule', async () => {
  const calls = [];
  const client = { query: async (sql, args) => {
    calls.push({ sql, args });
    if (sql.includes('SELECT')) return { rows: [
      { metadata: { accountLast4: '1797', transferParty: 'slice small finance bank', senderBank: sms.sender, isBankAccount: true }, transaction_id: 't1' },
      { metadata: { accountLast4: '5799', senderBank: 'VM-SLCBNK-S', isBankAccount: true }, transaction_id: 't2' },
    ] };
    return { rows: [] };
  } };
  const rule = await confirmSelfTransfer(client, 'user-a', 't1', destination);
  assert.deepEqual(rule.destination, destination);
  assert.equal(rule.sourceAccountLast4, '1797');
  assert.ok(calls.every(c => c.args.includes('user-a')));
  await assert.rejects(() => confirmSelfTransfer(client, 'user-a', 't1', { bank: 'slcbnk', accountLast4: '9999' }), /destination/);
  await assert.rejects(() => confirmSelfTransfer(client, 'user-a', 't1', { bank: 'slcbnk', accountLast4: '12345' }), /destination/);
});

test('remembered relationships have an explicit profile-scoped lifecycle', async () => {
  const calls = [];
  const client = { query: async (sql, args) => {
    calls.push({ sql, args });
    return { rows: [] };
  } };
  const rule = {
    sourceSender: 'hdfc', sourceAccountLast4: '1797',
    party: 'slice small finance bank', destination,
  };
  await saveSelfTransferRule(client, 'user-a', rule);
  await disableSelfTransferRule(client, 'user-a', rule);
  assert.equal(calls.length, 2);
  assert.ok(calls.every(({ args }) => args[0] === 'user-a'));
  assert.deepEqual(calls[0].args, ['user-a', 'hdfc', '1797', 'slice small finance bank', 'slcbnk', '5799']);
  assert.match(calls[0].sql, /ON CONFLICT/);
  assert.match(calls[1].sql, /is_active=false/);
});

test('historical correction only updates matching unlocked bank transfers', async () => {
  const writes = [];
  const client = { query: async (sql, args) => {
    if (sql.includes('SELECT t.id, o.metadata')) return { rows: [
      { id: 'old-match', metadata: {
        senderBank: 'VM-HDFCBK-S', accountLast4: '1797',
        transferParty: 'slice small finance bank',
      } },
      { id: 'locked-spend', metadata: {
        senderBank: 'VM-HDFCBK-S', accountLast4: '1797',
        transferParty: 'slice small finance bank', classificationLocked: true,
      } },
      { id: 'other-beneficiary', metadata: {
        senderBank: 'VM-HDFCBK-S', accountLast4: '1797',
        transferParty: 'another bank',
      } },
    ] };
    writes.push({ sql, args });
    return { rowCount: 1, rows: [{ id: args[0] }] };
  } };
  const applied = await applySelfTransferRuleHistorically(client, 'user-a', {
    sourceSender: 'hdfc', sourceAccountLast4: '1797',
    party: 'slice small finance bank', destination,
  });
  assert.equal(applied, 1);
  assert.equal(writes.filter((write) => write.sql.includes('UPDATE transactions')).length, 1);
  assert.equal(writes.filter((write) => write.sql.includes('UPDATE transaction_observations')).length, 1);
  assert.ok(writes.every(({ args }) => args[1] === 'user-a' || args[0] === 'user-a'));
});

test('historical correction preserves the remember choice in evidence', async () => {
  const writes = [];
  const client = { query: async (sql, args) => {
    if (sql.includes('SELECT t.id, o.metadata')) return { rows: [
      { id: 'old-match', metadata: {
        senderBank: 'VM-HDFCBK-S', accountLast4: '1797',
        transferParty: 'slice small finance bank',
      } },
    ] };
    writes.push({ sql, args });
    return { rowCount: 1, rows: [{ id: args[0] }] };
  } };
  await applySelfTransferRuleHistorically(client, 'user-a', {
    sourceSender: 'hdfc', sourceAccountLast4: '1797',
    party: 'slice small finance bank', destination,
  }, null, false);
  const observation = writes.find((write) => write.sql.includes('UPDATE transaction_observations'));
  assert.equal(JSON.parse(observation.args[2]).selfTransferRemembered, false);
});
