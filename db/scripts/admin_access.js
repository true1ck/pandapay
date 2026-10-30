#!/usr/bin/env node
'use strict';

// Operator provisioning for explicit reviewed targets. Does not read .env,
// accept passwords as argv, create/verify auth users, send mail or mint tokens.
const crypto=require('node:crypto');
const path=require('node:path');
const {createRequire}=require('node:module');
const {Client}=createRequire(path.join(__dirname,'../../api/package.json'))('pg');
function isLocalDatabaseUrl(value){try{const u=new URL(value);return ['localhost','127.0.0.1','::1'].includes(u.hostname.replace(/^\[|\]$/g,''))&&/^postgres(?:ql)?:$/.test(u.protocol);}catch{return false;}}
function parseArgs(argv) {
  const out = { _: [] };
  const allowed = new Set(['role','reason','email','environment','user-id','operation','plan-hash','slot','file','operation-id']);
  for (let index=0; index<argv.length; index++) {
    const value = argv[index];
    if (value === '--help') { out.help=true; continue; }
    if (!value.startsWith('--')) { out._.push(value); continue; }
    const key=value.slice(2);
    if (!allowed.has(key) || Object.hasOwn(out,key)) throw new Error('Unknown or duplicate option');
    const input=argv[++index];
    if (!input || input.startsWith('--')) throw new Error('Missing option value');
    out[key]=input;
  }
  if (out._.length > 1) throw new Error('Exactly one command is required');
  return out;
}
function assertLocal(env){
 if(!['local','staging','production'].includes(env.ADMIN_PROVISION_ENV))throw new Error('Explicit ADMIN_PROVISION_ENV is required');
 const urls=[env.ADMIN_PROVISION_PRODUCT_DATABASE_URL,env.ADMIN_PROVISION_AUTH_DATABASE_URL];
 if(urls.some(x=>!x))throw new Error('Both explicit provisioning URLs are required');
 for(const raw of urls){
   const u=new URL(raw);
   if(!['postgres:','postgresql:'].includes(u.protocol)||!u.hostname||u.hash)throw new Error('Invalid provisioning database target');
   const keys=[...u.searchParams.keys()];
   if(new Set(keys).size!==keys.length||keys.some(k=>!['sslmode','sslrootcert'].includes(k)))throw new Error('Provisioning URL contains unreviewed connection overrides');
 }
 if(env.ADMIN_PROVISION_ENV==='local') {
   if(urls.some(x=>!isLocalDatabaseUrl(x)))throw new Error('Local provisioning must use loopback');
 } else {
   const targets=urls.map(x=>{const u=new URL(x);return {host:u.hostname,port:u.port||'5432',database:u.pathname};});
   const fingerprint=crypto.createHash('sha256').update(JSON.stringify(targets)).digest('hex');
   if(env.ADMIN_PROVISION_APPROVED_TARGET_SHA256!==fingerprint)throw new Error('Reviewed target fingerprint is required for hosted provisioning: '+fingerprint);
 }
}
async function client(url,env=process.env){const tls=require('../../auth/src/utils/dbTls').resolveDatabaseTls(url,env.ADMIN_PROVISION_ENV==='local'?env:{...env,NODE_ENV:'production'});const c=new Client({connectionString:tls.connectionString,ssl:tls.ssl,application_name:'pandapay-admin-provisioning',connectionTimeoutMillis:5000,statement_timeout:5000,query_timeout:10000});await c.connect();return c;}
const provisioning = require('./admin_provisioning');
function targetConfig(env) {
  assertLocal(env);
  const targets = ['ADMIN_PROVISION_AUTH_DATABASE_URL', 'ADMIN_PROVISION_PRODUCT_DATABASE_URL'].map(key => {
    const u = new URL(env[key]);
    return { host: u.hostname, port: u.port || '5432', database: u.pathname };
  });
  return { environment: env.ADMIN_PROVISION_ENV, targetKey: crypto.createHash('sha256').update(JSON.stringify(targets)).digest('hex') };
}
async function enrollmentGrant(args, auth, config) {
  const fs = require('node:fs');
  const file = args.file;
  if (!/^[0-9a-f-]{36}$/i.test(args['user-id'] || '') || !['primary', 'backup'].includes(args.slot)) throw new provisioning.ProvisioningError('user_and_factor_slot_required');
  if (!file || !path.isAbsolute(file)) throw new provisioning.ProvisioningError('absolute_protected_file_required');
  const parent = fs.lstatSync(path.dirname(file));
  if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== process.getuid() || (parent.mode & 0o077)) throw new provisioning.ProvisioningError('protected_parent_directory_required');
  const grant = crypto.randomBytes(32).toString('base64url');
  const fd = fs.openSync(file, 'wx', 0o600);
  let stored = false;
  try {
    await provisioning.exclusive(auth, async () => {
      await auth.query('BEGIN');
      try {
        const state = await provisioning.authState(auth, args['user-id'], true);
        if (state.principal?.state !== 'pending' || !state.user.active || state.user.deleted || !state.user.verified) throw new provisioning.ProvisioningError('active_pending_principal_required');
        const open = await auth.query("SELECT 1 FROM admin_private.provisioning_operations WHERE user_id=$1 AND phase IN ('auth_prepared','product_applied')", [args['user-id']]);
        if (open.rowCount) throw new provisioning.ProvisioningError('unfinished_operation_requires_resume');
        if (state.credentials.some(c => c.slot === args.slot)) throw new provisioning.ProvisioningError('factor_slot_already_enrolled');
        // A new grant replaces older unused grants for the same slot.
        await auth.query('UPDATE admin_private.enrollment_grants SET consumed_at=coalesce(consumed_at,now()) WHERE user_id=$1 AND slot=$2', [args['user-id'], args.slot]);
        await auth.query(`INSERT INTO admin_private.enrollment_grants(grant_digest,user_id,environment,origin,rp_id,slot,expires_at)
          VALUES($1,$2,$3,'https://localhost:8443','localhost',$4,now()+interval '10 minutes')`, [crypto.createHash('sha256').update(grant).digest('hex'), args['user-id'], config.environment, args.slot]);
        fs.writeFileSync(fd, grant + '\n');
        fs.fsyncSync(fd);
        await auth.query('COMMIT');
        stored = true;
      } catch (error) { await auth.query('ROLLBACK').catch(() => {}); throw error; }
    });
  } finally {
    fs.closeSync(fd);
    if (!stored) fs.unlinkSync(file);
  }
  console.log(`One-use enrollment grant saved to protected file: ${file}`);
}
async function main(argv = process.argv.slice(2), env = process.env) {
  const args = parseArgs(argv);
  const command = args._[0];
  if (args.help) {
    console.log('admin_access.js inspect|plan|apply|resume|status|enable|revoke|enrollment-grant. plan --operation grant|reconcile|enable|revoke. Mutations/resume require the reviewed --plan-hash; resume/status require --operation-id.');
    return;
  }
  const config = targetConfig(env);
  if (args.environment && args.environment !== config.environment) throw new provisioning.ProvisioningError('environment_argument_mismatch');
  let auth, product;
  try {
    auth = await client(env.ADMIN_PROVISION_AUTH_DATABASE_URL, env);
    if (command === 'status') {
      console.log(JSON.stringify(await provisioning.operationStatus(args['operation-id'], auth, config), null, 2));
      return;
    }
    if (command === 'inspect') {
      const state = await provisioning.authState(auth, args['user-id']);
      if (args.email && state.user.email !== args.email.trim().toLowerCase()) throw new provisioning.ProvisioningError('email_identity_mismatch');
      console.log(JSON.stringify({ userId: state.user.id, email: state.user.email, accountActive: state.user.active && !state.user.deleted, emailVerified: state.user.verified, principal: state.principal, factorCount: state.credentials.length }, null, 2));
      return;
    }
    if (command === 'enrollment-grant') { await enrollmentGrant(args, auth, config); return; }
    product = await client(env.ADMIN_PROVISION_PRODUCT_DATABASE_URL, env);
    if (command === 'resume') {
      console.log(JSON.stringify(await provisioning.resumeOperation(args['operation-id'], args['plan-hash'], auth, product, config), null, 2));
      return;
    }
    if (command === 'enable' || command === 'revoke') args.operation = command;
    if (!['plan', 'apply', 'enable', 'revoke'].includes(command)) throw new provisioning.ProvisioningError('invalid_command');
    const plan = await provisioning.buildPlan(args, auth, product, config);
    const hash = provisioning.planHash(plan);
    if (command === 'plan') {
      console.log(JSON.stringify({ plan, planHash: hash, operationId: provisioning.operationId(hash) }, null, 2));
      return;
    }
    console.log(JSON.stringify(await provisioning.executePlan(plan, auth, product, config, { approvedHash: args['plan-hash'] }), null, 2));
  } finally { await Promise.allSettled([auth?.end(), product?.end()]); }
}
if (require.main === module) main().catch(error => {
  console.error('Admin provisioning stopped: ' + (error instanceof provisioning.ProvisioningError ? error.code : /^[A-Z0-9_]{2,20}$/.test(error.code || '') ? error.code : 'operation_failed'));
  process.exitCode = 1;
});
module.exports = { main, isLocalDatabaseUrl, parseArgs, assertLocal, targetConfig, enrollmentGrant, ...provisioning };
