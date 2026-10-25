# Reproduction recipe adapted from the executed local driver. Requires native PostgreSQL18.
# PANDAPAY_SANITIZED_TEST_CANDIDATE points to the prepared source/dependency copy.
from pathlib import Path
import os,socket,tempfile,subprocess,json,shutil,uuid,hashlib,sys
repo=Path(__file__).resolve().parents[2];candidate=Path(os.environ['PANDAPAY_SANITIZED_TEST_CANDIDATE']).resolve();out=Path(__file__).resolve().parent;work=Path(tempfile.mkdtemp(prefix='pandapay-sync-financial-pg-',dir='/private/tmp'));data=work/'data'
env={k:os.environ[k] for k in ('PATH','HOME') if k in os.environ};env.update(PATH='/opt/homebrew/bin:'+env.get('PATH',''),LC_ALL='C',LANG='C',TMPDIR=str(work),NODE_ENV='test',DB_SSL='false',APP_USER_PASSWORD='synthetic-app-fixture-password',REWARD_WORKER_DB_PASSWORD='synthetic-reward-fixture-password',SMS_LEARNING_WORKER_DB_PASSWORD='synthetic-sms-fixture-password')
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
started=False;results={}
def run(args,label,stdin=None):
 p=subprocess.run(args,cwd=candidate,env=env,text=True,input=stdin,capture_output=True,timeout=180)
 (out/(label+'.log')).write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError('Synthetic '+label+' failed; inspect synthetic-only evidence log')
 return p.stdout
try:
 version=run(['initdb','--version'],'pg-version')
 if '18.' not in version:raise RuntimeError('This recorded synthetic recipe requires PostgreSQL18; target-provider acceptance is separate')
 run(['initdb','-D',str(data),'-A','trust','--no-locale','--encoding=UTF8','-U','fixture_owner'],'pg-init')
 run(['pg_ctl','-D',str(data),'-l',str(work/'postgres.log'),'-o',f'-p {port} -h 127.0.0.1 -k {work}','start'],'pg-start');started=True
 url=f'postgresql://fixture_owner:synthetic-fixture-password@127.0.0.1:{port}/sync_transport_test'
 run(['createdb','-h','127.0.0.1','-p',str(port),'-U','fixture_owner','sync_transport_test'],'pg-createdb')
 env['ADMIN_DATABASE_URL']=url
 run(['node','db/scripts/product_migrate.js'],'synthetic-product-migrate');results['fresh_product_migration']='passed'
 run(['node','db/scripts/product_migrate.js'],'synthetic-product-migrate-repeat');results['checksummed_migration_repeat']='passed'
 env.update(PANDAPAY_SYNC_TYPED_TEST_URL=url,PANDAPAY_SYNC_TRANSPORT_TEST_URL=url,PANDAPAY_SYNC_FINANCIAL_TEST_URL=url)
 for name,filename in [('typed_sql','sync_typed_changes_postgres.js'),('legacy_transport','sync_transport_postgres.js')]:
  results[name]=run(['node','api/test/'+filename],'postgres-'+name).strip();print(json.dumps({name:results[name]}),flush=True)
 (out/'postgres-regression-results.json').write_text(json.dumps(results,indent=2)+'\n')
 print('Running frozen financial fixture',flush=True)
 results['financial_state']=run(['node','api/test/sync_financial_postgres.js'],'postgres-financial-state').strip();print(json.dumps({'financial_state':results['financial_state']}),flush=True)
 profile,device,txn=[str(uuid.uuid4()) for _ in range(3)]
 sql=f"""BEGIN;
 INSERT INTO profiles(id) VALUES('{profile}');
 INSERT INTO user_devices(id,profile_id,platform) VALUES('{device}','{profile}','web');
 INSERT INTO transactions(id,profile_id,amount_inr,occurred_at,instrument,entry_kind,source,status,note) VALUES('{txn}','{profile}',1000,'2026-10-01T10:00:00Z','cash','spend','manual','active','synthetic restore probe');
 SET LOCAL ROLE app_user; SELECT set_config('app.user_id','{profile}',true);
 SELECT * FROM pandapay.sync_apply_change_v2('{profile}','{device}','transactions','{txn}','update','{{"amount_inr":1750.25,"note":"typed restore probe"}}','{{"amount_inr":1000,"note":1000}}',1);
 COMMIT;
 """
 run(['psql','-X','--dbname',url,'-v','ON_ERROR_STOP=1'], 'restore-probe-seed',sql)
 fingerprint="SELECT jsonb_build_object('profiles',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM profiles t),'devices',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM user_devices t),'transactions',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM transactions t),'change_log',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM change_log t),'v2',pg_get_functiondef('pandapay.sync_apply_change_v2(uuid,uuid,text,uuid,sync_op,jsonb,jsonb,bigint)'::regprocedure))::text;"
 before=run(['psql','-X','--dbname',url,'-At','-v','ON_ERROR_STOP=1','-c',fingerprint],'restore-probe-before')
 run(['pg_dump','--dbname',url,'--format=custom','--file',str(work/'product.dump')],'product-dump')
 run(['createdb','-h','127.0.0.1','-p',str(port),'-U','fixture_owner','sync_transport_restore_test'],'pg-restore-createdb')
 restored=url.replace('/sync_transport_test','/sync_transport_restore_test')
 run(['pg_restore','--exit-on-error','--dbname',restored,str(work/'product.dump')],'product-restore')
 after=run(['psql','-X','--dbname',restored,'-At','-v','ON_ERROR_STOP=1','-c',fingerprint],'restore-probe-after')
 if before!=after:raise RuntimeError('Synthetic full dump/restore fingerprint changed')
 check=f"""BEGIN; SET LOCAL ROLE app_user; SELECT set_config('app.user_id','{profile}',true); SELECT * FROM pandapay.sync_apply_change_v2('{profile}','{device}','transactions','{txn}','update','{{"amount_inr":1800}}','{{"amount_inr":2000}}',2); SELECT amount_inr FROM transactions WHERE id='{txn}'; ROLLBACK;"""
 output=run(['psql','-X','--dbname',restored,'-At','-v','ON_ERROR_STOP=1','-c',check],'restore-probe-reopen')
 if '1800.00' not in output:raise RuntimeError('Synthetic typed write after restore failed')
 results['dump_restore']={'same_major':18,'full_schema_dump_restore':'passed','synthetic_profile_device_transaction_and_log_fingerprint_equal':True,'v2_definition_equal':True,'typed_write_after_restore':'passed','fingerprint_sha256':hashlib.sha256(before.encode()).hexdigest()}
 print(json.dumps(results),flush=True)
finally:
 if started:subprocess.run(['pg_ctl','-D',str(data),'-m','immediate','stop'],env=env,capture_output=True)
 shutil.rmtree(work,ignore_errors=True)
 (out/'postgres-regression-results.json').write_text(json.dumps(results,indent=2)+'\n')
