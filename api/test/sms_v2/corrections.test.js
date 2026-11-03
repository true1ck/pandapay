'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const { stageFor, templateMetadata, submitCorrection, patternFromSkeleton, decisionOutput, correctionStatusSince } = require('../../src/sms_v2/corrections_route');

const base = JSON.parse(fs.readFileSync(require('node:path').resolve(__dirname, '../../../contracts/sms/v2/fixtures/valid/request.corrections/wrong_category.json')));
test('attributes every correction kind and leaves private preferences local', () => {
  const stages = { not_financial:'extraction', wrong_kind:'extraction', wrong_amount:'extraction', wrong_date:'extraction', wrong_merchant:'extraction', wrong_instrument:'instrument', wrong_link:'linking', duplicate:'linking', wrong_category:'category', missing:'gate', preference_only:null };
  for (const [kind,stage] of Object.entries(stages)) assert.equal(stageFor(kind,{stage:'category'}), stage);
  assert.equal(stageFor('not_financial',{stage:'gate'}),'gate');
  assert.equal(stageFor('wrong_instrument',{stage:'extraction'}),'extraction');
});

test('redacted skeleton hash must match the normalized brand and exact content', () => {
  const redactedTemplate = 'Rs.<AMT> spent at <PARTY>';
  const metadata = { senderBrand:'HDFCBK', observedAt:'2026-11-01T12:00:00Z',
    hash: crypto.createHash('sha256').update('HDFCBK\n'+redactedTemplate).digest('hex') };
  const body = { ...base, redactedTemplate, corrected:{_template:metadata} };
  assert.equal(templateMetadata(body).hash,metadata.hash);
  assert.throws(()=>templateMetadata({...body,redactedTemplate:redactedTemplate+'!'}),/template_hash_mismatch/);
  assert.throws(()=>templateMetadata({...body,redactedTemplate:'Rs.123456 sent'}),/redacted_template_invalid/);
});

test('absent consent persists compact trace and kind without corrected values or template', async () => {
  let inserted;
  const client = { query:async (sql,args) => {
    if (sql.includes('FROM sms_v2_facts')) return {rows:base.factIds.map(fact_id=>({fact_id}))};
    if (sql.includes('FROM sms_v2_events')) return {rows:[{event_id:base.eventId}]};
    if (sql.includes('FROM user_consents')) return {rows:[{granted:false}]};
    inserted = args; return {rows:[{case_id:'case'}]};
  } };
  assert.deepEqual(await submitCorrection(client,'profile',base),{caseId:'case'});
  assert.deepEqual(inserted[7],{});
  assert.equal(inserted[8],null);
  assert.equal(inserted[10],null);
  assert.equal(inserted[11],false);
});

test('only owned facts can become review cases', async () => {
  await assert.rejects(submitCorrection({query:async()=>({rows:[]})},'profile',base),/correction_facts_not_found/);
});

test('draft skeleton escapes literals and includes bounded named captures', () => {
  const draft=patternFromSkeleton('Rs.<AMT> spent at <PARTY> (#)');
  assert.ok(new RegExp(draft.pattern).test('Rs.123.45 spent at SWIGGY (2)'));
  assert.ok(!new RegExp(draft.pattern).test('RsX123.45 spent at SWIGGY (2)'));
  assert.deepEqual(Object.keys(draft.groups),['<AMT>','<PARTY>','#']);
});

test('data fixes and reviewed synthetic code examples produce draft and golden shapes', () => {
  const row={case_id:'synthetic-case',stage:'category',sender_brand:'HDFCBK',
    redacted_template:'Rs.<AMT> spent',template_hash:'a'.repeat(64),
    corrected:{category:'groceries',merchantKey:'SYNTHETIC',
      goldenExample:{body:'Rs.10 spent',expect:{facts:[{factType:'movement'}]}}}};
  assert.equal(decisionOutput(row,'data_fix').categoryDraft.category,'groceries');
  assert.equal(decisionOutput(row,'code_fix').goldenCase.messages[0].body,'Rs.10 spent');
  assert.deepEqual(decisionOutput(row,'not_a_bug'),{});
  assert.throws(()=>decisionOutput({...row,corrected:{}},'code_fix'),/redacted_expectation_required/);
});

test('status sync is owner scoped and advances an opaque sequence cursor', async () => {
  const result=await correctionStatusSince(async(profile,op)=>{
    assert.equal(profile,'profile');
    return op({query:async(sql,args)=>{
      assert.match(sql,/profile_id=\$1/);assert.deepEqual(args,['profile',4]);
      return {rows:[{case_id:'c',source_key:'s',status:'decided',decision:'not_a_bug',reason:'x',change_seq:8}]};
    }});
  },'profile','4');
  assert.equal(result.cursor,'8');
  assert.equal(result.items[0].caseId,'c');
});
