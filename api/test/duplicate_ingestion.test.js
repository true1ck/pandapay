const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { parseSmsAgainstPatterns, isBankAccountMessage } = require('../src/sms_parser');
const {bestDuplicate, MAX_CROSS_SOURCE_CANDIDATE_MS, AMOUNT_TOLERANCE_INR} = require('../src/transaction_dedup');
const source = fs.readFileSync(require.resolve('../src/index.js'), 'utf8');
function extract(name, next) { return source.slice(source.indexOf(`async function ${name}(`), source.indexOf(`async function ${next}(`)); }
const detect = new Function('bestDuplicate', 'MAX_CROSS_SOURCE_CANDIDATE_MS', 'AMOUNT_TOLERANCE_INR', `${extract('detectDuplicates','loadUserCardForState')} return detectDuplicates;`)(bestDuplicate, MAX_CROSS_SOURCE_CANDIDATE_MS, AMOUNT_TOLERANCE_INR);
const incoming = {newTxnId:'new', amount:100, occurred:'2026-10-02T10:00:00Z', merchantName:'Shop', source:'statement', instrument:'credit_card', entryKind:'spend', userCardId:'card', bankReference:'ABC123456789'};
const existing = {id:'old', amount_inr:100, occurred_at:incoming.occurred, merchant_name:'Shop', source:'sms', instrument:'credit_card', entry_kind:'spend', user_card_id:'card', bank_reference:incoming.bankReference, status:'active'};
test('automatic reference match never creates a pending discrepancy', async () => {
  const calls=[];
  const client={query:async(sql)=>{calls.push(sql);return {rows:[existing]};}};
  const result=await detect(client,'profile',incoming);
  assert.equal(result.automatic,true);
  assert.equal(result.duplicateOf,'old');
  assert.equal(calls.length,2);
  assert.match(calls[0], /pg_advisory_xact_lock/);
  assert.match(calls[1], /metadata->>'transactionTimeMillis'\s*=\s*\(extract\(epoch FROM t\.occurred_at\)/);
});
test('uncertain match creates review record with incoming row suppressed', async () => {
  const calls=[];
  const client={query:async(sql,params)=>{calls.push({sql,params});return {rows:sql.includes('INSERT INTO')?[{id:'review'}]:[{...existing,bank_reference:null}]};}};
  const result=await detect(client,'profile',{...incoming,bankReference:null});
  assert.equal(result.candidateId,'review');
  assert.equal(calls[2].params[5],'new');
});
test('automatic ingestion links source alias and never applies card state', async () => {
  const observations=[];const writes=[];const tagMerges=[];
  const writer=new Function('recordTransactionObservation','detectDuplicates','loadUserCardForState','applyTransactionState','transactionTags',`${extract('insertTransactionAndUpdateState','importParsedMessage')} return insertTransactionAndUpdateState;`)(
    async(...args)=>observations.push(args),async()=>({automatic:true,duplicateOf:'old',transaction:existing}),async()=>({id:'card'}),async()=>{throw Error('must not apply state');},
    {mergeTransactionTags:async(...args)=>tagMerges.push(args)});
  const client={query:async(sql,params)=>{writes.push({sql,params});if(sql.includes('INSERT INTO transactions'))return {rowCount:1,rows:[{id:'new'}]};return {rows:[]};}};
  const result=await writer(client,'profile',{...incoming,sourceKey:'key',observationMetadata:{bankReference:incoming.bankReference}});
  assert.equal(result.duplicateKind,'high_confidence');
  assert.equal(result.transaction.id,'old');
  assert.equal(observations.at(-1)[2],'old');
  assert.deepEqual(tagMerges.map((args)=>args.slice(1)),[['profile','new','old']]);
  assert.ok(writes.some(({sql})=>sql.includes("status = 'ignored'")));
});

test('SMS and email imports keep unresolved generic cards cardless despite a selected credit card', async () => {
  const importMessage = new Function(
    'extractVpa', 'extractMcc', 'isBankAccountMessage', 'importResolvers', 'insertTransactionAndUpdateState',
    `${extract('importParsedMessage', 'reconcileArchivedCardReferences')} return importParsedMessage;`,
  )(
    () => null, () => null, isBankAccountMessage,
    {
      userCardMatchesInstrument: async (_client, _user, _card, instrument) => {
        assert.equal(instrument, 'credit_card', 'untyped cards must not enter card matching');
        return true;
      },
      resolveUserCardForImport: async (_client, _user, args) => {
        assert.equal(args.instrument, 'other');
        assert.equal(args.last4, '7788');
        return null;
      },
    },
    async (_client, _user, args) => ({ status: 201, transaction: args }),
  );
  const body = 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY on 05-Aug-26.';
  const unknown = parseSmsAgainstPatterns([], { sender: 'ICICIB', body });
  const credit = parseSmsAgainstPatterns([], { sender: 'ICICIB', body: `${body} Avl Limit Rs.9000.` });
  const legacy = { ...unknown, fields: { ...unknown.fields, instrument: undefined } };
  for (const channel of ['sms', 'email']) {
    for (const parsed of [unknown, legacy, credit]) {
      const result = await importMessage({}, 'profile', {
        parsed, sender: 'ICICIB', rawText: body, source: channel,
        explicitUserCardId: 'selected-credit-card', explicitCategoryId: 'food',
        occurred: new Date('2026-08-05T10:00:00Z'),
        observationMetadata: { transactionTimePrecise: true },
      });
      const knownCredit = parsed === credit;
      assert.equal(result.transaction.instrument, knownCredit ? 'credit_card' : 'other');
      assert.equal(result.transaction.userCardId, knownCredit ? 'selected-credit-card' : null);
      assert.equal(result.transaction.amount, 250);
      assert.equal(result.transaction.merchantName, 'SWIGGY');
      assert.equal(result.transaction.entryKind, 'spend');
      assert.equal(result.transaction.source, channel);
      assert.equal(result.transaction.observationMetadata.transactionTimeMillis,
        Date.parse('2026-08-05T10:00:00Z'));
    }
  }
});

test('card imports use saved suffix identity, never a stale selection or contradictory card type', async () => {
  const resolvers = require('../src/import_resolvers');
  const importMessage = new Function(
    'extractVpa', 'extractMcc', 'isBankAccountMessage', 'importResolvers', 'insertTransactionAndUpdateState',
    `${extract('importParsedMessage', 'reconcileArchivedCardReferences')} return importParsedMessage;`,
  )(() => null, () => null, isBankAccountMessage, resolvers,
    async (_client, _user, args) => ({ status: 201, transaction: args }));
  const credit = { id: 'credit', last4: '7788', card_type: 'credit', issuer: 'issuer-a' };
  const debit = { id: 'debit', last4: '7788', card_type: 'debit', issuer: 'issuer-a' };
  const stale = { ...credit, id: 'stale', last4: '9999', issuer: 'issuer-b' };
  const cases = [
    { cards: [credit, stale], expected: credit },
    { cards: [debit, stale], expected: debit },
    { cards: [stale], expected: null },
    { cards: [credit, debit], expected: null },
    { cards: [credit, { ...credit, id: 'another-credit' }], expected: null },
    { cards: [{ ...credit, is_archived: true }, stale], expected: null },
    { cards: [{ ...credit, card_type: null }], expected: null },
    { cards: [credit, { ...debit, issuer: 'issuer-b' }, stale], issuer: 'issuer-a', expected: credit },
    { cards: [credit, stale], issuer: 'issuer-b', expected: null },
    { cards: [credit, stale], label: 'Credit Card', expected: credit },
    { cards: [debit, stale], label: 'Debit Card', expected: debit },
    { cards: [debit, stale], label: 'Credit Card', expected: null },
    { cards: [credit, stale], label: 'Debit Card', expected: null },
  ];
  for (const source of ['sms', 'email']) {
    for (const scenario of cases) {
      const queries = [];
      const client = { query: async (sql, params) => {
        queries.push({ sql, params });
        assert.match(sql, /uc\.profile_id = \$\d/);
        assert.match(sql, /uc\.is_archived = false/);
        if (sql.includes('uc.id = $1')) {
          const [cardId, _user, type, last4, issuer] = params;
          assert.equal(last4, '7788', 'a caller selection must match the printed suffix');
          return { rows: scenario.cards.filter((c) => c.id === cardId && !c.is_archived && c.card_type === type &&
            (!last4 || c.last4 === last4) && (!issuer || c.issuer === issuer)) };
        }
        assert.match(sql, /uc\.last4 = \$2/);
        const [_user, last4, issuer, type] = params;
        return { rows: scenario.cards.filter((c) => !c.is_archived && c.last4 === last4 &&
          (!issuer || c.issuer === issuer) && (!type || c.card_type === type)) };
      } };
      const rawText = `INR 250 spent on Bank ${scenario.label || 'Card'} XX7788 at SWIGGY on 05-Aug-26.`;
      const parsed = parseSmsAgainstPatterns([], { sender: 'BANK', body: rawText });
      assert.equal(parsed.ok, true);
      const { transaction } = await importMessage(client, 'profile', {
        parsed, rawText, source, patternIssuerId: scenario.issuer,
        explicitUserCardId: stale.id, explicitCategoryId: 'food', occurred: new Date('2026-08-05T10:00:00Z'),
      });
      assert.equal(transaction.userCardId, scenario.expected?.id || null, JSON.stringify(scenario));
      const expectedInstrument = scenario.label === 'Credit Card' ? 'credit_card'
        : scenario.label === 'Debit Card' ? 'debit_card'
        : scenario.expected?.card_type === 'credit' ? 'credit_card'
        : scenario.expected?.card_type === 'debit' ? 'debit_card' : 'other';
      assert.equal(transaction.instrument, expectedInstrument, JSON.stringify(scenario));
      assert.ok(queries.length > 0);
    }
  }
});

test('untyped account evidence or missing card context never uses a saved card or caller selection', async () => {
  const importMessage = new Function(
    'extractVpa', 'extractMcc', 'isBankAccountMessage', 'importResolvers', 'insertTransactionAndUpdateState',
    `${extract('importParsedMessage', 'reconcileArchivedCardReferences')} return importParsedMessage;`,
  )(() => null, () => null, isBankAccountMessage, {
    resolveUserCardForImport: async () => assert.fail('no physical-card identity'),
    userCardMatchesInstrument: async () => assert.fail('must not trust the selected card'),
  }, async (_client, _user, args) => ({ transaction: args }));
  for (const [rawText, fields] of [
    ['INR 250 debited from account 7788 for card services.', { last4: '7788', accountLast4: '7788' }],
    ['INR 250 spent at SWIGGY.', { last4: '7788' }],
    ['INR 250 spent on Bank Card at SWIGGY.', {}],
  ]) {
    const { transaction } = await importMessage({}, 'profile', {
      parsed: { fields: { amountInr: 250, instrument: 'other', ...fields } }, rawText,
      explicitUserCardId: 'selected', explicitCategoryId: 'food', source: 'sms',
    });
    assert.equal(transaction.userCardId, null);
    assert.equal(transaction.instrument, 'other');
  }
});
