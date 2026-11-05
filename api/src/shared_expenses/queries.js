'use strict';
const v=require('./validation');
const {canonicalJson}=require('./canonical');
const {uuid}=require('./commands');

function pageRequest(query) {
  v.record(query,[],'query','INVALID_INPUT',['limit','after']);
  if(query.limit!==undefined && (typeof query.limit!=='string'||!v.matches(/^[1-9][0-9]{0,2}$/,query.limit)||Number(query.limit)>100))v.fail('INVALID_INPUT','query.limit');
  if(query.after!==undefined && (typeof query.after!=='string'||query.after.length>1024))v.fail('INVALID_CURSOR','query.after');
  return {limit:query.limit===undefined?50:Number(query.limit),after:query.after};
}
function encodeCursor(scope,lastKey) {return Buffer.from(canonicalJson({v:1,scope,lastKey}),'utf8').toString('base64url');}
function decodeCursor(value,scope) {
  if(typeof value!=='string'||value.length>1024||!v.matches(/^[A-Za-z0-9_-]+$/,value))v.fail('INVALID_CURSOR','after');
  let parsed;
  try {
    const bytes=Buffer.from(value,'base64url');
    if(bytes.toString('base64url')!==value)throw new Error('invalid');
    parsed=JSON.parse(bytes.toString('utf8'));
    v.record(parsed,['v','scope','lastKey']);
    if(parsed.v!==1||canonicalJson(parsed.scope)!==canonicalJson(scope)||!Array.isArray(parsed.lastKey)||parsed.lastKey.length>2||parsed.lastKey.some(key=>typeof key!=='string'||key.length>128))throw new Error('invalid');
  } catch {v.fail('INVALID_CURSOR','after');}
  return parsed.lastKey;
}
function scopeFor(actorId,kind,contextId=null) {uuid(actorId,'actorId');if(contextId!==null)uuid(contextId,'contextId');return {actorId,kind,contextId};}
async function authorizeContext(client,contextId) {
  uuid(contextId,'contextId');
  const result=await client.query('SELECT shared_expenses._can_read_context($1::uuid) AS allowed',[contextId]);
  if(result.rows[0]?.allowed!==true)v.fail('CONTEXT_NOT_FOUND','contextId');
}
function page(scope,request,rows,key,convert) {
  const hasMore=rows.length>request.limit,items=rows.slice(0,request.limit);
  return {items:items.map(convert),nextCursor:hasMore?encodeCursor(scope,key(items.at(-1))):null,hasMore};
}
function sequence(value,field) {
  if(typeof value!=='string'||!v.matches(/^(0|[1-9][0-9]*)$/,value)||BigInt(value)>v.MAX_AGGREGATE_MINOR)v.fail('INVALID_CURSOR',field);
  return value;
}
function timestamp(value) {const result=value instanceof Date?value:new Date(value);if(!Number.isFinite(result.getTime()))throw new Error('shared_query_result_invalid');return result.toISOString();}
function dateCursor(request,scope) {
  if(!request.after)return [null,null];
  const keys=decodeCursor(request.after,scope);
  if(keys.length!==2||!v.matches(/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3,6}Z$/,keys[0]))v.fail('INVALID_CURSOR','after');
  try {timestamp(keys[0]);uuid(keys[1],'after');}catch{v.fail('INVALID_CURSOR','after');}
  return keys; // Preserve PostgreSQL microseconds verbatim in the next bound.
}
function cursorUuid(request,scope) {
  if(!request.after)return null;
  const keys=decodeCursor(request.after,scope);
  if(keys.length!==1)v.fail('INVALID_CURSOR','after');
  try{return uuid(keys[0],'after');}catch{v.fail('INVALID_CURSOR','after');}
}
async function listContexts(client,actorId,query={}) {
  v.record(query,[],'query','INVALID_INPUT',['limit','after','kind','q']);
  if(query.kind!==undefined&&!['direct','group'].includes(query.kind))v.fail('INVALID_INPUT','query.kind');
  if(query.q!==undefined&&(typeof query.q!=='string'||query.q.length>128||/[\x00-\x1f\x7f]/.test(query.q)))v.fail('INVALID_INPUT','query.q');
  const filter=query.q??'',kind=query.kind??null;
  const request=pageRequest({...(query.limit===undefined?{}:{limit:query.limit}),...(query.after===undefined?{}:{after:query.after})});
  const scope=scopeFor(actorId,kind!==null||filter!==''?`contexts:${kind??'all'}:${require('node:crypto').createHash('sha256').update(filter).digest('hex')}`:'contexts');
  const [beforeDate,beforeId]=dateCursor(request,scope);
  const {rows}=await client.query(`SELECT c.context_id,c.kind,shared_expenses._context_label(c.kind,c.name,c.created_by,$1::uuid) AS name,c.currency,c.state,c.committed_sequence::text,c.created_at,
      to_char(c.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at_key,me.state AS membership_state,me.member_id,
      coalesce(t.expense_count,0)::text expense_count,b.owed_minor,b.owing_minor,
      EXISTS(SELECT FROM shared_expenses.expenses p WHERE p.context_id=c.context_id AND p.accepted_revision_id IS NULL) AS has_unaccepted_expenses
    FROM shared_expenses.members me JOIN shared_expenses.contexts c ON c.context_id=me.context_id
    LEFT JOIN shared_expenses.context_totals t ON t.context_id=c.context_id
    LEFT JOIN LATERAL(SELECT coalesce(sum(greatest(CASE WHEN p.low_member_id=me.member_id THEN p.balance_minor::numeric ELSE -p.balance_minor::numeric END,0)),0)::text owed_minor,
      coalesce(sum(greatest(CASE WHEN p.low_member_id=me.member_id THEN -p.balance_minor::numeric ELSE p.balance_minor::numeric END,0)),0)::text owing_minor
      FROM shared_expenses.pair_balances p WHERE p.context_id=c.context_id AND (p.low_member_id=me.member_id OR p.high_member_id=me.member_id)) b ON me.state='active'
    WHERE me.profile_id=$1::uuid AND me.state IN ('active','invited')
      AND ($5::text IS NULL OR c.kind=$5::text) AND ($6::text='' OR position(lower($6::text) in lower(shared_expenses._context_label(c.kind,c.name,c.created_by,$1::uuid)))>0)
      AND ($2::timestamptz IS NULL OR (c.created_at,c.context_id)<($2::timestamptz,$3::uuid))
    ORDER BY c.created_at DESC,c.context_id DESC LIMIT $4::int`,[actorId,beforeDate,beforeId,request.limit+1,kind,filter]);
  return page(scope,request,rows,row=>[row.created_at_key??timestamp(row.created_at),row.context_id],row=>({contextId:row.context_id,kind:row.kind,name:row.name,currency:row.currency,state:row.state,membershipState:row.membership_state,committedSequence:row.committed_sequence,createdAt:row.created_at_key??timestamp(row.created_at),memberId:row.member_id??null,expenseCount:row.expense_count??'0',hasUnacceptedExpenses:row.has_unaccepted_expenses===true,owedMinor:row.owed_minor??null,owingMinor:row.owing_minor??null}));
}
async function readContext(client,actorId,contextId) {
  scopeFor(actorId,'context',contextId);
  const {rows}=await client.query(`SELECT c.context_id,c.kind,shared_expenses._context_label(c.kind,c.name,c.created_by,$1::uuid) AS name,c.currency,c.state,c.committed_sequence::text,c.created_at,me.state AS membership_state
    FROM shared_expenses.members me JOIN shared_expenses.contexts c ON c.context_id=me.context_id
    WHERE me.profile_id=$1::uuid AND c.context_id=$2::uuid AND me.state IN ('active','invited')`,[actorId,contextId]);
  const row=rows[0];if(!row)v.fail('CONTEXT_NOT_FOUND','contextId');
  return {contextId:row.context_id,kind:row.kind,name:row.name,currency:row.currency,state:row.state,membershipState:row.membership_state,committedSequence:row.committed_sequence,createdAt:timestamp(row.created_at)};
}
async function listContextMembers(client,actorId,contextId,query={}) {
  const request=pageRequest(query),scope=scopeFor(actorId,'members',contextId),after=cursorUuid(request,scope);
  await authorizeContext(client,contextId);
  const {rows}=await client.query(`SELECT m.member_id,m.profile_id,m.role,m.state,shared_expenses._member_label(m.display_name,m.profile_id) AS display_name,b.balance_minor::text
    FROM shared_expenses.members m LEFT JOIN shared_expenses.member_balances b ON b.context_id=m.context_id AND b.member_id=m.member_id AND b.currency='INR'
    WHERE m.context_id=$1::uuid AND ($2::uuid IS NULL OR m.member_id>$2::uuid)
    ORDER BY m.member_id LIMIT $3::int`,[contextId,after,request.limit+1]);
  return page(scope,request,rows,row=>[row.member_id],row=>({contextId,memberId:row.member_id,profileId:row.profile_id,role:row.role,state:row.state,displayName:row.display_name,balanceMinor:row.balance_minor??'0'}));
}
async function listContextExpenses(client,actorId,contextId,query={}) {
  const request=pageRequest(query),scope=scopeFor(actorId,'expenses',contextId),after=cursorUuid(request,scope);
  await authorizeContext(client,contextId);
  const {rows}=await client.query(`SELECT e.expense_id,e.created_by,e.accepted_revision_id,e.head_version::text,
      r.title,r.occurred_on::text,r.currency,r.total_minor::text,r.is_void,r.revision_hash,r.projection_version,r.bill,
      coalesce(own.paid_minor,0)::text your_paid_minor,coalesce(own.share_minor,0)::text your_share_minor,
      CASE WHEN latest.revision_id IS NOT NULL AND latest.revision_id IS DISTINCT FROM e.accepted_revision_id THEN
        jsonb_build_object('revisionId',latest.revision_id,'title',latest.title,'occurredOn',latest.occurred_on::text,
          'totalMinor',latest.total_minor::text,'bill',latest.bill,'void',latest.is_void,
          'yourPaidMinor',coalesce(pending_own.paid_minor,0)::text,'yourShareMinor',coalesce(pending_own.share_minor,0)::text)
        ELSE NULL END AS pending_revision
    FROM shared_expenses.expenses e LEFT JOIN shared_expenses.expense_revisions r
      ON r.context_id=e.context_id AND r.expense_id=e.expense_id AND r.revision_id=e.accepted_revision_id
    LEFT JOIN shared_expenses.revision_members own ON own.context_id=e.context_id AND own.revision_id=e.accepted_revision_id AND shared_expenses._review_profile(own.context_id,own.member_id,own.approver_profile_id)=$4::uuid
    LEFT JOIN LATERAL(SELECT revision_id,title,occurred_on,total_minor,bill,is_void FROM shared_expenses.expense_revisions
      WHERE context_id=e.context_id AND expense_id=e.expense_id ORDER BY created_at DESC,revision_id DESC LIMIT 1) latest ON true
    LEFT JOIN shared_expenses.revision_members pending_own ON pending_own.context_id=e.context_id AND pending_own.revision_id=latest.revision_id AND shared_expenses._review_profile(pending_own.context_id,pending_own.member_id,pending_own.approver_profile_id)=$4::uuid
    WHERE e.context_id=$1::uuid AND ($2::uuid IS NULL OR e.expense_id>$2::uuid)
    ORDER BY e.expense_id LIMIT $3::int`,[contextId,after,request.limit+1,actorId]);
  return page(scope,request,rows,row=>[row.expense_id],row=>({contextId,expenseId:row.expense_id,createdBy:row.created_by,acceptedRevisionId:row.accepted_revision_id,headVersion:row.head_version,title:row.title??null,occurredOn:row.occurred_on??null,currency:row.currency??'INR',totalMinor:row.total_minor??null,void:row.is_void??false,revisionHash:row.revision_hash??null,projectionVersion:row.projection_version??null,yourPaidMinor:row.your_paid_minor??'0',yourShareMinor:row.your_share_minor??'0',bill:row.bill??null,pendingRevision:row.pending_revision??null}));
}
async function readBalances(client,actorId,contextId,query={}) {
  const request=pageRequest(query),scope=scopeFor(actorId,'pairs',contextId);
  let low=null,high=null;
  if(request.after) {
    const keys=decodeCursor(request.after,scope);
    if(keys.length!==2)v.fail('INVALID_CURSOR','after');
    try {low=uuid(keys[0],'after');high=uuid(keys[1],'after');}catch{v.fail('INVALID_CURSOR','after');}
  }
  await authorizeContext(client,contextId);
  const {rows}=await client.query(`SELECT low_member_id,high_member_id,currency,balance_minor::text FROM shared_expenses.pair_balances
    WHERE context_id=$1::uuid AND ($2::uuid IS NULL OR (low_member_id,high_member_id)>($2::uuid,$3::uuid))
    ORDER BY low_member_id,high_member_id LIMIT $4::int`,[contextId,low,high,request.limit+1]);
  return page(scope,request,rows,row=>[row.low_member_id,row.high_member_id],row=>({contextId,lowMemberId:row.low_member_id,highMemberId:row.high_member_id,currency:row.currency,balanceMinor:row.balance_minor}));
}
async function listContextActivity(client,actorId,contextId,query={}) {
  const request=pageRequest(query),scope=scopeFor(actorId,'activity',contextId);
  let after='0';
  if(request.after) {const keys=decodeCursor(request.after,scope);if(keys.length!==1)v.fail('INVALID_CURSOR','after');after=sequence(keys[0],'after');}
  await authorizeContext(client,contextId);
  const {rows}=await client.query(`SELECT sequence::text,event_id,kind,origin_id,actor_profile_id,payload,created_at FROM shared_expenses.context_events
    WHERE context_id=$1::uuid AND sequence>$2::bigint ORDER BY sequence LIMIT $3::int`,[contextId,after,request.limit+1]);
  return page(scope,request,rows,row=>[row.sequence],row=>({contextId,sequence:row.sequence,eventId:row.event_id,kind:row.kind,originId:row.origin_id,actorProfileId:row.actor_profile_id,payload:row.payload,createdAt:timestamp(row.created_at)}));
}
async function listChanges(client,actorId,query={}) {
  const request=pageRequest(query),scope=scopeFor(actorId,'changes');
  let after='0';
  if(request.after) {const keys=decodeCursor(request.after,scope);if(keys.length!==1)v.fail('INVALID_CURSOR','after');after=sequence(keys[0],'after');}
  const {rows}=await client.query(`SELECT sequence::text,context_id,context_sequence::text FROM shared_expenses.profile_events
    WHERE profile_id=$1::uuid AND sequence > $2::bigint ORDER BY sequence LIMIT $3::int`,[actorId,after,request.limit+1]);
  const result=page(scope,request,rows,row=>[row.sequence],row=>({sequence:row.sequence,contextId:row.context_id,contextSequence:row.context_sequence}));
  const cursorAfter=result.items.at(-1)?.sequence??after;
  return {...result,cursorAfter,cursor:encodeCursor(scope,[cursorAfter])};
}
async function readOperation(client,actorId,operationId) {
  uuid(actorId,'actorId');uuid(operationId,'operationId');
  const {rows}=await client.query(`SELECT operation_id,command_kind,request_hash,context_id,result FROM shared_expenses.operation_receipts
    WHERE actor_profile_id=$1::uuid AND operation_id=$2::uuid`,[actorId,operationId]);
  const row=rows[0];if(!row||row.result===null)v.fail('OPERATION_NOT_FOUND','operationId');
  if(row.context_id!==null)await authorizeContext(client,row.context_id);
  return {operationId:row.operation_id,kind:row.command_kind,requestHash:row.request_hash,contextId:row.context_id,result:row.result,state:'committed'};
}
async function readExpense(client,actorId,contextId,expenseId) {
  scopeFor(actorId,'expense',contextId);uuid(expenseId,'expenseId');
  await authorizeContext(client,contextId);
  const {rows}=await client.query(`SELECT expense_id,created_by,accepted_revision_id,head_version::text FROM shared_expenses.expenses
    WHERE context_id=$1::uuid AND expense_id=$2::uuid`,[contextId,expenseId]);
  const row=rows[0];if(!row)v.fail('EXPENSE_NOT_FOUND','expenseId');
  return {contextId,expenseId:row.expense_id,createdBy:row.created_by,acceptedRevisionId:row.accepted_revision_id,headVersion:row.head_version};
}
async function listExpenseRevisions(client,actorId,contextId,expenseId,query={}) {
  uuid(expenseId,'expenseId');
  const request=pageRequest(query),scope={...scopeFor(actorId,'revisions',contextId),expenseId};
  const [beforeDate,beforeId]=dateCursor(request,scope);
  await authorizeContext(client,contextId);
  const {rows}=await client.query(`SELECT r.revision_id,r.author_profile_id,r.expected_head_revision_id,r.revision_hash,r.projection_version,r.title,r.occurred_on::text,r.currency,r.total_minor::text,r.is_void,r.snapshot,r.projected_edges,r.bill,r.created_at,
      to_char(r.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at_key,
      CASE WHEN e.accepted_revision_id=r.revision_id THEN CASE WHEN r.is_void THEN 'voided' ELSE 'accepted' END
        WHEN r.expected_head_revision_id IS DISTINCT FROM e.accepted_revision_id THEN 'superseded'
        WHEN EXISTS(SELECT FROM shared_expenses.revision_approvals d WHERE d.context_id=r.context_id AND d.revision_id=r.revision_id AND d.decision='reject') THEN 'rejected'
        WHEN EXISTS(SELECT FROM shared_expenses.revision_members m WHERE m.context_id=r.context_id AND m.revision_id=r.revision_id AND m.approval_required
          AND (shared_expenses._review_profile(m.context_id,m.member_id,m.approver_profile_id) IS NULL OR NOT EXISTS(SELECT FROM shared_expenses.revision_approvals d WHERE d.context_id=m.context_id AND d.revision_id=m.revision_id AND d.member_id=m.member_id AND d.actor_profile_id=shared_expenses._review_profile(m.context_id,m.member_id,m.approver_profile_id) AND d.revision_hash=r.revision_hash AND d.decision='approve'))) THEN 'awaiting_approval'
        ELSE 'awaiting_acceptance' END AS review_state,
      EXISTS(SELECT FROM shared_expenses.revision_members m WHERE m.context_id=r.context_id AND m.revision_id=r.revision_id AND shared_expenses._review_profile(m.context_id,m.member_id,m.approver_profile_id)=$6::uuid AND m.approval_required) AS actor_required,
      (SELECT d.decision FROM shared_expenses.revision_approvals d WHERE d.context_id=r.context_id AND d.revision_id=r.revision_id AND d.actor_profile_id=$6::uuid LIMIT 1) AS your_decision,
      coalesce(own.paid_minor,0)::text your_paid_minor,coalesce(own.share_minor,0)::text your_share_minor,own.member_id AS own_member_id
    FROM shared_expenses.expense_revisions r JOIN shared_expenses.expenses e ON e.context_id=r.context_id AND e.expense_id=r.expense_id
    LEFT JOIN shared_expenses.revision_members own ON own.context_id=r.context_id AND own.revision_id=r.revision_id AND shared_expenses._review_profile(own.context_id,own.member_id,own.approver_profile_id)=$6::uuid
    WHERE r.context_id=$1::uuid AND r.expense_id=$2::uuid
      AND ($3::timestamptz IS NULL OR (r.created_at,r.revision_id)<($3::timestamptz,$4::uuid))
    ORDER BY r.created_at DESC,r.revision_id DESC LIMIT $5::int`,[contextId,expenseId,beforeDate,beforeId,request.limit+1,actorId]);
  return page(scope,request,rows,row=>[row.created_at_key??timestamp(row.created_at),row.revision_id],row=>({contextId,expenseId,revisionId:row.revision_id,authorProfileId:row.author_profile_id,expectedHeadRevisionId:row.expected_head_revision_id,revisionHash:row.revision_hash,projectionVersion:row.projection_version,title:row.title,occurredOn:row.occurred_on,currency:row.currency,totalMinor:row.total_minor,void:row.is_void,snapshot:row.snapshot,bill:row.bill??null,projectedEdges:row.projected_edges,createdAt:row.created_at_key??timestamp(row.created_at),reviewState:row.review_state??'unknown',canRespond:row.actor_required===true&&!row.your_decision&&row.review_state==='awaiting_approval',yourDecision:row.your_decision??null,yourPaidMinor:row.your_paid_minor??'0',yourShareMinor:row.your_share_minor??'0',ownMemberId:row.own_member_id??null}));
}
async function listSettlementReports(client,actorId,contextId,query={}) {
  const request=pageRequest(query),scope=scopeFor(actorId,'settlements',contextId),after=cursorUuid(request,scope);
  await authorizeContext(client,contextId);
  const {rows}=await client.query(`SELECT r.settlement_id,r.reporter_profile_id,r.payer_member_id,r.receiver_member_id,r.amount_minor::text,r.currency,r.method,r.paid_on::text,r.created_at,coalesce(e.kind,'pending') AS status
    FROM shared_expenses.settlement_reports r
    LEFT JOIN LATERAL(SELECT kind FROM shared_expenses.settlement_events e WHERE e.context_id=r.context_id AND e.settlement_id=r.settlement_id ORDER BY e.created_at DESC,e.event_id DESC LIMIT 1) e ON true
    WHERE r.context_id=$1::uuid AND ($2::uuid IS NULL OR r.settlement_id>$2::uuid)
    ORDER BY r.settlement_id LIMIT $3::int`,[contextId,after,request.limit+1]);
  return page(scope,request,rows,row=>[row.settlement_id],row=>({contextId,settlementId:row.settlement_id,reporterProfileId:row.reporter_profile_id,payerMemberId:row.payer_member_id,receiverMemberId:row.receiver_member_id,amountMinor:row.amount_minor,currency:row.currency,method:row.method,paidOn:row.paid_on,createdAt:timestamp(row.created_at),status:row.status}));
}

// Each branch has a native UUID keyset and its own LIMIT, before JSON shaping.
// The event window is bounded independently from returned record count. A grant
// snapshot can span pages without acknowledging the source event prematurely.
const PROJECTION_FEED_SQL=`WITH selected_events AS MATERIALIZED (
  SELECT pe.sequence AS profile_sequence,pe.context_id,pe.context_sequence,
    ce.event_id,ce.kind,ce.origin_id,ce.actor_profile_id,ce.payload AS event_payload,ce.created_at AS event_created_at
  FROM shared_expenses.profile_events pe
  LEFT JOIN shared_expenses.context_events ce ON ce.context_id=pe.context_id AND ce.sequence=pe.context_sequence
  WHERE pe.profile_id=$1::uuid AND pe.sequence >= $2::bigint AND $3::text IS NOT NULL
  ORDER BY pe.sequence LIMIT 10
), visible AS MATERIALIZED (
  SELECT p.profile_sequence,p.context_id,p.context_sequence,p.event_id,p.kind,p.origin_id,p.actor_profile_id,p.event_payload,p.event_created_at,
    c.context_id IS NOT NULL AS readable,c.kind AS context_kind,shared_expenses._context_label(c.kind,c.name,c.created_by,$1::uuid) AS name,c.currency,c.state,c.created_at AS context_created_at,
    coalesce(c.committed_sequence,p.context_sequence)::text AS revision,me.state AS membership_state,me.member_id AS own_member_id,
    me.state='active' AND (p.kind='context.created' OR (p.kind='membership.responded' AND p.origin_id=me.member_id AND p.event_payload->>'accepted'='true')) AS full_grant
  FROM selected_events p LEFT JOIN shared_expenses.contexts c ON c.context_id=p.context_id
  LEFT JOIN shared_expenses.members me ON me.context_id=c.context_id AND me.profile_id=$1::uuid
), records AS (
  SELECT p.profile_sequence,'00_context:'||p.context_id::text AS record_key,'contexts'::text AS entity,p.context_id::text AS id,p.context_id,p.revision,
    jsonb_build_object('contextId',p.context_id,'kind',p.context_kind,'name',p.name,'currency',p.currency,'state',p.state,'membershipState',p.membership_state,'committedSequence',p.revision,'createdAt',p.context_created_at) AS payload,false AS deleted,NULL::text AS marker
  FROM visible p WHERE p.readable AND (p.profile_sequence>$2::bigint OR $5::int<0 OR ($5::int=0 AND p.context_id>$6::uuid))
  UNION ALL
  SELECT p.profile_sequence,'10_member:'||m.member_id::text,'members',m.member_id::text,p.context_id,p.revision,
    jsonb_build_object('contextId',p.context_id,'memberId',m.member_id,'profileId',m.profile_id,'role',m.role,'state',m.state,'displayName',shared_expenses._member_label(m.display_name,m.profile_id)),false,NULL::text
  FROM visible p CROSS JOIN LATERAL (
    SELECT member_id,profile_id,role,state,display_name FROM shared_expenses.members
    WHERE context_id=p.context_id AND (p.full_grant OR member_id=p.origin_id)
      AND (p.profile_sequence>$2::bigint OR $5::int<10 OR ($5::int=10 AND member_id>$6::uuid))
    ORDER BY member_id LIMIT $4::int
  ) m WHERE p.readable
  UNION ALL
  SELECT p.profile_sequence,'20_expense:'||e.expense_id::text,'expenses',e.expense_id::text,p.context_id,p.revision,
    jsonb_build_object('recordType','head','contextId',p.context_id,'expenseId',e.expense_id,'createdBy',e.created_by,'acceptedRevisionId',e.accepted_revision_id,'headVersion',e.head_version::text,
      'accepted',CASE WHEN r.revision_id IS NULL THEN NULL ELSE jsonb_build_object('revisionId',r.revision_id,'title',r.title,'occurredOn',r.occurred_on,'currency',r.currency,'totalMinor',r.total_minor::text,'void',r.is_void,'snapshot',r.snapshot,'bill',r.bill,'projectionVersion',r.projection_version) END),false,NULL::text
  FROM visible p CROSS JOIN LATERAL (
    SELECT expense_id,created_by,accepted_revision_id,head_version FROM shared_expenses.expenses
    WHERE context_id=p.context_id AND (p.full_grant OR expense_id=(p.event_payload->>'expenseId')::uuid)
      AND (p.profile_sequence>$2::bigint OR $5::int<20 OR ($5::int=20 AND expense_id>$6::uuid))
    ORDER BY expense_id LIMIT $4::int
  ) e LEFT JOIN shared_expenses.expense_revisions r ON r.context_id=p.context_id AND r.expense_id=e.expense_id AND r.revision_id=e.accepted_revision_id
  WHERE p.readable
  UNION ALL
  SELECT p.profile_sequence,'21_revision:'||r.revision_id::text,'expenses',r.expense_id::text||':'||r.revision_id::text,p.context_id,p.revision,
    jsonb_build_object('recordType','revision','contextId',p.context_id,'expenseId',r.expense_id,'revisionId',r.revision_id,'authorProfileId',r.author_profile_id,'expectedHeadRevisionId',r.expected_head_revision_id,'revisionHash',r.revision_hash,'projectionVersion',r.projection_version,'title',r.title,'occurredOn',r.occurred_on,'currency',r.currency,'totalMinor',r.total_minor::text,'void',r.is_void,'snapshot',r.snapshot,'bill',r.bill,'projectedEdges',r.projected_edges),false,NULL::text
  FROM visible p CROSS JOIN LATERAL (
    SELECT revision_id,expense_id,author_profile_id,expected_head_revision_id,revision_hash,projection_version,title,occurred_on,currency,total_minor,is_void,snapshot,projected_edges,bill
    FROM shared_expenses.expense_revisions WHERE context_id=p.context_id AND revision_id=p.origin_id
      AND (p.profile_sequence>$2::bigint OR $5::int<21 OR ($5::int=21 AND revision_id>$6::uuid))
    ORDER BY revision_id LIMIT $4::int
  ) r WHERE p.readable AND p.kind LIKE 'expense.%'
  UNION ALL
  SELECT p.profile_sequence,'30_balance:'||k.low_member_id::text||':'||k.high_member_id::text,'balances',k.low_member_id::text||':'||k.high_member_id::text,p.context_id,p.revision,
    jsonb_build_object('contextId',p.context_id,'currency','INR','lowMemberId',k.low_member_id,'highMemberId',k.high_member_id,'balanceMinor',coalesce(b.balance_minor,0)::text),b.low_member_id IS NULL,NULL::text
  FROM visible p CROSS JOIN LATERAL (
    SELECT pair.low_member_id,pair.high_member_id FROM (
      SELECT low_member_id,high_member_id FROM shared_expenses.pair_balances WHERE context_id=p.context_id AND currency='INR' AND p.full_grant
        AND (p.profile_sequence>$2::bigint OR $5::int<30 OR ($5::int=30 AND (low_member_id,high_member_id)>($6::uuid,$7::uuid)))
      UNION
      SELECT low_member_id,high_member_id FROM shared_expenses.journal_entries WHERE context_id=p.context_id AND origin_id=p.origin_id AND NOT coalesce(p.full_grant,false)
        AND (p.profile_sequence>$2::bigint OR $5::int<30 OR ($5::int=30 AND (low_member_id,high_member_id)>($6::uuid,$7::uuid)))
    ) pair ORDER BY pair.low_member_id,pair.high_member_id LIMIT $4::int
  ) k LEFT JOIN shared_expenses.pair_balances b ON b.context_id=p.context_id AND b.currency='INR' AND b.low_member_id=k.low_member_id AND b.high_member_id=k.high_member_id
  WHERE p.readable AND (p.full_grant OR p.kind IN ('expense.accepted','settlement.confirmed'))
  UNION ALL
  SELECT p.profile_sequence,'40_cost:'||f.expense_id::text,'personal_cost',f.expense_id::text,p.context_id,p.revision,
    jsonb_build_object('contextId',p.context_id,'expenseId',f.expense_id,'revisionId',f.revision_id,'memberId',f.member_id,'currency',f.currency,'shareMinor',f.share_minor::text,'sourceLinkedMinor',f.source_linked_minor::text,'occurredOn',f.occurred_on),false,NULL::text
  FROM visible p CROSS JOIN LATERAL (
    SELECT expense_id,revision_id,member_id,currency,share_minor,source_linked_minor,occurred_on FROM shared_expenses.private_cost_facts
    WHERE profile_id=$1::uuid AND context_id=p.context_id AND (p.full_grant OR expense_id=(p.event_payload->>'expenseId')::uuid)
      AND (p.profile_sequence>$2::bigint OR $5::int<40 OR ($5::int=40 AND expense_id>$6::uuid))
    ORDER BY expense_id LIMIT $4::int
  ) f WHERE p.readable
  UNION ALL
  SELECT p.profile_sequence,'50_activity:'||p.event_id::text,'activity',p.event_id::text,p.context_id,p.revision,
    jsonb_build_object('contextId',p.context_id,'eventId',p.event_id,'kind',p.kind,'originId',p.origin_id,'actorProfileId',p.actor_profile_id,'payload',p.event_payload,'sequence',p.context_sequence::text,'createdAt',p.event_created_at),false,NULL::text
  FROM visible p WHERE p.readable AND p.event_id IS NOT NULL AND (p.profile_sequence>$2::bigint OR $5::int<50 OR ($5::int=50 AND p.event_id>$6::uuid))
  UNION ALL
  SELECT p.profile_sequence,'90_revoked:'||p.context_id::text,'contexts',p.context_id::text,p.context_id,p.revision,'{}'::jsonb,true,'revoked'
  FROM visible p WHERE NOT p.readable AND (p.profile_sequence>$2::bigint OR $5::int<90 OR ($5::int=90 AND p.context_id>$6::uuid))
  UNION ALL
  SELECT p.profile_sequence,'99_granted:'||p.context_id::text,NULL::text,p.context_id::text,p.context_id,p.revision,'{}'::jsonb,false,'granted'
  FROM visible p WHERE p.full_grant AND p.readable AND (p.profile_sequence>$2::bigint OR $5::int<99 OR ($5::int=99 AND p.context_id>$6::uuid))
)
SELECT profile_sequence::text,record_key,entity,id,context_id,revision,payload,deleted,marker,
  EXISTS(SELECT FROM shared_expenses.profile_events more WHERE more.profile_id=$1::uuid AND more.sequence>(SELECT max(profile_sequence) FROM selected_events)) AS stream_more
FROM records ORDER BY profile_sequence,record_key COLLATE "C" LIMIT $4::int`;

async function pullProjectionChanges(client,actorId,query={}) {
  const request=pageRequest(query),scope=scopeFor(actorId,'projection_changes');
  let afterSequence='0',afterKey='',rank=-1,low=null,high=null;
  if(request.after) {
    const keys=decodeCursor(request.after,scope);
    if(keys.length!==2)v.fail('INVALID_CURSOR','after');
    afterSequence=sequence(keys[0],'after');afterKey=keys[1];
    const match=/^(00_context|10_member|20_expense|21_revision|30_balance|40_cost|50_activity|90_revoked|99_granted):([a-f0-9-]{36})(?::([a-f0-9-]{36}))?$/.exec(afterKey);
    if(!match)v.fail('INVALID_CURSOR','after');
    rank=Number(match[1].slice(0,2));
    try {low=uuid(match[2],'after');if(rank===30)high=uuid(match[3],'after');else if(match[3])v.fail('INVALID_CURSOR','after');}catch{v.fail('INVALID_CURSOR','after');}
  }
  const {rows}=await client.query(PROJECTION_FEED_SQL,[actorId,afterSequence,afterKey,request.limit+1,rank,low,high]);
  const records=[],revoked=new Set(),granted=new Set();
  let consumed=0,bytes=0,cursor=request.after??null;
  for(const row of rows.slice(0,request.limit)) {
    const record=row.entity===null?null:{entity:row.entity,id:row.id,contextId:row.context_id,revision:row.revision,payload:row.payload,deleted:row.deleted};
    const size=record?Buffer.byteLength(JSON.stringify(record),'utf8'):64;
    if(size>262144)throw new Error('shared_projection_record_too_large');
    if(bytes+size>1900000)break;
    bytes+=size;consumed++;
    if(record)records.push(record);
    if(row.marker==='revoked')revoked.add(row.context_id);
    if(row.marker==='granted')granted.add(row.context_id);
    cursor=encodeCursor(scope,[row.profile_sequence,row.record_key]);
  }
  // A revocation wins over a grant in the same page; no partial snapshot may
  // reopen a private scope whose current membership was removed.
  for(const id of revoked)granted.delete(id);
  return {records,nextCursor:cursor,hasMore:consumed<rows.length||rows.some(row=>row.stream_more===true),revokedContextIds:[...revoked],grantedContextIds:[...granted]};
}
function reportAmount(value,field) {
  return v.amount(value,field,{max:v.MAX_AGGREGATE_MINOR,overflow:'AGGREGATE_LIMIT_EXCEEDED'}).toString();
}
async function readOverview(client,actorId) {
  uuid(actorId,'actorId');
  const {rows}=await client.query(`WITH mine AS MATERIALIZED(
    SELECT context_id,member_id FROM shared_expenses.members WHERE profile_id=$1::uuid AND state='active'
  ), directions AS(
    SELECT CASE WHEN p.low_member_id=m.member_id THEN p.balance_minor::numeric ELSE -p.balance_minor::numeric END amount
    FROM mine m JOIN shared_expenses.pair_balances p ON p.context_id=m.context_id AND (p.low_member_id=m.member_id OR p.high_member_id=m.member_id)
  ) SELECT coalesce(sum(greatest(amount,0)),0)::text owed_minor,coalesce(sum(greatest(-amount,0)),0)::text owing_minor,
    (SELECT count(*)::text FROM mine) context_count,
    (SELECT coalesce(sum(t.expense_count),0)::text FROM mine m JOIN shared_expenses.context_totals t ON t.context_id=m.context_id) expense_count FROM directions`,[actorId]);
  const row=rows[0];if(!row)throw new Error('shared_query_result_invalid');
  const owed=reportAmount(row.owed_minor,'owedMinor'),owing=reportAmount(row.owing_minor,'owingMinor');
  return {currency:'INR',owedMinor:owed,owingMinor:owing,netMinor:(BigInt(owed)-BigInt(owing)).toString(),contextCount:reportAmount(row.context_count,'contextCount'),expenseCount:reportAmount(row.expense_count,'expenseCount')};
}
async function readContextTotals(client,actorId,contextId) {
  scopeFor(actorId,'totals',contextId);await authorizeContext(client,contextId);
  const {rows}=await client.query(`SELECT me.member_id,coalesce(t.total_minor,0)::text total_minor,coalesce(t.expense_count,0)::text expense_count,
    coalesce(mt.paid_minor,0)::text paid_minor,coalesce(mt.share_minor,0)::text share_minor
    FROM shared_expenses.members me LEFT JOIN shared_expenses.context_totals t ON t.context_id=me.context_id
    LEFT JOIN shared_expenses.member_totals mt ON mt.context_id=me.context_id AND mt.member_id=me.member_id
    WHERE me.context_id=$1::uuid AND me.profile_id=$2::uuid AND me.state='active'`,[contextId,actorId]);
  const row=rows[0];if(!row)v.fail('CONTEXT_NOT_FOUND','contextId');
  return {contextId,currency:'INR',sharedTotalMinor:reportAmount(row.total_minor,'sharedTotalMinor'),yourPaidMinor:reportAmount(row.paid_minor,'yourPaidMinor'),yourShareMinor:reportAmount(row.share_minor,'yourShareMinor'),expenseCount:reportAmount(row.expense_count,'expenseCount'),memberId:row.member_id};
}
async function listPersonalActivity(client,actorId,query={}) {
  v.record(query,[],'query','INVALID_INPUT',['limit','after','q']);
  const filter=query.q??'';
  if(typeof filter!=='string'||filter.length>128||/[\x00-\x1f\x7f]/.test(filter))v.fail('INVALID_INPUT','query.q');
  const request=pageRequest({...(query.limit===undefined?{}:{limit:query.limit}),...(query.after===undefined?{}:{after:query.after})});
  const scope=scopeFor(actorId,`personal_activity:${require('node:crypto').createHash('sha256').update(filter).digest('hex')}`);
  let before=null;
  if(request.after){const keys=decodeCursor(request.after,scope);if(keys.length!==1)v.fail('INVALID_CURSOR','after');before=sequence(keys[0],'after');}
  const {rows}=await client.query(`SELECT pe.sequence::text,c.context_id,shared_expenses._context_label(c.kind,c.name,c.created_by,$1::uuid) AS name,ce.kind,ce.origin_id,ce.created_at
    FROM shared_expenses.profile_events pe JOIN shared_expenses.contexts c ON c.context_id=pe.context_id
    JOIN shared_expenses.context_events ce ON ce.context_id=pe.context_id AND ce.sequence=pe.context_sequence
    WHERE pe.profile_id=$1::uuid AND ($2::bigint IS NULL OR pe.sequence<$2::bigint)
      AND ($4::text='' OR position(lower($4::text) in lower(shared_expenses._context_label(c.kind,c.name,c.created_by,$1::uuid)||' '||ce.kind))>0)
    ORDER BY pe.sequence DESC LIMIT $3::int`,[actorId,before,request.limit+1,filter]);
  return page(scope,request,rows,row=>[row.sequence],row=>({contextId:row.context_id,sequence:row.sequence,contextName:row.name,kind:row.kind,originId:row.origin_id,createdAt:timestamp(row.created_at)}));
}
module.exports={pageRequest,encodeCursor,decodeCursor,authorizeContext,listContexts,readContext,listContextMembers,listContextExpenses,readBalances,listContextActivity,listChanges,readOperation,readExpense,listExpenseRevisions,listSettlementReports,pullProjectionChanges,readOverview,readContextTotals,listPersonalActivity};
