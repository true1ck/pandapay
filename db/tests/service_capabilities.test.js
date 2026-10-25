'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { configureServiceCapabilities } = require('../scripts/service_capabilities');
function fixture(existing=false, extra={}) {
  const calls=[];
  const query=async(sql,params)=>{
    calls.push({sql,params});
    if(sql.includes('quote_literal')) return {rows:[{value:"'synthetic''quoted'"}]};
    if(sql.includes('current_database')) return {rows:[{name:'synthetic_db'}]};
    if(sql.includes('pg_auth_members')) return {rows:[]};
    if(sql.includes('pg_roles') && params[0]==='pandapay_partner_webhook') return {rows:[{rolcanlogin:false,rolsuper:false,rolbypassrls:false}]};
    if(sql.includes('pg_roles')) return {rows:existing?[{rolcanlogin:true,rolsuper:false,rolbypassrls:false,rolcreatedb:false,rolcreaterole:false,rolreplication:false,...extra}]:[]};
    return {rows:[]};
  };return {calls,query};
}
test('blank opt-in service credentials perform no SQL',async()=>{
  assert.deepEqual(await configureServiceCapabilities({query:()=>assert.fail('disabled')},{}),[]);
});
test('bootstrap creates one narrow login with server-quoted password and EXECUTE capability membership',async()=>{
  const f=fixture();
  assert.deepEqual(await configureServiceCapabilities(f,{PARTNER_WEBHOOK_DB_PASSWORD:'s'.repeat(32)}),['partner_webhook_runtime']);
  const create=f.calls.find(x=>x.sql.startsWith('CREATE ROLE')).sql;
  assert.match(create,/NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS/);
  assert.ok(create.includes("PASSWORD 'synthetic''quoted'"));
  assert.ok(f.calls.some(x=>x.sql==='GRANT "pandapay_partner_webhook" TO "partner_webhook_runtime"'));
  assert.equal(f.calls.some(x=>/ALL TABLES|BYPASSRLS\s*;|TO "app_user"/.test(x.sql)),false);
});
test('repeat bootstrap preserves credentials and refuses unsafe existing identities',async()=>{
  const f=fixture(true);await configureServiceCapabilities(f,{PARTNER_WEBHOOK_DB_PASSWORD:'s'.repeat(32)});
  assert.equal(f.calls.some(x=>/CREATE ROLE|ALTER ROLE|PASSWORD/.test(x.sql)),false);
  await assert.rejects(configureServiceCapabilities(fixture(true,{rolsuper:true}),{PARTNER_WEBHOOK_DB_PASSWORD:'s'.repeat(32)}),/unsafe/);
  await assert.rejects(configureServiceCapabilities(fixture(),{PARTNER_WEBHOOK_DB_PASSWORD:'short'}),/32 bytes/);
});
