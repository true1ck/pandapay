'use strict';
const crypto=require('node:crypto');
const {uuid}=require('./commands');
const {record,fail}=require('./validation');
const TOKEN=/^[A-Za-z0-9_-]{43}$/;
function normalizePhone(value) {
  if(typeof value!=='string'||value.length>40||!/^[+0-9 ()-]+$/.test(value))fail('INVALID_INPUT','phoneNumber');
  let phone=value.replace(/[ ()-]/g,'');
  if(/^[6-9][0-9]{9}$/.test(phone))phone='+91'+phone;
  if(!/^\+[1-9][0-9]{7,14}$/.test(phone))fail('INVALID_INPUT','phoneNumber');
  return phone;
}
function key(secret) {
  if(typeof secret!=='string'||secret.length<32)throw Object.assign(new Error('invitations_unavailable'),{status:503});
  return secret;
}
function phoneHash(secret,phone) {return crypto.createHmac('sha256',key(secret)).update('pandapay:split-phone:v1:'+normalizePhone(phone)).digest('hex');}
function verifiedPhoneHash(secret,contacts) {
  if(contacts?.phone?.verified!==true||typeof contacts.phone.value!=='string')return null;
  return phoneHash(secret,contacts.phone.value);
}
function inviteCredentials(secret,actor,id) {
  uuid(actor,'actorId');uuid(id,'invitationId');
  const token=crypto.createHmac('sha256',key(secret)).update(`pandapay:split-invite:v1:${actor}:${id}`).digest('base64url');
  return {token,tokenHash:crypto.createHash('sha256').update(token).digest('hex')};
}
function groupLinkCredentials(secret,actor,ctx,linkId) {
  uuid(actor,'actorId');uuid(ctx,'contextId');uuid(linkId,'linkId');
  const token=crypto.createHmac('sha256',key(secret)).update(`pandapay:group-link:v1:${actor}:${ctx}:${linkId}`).digest('base64url');
  return {token,tokenHash:crypto.createHash('sha256').update(token).digest('hex')};
}
function tokenHash(token) {if(!TOKEN.test(token))fail('INVALID_INPUT','token');return crypto.createHash('sha256').update(token).digest('hex');}
/** First name and last initial only: enough to recognise a person, not to profile them. */
function maskName(name) {
  if(typeof name!=='string')return null;
  const parts=name.trim().split(/\s+/).filter(Boolean);
  if(!parts.length)return null;
  return parts.length===1?parts[0].slice(0,40):parts[0].slice(0,40)+' '+Array.from(parts[parts.length-1])[0]+'.';
}
/**
 * Keeps the caller's own phone hash in the directory without any client call:
 * at most one write per person per day (or when the number changes), never
 * blocking or failing the request that triggered it.
 */
function createDirectoryToucher({withUserClient,secret,ttlMs=24*3600*1000,limit=20000,now=Date.now}) {
  const seen=new Map();
  return function touch(req) {
    try {
      const hash=verifiedPhoneHash(secret,req.verifiedSession?.verifiedContacts);
      if(!hash||!req.userId)return Promise.resolve(false);
      const prior=seen.get(req.userId);
      if(prior&&prior.hash===hash&&now()-prior.at<ttlMs)return Promise.resolve(false);
      return withUserClient(req.userId,client=>client.query('SELECT shared_expenses.register_phone($1::text,NULL) AS result',[hash]))
        .then(()=>{if(seen.size>=limit)seen.delete(seen.keys().next().value);seen.set(req.userId,{hash,at:now()});return true;})
        .catch(()=>false);
    }catch(_){return Promise.resolve(false);}
  };
}
function requestHash(body) {return crypto.createHash('sha256').update(JSON.stringify(body)).digest('hex');}
/**
 * Public landing page for an invite link opened on a phone without the app.
 * It never joins anyone, never reveals who or what the invite is for, and never
 * touches the database: opening or crawling a link must not change any state.
 * The Play Store referrer carries the token so the installed app can resume it.
 */
function landingPage(token,packageId) {
  const store='https://play.google.com/store/apps/details?id='+encodeURIComponent(packageId)+'&referrer='+encodeURIComponent('split_join='+token);
  const open='pandapay://split/join/'+token;
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'+
  '<meta name="robots" content="noindex,nofollow"><meta name="referrer" content="no-referrer"><title>Join on PandaPay</title>'+
  '<style>body{margin:0;font-family:system-ui,sans-serif;background:#f6f8f4;color:#2a313b;display:flex;min-height:100vh;align-items:center;justify-content:center}'+
  'main{max-width:380px;padding:28px;text-align:center}h1{font-size:22px;margin:0 0 10px}p{color:#3c4652;line-height:1.5}'+
  'a.btn{display:block;margin-top:14px;padding:14px;border-radius:14px;text-decoration:none;font-weight:600}'+
  'a.p{background:#2a313b;color:#c9f55a}a.s{border:1px solid #aeb8c2;color:#2a313b}small{display:block;margin-top:18px;color:#6b7684}</style></head><body><main>'+
  '<h1>You’ve been invited to split expenses</h1>'+
  '<p>Install PandaPay, sign in, and you’ll be asked to join. Joining never accepts any expense or debt on its own.</p>'+
  '<a class="btn p" href="'+store+'">Install PandaPay</a><a class="btn s" href="'+open+'">Already have the app? Open it</a>'+
  '<small>Opening this page does not join anyone.</small></main></body></html>';
}
function registerInvitationRoutes(app,{protect,withUserClient,sendError,secret,androidPackageId='app.pandapay.pandapay',notify=async()=>0}) {
  app.get('/split/join/:token',(req,res)=>{
    res.set({'Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Robots-Tag':'noindex, nofollow','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"});
    if(!TOKEN.test(req.params.token))return res.status(404).type('text/plain').send('Not found');
    res.type('html').send(landingPage(req.params.token,androidPackageId));
  });
  const route=(path,handler)=>app.post(path,...protect(async(req,res)=>{
    try {key(secret);await handler(req,res);}catch(error){if(error?.message==='invitations_unavailable')return res.status(503).json({error:'invitations_unavailable'});throw error;}
  }));
  route('/shared-expenses/invitations',async(req,res)=>{
    const b=req.body;record(b,['invitationId','contextId','memberId'],'$','INVALID_INPUT',['phoneNumber']);
    for(const field of ['invitationId','contextId','memberId'])uuid(b[field],field);
    const target=b.phoneNumber==null?null:phoneHash(secret,b.phoneNumber);
    if(target&&target===verifiedPhoneHash(secret,req.verifiedSession?.verifiedContacts))return res.status(400).json({error:'invitation_self'});
    const creds=inviteCredentials(secret,req.userId,b.invitationId);
    const result=await withUserClient(req.userId,async client=>{
      const payload={invitationId:b.invitationId,contextId:b.contextId,memberId:b.memberId,targetPhoneHash:target,tokenHash:creds.tokenHash};
      return (await client.query('SELECT shared_expenses.create_invitation($1::jsonb,$2::text) AS result',[JSON.stringify(payload),requestHash(payload)])).rows[0].result;
    });
    res.json({...result,joinUrl:`https://pandapay.app/split/join/${creds.token}`});
  });
  route('/shared-expenses/invitations/preview',async(req,res)=>{
    record(req.body,['token']);const hash=tokenHash(req.body.token);
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.preview_invitation($1::text) AS result',[hash])).rows[0].result);
    res.json(result);
  });
  route('/shared-expenses/invitations/claim',async(req,res)=>{
    const b=req.body;record(b,['token','operationId']);uuid(b.operationId,'operationId');
    const hash=tokenHash(b.token),phone=verifiedPhoneHash(secret,req.verifiedSession?.verifiedContacts);
    const last4=phone?normalizePhone(req.verifiedSession.verifiedContacts.phone.value).slice(-4):null;
    let result;
    try {
      result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.claim_invitation($1::text,$2::text,$3::text,$4::uuid,$5::text) AS result',[hash,phone,last4,b.operationId,requestHash({tokenHash:hash,accept:true})])).rows[0].result);
    }catch(error){
      // A number-bound invite needs a verified number; say that instead of "wrong number".
      if(error?.message==='invitation_phone_mismatch'&&!phone)return res.status(409).json({error:'phone_not_verified'});
      throw error;
    }
    res.json(result);
    void notify({actorId:req.userId,kind:result?.status==='joined'?'invitation.joined':'invitation.requested',payload:{},contextId:result?.contextId,operationId:b.operationId,tokenHash:hash});
  });
  route('/shared-expenses/invitations/respond',async(req,res)=>{
    const b=req.body;record(b,['invitationId','operationId','approve']);uuid(b.invitationId,'invitationId');uuid(b.operationId,'operationId');if(typeof b.approve!=='boolean')fail('INVALID_INPUT','approve');
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.respond_invitation($1::uuid,$2::boolean,$3::uuid,$4::text) AS result',[b.invitationId,b.approve,b.operationId,requestHash(b)])).rows[0].result);
    res.json(result);
  });
  const own=(req)=>verifiedPhoneHash(secret,req.verifiedSession?.verifiedContacts);
  const touch=createDirectoryToucher({withUserClient,secret});
  route('/shared-expenses/directory/lookup',async(req,res)=>{
    record(req.body,['phoneNumber']);
    const hash=phoneHash(secret,req.body.phoneNumber);
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.lookup_phone($1::text) AS result',[hash])).rows[0].result);
    res.json({found:result.found===true,self:result.self===true,...(result.found?{displayName:maskName(result.displayName)??'A PandaPay user',existingContextId:result.existingContextId??null}:{})});
  });
  app.get('/shared-expenses/directory',...protect(async(req,res)=>{
    key(secret);
    const phone=own(req);
    if(!phone)return res.json({phoneVerified:false,registered:false,discoverable:true});
    await touch(req);
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.directory_status() AS result')).rows[0].result);
    res.json({phoneVerified:true,registered:result.registered===true,discoverable:result.discoverable!==false});
  }));
  route('/shared-expenses/directory',async(req,res)=>{
    record(req.body,['discoverable']);
    if(typeof req.body.discoverable!=='boolean')fail('INVALID_INPUT','discoverable');
    const phone=own(req);
    if(!phone)return res.status(409).json({error:'phone_not_verified'});
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.register_phone($1::text,$2::boolean) AS result',[phone,req.body.discoverable])).rows[0].result);
    res.json({phoneVerified:true,registered:true,discoverable:result.discoverable!==false});
  });
  app.get('/shared-expenses/invitations/inbox',...protect(async(req,res)=>{
    key(secret);
    if(Object.keys(req.query).length)fail('INVALID_INPUT','query');
    const phone=own(req);
    if(!phone)return res.json({phoneVerified:false,items:[]});
    await touch(req);
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.list_my_invitations($1::text) AS result',[phone])).rows[0].result);
    res.json({phoneVerified:true,items:(result.items||[]).map(i=>({...i,inviterName:maskName(i.inviterName)}))});
  }));
  route('/shared-expenses/members/remove',async(req,res)=>{
    const b=req.body;record(b,['contextId','memberId','operationId']);for(const f of ['contextId','memberId','operationId'])uuid(b[f],f);
    const rh=requestHash({contextId:b.contextId,memberId:b.memberId,action:'remove'});
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.remove_member($1::uuid,$2::uuid,$3::uuid,$4::text) AS result',[b.contextId,b.memberId,b.operationId,rh])).rows[0].result);
    res.json(result);
  });
  route('/shared-expenses/members/transfer-owner',async(req,res)=>{
    const b=req.body;record(b,['contextId','memberId','operationId']);for(const f of ['contextId','memberId','operationId'])uuid(b[f],f);
    const rh=requestHash({contextId:b.contextId,memberId:b.memberId,action:'transfer'});
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.transfer_owner($1::uuid,$2::uuid,$3::uuid,$4::text) AS result',[b.contextId,b.memberId,b.operationId,rh])).rows[0].result);
    res.json(result);
  });
  route('/shared-expenses/contexts/take-over',async(req,res)=>{
    const b=req.body;record(b,['contextId','operationId']);uuid(b.contextId,'contextId');uuid(b.operationId,'operationId');
    const rh=requestHash({contextId:b.contextId,action:'takeover'});
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.take_over_ownership($1::uuid,$2::uuid,$3::text) AS result',[b.contextId,b.operationId,rh])).rows[0].result);
    res.json(result);
  });
  route('/shared-expenses/contexts/leave',async(req,res)=>{
    const b=req.body;record(b,['contextId','operationId']);uuid(b.contextId,'contextId');uuid(b.operationId,'operationId');
    const rh=requestHash({contextId:b.contextId,action:'leave'});
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.leave_context($1::uuid,$2::uuid,$3::text) AS result',[b.contextId,b.operationId,rh])).rows[0].result);
    res.json(result);
  });
  route('/shared-expenses/groups/link',async(req,res)=>{
    const b=req.body;record(b,['contextId','linkId']);uuid(b.contextId,'contextId');uuid(b.linkId,'linkId');
    const creds=groupLinkCredentials(secret,req.userId,b.contextId,b.linkId);
    const rh=requestHash({contextId:b.contextId,linkId:b.linkId,action:'create'});
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.create_group_link($1::uuid,$2::text,$3::uuid,$4::text) AS result',[b.contextId,creds.tokenHash,b.linkId,rh])).rows[0].result);
    res.json({...result,joinUrl:`https://pandapay.app/split/join/${creds.token}`});
  });
  route('/shared-expenses/groups/link/revoke',async(req,res)=>{
    const b=req.body;record(b,['contextId','operationId']);uuid(b.contextId,'contextId');uuid(b.operationId,'operationId');
    const rh=requestHash({contextId:b.contextId,action:'revoke'});
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.revoke_group_link($1::uuid,$2::uuid,$3::text) AS result',[b.contextId,b.operationId,rh])).rows[0].result);
    res.json(result);
  });
  app.get('/shared-expenses/groups/:contextId/link',...protect(async(req,res)=>{
    key(secret);uuid(req.params.contextId,'contextId');
    if(Object.keys(req.query).length)fail('INVALID_INPUT','query');
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.group_link_status($1::uuid) AS result',[req.params.contextId])).rows[0].result);
    res.json(result);
  }));
  app.get('/shared-expenses/invitations/requests',...protect(async(req,res)=>{
    key(secret);
    if(Object.keys(req.query).length)fail('INVALID_INPUT','query');
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.list_join_requests() AS result')).rows[0].result);
    res.json({items:result.items||[]});
  }));
  for(const [path,fn] of [['accept','claim_invitation_by_id'],['decline','decline_invitation']]) {
    route('/shared-expenses/invitations/'+path,async(req,res)=>{
      const b=req.body;record(b,['invitationId','operationId']);uuid(b.invitationId,'invitationId');uuid(b.operationId,'operationId');
      const phone=own(req);
      if(!phone)return res.status(409).json({error:'phone_not_verified'});
      const rh=requestHash({invitationId:b.invitationId,action:path});
      const result=await withUserClient(req.userId,async client=>{
        const sql=path==='accept'?'SELECT shared_expenses.claim_invitation_by_id($1::uuid,$2::text,$3::text,$4::uuid,$5::text) AS result':'SELECT shared_expenses.decline_invitation($1::uuid,$2::text,$4::uuid,$5::text) AS result';
        return (await client.query(sql,[b.invitationId,phone,normalizePhone(req.verifiedSession.verifiedContacts.phone.value).slice(-4),b.operationId,rh])).rows[0].result;
      });
      res.json(result);
    });
  }
  app.get('/shared-expenses/contexts/:contextId/invitations',...protect(async(req,res)=>{
    key(secret);uuid(req.params.contextId,'contextId');
    const after=req.query.after??null;if(after!==null)uuid(after,'after');
    if(Object.keys(req.query).some(k=>k!=='after'))fail('INVALID_INPUT','query');
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.list_invitations($1::uuid,$2::uuid) AS result',[req.params.contextId,after])).rows[0].result);
    res.json(result);
  }));
}
module.exports={normalizePhone,inviteCredentials,groupLinkCredentials,verifiedPhoneHash,registerInvitationRoutes,createDirectoryToucher,maskName};
