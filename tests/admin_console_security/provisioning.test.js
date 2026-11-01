'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { Client, Pool } = require('../../auth/node_modules/pg');
const {createAdminRepository} = require('../../auth/src/admin/repository');
const {configureAdminGatewayRuntime} = require('../../auth/scripts/adminGatewayPermissions');
const { buildPlan, executePlan, resumeOperation, planHash, operationId } = require('../../db/scripts/admin_provisioning');

const socket = process.env.ADMIN_TEST_PG_SOCKET;
const enabled = typeof socket === 'string' && /^\/tmp\/pandapay-admin-pg\.[A-Za-z0-9]+$/.test(socket);
test('operator provisioning survives crashes and cannot replay later revoked authority', { skip: !enabled }, async t => {
  const connection = { host: socket, port: 55487, user: 'postgres' };
  const control = new Client({ ...connection, database: 'postgres' });
  await control.connect();
  await control.query('CREATE DATABASE private_admin_provision_auth_test');
  await control.query('CREATE DATABASE private_admin_provision_product_test');
  const auth = new Client({ ...connection, database: 'private_admin_provision_auth_test' });
  const product = new Client({ ...connection, database: 'private_admin_provision_product_test' });
  await auth.connect(); await product.connect();
  t.after(async () => {
    await Promise.allSettled([auth.end(), product.end()]);
    await control.query('DROP DATABASE private_admin_provision_auth_test WITH (FORCE)');
    await control.query('DROP DATABASE private_admin_provision_product_test WITH (FORCE)');
    await control.end();
  });
  await auth.query('CREATE TABLE users(id uuid PRIMARY KEY,email text,is_active boolean DEFAULT true,deleted boolean DEFAULT false,is_email_verified boolean DEFAULT true)');
  for (const name of ['0012_private_admin_access.sql','0013_admin_provisioning_journal.sql','0014_approved_browser_enrollment.sql']) {
    await auth.query(fs.readFileSync(path.resolve(__dirname,'../../auth/db/migrations',name),'utf8'));
  }
  await product.query(`CREATE TABLE admin_users(id uuid PRIMARY KEY,email text NOT NULL,role text NOT NULL,is_active boolean NOT NULL DEFAULT true);
    CREATE UNIQUE INDEX active_email ON admin_users(lower(email)) WHERE is_active;
    CREATE TABLE admin_audit_log(id bigserial PRIMARY KEY,admin_id uuid,action text,entity text,entity_id uuid,before_value jsonb,after_value jsonb,reason text);
    DO $$ BEGIN IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='pandapay_admin_api') THEN CREATE ROLE pandapay_admin_api NOLOGIN; END IF; END $$`);
  await product.query(fs.readFileSync(path.resolve(__dirname,'../../db/supabase/migrations/20261030110000_admin_provisioning_receipts.sql'),'utf8'));
  const config = { environment: 'local', targetKey: 'a'.repeat(64) };
  const row = async (sql, values) => (await auth.query(sql, values)).rows[0];
  async function identity() {
    const userId = crypto.randomUUID(), email = userId + '@example.test';
    await auth.query('INSERT INTO users(id,email) VALUES($1,$2)',[userId,email]);
    return { 'user-id':userId, email, role:'owner', reason:'Synthetic operator acceptance' };
  }
  const plan = (args, operation) => buildPlan({ ...args, operation }, auth, product, config);
  const apply = (p, checkpoint) => executePlan(p, auth, product, config, { approvedHash:planHash(p),checkpoint });
  const resume = p => resumeOperation(operationId(planHash(p)),planHash(p),auth,product,config);
  async function factors(id) {
    for (const slot of ['primary','backup']) await auth.query(`INSERT INTO admin_private.credentials(credential_id,user_id,public_key,slot,device_type)
      VALUES($1,$2,$3,$4,'singleDevice')`,[crypto.randomUUID(),id,Buffer.from('synthetic-public-key-'+slot),slot]);
  }
  const failAt = stage => async current => { if (current === stage) throw new Error('simulated_process_exit'); };
  await t.test('browser-managed initial enrollment requires completed operator intent, current proof and missing slots',async () => {
    await configureAdminGatewayRuntime(auth,{ADMIN_GATEWAY_DB_PASSWORD:'synthetic-runtime-secret-'.repeat(2)});
    const runtime=new Pool({...connection,database:'private_admin_provision_auth_test',user:'admin_gateway_runtime',options:'-c role=pandapay_admin_gateway',max:2});
    try {
      const repo=createAdminRepository({pool:runtime,environment:'local',sessionEpoch:'synthetic-epoch-'.repeat(3)});
      async function proof(args) {
        const loginId=crypto.randomUUID(),cookie=crypto.randomBytes(32).toString('hex'),code=crypto.randomBytes(32).toString('hex');
        await repo.createLoginChallenge({loginId,email:args.email,preauthCookieDigest:cookie,codeDigest:code,expiresAt:new Date(Date.now()+120000)});
        assert.equal((await repo.consumeEmailChallenge({loginId,preauthCookieDigest:cookie,codeDigest:code})).ok,true);
        return {loginId,preauthCookieDigest:cookie,grantDigest:crypto.randomBytes(32).toString('hex')};
      }
      const unapproved=await identity();
      await auth.query("INSERT INTO admin_private.principals(user_id,state) VALUES($1,'pending')",[unapproved['user-id']]);
      assert.equal(await repo.prepareApprovedEnrollment(await proof(unapproved)),null);
      const args=await identity(),p=await plan(args,'grant');await apply(p);
      const primaryProof=await proof(args);
      assert.equal(await repo.prepareApprovedEnrollment({...primaryProof,preauthCookieDigest:'0'.repeat(64)}),null);
      assert.equal(await repo.prepareApprovedEnrollment({...primaryProof,environment:'production'}),null);
      const primary=await repo.prepareApprovedEnrollment(primaryProof);assert.equal(primary.slot,'primary');assert.equal(primary.userId,p.userId);
      const retry=await repo.prepareApprovedEnrollment({...primaryProof,grantDigest:'a'.repeat(64)});assert.equal(retry.slot,'primary');
      assert.equal((await row('SELECT consumed_at IS NOT NULL AS consumed FROM admin_private.enrollment_grants WHERE grant_digest=$1',[primary.grantDigest])).consumed,true);
      const challenge=crypto.randomBytes(32).toString('hex');
      await repo.createWebAuthnChallenge({userId:p.userId,loginId:primaryProof.loginId,preauthCookieDigest:primaryProof.preauthCookieDigest,purpose:'enrollment',challengeDigest:challenge,challengeValue:'fixture',grantDigest:retry.grantDigest,origin:'https://localhost:8443',rpId:'localhost',expiresAt:new Date(Date.now()+120000)});
      assert.ok(await repo.addCredential({...primaryProof,challengeDigest:challenge,credentialId:crypto.randomUUID(),publicKey:Buffer.from('synthetic-primary'),deviceType:'singleDevice',origin:'https://localhost:8443',rpId:'localhost'}));
      assert.equal(await repo.prepareApprovedEnrollment(primaryProof),null);
      const backupProof=await proof(args);
      assert.equal((await repo.prepareApprovedEnrollment(backupProof)).slot,'backup');
      await auth.query("UPDATE admin_private.email_proofs SET expires_at=now()-interval '1 second' WHERE login_id=$1",[backupProof.loginId]);
      assert.equal(await repo.prepareApprovedEnrollment(backupProof),null);
      await auth.query("INSERT INTO admin_private.credentials(credential_id,user_id,public_key,device_type,slot) VALUES($1,$2,$3,'singleDevice','backup')",[crypto.randomUUID(),p.userId,Buffer.from('synthetic-backup')]);
      assert.equal(await repo.prepareApprovedEnrollment(await proof(args)),null);
      await assert.rejects(runtime.query('UPDATE admin_private.principals SET state=\'enabled\''),/permission denied/);
      assert.equal((await row('SELECT state FROM admin_private.principals WHERE user_id=$1',[p.userId])).state,'pending');
      assert.equal((await product.query('SELECT is_active FROM admin_users WHERE id=$1',[p.userId])).rows[0].is_active,false);
      await auth.query("UPDATE admin_private.credentials SET revoked_at=now() WHERE user_id=$1 AND slot='backup'",[p.userId]);
      assert.equal(await repo.prepareApprovedEnrollment(await proof(args)),null);
    } finally {await runtime.end();}
  });
  for (const stage of ['after_auth_commit','after_product_commit','after_product_ack','after_complete']) {
    await t.test(stage, async () => {
      const args = await identity(), p = await plan(args,'grant');
      await assert.rejects(apply(p,failAt(stage)),/simulated_process_exit/);
      assert.equal((await row('SELECT state FROM admin_private.principals WHERE user_id=$1',[p.userId])).state,'pending');
      const versionBefore = (await row('SELECT version::text AS v FROM admin_private.principals WHERE user_id=$1',[p.userId])).v;
      const result = await resume(p);
      assert.equal(result.phase,'complete');
      assert.equal((await product.query('SELECT is_active FROM admin_users WHERE id=$1',[p.userId])).rows[0].is_active,false);
      assert.equal((await resume(p)).phase,'complete');
      assert.equal((await row('SELECT version::text AS v FROM admin_private.principals WHERE user_id=$1',[p.userId])).v,versionBefore);
      assert.equal((await product.query('SELECT count(*)::int AS n FROM admin_control.provisioning_receipts WHERE operation_id=$1',[result.operationId])).rows[0].n,1);
      assert.equal((await product.query('SELECT count(*)::int AS n FROM admin_audit_log WHERE entity_id=$1',[p.userId])).rows[0].n,1);
    });
  }
  await t.test('enable crash, factor change and explicit revoke cannot resurrect admission',async () => {
    const args=await identity(), prepared=await plan(args,'grant');
    await apply(prepared); await factors(prepared.userId);
    const enabling=await plan(args,'enable');
    await assert.rejects(apply(enabling,failAt('after_product_commit')),/simulated_process_exit/);
    assert.equal((await row('SELECT state FROM admin_private.principals WHERE user_id=$1',[prepared.userId])).state,'pending');
    assert.equal((await product.query('SELECT is_active FROM admin_users WHERE id=$1',[prepared.userId])).rows[0].is_active,true);
    await auth.query("UPDATE admin_private.credentials SET revoked_at=now() WHERE user_id=$1 AND slot='backup'",[prepared.userId]);
    await assert.rejects(resume(enabling),/principal_changed/);
    assert.equal((await row('SELECT phase FROM admin_private.provisioning_operations WHERE id=$1',[operationId(planHash(enabling))])).phase,'blocked');
    const revoking=await plan(args,'revoke'); await apply(revoking);
    await resume(prepared);
    assert.equal((await row('SELECT state FROM admin_private.principals WHERE user_id=$1',[prepared.userId])).state,'revoked');
    assert.equal((await product.query('SELECT is_active FROM admin_users WHERE id=$1',[prepared.userId])).rows[0].is_active,false);
  });
  await t.test('revocation supersedes an unfinished enable and replay of completed enable stays inert',async () => {
    const args=await identity(), prepared=await plan(args,'grant');
    await apply(prepared); await factors(prepared.userId);
    const enabling=await plan(args,'enable'); await apply(enabling);
    const revoking=await plan(args,'revoke');
    await assert.rejects(apply(revoking,failAt('after_auth_commit')),/simulated_process_exit/);
    assert.equal((await row('SELECT state FROM admin_private.principals WHERE user_id=$1',[prepared.userId])).state,'revoked');
    await resume(revoking); await resume(enabling);
    assert.equal((await row('SELECT state FROM admin_private.principals WHERE user_id=$1',[prepared.userId])).state,'revoked');
    assert.equal((await product.query('SELECT is_active FROM admin_users WHERE id=$1',[prepared.userId])).rows[0].is_active,false);
    // Prepare a new grant/enable, crash before product write, then revoke it.
    const regrant=await plan(args,'grant'); await apply(regrant); await factors(prepared.userId);
    const pending=await plan(args,'enable');
    await assert.rejects(apply(pending,failAt('after_auth_commit')),/simulated_process_exit/);
    const cancel=await plan(args,'revoke'); await apply(cancel);
    await assert.rejects(resume(pending),/superseded_by_revocation/);
  });
  await t.test('stale preview and wrong target cannot prepare or resume',async () => {
    const args=await identity(), p=await plan(args,'grant');
    await product.query('INSERT INTO admin_users(id,email,role,is_active) VALUES($1,$2,\'readonly\',false)',[p.userId,p.email]);
    await assert.rejects(apply(p),/stale_product_preview/);
    assert.equal((await auth.query('SELECT * FROM admin_private.principals WHERE user_id=$1',[p.userId])).rowCount,0);
    const fresh=await plan(args,'grant'); await apply(fresh);
    await assert.rejects(resumeOperation(operationId(planHash(fresh)),planHash(fresh),auth,product,{...config,targetKey:'b'.repeat(64)}),/target_mismatch/);
    await assert.rejects(resumeOperation(operationId(planHash(fresh)),'b'.repeat(64),auth,product,config),/approval_mismatch/);
  });
  await t.test('product drift after a receipt blocks resume without overwriting operator changes',async () => {
    const args=await identity(), p=await plan(args,'grant');
    await assert.rejects(apply(p,failAt('after_product_commit')),/simulated_process_exit/);
    await product.query("UPDATE admin_users SET role='readonly' WHERE id=$1",[p.userId]);
    await assert.rejects(resume(p),/product_receipt_drift/);
    assert.equal((await product.query('SELECT role FROM admin_users WHERE id=$1',[p.userId])).rows[0].role,'readonly');
  });
  await t.test('revocation can cancel a partially prepared account before a product row exists',async () => {
    const args=await identity(), p=await plan(args,'grant');
    await assert.rejects(apply(p,failAt('after_auth_commit')),/simulated_process_exit/);
    const revoking=await plan(args,'revoke'); await apply(revoking);
    await assert.rejects(resume(p),/superseded_by_revocation/);
    assert.equal((await row('SELECT state FROM admin_private.principals WHERE user_id=$1',[p.userId])).state,'revoked');
    assert.equal((await product.query('SELECT * FROM admin_users WHERE id=$1',[p.userId])).rowCount,0);
  });
  await t.test('a different operation waits for unfinished intent and a second CLI cannot acquire its lock',async () => {
    const args=await identity(), p=await plan(args,'grant');
    await assert.rejects(apply(p,failAt('after_auth_commit')),/simulated_process_exit/);
    const second=await plan({...args,reason:'Different reviewed grant attempt'},'grant');
    await assert.rejects(apply(second),/unfinished_operation_requires_resume/);
    const other=new Client({...connection,database:'private_admin_provision_auth_test'});
    await other.connect();
    try {
      await other.query('SELECT pg_advisory_lock(1346457153,3)');
      await assert.rejects(resume(p),/provisioning_busy/);
    } finally { await other.end(); }
    assert.equal((await resume(p)).phase,'complete');
  });
  await t.test('enrollment files are single-use outputs and never overwrite an existing file',async () => {
    const {enrollmentGrant}=require('../../db/scripts/admin_access');
    const os=require('node:os'), folder=fs.mkdtempSync(path.join(os.tmpdir(),'admin-grants-'));
    fs.chmodSync(folder,0o700);
    const args=await identity(), p=await plan(args,'grant'); await apply(p);
    const file=path.join(folder,'primary.txt');
    try {
      await enrollmentGrant({...args,slot:'primary',file},auth,config);
      assert.equal(fs.statSync(file).mode&0o777,0o600);
      const value=fs.readFileSync(file,'utf8').trim();
      assert.equal((await auth.query('SELECT * FROM admin_private.enrollment_grants WHERE grant_digest=$1 AND consumed_at IS NULL',[crypto.createHash('sha256').update(value).digest('hex')])).rowCount,1);
      await assert.rejects(enrollmentGrant({...args,slot:'primary',file},auth,config),{code:'EEXIST'});
      assert.equal(fs.readFileSync(file,'utf8').trim(),value);
      const next=path.join(folder,'replacement.txt');
      await enrollmentGrant({...args,slot:'primary',file:next},auth,config);
      assert.equal((await auth.query('SELECT * FROM admin_private.enrollment_grants WHERE user_id=$1 AND consumed_at IS NULL',[p.userId])).rowCount,1);
    } finally { fs.rmSync(folder,{recursive:true}); }
  });
  await t.test('reconciliation preserves old membership and audit IDs while denying stale authority',async () => {
    const args=await identity(), oldId=crypto.randomUUID();
    await auth.query('INSERT INTO users(id,email) VALUES($1,$2)',[oldId,'retired-'+args.email]);
    await auth.query("INSERT INTO admin_private.principals(user_id,state,enabled_at) VALUES($1,'enabled',now())",[oldId]);
    await product.query("INSERT INTO admin_users(id,email,role) VALUES($1,$2,'owner')",[oldId,args.email]);
    await product.query("INSERT INTO admin_audit_log(admin_id,action,entity,entity_id) VALUES($1,'historical','admin_users',$1)",[oldId]);
    await assert.rejects(plan(args,'grant'),/explicit_reconcile_required/);
    const p=await plan(args,'reconcile');
    await assert.rejects(apply(p,failAt('after_auth_commit')),/simulated_process_exit/);
    assert.equal((await row('SELECT state FROM admin_private.principals WHERE user_id=$1',[oldId])).state,'revoked');
    await resume(p);
    const records=(await product.query('SELECT id,is_active FROM admin_users WHERE lower(email)=lower($1) ORDER BY id',[args.email])).rows;
    assert.equal(records.length,2); assert.ok(records.every(x=>x.is_active===false));
    assert.equal((await product.query("SELECT admin_id FROM admin_audit_log WHERE action='historical' AND entity_id=$1",[oldId])).rows[0].admin_id,oldId);
  });
  await t.test('revoking a retired UUID never revokes a replacement UUID sharing historical email',async () => {
    const args=await identity(), p=await plan(args,'grant'); await apply(p);
    const replacement=crypto.randomUUID();
    await auth.query('INSERT INTO users(id,email) VALUES($1,$2)',[replacement,'replacement-'+args.email]);
    await auth.query("INSERT INTO admin_private.principals(user_id,state,enabled_at) VALUES($1,'enabled',now())",[replacement]);
    await product.query("INSERT INTO admin_users(id,email,role,is_active) VALUES($1,$2,'owner',true)",[replacement,args.email]);
    const revoking=await plan(args,'revoke');
    assert.deepEqual(revoking.conflictingIds,[]);
    await apply(revoking);
    assert.equal((await row('SELECT state FROM admin_private.principals WHERE user_id=$1',[replacement])).state,'enabled');
    assert.equal((await product.query('SELECT is_active FROM admin_users WHERE id=$1',[replacement])).rows[0].is_active,true);
  });
  await t.test('runtime capabilities cannot author the journal or product receipts',async () => {
    await auth.query('BEGIN');
    await auth.query('SET LOCAL ROLE pandapay_admin_gateway');
    await assert.rejects(auth.query('SELECT * FROM admin_private.provisioning_operations'),/permission denied/);
    await auth.query('ROLLBACK');
    await product.query('BEGIN');
    await product.query('SET LOCAL ROLE pandapay_admin_api');
    await assert.rejects(product.query('SELECT * FROM admin_control.provisioning_receipts'),/permission denied/);
    await product.query('ROLLBACK');
  });
});
