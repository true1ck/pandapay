'use strict';
const express = require('express');
const { timingSafeEqual, randomUUID, createHash } = require('node:crypto');
const {isIP}=require('node:net');
const { createConsoleSessionStore } = require('./consoleSessionStore');

function validateOrigin(value, { local = false } = {}) {
  const url = new URL(value);
  if (url.origin !== value || url.username || url.password ||
      !(url.protocol === 'https:' || (local && url.protocol === 'http:' && ['localhost','127.0.0.1','[::1]'].includes(url.hostname)))) throw new Error('Invalid console browser origin');
  return url.origin;
}
function upstream(value) {
  const url = new URL(value);
  if (url.username || url.password || url.search || url.hash || url.pathname !== '/' ||
    !(url.protocol === 'https:' || (url.protocol === 'http:' && ['localhost','127.0.0.1','[::1]','auth','api'].includes(url.hostname)))) throw new Error('Invalid console browser upstream');
  return url.origin;
}
function equal(a,b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const x=Buffer.from(a),y=Buffer.from(b);return x.length===y.length && timingSafeEqual(x,y);
}
function cookie(req, name) {
  const entries=(req.headers.cookie || '').split(';').map(value=>value.trim()).filter(value=>value.startsWith(name+'='));
  return entries.length===1 ? entries[0].slice(name.length+1) : null;
}

function createConsoleBrowserRouter({ origin, authUpstream, apiUpstream, pool, encryptionKey,
  store = pool && createConsoleSessionStore({pool,encryptionKey}), fetchImpl = fetch,
  local = false, logger = console } = {}) {
  const allowedOrigin=validateOrigin(origin,{local});
  const authBase=upstream(authUpstream),apiBase=upstream(apiUpstream);
  if (!store) throw new Error('Console session storage required');
  const secure=new URL(origin).protocol==='https:';
  const cookieName=secure?'__Host-pandapay_console':'pandapay_console_dev';
  const setCookie=(res,id,clear=false)=>res.setHeader('Set-Cookie',`${cookieName}=${clear?'':id}; Path=/; HttpOnly; SameSite=Strict; ${secure?'Secure; ':''}Max-Age=${clear?0:43200}`);
  const router=express.Router();
  router.use((req,res,next)=>{
    res.setHeader('Cache-Control','no-store');res.setHeader('Pragma','no-cache');
    res.setHeader('Content-Security-Policy',"default-src 'none'; frame-ancestors 'none'; base-uri 'none'");
    res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');
    if(req.headers['x-console-request']!=='1'||req.headers['sec-fetch-site']==='cross-site'||
      (req.headers.origin && req.headers.origin!==allowedOrigin)||
      (!['GET','HEAD'].includes(req.method)&&req.headers.origin!==allowedOrigin)) return res.status(403).json({error:'browser_origin_denied'});
    next();
  });
  const wrap=fn=>(req,res,next)=>Promise.resolve(fn(req,res)).catch(()=>{
    logger.error('Console browser service unavailable');res.status(503).json({error:'browser_service_unavailable'});
  });
  async function call(base, path, {method='POST',body,access,req}={}) {
    const response=await fetchImpl(base+path,{method,redirect:'error',signal:AbortSignal.timeout(10000),
      headers:{'Content-Type':'application/json',
        'User-Agent':typeof req?.headers?.['user-agent']==='string'&&/^[\x20-\x7e]{1,512}$/.test(req.headers['user-agent'])?req.headers['user-agent']:'PandaPayConsoleGateway',...(access?{Authorization:`Bearer ${access}`}:{ }),
        // req.ip has already passed the configured trusted-hop and malformed
        // IP middleware. Never relay the caller's raw forwarding headers.
        ...(req&&isIP(req.ip)?{'X-Forwarded-For':req.ip}:{})},
      ...(body===undefined?{}:{body:JSON.stringify(body)})});
    // No raw response text/headers or upstream cookies reach the browser.
    const reader=response.body?.getReader(); let size=0,chunks=[];
    if(!reader) throw new Error('Console upstream unavailable');
    try {while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;
      if(size>4*1024*1024)throw new Error('Console upstream response too large');chunks.push(Buffer.from(value));}}
    finally {await reader.cancel().catch(()=>{});}
    const raw=Buffer.concat(chunks).toString('utf8');
    let data;try{data=raw?JSON.parse(raw):{};}catch{throw new Error('Console upstream response invalid');}
    return {status:response.status,data};
  }
  async function refresh(state,req) {
    const requestId=createHash('sha256').update('console-refresh:'+state.refresh).digest('hex');
    const result=await call(authBase,'/auth/refresh',{body:{refresh_token:state.refresh,refresh_request_id:requestId},req});
    if(result.status===401||(result.status===403&&result.data.error==='step_up_required'))return false;
    if(result.status!==200||typeof result.data.access_token!=='string'||typeof result.data.refresh_token!=='string')throw new Error('Console refresh unavailable');
    state.access=result.data.access_token;state.refresh=result.data.refresh_token;return true;
  }
  const v2Body=(req,verify,field)=>{
    const b=req.body,fields=[field,'device_id',...(verify?['code','challenge_id']:[])];
    return b&&typeof b==='object'&&!Array.isArray(b)&&Object.keys(req.query||{}).length===0&&
      Object.keys(b).every(key=>fields.includes(key))&&typeof b[field]==='string'&&b[field].length<=320&&
      typeof b.device_id==='string'&&/^[A-Za-z0-9:_-]{4,128}$/.test(b.device_id)&&
      (!verify||(typeof b.code==='string'&&/^\d{6}$/.test(b.code)&&typeof b.challenge_id==='string'&&
        /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(b.challenge_id)));
  };
  for(const prefix of ['', 'v2/']){
  for(const [name,field] of [['request-otp','phone_number'],['request-email-otp','email']]){
    const path=prefix+name,remote=path;
    router.post('/'+path,wrap(async(req,res)=>{
      if(prefix&&!v2Body(req,false,field))return res.status(400).json({error:'invalid_v2_otp_request'});
      const body=prefix?{[field]:req.body[field],device_id:req.body.device_id,recovery_only:true}:{[field]:req.body?.[field]};
      const result=await call(authBase,'/auth/'+remote,{body,req});
      if(prefix&&result.status===200){
        const d=result.data;
        if(d.ok!==true||d.version!==2||d.code_length!==6||d.expires_in!==120||
          typeof d.challenge_id!=='string'||!/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(d.challenge_id))throw new Error('Console OTP challenge unavailable');
        return res.json({ok:true,version:2,challenge_id:d.challenge_id,code_length:6,expires_in:120});
      }
      res.status(result.status).json(result.status===200?{success:true}:{error:'otp_request_failed'});
    }));
  }
  for(const [name,field] of [['verify-otp','phone_number'],['verify-email-otp','email']]){
    const path=prefix+name;
    router.post('/'+path,wrap(async(req,res)=>{
      if(prefix&&!v2Body(req,true,field))return res.status(400).json({error:'invalid_v2_otp_request'});
      const body=prefix?{[field]:req.body[field],code:req.body.code,device_id:req.body.device_id,challenge_id:req.body.challenge_id,recovery_only:true}:{[field]:req.body?.[field],code:req.body?.code,device_id:'console-'+randomUUID()};
      const result=await call(authBase,'/auth/'+path,{body,req});
      if(result.status!==200)return res.status(result.status).json({error:'otp_verification_failed'});
      if(typeof result.data.access_token!=='string'||typeof result.data.refresh_token!=='string')throw new Error('Console tokens missing');
      const state={access:result.data.access_token,refresh:result.data.refresh_token};
      const admin=await call(apiBase,'/admin/me',{method:'GET',access:state.access,req});
      if(admin.status!==200||admin.data.isAdmin!==true){
        await call(authBase,'/auth/logout',{access:state.access,body:{refresh_token:state.refresh},req}).catch(()=>{});
        return res.status(403).json({error:'console_access_denied'});
      }
      // Persist the new session first. A fresh OTP must still work when an old
      // cookie's session ciphertext is damaged/unreadable, and a failed insert
      // must not destroy a still-usable previous sign-in.
      const session=await store.create(state);
      await store.destroy(cookie(req,cookieName)).catch(()=>logger.error('Previous console session cleanup deferred'));
      setCookie(res,session.id);
      await store.cleanup().catch(()=>logger.error('Console session cleanup deferred'));
      res.json({authenticated:true,csrfToken:session.csrf});
    }));
  }
  }
  router.get('/session',wrap(async(req,res)=>{
    const result=await store.withSession(cookie(req,cookieName),async state=>{
      if(!await refresh(state,req))return {destroy:true,invalid:true};
      const admin=await call(apiBase,'/admin/me',{method:'GET',access:state.access,req});
      if(admin.status===401||admin.status===403||admin.data.isAdmin===false)return {destroy:true,invalid:true};
      if(admin.status!==200||admin.data.isAdmin!==true)throw new Error('Console admission unavailable');
      return {csrfToken:state.csrf};
    });
    if(!result||result.invalid){setCookie(res,'',true);return res.status(401).json({error:'session_invalid'});}
    res.json({authenticated:true,csrfToken:result.csrfToken});
  }));
  router.post('/logout',wrap(async(req,res)=>{
    const result=await store.withSession(cookie(req,cookieName),async state=>{
      if(!equal(req.headers['x-csrf-token'],state.csrf))return {denied:true};
      await call(authBase,'/auth/logout',{access:state.access,body:{refresh_token:state.refresh},req}).catch(()=>{});
      return {destroy:true};
    });
    if(result?.denied)return res.status(403).json({error:'csrf_denied'});
    setCookie(res,'',true);res.json({ok:true});
  }));
  router.use('/api',wrap(async(req,res)=>{
    // Fixed admin-only upstream. URL/query strings cannot select another host,
    // auth endpoint, redirects or a general bearer-token relay.
    const path=req.url;
    const pathname=path.split('?')[0];
    const allowedPath=/^\/admin(?:\/|$)/.test(pathname)||(req.method==='GET'&&pathname==='/categories');
    if(!allowedPath||pathname.includes('\\')||/%(?:2f|5c|2e|00)/i.test(pathname)||pathname.split('/').some(x=>x==='.'||x==='..')||
      !['GET','POST','PUT','PATCH','DELETE'].includes(req.method))return res.status(404).json({error:'not_found'});
    const result=await store.withSession(cookie(req,cookieName),async state=>{
      if(!equal(req.headers['x-csrf-token'],state.csrf))return {denied:true};
      const args={method:req.method,access:state.access,req,...(req.method==='GET'?{}:{body:req.body})};
      let result=await call(apiBase,path,args);
      if(result.status===401){
        if(!await refresh(state,req))return {destroy:true,invalid:true};
        result=await call(apiBase,path,{...args,access:state.access});
      }
      return result;
    });
    if(!result||result.invalid){setCookie(res,'',true);return res.status(401).json({error:'session_invalid'});}
    if(result.denied)return res.status(403).json({error:'csrf_denied'});
    res.status(result.status).json(result.data);
  }));
  return router;
}
module.exports={createConsoleBrowserRouter,validateOrigin,upstream,equal,cookie};
