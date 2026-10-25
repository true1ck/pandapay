'use strict';
// A fresh, explicitly named local fixture only; never reads DATABASE_URL.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {Client}=require('pg');
const {CAPABILITY_SQL}=require('../src/middleware/adminAuth');
const {setSecurityAdminAccess}=require('../scripts/security_admin_access');
const {configureAuthRuntimeRole}=require('../scripts/runtimePermissions');

async function main(){
 const raw=process.env.AUTH_ADMIN_CAPABILITY_TEST_URL;
 if(!raw)throw new Error('AUTH_ADMIN_CAPABILITY_TEST_URL is required');
 const url=new URL(raw);
 if(!['postgres:','postgresql:'].includes(url.protocol)||!['127.0.0.1','localhost','[::1]'].includes(url.hostname)||url.pathname!=='/auth_admin_capability_test'||url.search||url.hash)throw new Error('A fresh loopback auth_admin_capability_test is required');
 const client=new Client({connectionString:raw,ssl:false,connectionTimeoutMillis:3000});
 await client.connect();
 try{
  const existing=await client.query("SELECT count(*)::int AS count FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast') AND c.relkind IN ('r','p','v','m','S','f') AND c.relname NOT LIKE 'pg_%'");
  assert.equal(existing.rows[0].count,0,'fixture refuses nonempty DB');
  await client.query(fs.readFileSync(path.join(__dirname,'../db/pandapay-auth/init.sql'),'utf8'));
  await client.query(fs.readFileSync(path.join(__dirname,'../db/migrations/0007_security_dashboard_capability.sql'),'utf8'));
  const role='dashboard_rt_'+crypto.randomBytes(5).toString('hex');
  await client.query(`CREATE ROLE "${role}" NOLOGIN NOSUPERUSER NOBYPASSRLS`);
  await client.query(`GRANT USAGE ON SCHEMA public TO "${role}"`);
  await client.query(`GRANT SELECT(id,is_active,deleted) ON public.users TO "${role}"`);
  await configureAuthRuntimeRole(client,{files:[{file:'0007_security_dashboard_capability.sql'}],runtimeRole:role,securityDashboardEnabled:true});
  const user=crypto.randomUUID(),other=crypto.randomUUID();
  await client.query("INSERT INTO users(id,email,is_email_verified,is_active,deleted) VALUES ($1,'dashboard@example.test',true,true,false),($2,'other@example.test',true,true,false)",[user,other]);
  async function lookup(id,sql=CAPABILITY_SQL){
   await client.query('BEGIN');
   try{await client.query(`SET LOCAL ROLE "${role}"`);const result=await client.query(sql,[id]);await client.query('COMMIT');return result;}
   catch(error){await client.query('ROLLBACK');throw error;}
  }
  assert.equal((await lookup(user)).rowCount,0);
  await setSecurityAdminAccess(client,{action:'grant',userId:user,expiresAt:new Date(Date.now()+3600000).toISOString()});
  assert.equal((await lookup(user)).rowCount,1);assert.equal((await lookup(other)).rowCount,0);
  await assert.rejects(lookup(user,'INSERT INTO auth_private.security_admins(user_id,expires_at) VALUES ($1,now()+interval \'1 hour\')'),error=>error.code==='42501');
  await setSecurityAdminAccess(client,{action:'revoke',userId:user});assert.equal((await lookup(user)).rowCount,0);
  await setSecurityAdminAccess(client,{action:'grant',userId:user,expiresAt:new Date(Date.now()+3600000).toISOString()});
  await client.query('UPDATE users SET is_active=false WHERE id=$1',[user]);assert.equal((await lookup(user)).rowCount,0);
  await client.query('UPDATE users SET is_active=true,deleted=true WHERE id=$1',[user]);assert.equal((await lookup(user)).rowCount,0);
  await assert.rejects(setSecurityAdminAccess(client,{action:'grant',userId:user,expiresAt:new Date(Date.now()+3600000).toISOString()}),/active verified/);
  await client.query('UPDATE users SET deleted=false WHERE id=$1',[user]);
  for(const state of [
   {label:'disabled',change:'is_active=false',restore:'is_active=true'},
   {label:'deleted',change:'deleted=true',restore:'deleted=false'},
   {label:'unverified',change:'is_email_verified=false,is_phone_verified=false',restore:'is_email_verified=true'},
  ]){
   await setSecurityAdminAccess(client,{action:'grant',userId:user,expiresAt:new Date(Date.now()+3600000).toISOString()});
   assert.equal((await lookup(user)).rowCount,1);
   await client.query(`UPDATE users SET ${state.change} WHERE id=$1`,[user]);
   await setSecurityAdminAccess(client,{action:'revoke',userId:user});
   const revoked=(await client.query('SELECT revoked_at FROM auth_private.security_admins WHERE user_id=$1',[user])).rows[0].revoked_at;
   assert.ok(revoked,`${state.label} account capability can be revoked`);
   await setSecurityAdminAccess(client,{action:'revoke',userId:user});
   assert.equal((await client.query('SELECT revoked_at FROM auth_private.security_admins WHERE user_id=$1',[user])).rows[0].revoked_at.getTime(),revoked.getTime());
   await client.query(`UPDATE users SET ${state.restore} WHERE id=$1`,[user]);
   assert.equal((await lookup(user)).rowCount,0,`${state.label} account restoration must not restore revoked access`);
  }
  await setSecurityAdminAccess(client,{action:'revoke',userId:other});
  assert.equal((await client.query('SELECT count(*)::int AS count FROM auth_private.security_admins WHERE user_id=$1',[other])).rows[0].count,0,'revoke without a grant creates no capability');
  await setSecurityAdminAccess(client,{action:'grant',userId:user,expiresAt:new Date(Date.now()+3600000).toISOString()});
  await client.query("UPDATE auth_private.security_admins SET granted_at=now()-interval '2 hours',expires_at=now()-interval '1 hour' WHERE user_id=$1",[user]);
  assert.equal((await lookup(user)).rowCount,0);
  console.log('PASS: explicit dashboard grant/revoke/expiry and account status under a read-only non-owner runtime; disabled/deleted/unverified revocation survives restoration; no self-promotion');
 }finally{await client.end();}
}
main().catch(error=>{console.error('Synthetic dashboard capability fixture failed',error.stack);process.exitCode=1;});
