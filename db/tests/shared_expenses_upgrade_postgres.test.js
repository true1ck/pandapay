'use strict';
// Full historical product chain on one absent, marker-owned loopback database.
// Never reads dotenv, DATABASE_URL or a user database. Explicit opt-in only.
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {execFileSync}=require('node:child_process');
const {Client}=require('../../api/node_modules/pg');
const {migrationInventory,transactionalSql,runProductMigrations}=require('../scripts/product_migrate');
const raw=process.env.PANDAPAY_SHARED_EXPENSES_UPGRADE_TEST_URL;
const dbName='shared_expenses_upgrade_test',container='pandapay-shared-expenses-20261104-thread';
test('full product history, populated source preservation, role setup and shared replay',{skip:!raw&&'explicit owned loopback upgrade fixture not supplied'},async t=>{
  const url=new URL(raw);
  assert.ok(['127.0.0.1','localhost'].includes(url.hostname)&&url.pathname===`/${dbName}`&&!url.search&&!url.hash);
  assert.equal(url.port,'55436'); // Matches the task-owned container, not ambient pg.
  const adminUrl=new URL(url);adminUrl.pathname='/postgres';
  const admin=new Client({connectionString:adminUrl.toString(),connectionTimeoutMillis:5000});await admin.connect();
  const marker='shared-upgrade-'+crypto.randomUUID();let created=false,db;
  t.after(async()=>{
    await db?.end().catch(()=>{});
    if(created){
      const owner=await admin.query('SELECT shobj_description(oid,\'pg_database\') AS marker FROM pg_database WHERE datname=$1',[dbName]);
      if(owner.rows[0]?.marker===marker)await admin.query(`DROP DATABASE ${dbName} WITH (FORCE)`);
    }
    await admin.end();
  });
  assert.equal((await admin.query('SELECT 1 FROM pg_database WHERE datname=$1',[dbName])).rowCount,0,'refuse existing database');
  await admin.query(`CREATE DATABASE ${dbName}`);created=true;
  await admin.query(`COMMENT ON DATABASE ${dbName} IS '${marker}'`);
  db=new Client({connectionString:url.toString(),connectionTimeoutMillis:5000});await db.connect();
  const root=path.resolve(__dirname,'..'),files=migrationInventory(root).filter(([name])=>!name.startsWith('seed:')&&name!=='0013_cron_jobs.sql');
  function roleSetup(){
    execFileSync('docker',['exec','-i',container,'psql','-U','postgres','-d',dbName,'-X','-q','-v','ON_ERROR_STOP=1'],{input:fs.readFileSync(path.join(root,'setup_app_role.sql')),stdio:['pipe','pipe','pipe'],timeout:60000});
  }
  await db.query('CREATE SCHEMA pandapay');
  roleSetup();
  await db.query('CREATE TABLE schema_migrations(filename text PRIMARY KEY,applied_at timestamptz NOT NULL DEFAULT now(),checksum text)');
  for(const [name,file] of files.filter(([name])=>name<'20261112210000_shared_expenses_foundation.sql')){
    const sql=fs.readFileSync(file,'utf8');
    try{
      await db.query('BEGIN');await db.query(transactionalSql(sql));
      await db.query('RESET ROLE;RESET search_path');
      await db.query('INSERT INTO schema_migrations(filename,checksum) VALUES($1,$2)',[name,crypto.createHash('sha256').update(sql).digest('hex')]);await db.query('COMMIT');
    }catch(error){await db.query('ROLLBACK');throw Object.assign(new Error(`synthetic baseline migration failed: ${name} (${error.code}): ${error.message}`),{cause:error});}
  }
  const profile='11111111-1111-4111-8111-111111111111';
  await db.query('INSERT INTO public.profiles(id) VALUES($1)',[profile]);
  const txn=crypto.randomUUID();
  await db.query("INSERT INTO public.transactions(id,profile_id,source,amount_inr,merchant_name,occurred_at) VALUES($1,$2,'manual',1200,'Synthetic upgrade dinner','2026-11-04T12:00:00Z')",[txn,profile]);
  const before=(await db.query('SELECT to_jsonb(t) row FROM public.transactions t WHERE id=$1',[txn])).rows[0].row;
  await runProductMigrations(db,{dbDir:root,runRoleSetup:roleSetup});
  await runProductMigrations(db,{dbDir:root,runRoleSetup:roleSetup});
  assert.deepEqual((await db.query('SELECT to_jsonb(t) row FROM public.transactions t WHERE id=$1',[txn])).rows[0].row,before);
  assert.equal((await db.query('SELECT source_guards_enabled FROM shared_expenses.settings')).rows[0].source_guards_enabled,false);
  await db.query('BEGIN;SET LOCAL ROLE app_user');await db.query("SELECT set_config('app.user_id',$1,true)",[profile]);
  assert.equal((await db.query('SELECT count(*)::int n FROM transactions')).rows[0].n,1);
  assert.equal((await db.query('SELECT shared_expenses.capabilities() result')).rows[0].result.acceptedWrites,false);
  await db.query('SAVEPOINT denied');await assert.rejects(db.query('UPDATE shared_expenses.context_totals SET total_minor=0'),/permission denied/);await db.query('ROLLBACK TO denied');
  await db.query('SAVEPOINT denied_private');await assert.rejects(db.query('SELECT source_links FROM shared_expenses.expense_revisions'),/permission denied/);await db.query('ROLLBACK TO denied_private');
  await db.query('ROLLBACK');
  const accepted=(await db.query('SELECT count(*)::int n FROM shared_expenses.expenses')).rows[0].n;assert.equal(accepted,0);
});
