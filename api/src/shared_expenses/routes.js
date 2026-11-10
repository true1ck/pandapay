'use strict';
const {SharedExpenseError}=require('./validation');
const {validateCommand,executeCommand,validateSourceIdentity,uuid,UUID}=require('./commands');
const {parseSharedExpenseSourceReference}=require('./source_reference');
const {canonicalJson}=require('./canonical');
const q=require('./queries');
const {registerInvitationRoutes}=require('./invitations');
const {parseKeyRing}=require('./phone_crypto');
const {notifyAfterCommit}=require('./notifications');
const config=require('../config');

const UNAVAILABLE=Object.freeze({schemaVersion:1,available:false,reads:false,proposals:false,acceptedWrites:false,settlements:false,sourceFunding:false});
const MISSING_SCHEMA=new Set(['3F000','42P01','42883']);
const SQL_ERRORS=new Map([
  ['authentication_required',401],['feature_disabled',503],['invitations_unavailable',503],['invitation_unavailable',404],['invitation_phone_mismatch',403],['invitation_conflict',409],['invitation_rate_limited',429],['lookup_rate_limited',429],['invitation_self',400],['invalid_phone',400],['invitation_already_member',409],['invitation_duplicate',409],['invitation_declined_recently',409],['phone_not_verified',409],['join_declined_recently',409],['member_has_expenses',409],['owner_cannot_leave',409],['settle_first',409],['owner_still_present',409],['join_requests_full',409],['reveal_rate_limited',429],['check_attempts_exhausted',429],
  ...['context_not_authorized','member_not_authorized','membership_not_authorized','revision_not_authorized','source_not_authorized','receiver_confirmation_required','settlement_member_not_authorized','member_rename_not_authorized'].map(code=>[code,403]),
  ...['operation_conflict','operation_already_finished','approval_conflict','membership_conflict','revision_head_conflict','context_not_active','settlement_terminal_conflict','source_version_mismatch','source_explicit_review_required','source_not_eligible','member_not_renamable','member_name_taken','friend_name_taken','phone_not_available','owner_phone_required'].map(code=>[code,409]),
  ...['invalid_bill','invalid_context','invalid_invitation','invalid_member_name','member_name_reserved','member_not_found','invalid_member_order','invalid_operation','invalid_pair','invalid_proposal','invalid_response','invalid_settlement_response','invalid_settlement','invalid_snapshot','invalid_source_link','invalid_source_reference','invalid_void','snapshot_total_mismatch','context_member_limit','aggregate_limit_exceeded','source_overallocated'].map(code=>[code,400]),
]);
function sendError(res,error) {
  if(error instanceof SharedExpenseError) {
    const status=error.code==='PAYLOAD_TOO_LARGE'?413:['CONTEXT_NOT_FOUND','OPERATION_NOT_FOUND','EXPENSE_NOT_FOUND'].includes(error.code)?404:error.code==='SOURCE_NOT_AUTHORIZED'?403:400;
    return res.status(status).json({error:error.code.toLowerCase(),...(error.field?{field:error.field}:{})});
  }
  const status=SQL_ERRORS.get(error?.message);
  if(status) {
    // friend_name_taken carries the existing split so the app can offer to open it.
    const existing=error.message==='friend_name_taken'&&UUID.test(String(error.detail))?{existingContextId:error.detail}:{};
    return res.status(status).json({error:error.message,...existing});
  }
  if(MISSING_SCHEMA.has(error?.code))return res.status(503).json({error:'feature_unavailable'});
  if(['40001','40P01'].includes(error?.code))return res.status(409).json({error:'retryable_conflict',retryable:true});
  if(error?.code==='23505')return res.status(409).json({error:'identity_conflict'});
  return res.status(500).json({error:'internal_error'});
}
async function capabilities(client,{allowMissing=false}={}) {
  if(allowMissing)await client.query('SAVEPOINT shared_expenses_capability');
  try {
    const {rows}=await client.query('SELECT shared_expenses.capabilities() AS result');
    const result=rows[0]?.result;
    const flags=['reads','proposals','acceptedWrites','settlements','sourceFunding'];
    if(!result||typeof result!=='object'||result.schemaVersion!==1||flags.some(key=>typeof result[key]!=='boolean'))throw new Error('shared_capabilities_result_invalid');
    if(allowMissing)await client.query('RELEASE SAVEPOINT shared_expenses_capability');
    return {schemaVersion:1,available:true,...Object.fromEntries(flags.map(key=>[key,result[key]]))};
  }catch(error) {
    if(allowMissing&&MISSING_SCHEMA.has(error?.code)) {
      await client.query('ROLLBACK TO SAVEPOINT shared_expenses_capability');
      await client.query('RELEASE SAVEPOINT shared_expenses_capability');
      return {...UNAVAILABLE};
    }
    throw error;
  }
}
function registerSharedExpenseRoutes(app,{requireAuth,withUserClient,invitationSecret=config.sharedExpenseInviteSecret,phone}) {
  if(typeof requireAuth!=='function'||typeof withUserClient!=='function')throw new TypeError('shared expense dependencies required');
  const protect=(handler)=>[requireAuth,async(req,res)=>{
    res.set('Cache-Control','private, no-store');
    try {uuid(req.userId,'actorId');await handler(req,res);}catch(error){sendError(res,error);}
  }];
  let ring;const phoneOpts=phone||{enabled:()=>config.sharedExpensePhoneSharingEnabled===true,ring:()=>(ring===undefined?(ring=parseKeyRing(config.sharedExpensePhoneEncKeys)):ring)};
  // Loud, key-free warning when the feature is switched on but cannot store anything.
  if(phoneOpts.enabled()===true&&!phoneOpts.ring()) {
    process.stderr.write(JSON.stringify({level:'warn',ts:new Date().toISOString(),msg:'shared_expense_phone_sharing_enabled_without_usable_key_ring',hint:'set SHARED_EXPENSE_PHONE_ENC_KEYS; join requests will carry no phone number until then'})+'\n');
  }
  registerInvitationRoutes(app,{protect,withUserClient,sendError,secret:invitationSecret,phone:phoneOpts,androidPackageId:config.androidPackageId,
    notify:(args)=>notifyAfterCommit({withUserClient,...args}),
    // True when the API's database pool is short of connections: background work (the phone directory write) then
    // waits so it never takes a connection a request is waiting for.
    poolBusy:()=>{try{const {pool}=require('../db');return pool.waitingCount>0||(pool.idleCount===0&&pool.totalCount>=(pool.options?.max??10)-1);}catch(_){return false;}}});
  app.get('/shared-expenses/capabilities',...protect(async(req,res)=>{
    const result=await withUserClient(req.userId,client=>capabilities(client,{allowMissing:true}));
    res.json(result);
  }));
  app.post('/shared-expenses/commands',...protect(async(req,res)=>{
    const validated=validateCommand(req.body); // reject before DB or write locks
    const result=await withUserClient(req.userId,client=>executeCommand(client,validated.command));
    res.json({receipt:result,records:[]});
    // After the commit and the response: push is best effort and never blocks or fails a command.
    void notifyAfterCommit({withUserClient,actorId:req.userId,kind:validated.command.kind,payload:validated.command.payload,
      contextId:validated.command.payload.contextId,operationId:validated.command.operationId});
  }));
  app.post('/shared-expenses/sources/inspect',...protect(async(req,res)=>{
    const identity=validateSourceIdentity(req.body);
    if(identity.ownerAccountId!==req.userId)return res.status(403).json({error:'source_not_authorized'});
    const result=await withUserClient(req.userId,async client=>{
      const {rows}=await client.query('SELECT shared_expenses.inspect_source($1::jsonb) AS result',[JSON.stringify(identity)]);
      if(!rows[0]?.result)throw new Error('shared_source_result_invalid');
      return rows[0].result;
    });
    res.json(result);
  }));
  app.post('/shared-expenses/sources/admit',...protect(async(req,res)=>{
    const reference=parseSharedExpenseSourceReference(JSON.parse(canonicalJson(req.body)));
    if(reference.ownerAccountId!==req.userId)return res.status(403).json({error:'source_not_authorized'});
    if(!/^[a-f0-9]{64}$/.test(reference.sourceVersion??''))return res.status(400).json({error:'source_admission_pending'});
    const result=await withUserClient(req.userId,async client=>{
      const {rows}=await client.query('SELECT shared_expenses.admit_source($1::jsonb) AS result',[JSON.stringify(reference)]);
      if(!rows[0]?.result)throw new Error('shared_source_result_invalid');
      return rows[0].result;
    });
    res.json(result);
  }));
  const read=(path,handler)=>app.get(path,...protect(async(req,res)=>{
    const result=await withUserClient(req.userId,async client=>{
      if(!(await capabilities(client)).reads)throw Object.assign(new Error('feature_disabled'),{code:'55000'});
      return handler(client,req);
    });res.json(result);
  }));
  read('/shared-expenses/contexts',(client,req)=>q.listContexts(client,req.userId,req.query));
  read('/shared-expenses/overview',(client,req)=>q.readOverview(client,req.userId));
  read('/shared-expenses/activity',(client,req)=>q.listPersonalActivity(client,req.userId,req.query));
  read('/shared-expenses/contexts/:contextId/totals',(client,req)=>q.readContextTotals(client,req.userId,req.params.contextId));
  read('/shared-expenses/contexts/:contextId',(client,req)=>q.readContext(client,req.userId,req.params.contextId));
  read('/shared-expenses/contexts/:contextId/members',(client,req)=>q.listContextMembers(client,req.userId,req.params.contextId,req.query));
  read('/shared-expenses/contexts/:contextId/expenses',(client,req)=>q.listContextExpenses(client,req.userId,req.params.contextId,req.query));
  read('/shared-expenses/contexts/:contextId/expenses/:expenseId',(client,req)=>q.readExpense(client,req.userId,req.params.contextId,req.params.expenseId));
  read('/shared-expenses/contexts/:contextId/expenses/:expenseId/revisions',(client,req)=>q.listExpenseRevisions(client,req.userId,req.params.contextId,req.params.expenseId,req.query));
  read('/shared-expenses/contexts/:contextId/settlements',(client,req)=>q.listSettlementReports(client,req.userId,req.params.contextId,req.query));
  read('/shared-expenses/contexts/:contextId/balances',(client,req)=>q.readBalances(client,req.userId,req.params.contextId,req.query));
  read('/shared-expenses/contexts/:contextId/activity',(client,req)=>q.listContextActivity(client,req.userId,req.params.contextId,req.query));
  read('/shared-expenses/changes',(client,req)=>q.pullProjectionChanges(client,req.userId,req.query));
  read('/shared-expenses/operations/:operationId',async(client,req)=>({receipt:await q.readOperation(client,req.userId,req.params.operationId),records:[]}));
}
module.exports={registerSharedExpenseRoutes,capabilities,sendError};
