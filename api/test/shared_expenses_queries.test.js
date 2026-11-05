'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {pageRequest,encodeCursor,decodeCursor,listContexts,listContextExpenses,listContextMembers,listContextActivity,listChanges,readBalances,readOperation,readExpense,listExpenseRevisions,listSettlementReports,pullProjectionChanges,readContext}=require('../src/shared_expenses/queries');
const actor='11111111-1111-4111-8111-111111111111',context='22222222-2222-4222-8222-222222222222',id='33333333-3333-4333-8333-333333333333';

test('context search and per-tab pagination bind cursors to their exact filter',async()=>{
  const calls=[],row={context_id:context,kind:'group',name:'Home',currency:'INR',state:'active',committed_sequence:'3',created_at_key:'2026-11-04T00:00:00.123456Z',membership_state:'active',owed_minor:'0',owing_minor:'0'};
  const first=await listContexts({query:async(sql,args)=>{calls.push({sql,args});return{rows:[row,{...row,context_id:id}]};}},actor,{kind:'group',q:'Home',limit:'1'});
  assert.ok(calls[0].args.includes('group'));assert.ok(calls[0].args.includes('Home'));
  await assert.rejects(listContexts({query:async()=>{throw new Error('must not query');}},actor,{kind:'direct',q:'Home',after:first.nextCursor}),{code:'INVALID_CURSOR'});
  await assert.rejects(listContexts({query:async()=>{throw new Error('must not query');}},actor,{q:'x'.repeat(129)}),{code:'INVALID_INPUT'});
});
test('pagination and cursors are bounded and bound to authenticated owner, route and context',()=>{
  assert.equal(pageRequest({}).limit,50);assert.equal(pageRequest({limit:'100'}).limit,100);
  for(const query of [{limit:'101'},{limit:'0'},{limit:['1']},{other:'x'}])assert.throws(()=>pageRequest(query));
  const scope={actorId:actor,kind:'members',contextId:context};
  const cursor=encodeCursor(scope,[id]);
  assert.deepEqual(decodeCursor(cursor,scope),[id]);
  for(const other of [{...scope,actorId:id},{...scope,contextId:id},{...scope,kind:'expenses'}])assert.throws(()=>decodeCursor(cursor,other));
  assert.throws(()=>decodeCursor('x'.repeat(1025),scope));
});
test('context list SQL is keyset bounded with one extra row and never reads private source links',async()=>{
  const calls=[];const rows=[{context_id:context,kind:'group',name:'Home',currency:'INR',state:'active',committed_sequence:'3',created_at:new Date('2026-11-04T00:00:00Z')},{context_id:id,kind:'group',name:'Trip',currency:'INR',state:'active',committed_sequence:'2',created_at:new Date('2026-11-03T00:00:00Z')}];
  const result=await listContexts({query:async(sql,params)=>{calls.push({sql,params});return {rows};}},actor,{limit:'1'});
  assert.equal(result.items.length,1);assert.equal(result.items[0].contextId,context);assert.ok(result.nextCursor);
  assert.equal(calls[0].params[3],2);assert.match(calls[0].sql,/LIMIT \$/);assert.doesNotMatch(calls[0].sql,/source_links|SELECT \*/i);
});
test('context queries authorize first and expose empty only for authorized empty pages',async()=>{
  for(const fn of [listContextExpenses,listContextMembers,listContextActivity,readBalances]) {
    let calls=0;
    await assert.rejects(fn({query:async()=>{calls++;return {rows:[{allowed:false}]};}},actor,context,{}),{code:'CONTEXT_NOT_FOUND'});
    assert.equal(calls,1);
  }
});
test('operation lookup is actor-bound and reauthorizes context before returning its result',async()=>{
  const receipt={operation_id:id,command_kind:'context.create',request_hash:'a'.repeat(64),context_id:context,result:{status:'created'}};
  const calls=[];
  const result=await readOperation({query:async(sql,params)=>{calls.push({sql,params});return calls.length===1?{rows:[receipt]}:{rows:[{allowed:true}]};}},actor,id);
  assert.equal(result.operationId,id);assert.equal(result.state,'committed');assert.equal(calls[0].params[0],actor);
  await assert.rejects(readOperation({query:async(sql)=>sql.includes('operation_receipts')?{rows:[receipt]}:{rows:[{allowed:false}]}},actor,id),{code:'CONTEXT_NOT_FOUND'});
});
test('profile changes use committed sequence and produce a scope-bound cursor',async()=>{
  const calls=[];
  const result=await listChanges({query:async(sql,params)=>{calls.push({sql,params});return {rows:[{sequence:'8',context_id:context,context_sequence:'4'}]};}},actor,{limit:'1'});
  assert.equal(result.items[0].sequence,'8');assert.match(calls[0].sql,/sequence > \$2::bigint/);assert.equal(calls[0].params[0],actor);
  assert.equal(result.cursorAfter,'8');
});
test('context cursor preserves PostgreSQL microseconds instead of skipping equal-millisecond rows',async()=>{
  const row={context_id:context,kind:'group',name:'Home',currency:'INR',state:'active',committed_sequence:'3',created_at:new Date('2026-11-04T00:00:00.123Z'),created_at_key:'2026-11-04T00:00:00.123456Z',membership_state:'invited'};
  const first=await listContexts({query:async()=>({rows:[row,{...row,context_id:id}]})},actor,{limit:'1'});
  const keys=decodeCursor(first.nextCursor,{actorId:actor,kind:'contexts',contextId:null});
  assert.equal(keys[0],row.created_at_key);assert.equal(first.items[0].membershipState,'invited');
  const calls=[];
  await listContexts({query:async(sql,params)=>{calls.push(params);return {rows:[]};}},actor,{after:first.nextCursor});
  assert.ok(calls[0].includes(row.created_at_key));
});
test('expense and settlement reads select safe columns, never source_links or private references',async()=>{
  for(const fn of [readExpense,listExpenseRevisions,listSettlementReports]) {
    const calls=[];
    const client={query:async(sql,params)=>{calls.push({sql,params});return calls.length===1?{rows:[{allowed:true}]}:sql.includes('FROM shared_expenses.expenses')?{rows:[{expense_id:id,created_by:actor,accepted_revision_id:null,head_version:'0'}]}:{rows:[]};}};
    await (fn===listSettlementReports?fn(client,actor,context,{}):fn(client,actor,context,id,{}));
    assert.ok(calls.length>=2);assert.doesNotMatch(calls.at(-1).sql,/SELECT \*|source_links|private_reference/i);
  }
});
test('materialized changes advance only through returned records and expose terminal access markers',async()=>{
  const rows=[
    {profile_sequence:'7',record_key:'00_context:'+context,entity:'contexts',id:context,context_id:context,revision:'3',payload:{name:'Home'},deleted:false,marker:null,stream_more:false},
    {profile_sequence:'7',record_key:'99_granted:'+context,entity:null,id:context,context_id:context,revision:'3',payload:{},deleted:false,marker:'granted',stream_more:false},
  ];
  const calls=[];
  const result=await pullProjectionChanges({query:async(sql,params)=>{calls.push({sql,params});return {rows};}},actor,{limit:'2'});
  assert.equal(result.records.length,1);assert.deepEqual(result.grantedContextIds,[context]);assert.deepEqual(result.revokedContextIds,[]);
  assert.deepEqual(decodeCursor(result.nextCursor,{actorId:actor,kind:'projection_changes',contextId:null}),['7','99_granted:'+context]);
  assert.match(calls[0].sql,/LIMIT 10/);assert.match(calls[0].sql,/LIMIT \$4::int/);assert.doesNotMatch(calls[0].sql,/source_links|private_reference/);
});
test('a byte-limited projection page never acknowledges discarded records',async()=>{
  const rows=Array.from({length:12},(_,i)=>({profile_sequence:'7',record_key:'20_expense:'+String(i+1).padStart(8,'0')+'-3333-4333-8333-333333333333',entity:'expenses',id:String(i),context_id:context,revision:'3',payload:{title:'x'.repeat(190000)},deleted:false,marker:null,stream_more:false}));
  const result=await pullProjectionChanges({query:async()=>({rows})},actor,{limit:'100'});
  assert.ok(result.records.length>0&&result.records.length<rows.length);assert.equal(result.hasMore,true);
  const keys=decodeCursor(result.nextCursor,{actorId:actor,kind:'projection_changes',contextId:null});
  assert.equal(keys[1],rows[result.records.length-1].record_key);
  assert.ok(Buffer.byteLength(JSON.stringify(result),'utf8')<2*1024*1024);
});
test('revoked materialized scopes carry tombstones and cannot simultaneously grant access',async()=>{
  const rows=[{profile_sequence:'7',record_key:'90_revoked:'+context,entity:'contexts',id:context,context_id:context,revision:'3',payload:{},deleted:true,marker:'revoked',stream_more:false}];
  const result=await pullProjectionChanges({query:async()=>({rows})},actor,{limit:'100'});
  assert.deepEqual(result.revokedContextIds,[context]);assert.deepEqual(result.grantedContextIds,[]);
  assert.equal(result.records[0].deleted,true);
});
test('record cursor is scoped, composite UUID checked, and never interpolated into SQL',async()=>{
  const scope={actorId:actor,kind:'projection_changes',contextId:null};
  const after=encodeCursor(scope,['7','30_balance:'+context+':'+id]);
  const calls=[];
  await pullProjectionChanges({query:async(sql,params)=>{calls.push({sql,params});return {rows:[]};}},actor,{after});
  assert.equal(calls[0].params[4],30);assert.equal(calls[0].params[5],context);assert.equal(calls[0].params[6],id);
  assert.ok(!calls[0].sql.includes(after));
  await assert.rejects(pullProjectionChanges({query:async()=>{throw new Error('must not run');}},actor,{after:encodeCursor(scope,['7','30_balance:not-a-uuid'])}),{code:'INVALID_CURSOR'});
});
test('context detail returns only an authorized membership summary including invitations',async()=>{
  const result=await readContext({query:async()=>({rows:[{context_id:context,kind:'group',name:'Home',currency:'INR',state:'active',membership_state:'invited',committed_sequence:'1',created_at:'2026-11-04T00:00:00Z'}]})},actor,context);
  assert.equal(result.contextId,context);assert.equal(result.membershipState,'invited');
  await assert.rejects(readContext({query:async()=>({rows:[]})},actor,context),{code:'CONTEXT_NOT_FOUND'});
});

test('expense reads preserve explicit full bill metadata and keep legacy totals unknown',async()=>{
 const bill={currency:'INR',totalMinor:'140000',contributions:[],allocation:{mode:'equal',participants:[],tieOrder:[]}};
 for(const value of [bill,null]) {
  let count=0;
  const client={query:async()=>++count===1?{rows:[{allowed:true}]}:{rows:[{expense_id:id,created_by:actor,accepted_revision_id:id,head_version:'1',total_minor:'120000',bill:value}]}};
  const result=await listContextExpenses(client,actor,context,{});
  assert.deepEqual(result.items[0].bill,value);
  assert.equal(result.items[0].totalMinor,'120000');
 }
});
