'use strict';
const crypto=require('node:crypto');
const {uuid}=require('./commands');
const {record,fail}=require('./validation');
const {encryptPhone,decryptPhone}=require('./phone_crypto');
const {cleanLabel}=require('./label');
const {describePhone}=require('./phone_display');
const {PUBLIC_LINK_BASE_URL:INVITE_BASE_URL}=require('../public_links');
const TOKEN=/^[A-Za-z0-9_-]{43}$/;
function normalizePhone(value) {
  if(typeof value!=='string'||value.length>40||!/^[+0-9 ()-]+$/.test(value))fail('INVALID_INPUT','phoneNumber');
  let phone=value.replace(/[ ()-]/g,'');
  if(/^[6-9][0-9]{9}$/.test(phone))phone='+91'+phone;
  if(!/^\+[1-9][0-9]{6,14}$/.test(phone))fail('INVALID_INPUT','phoneNumber');
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
/**
 * The number a person can be found by: a verified one first, else a typed one, else whatever
 * number the account holds. Nobody confirms numbers by code today, so requiring that would make
 * every lookup miss. Returns null when there is no usable number.
 */
function sessionPhone(session) {
  const contacts=session?.verifiedContacts;
  const candidates=[
    contacts?.phone?.verified===true?contacts.phone.value:null,
    session?.claimedContacts?.phone?.claimed===true?session.claimedContacts.phone.value:null,
    session?.phoneOnFile?.value,
  ];
  for(const value of candidates) {
    if(typeof value!=='string'||!value)continue;
    try {return normalizePhone(value);}catch(_){/* not a usable number; try the next */}
  }
  return null;
}
function sessionPhoneHash(secret,session) {
  const phone=sessionPhone(session);
  return phone?phoneHash(secret,phone):null;
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
  const parts=cleanLabel(name).split(/\s+/).filter(Boolean);
  if(!parts.length)return null;
  return parts.length===1?parts[0].slice(0,40):parts[0].slice(0,40)+' '+Array.from(parts[parts.length-1])[0]+'.';
}
/**
 * Keeps the caller's own phone hash in the directory without any client call:
 * at most one write per person per day (or when the number changes), never
 * blocking or failing the request that triggered it.
 */
function createDirectoryToucher({withUserClient,secret,ttlMs=24*3600*1000,retryMs=10*60*1000,limit=20000,now=Date.now,busy=()=>false,maxInFlight=2}) {
  const seen=new Map();
  // People whose write is running right now, and how many writes run at all. A phone opening the app sends
  // several requests at once; without these, every one of them started its own write on a connection the
  // requests themselves needed (the 10-connection pool ran dry and real requests failed with 503).
  const inFlight=new Set();
  let active=0;
  const remember=(userId,entry)=>{if(seen.size>=limit)seen.delete(seen.keys().next().value);seen.set(userId,entry);};
  // The write itself. The slot taken by the caller is ALWAYS given back (try/finally), whatever happens, so a
  // failure of any kind can never leave the counters stuck and silently switch the feature off.
  const write=async(userId,hash)=>{
    try {
      await withUserClient(userId,client=>client.query('SELECT shared_expenses.register_phone($1::text,NULL) AS result',[hash]));
      remember(userId,{hash,at:now()});
      return true;
    } catch(_) {
      // Back off for a few minutes so a switched-off feature or a database blip
      // costs one attempt, not one per request.
      remember(userId,{hash,at:now()-ttlMs+retryMs});
      return false;
    } finally {
      inFlight.delete(userId);active--;
    }
  };
  return function touch(req) {
    try {
      const hash=sessionPhoneHash(secret,req.verifiedSession);
      if(!hash||!req.userId)return Promise.resolve(false);
      const prior=seen.get(req.userId);
      if(prior&&prior.hash===hash&&now()-prior.at<ttlMs)return Promise.resolve(false);
      if(inFlight.has(req.userId))return Promise.resolve(false);
      // Not now: nothing is recorded, so the person's next request tries again. A request that needs the
      // database always comes first.
      if(active>=maxInFlight||busy())return Promise.resolve(false);
      inFlight.add(req.userId);active++;
      return write(req.userId,hash);
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
function landingPage(token,packageId,kind='split') {
  const referral=kind==='referral';
  const store='https://play.google.com/store/apps/details?id='+encodeURIComponent(packageId)+'&referrer='+encodeURIComponent((referral?'invite_code=':'split_join=')+token);
  const open=referral?'pandapay://i/'+token:'pandapay://split/join/'+token;
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'+
  '<meta name="robots" content="noindex,nofollow"><meta name="referrer" content="no-referrer"><title>Join on PandaPay</title>'+
  '<style>body{margin:0;font-family:system-ui,sans-serif;background:#f6f8f4;color:#2a313b;display:flex;min-height:100vh;align-items:center;justify-content:center}'+
  'main{max-width:380px;padding:28px;text-align:center}h1{font-size:22px;margin:0 0 10px}p{color:#3c4652;line-height:1.5}'+
  'a.btn{display:block;margin-top:14px;padding:14px;border-radius:14px;text-decoration:none;font-weight:600}'+
  'a.p{background:#2a313b;color:#c9f55a}a.s{border:1px solid #aeb8c2;color:#2a313b}small{display:block;margin-top:18px;color:#6b7684}</style></head><body><main>'+
  (referral?'<h1>You’ve been invited to PandaPay</h1><p>Install PandaPay and your invite will be applied when you sign up.</p>':'<h1>You’ve been invited to split expenses</h1><p>Install PandaPay, sign in, and you’ll be asked to join. Joining never accepts any expense or debt on its own.</p>')+
  '<a class="btn p" href="'+store+'">Install PandaPay</a><a class="btn s" href="'+open+'">Already have the app? Open it</a>'+
  '<small>'+(referral?'Opening this page does not create an account.':'Opening this page does not join anyone.')+'</small></main></body></html>';
}
function stripPhone(items) {return (items||[]).map(({claimantPhone,...rest})=>rest);}
function registerInvitationRoutes(app,{protect,withUserClient,sendError,secret,androidPackageId='app.pandapay.pandapay',notify=async()=>0,phone:phoneOpts={enabled:()=>false,ring:()=>null},poolBusy=()=>false}) {
  const phoneOn=()=>phoneOpts.enabled()===true;
  // Android App Links verification. Fingerprints (SHA-256 of each signing cert,
  // colon-separated hex) come from ANDROID_CERT_SHA256, comma-separated, so
  // release, staging and debug builds can all be verified without a code change.
  app.get('/.well-known/assetlinks.json',(req,res)=>{
    const fingerprints=(process.env.ANDROID_CERT_SHA256||'').split(',').map(s=>s.trim().toUpperCase()).filter(Boolean);
    res.set('Cache-Control','public, max-age=300').json(fingerprints.length?[{relation:['delegate_permission/common.handle_all_urls'],target:{namespace:'android_app',package_name:androidPackageId,sha256_cert_fingerprints:fingerprints}}]:[]);
  });
  app.get('/i/:code',(req,res)=>{
    res.set({'Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Robots-Tag':'noindex, nofollow','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"});
    const code=String(req.params.code).trim().toUpperCase();
    if(code.length<6||code.length>32||!/^[A-Z0-9]+(?:-[A-Z0-9]+)*$/.test(code))return res.status(404).type('text/plain').send('Not found');
    res.type('html').send(landingPage(code,androidPackageId,'referral'));
  });
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
    if(target&&target===sessionPhoneHash(secret,req.verifiedSession))return res.status(400).json({error:'invitation_self'});
    const creds=inviteCredentials(secret,req.userId,b.invitationId);
    const result=await withUserClient(req.userId,async client=>{
      const payload={invitationId:b.invitationId,contextId:b.contextId,memberId:b.memberId,targetPhoneHash:target,tokenHash:creds.tokenHash};
      return (await client.query('SELECT shared_expenses.create_invitation($1::jsonb,$2::text) AS result',[JSON.stringify(payload),requestHash(payload)])).rows[0].result;
    });
    // Tell an invitee who is already on PandaPay. The server decides from the stored
    // invitation whether it is phone-bound to a registered person; link-only invites
    // notify nobody. After the commit, fire-and-forget: a failed push never affects
    // the invitation, and a replay is deduplicated by invitation id.
    void notify({actorId:req.userId,kind:'invitation.created',payload:{},contextId:b.contextId,operationId:b.invitationId,invitationId:b.invitationId});
    res.json({...result,joinUrl:`${INVITE_BASE_URL}/split/join/${creds.token}`});
  });
  route('/shared-expenses/invitations/preview',async(req,res)=>{
    record(req.body,['token']);const hash=tokenHash(req.body.token);
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.preview_invitation($1::text) AS result',[hash])).rows[0].result);
    if(!phoneOn())return res.json(result);
    // phoneSharing: the feature is on and this server can store a number. ownPhoneMask is the caller's OWN
    // masked number (from the verified session) so they can see exactly what would be shared; null without one.
    let ownPhoneMask=null;
    try {
      const own=verifiedPhoneHash(secret,req.verifiedSession?.verifiedContacts)?normalizePhone(req.verifiedSession.verifiedContacts.phone.value):null;
      if(own)ownPhoneMask=describePhone(own).mask;
    }catch(_){ownPhoneMask=null;}
    res.json({...result,phoneSharing:phoneOpts.ring()!=null,ownPhoneMask});
  });
  route('/shared-expenses/invitations/claim',async(req,res)=>{
    const b=req.body;record(b,['token','operationId'],'$','INVALID_INPUT',['sharePhone']);uuid(b.operationId,'operationId');
    if(Object.hasOwn(b,'sharePhone')&&typeof b.sharePhone!=='boolean')fail('INVALID_INPUT','sharePhone');
    // The hash decides whether this invite is theirs (any number we hold). The number itself is only
    // shared with the owner when it is a verified one the person agreed to share.
    const hash=tokenHash(b.token),phone=sessionPhoneHash(secret,req.verifiedSession);
    const e164=verifiedPhoneHash(secret,req.verifiedSession?.verifiedContacts)?normalizePhone(req.verifiedSession.verifiedContacts.phone.value):null;
    const last4=e164?e164.slice(-4):null;
    const on=phoneOn();
    // Consent is only recorded when the feature is on. No verified phone => 'none'. A missing sharePhone
    // (older app) stays 'not_asked' and nothing is stored.
    const share=!on?null:!e164?'none':b.sharePhone===true?'shared':b.sharePhone===false?'declined':null;
    let result;
    try {
      result=await withUserClient(req.userId,async client=>{
        const r=(await client.query('SELECT shared_expenses.claim_invitation($1::text,$2::text,$3::text,$4::uuid,$5::text,$6::text) AS result',[hash,phone,last4,b.operationId,requestHash({tokenHash:hash,accept:true,sharePhone:on&&Object.hasOwn(b,'sharePhone')?b.sharePhone:null}),share==='shared'?null:share])).rows[0].result;
        let phoneShare=share==='shared'?'not_asked':(share||'not_asked');
        const ring=share==='shared'&&r?.fresh===true&&r?.status==='awaiting_owner'&&r.invitationId?phoneOpts.ring():null;
        if(ring) {
          // The number is bound to the invitation id, which this very call may have just created,
          // so it is attached afterwards in the same transaction. Any failure keeps the claim and stores nothing.
          await client.query('SAVEPOINT attach_phone');
          try {
            const sealed=encryptPhone(ring,r.invitationId,e164),shown=describePhone(e164);
            const attached=(await client.query('SELECT shared_expenses.attach_claimant_phone($1::uuid,$2::uuid,$3::text,$4::text,$5::text,$6::bytea,$7::text,$8::text) AS result',[r.invitationId,b.operationId,phone,shown.countryCode,shown.mask,sealed.enc,sealed.keyId,last4])).rows[0].result;
            if(attached?.attached===true)phoneShare='shared';
            await client.query('RELEASE SAVEPOINT attach_phone');
          } catch(_) {
            await client.query('ROLLBACK TO SAVEPOINT attach_phone');
          }
        }
        const {fresh,...reply}=r;
        return on?{...reply,phoneShare}:(({invitationId,...rest})=>rest)(reply);
      });
    }catch(error){
      // A number-bound invite needs a verified number; say that instead of "wrong number".
      if(error?.message==='invitation_phone_mismatch'&&!phone)return res.status(409).json({error:'phone_not_verified'});
      throw error;
    }
    res.json(result);
    void notify({actorId:req.userId,kind:result?.status==='joined'?'invitation.joined':'invitation.requested',payload:{},contextId:result?.contextId,operationId:b.operationId,tokenHash:hash});
  });
  route('/shared-expenses/invitations/reveal-phone',async(req,res)=>{
    if(!phoneOn())return res.status(404).json({error:'not_found'});
    const b=req.body;record(b,['invitationId','operationId']);uuid(b.invitationId,'invitationId');uuid(b.operationId,'operationId');
    res.set('Cache-Control','no-store');
    const invitationId=b.invitationId.toLowerCase();
    const undecryptable=Symbol('undecryptable');
    let out;
    try {
      out=await withUserClient(req.userId,async client=>{
        const r=(await client.query('SELECT shared_expenses.reveal_claimant_phone($1::uuid) AS result',[invitationId])).rows[0].result;
        if(r.error)return {error:r.error};
        // Decrypt before the reveal counts: if it cannot be read, the transaction (audit row included) is rolled back.
        const plain=decryptPhone(phoneOpts.ring(),String(r.invitationId).toLowerCase(),Buffer.from(String(r.enc),'hex'),r.keyId);
        if(!plain)throw undecryptable;
        return {invitationId:String(r.invitationId).toLowerCase(),e164:plain};
      });
    }catch(error){
      if(error===undecryptable)return res.status(409).json({error:'phone_not_available'});
      throw error;
    }
    if(out.error)return res.status(out.error==='reveal_rate_limited'?429:409).json({error:out.error});
    res.json({invitationId:out.invitationId,e164:out.e164,revealedAt:new Date().toISOString()});
  });
  route('/shared-expenses/invitations/check-phone',async(req,res)=>{
    if(!phoneOn())return res.status(404).json({error:'not_found'});
    const b=req.body;record(b,['invitationId','phoneNumber']);uuid(b.invitationId,'invitationId');
    const typed=phoneHash(secret,b.phoneNumber);
    const r=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.check_claimant_phone($1::uuid,$2::text) AS result',[b.invitationId,typed])).rows[0].result);
    if(r.error)return res.status(['check_attempts_exhausted','check_rate_limited'].includes(r.error)?429:409).json({error:r.error});
    res.json({matches:r.matches===true?true:r.matches===false?false:null,attemptsLeft:r.attemptsLeft});
  });
  route('/shared-expenses/invitations/respond',async(req,res)=>{
    const b=req.body;record(b,['invitationId','operationId','approve']);uuid(b.invitationId,'invitationId');uuid(b.operationId,'operationId');if(typeof b.approve!=='boolean')fail('INVALID_INPUT','approve');
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.respond_invitation($1::uuid,$2::boolean,$3::uuid,$4::text) AS result',[b.invitationId,b.approve,b.operationId,requestHash(b)])).rows[0].result);
    res.json(result);
  });
  const own=(req)=>sessionPhoneHash(secret,req.verifiedSession);
  const touch=createDirectoryToucher({withUserClient,secret,busy:poolBusy});
  // Register everyone's verified phone as soon as they use the app at all, so a person
  // who has installed and signed in is findable and can receive invites without ever
  // opening Splits. Throttled per person; never blocks or fails a request.
  try{require('../auth').onVerifiedSession(req=>{void touch(req);});}catch(_){}
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
    const b=req.body;record(b,['contextId','linkId'],'$','INVALID_INPUT',['autoJoin']);uuid(b.contextId,'contextId');uuid(b.linkId,'linkId');
    // autoJoin: true = anyone with the link joins at once; false (or left out) = the owner approves each person.
    if(b.autoJoin!==undefined&&typeof b.autoJoin!=='boolean')fail('INVALID_INPUT','autoJoin');
    const creds=groupLinkCredentials(secret,req.userId,b.contextId,b.linkId);
    const rh=requestHash({contextId:b.contextId,linkId:b.linkId,action:'create'});
    const result=await withUserClient(req.userId,async client=>{
      const created=(await client.query('SELECT shared_expenses.create_group_link($1::uuid,$2::text,$3::uuid,$4::text) AS result',[b.contextId,creds.tokenHash,b.linkId,rh])).rows[0].result;
      // Same transaction: the link is never visible without its chosen mode.
      const mode=(await client.query('SELECT shared_expenses.set_group_link_mode($1::uuid,$2::boolean,$3::text) AS result',[b.contextId,b.autoJoin===true,creds.tokenHash])).rows[0].result;
      return {...created,autoJoin:mode.autoJoin===true};
    });
    res.json({...result,joinUrl:`${INVITE_BASE_URL}/split/join/${creds.token}`});
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
    if(Object.keys(req.query).some(k=>k!=='withLookalikeFull')||(req.query.withLookalikeFull!==undefined&&!['0','1'].includes(req.query.withLookalikeFull)))fail('INVALID_INPUT','query');
    const items=await withUserClient(req.userId,async client=>{
      const list=(await client.query('SELECT shared_expenses.list_join_requests() AS result')).rows[0].result.items||[];
      if(!phoneOn())return stripPhone(list);
      const ids=req.query.withLookalikeFull==='1'?list.filter(i=>i.claimantPhone?.lookalike===true).map(i=>i.invitationId):[];
      if(!ids.length)return list;
      const sealed=new Map(((await client.query('SELECT shared_expenses.list_join_requests_enc($1::uuid[]) AS result',[ids])).rows[0].result||[]).map(r=>[r.invitationId,r]));
      const ring=phoneOpts.ring();
      return list.map(i=>{
        const s=sealed.get(i.invitationId);
        const full=s?decryptPhone(ring,i.invitationId,Buffer.from(String(s.enc),'hex'),s.keyId):null;
        return full?{...i,fullNumber:full}:i;
      });
    });
    res.set('Cache-Control','no-store');
    res.json({items});
  }));
  for(const [path,fn] of [['accept','claim_invitation_by_id'],['decline','decline_invitation']]) {
    route('/shared-expenses/invitations/'+path,async(req,res)=>{
      const b=req.body;record(b,['invitationId','operationId']);uuid(b.invitationId,'invitationId');uuid(b.operationId,'operationId');
      const phone=own(req);
      if(!phone)return res.status(409).json({error:'phone_not_verified'});
      const rh=requestHash({invitationId:b.invitationId,action:path});
      const result=await withUserClient(req.userId,async client=>{
        const sql=path==='accept'?'SELECT shared_expenses.claim_invitation_by_id($1::uuid,$2::text,$3::text,$4::uuid,$5::text) AS result':'SELECT shared_expenses.decline_invitation($1::uuid,$2::text,$3::uuid,$4::text) AS result';
        const verifiedNumber=verifiedPhoneHash(secret,req.verifiedSession?.verifiedContacts)?normalizePhone(req.verifiedSession.verifiedContacts.phone.value):null;
        const params=path==='accept'?[b.invitationId,phone,verifiedNumber?verifiedNumber.slice(-4):null,b.operationId,rh]:[b.invitationId,phone,b.operationId,rh];
        return (await client.query(sql,params)).rows[0].result;
      });
      const {audienceKey,...publicResult}=result;
      res.json(publicResult);
      if(path==='accept'&&result.status==='awaiting_owner'&&audienceKey) {
        void notify({actorId:req.userId,kind:'invitation.requested',payload:{},contextId:result.contextId,
          operationId:b.operationId,tokenHash:audienceKey});
      }
    });
  }
  app.get('/shared-expenses/contexts/:contextId/invitations',...protect(async(req,res)=>{
    key(secret);uuid(req.params.contextId,'contextId');
    const after=req.query.after??null;if(after!==null)uuid(after,'after');
    if(Object.keys(req.query).some(k=>k!=='after'))fail('INVALID_INPUT','query');
    const result=await withUserClient(req.userId,async client=>(await client.query('SELECT shared_expenses.list_invitations($1::uuid,$2::uuid) AS result',[req.params.contextId,after])).rows[0].result);
    res.json(phoneOn()?result:{...result,items:stripPhone(result.items)});
  }));
}
module.exports={normalizePhone,sessionPhone,sessionPhoneHash,inviteCredentials,groupLinkCredentials,verifiedPhoneHash,registerInvitationRoutes,createDirectoryToucher,maskName};
