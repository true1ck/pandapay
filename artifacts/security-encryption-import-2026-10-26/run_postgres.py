#!/usr/bin/env python3
"""Owned temporary loopback PostgreSQL, synthetic data; no saved env/URLs."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import base64
import secrets
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]
OUT=Path(__file__).resolve().parent
MIGRATIONS=['20261026130000_notification_delivery_health.sql','20261026140000_statement_import_receipts.sql']

def main():
    binding=json.loads(subprocess.check_output(['node','-e',"const s=require('./db/scripts/release_security_check').sourceSnapshot(process.cwd());console.log(JSON.stringify({candidate_sha256:s.candidate_sha256,file_count:s.file_count}));"],cwd=ROOT,text=True))
    results={'source':binding,'scope':'owned-synthetic-loopback-only','saved_credentials_or_customer_data':False,'checks':{}}
    with tempfile.TemporaryDirectory(prefix='pandapay-durable-pg-',dir='/private/tmp') as temporary:
        work=Path(temporary); candidate=work/'candidate'; candidate.mkdir()
        shutil.copytree(ROOT/'db',candidate/'db',ignore=shutil.ignore_patterns('.env*','__pycache__','*.dump','*.age'))
        for folder in ['api','auth']:
            (candidate/folder).mkdir(); shutil.copytree(ROOT/folder/'src',candidate/folder/'src')
            shutil.copytree(ROOT/folder/'test',candidate/folder/'test')
            for filename in ['package.json','package-lock.json']:shutil.copyfile(ROOT/folder/filename,candidate/folder/filename)
            (candidate/folder/'node_modules').symlink_to(ROOT/folder/'node_modules',target_is_directory=True)
        env={key:os.environ[key] for key in ['PATH','HOME','SYSTEMROOT'] if key in os.environ}
        env.update(PATH='/opt/homebrew/opt/postgresql@18/bin:'+env.get('PATH',''),TMPDIR=str(work),LC_ALL='C',LANG='C',NODE_ENV='test',DB_SSL='false',DOTENV_CONFIG_QUIET='true',APP_USER_PASSWORD='synthetic-app-password',REWARD_WORKER_DB_PASSWORD='synthetic-reward-password',SMS_LEARNING_WORKER_DB_PASSWORD='synthetic-learning-password')
        tools={key:shutil.which(key,path=env['PATH']) for key in ['initdb','pg_ctl','psql','node','pg_dump','pg_restore','createdb']}
        if not all(tools.values()): raise RuntimeError('Installed Node and PostgreSQL required')
        logs=work/'logs';logs.mkdir()
        def run(args,label,stdin=None):
            r=subprocess.run(args,cwd=candidate,env=env,input=stdin,text=True,capture_output=True,timeout=180)
            (logs/(label+'.log')).write_text(r.stdout+r.stderr)
            results['checks'][label]={'exit_code':r.returncode,'log_sha256':hashlib.sha256((r.stdout+r.stderr).encode()).hexdigest()}
            if r.returncode: raise RuntimeError(label+' failed: '+(r.stderr+r.stdout)[-3500:])
            return r.stdout
        with socket.socket() as sock: sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        cluster=work/'cluster';started=False
        try:
            run([tools['initdb'],'-D',str(cluster),'-A','trust','--no-locale','--encoding=UTF8','-U','durable_fixture'],'init')
            run([tools['pg_ctl'],'-D',str(cluster),'-l',str(work/'server.log'),'-o',f'-p {port} -h 127.0.0.1 -k {work}','start'],'start');started=True
            base=f'postgresql://durable_fixture:synthetic@127.0.0.1:{port}'
            run([tools['createdb'],'--maintenance-db',base+'/postgres','sync_isolation_upgrade_test'],'create')
            url=base+'/sync_isolation_upgrade_test';env['ADMIN_DATABASE_URL']=url
            results['postgres_version']=run([tools['psql'],url,'-X','-Atc','SHOW server_version'],'version').strip()
            pending={}
            for name in MIGRATIONS:
                f=candidate/'db/supabase/migrations'/name;pending[name]=f.read_bytes();f.unlink()
            run([tools['node'],'db/scripts/product_migrate.js'],'baseline-migrate')
            env['PANDAPAY_SYNC_ISOLATION_TEST_URL']=url
            run([tools['node'],'api/test/sync_isolation_postgres.js','--seed'],'seed')
            snapshot="""const {Client}=require('./api/node_modules/pg'),{createHash}=require('node:crypto');(async()=>{const c=new Client({connectionString:process.env.ADMIN_DATABASE_URL,ssl:false});await c.connect();const t=(await c.query(\"SELECT schemaname,tablename FROM pg_tables WHERE schemaname !~ '^pg_' AND schemaname <> 'information_schema' AND tablename NOT IN ('schema_migrations','worker_status') ORDER BY 1,2\")).rows;const r={};for(const x of t){const q='SELECT to_jsonb(t)'+(x.schemaname==='public'&&x.tablename==='statement_imports'?\" - 'import_request_hash' - 'import_response_summary'\":'')+' AS v FROM \"'+x.schemaname+'\".\"'+x.tablename+'\" t';const values=(await c.query(q)).rows.map(x=>JSON.stringify(x.v)).sort();r[x.schemaname+'.'+x.tablename]=createHash('sha256').update(JSON.stringify(values)).digest('hex');}await c.end();console.log(JSON.stringify(r));})().catch(e=>{console.error(e);process.exitCode=1;});"""
            before=json.loads(run([tools['node'],'-e',snapshot],'before-data'))
            for name,data in pending.items():(candidate/'db/supabase/migrations'/name).write_bytes(data)
            run([tools['node'],'db/scripts/product_migrate.js'],'upgrade')
            after=json.loads(run([tools['node'],'-e',snapshot],'after-data'));assert before==after
            results['original_tables_preserved']=len(before)
            run([tools['node'],'db/scripts/product_migrate.js'],'repeat-ledger')
            for name in MIGRATIONS:
                run([tools['psql'],url,'-X','-v','ON_ERROR_STOP=1','-f','db/supabase/migrations/'+name], 'replay-'+name)
                run([tools['psql'],url,'-X','-v','ON_ERROR_STOP=1','-f','db/tests/'+name.replace('.sql','_test.sql')], 'fixture-'+name)
            assert before==json.loads(run([tools['node'],'-e',snapshot],'post-fixtures-data'))
            env['SECURITY_DELIVERY_TEST_URL']=url
            run([tools['node'],'api/test/security_delivery_postgres.js'],'concurrency-and-login')
            dump=work/'synthetic.dump';run([tools['pg_dump'],'--dbname',url,'--format=custom','--file',str(dump)],'dump')
            run([tools['createdb'],'--maintenance-db',base+'/postgres','security_durable_restored'],'restore-create')
            restored=base+'/security_durable_restored'
            run([tools['pg_restore'],'--dbname',restored,'--exit-on-error',str(dump)],'restore')
            env['ADMIN_DATABASE_URL']=restored
            assert json.loads(run([tools['node'],'-e',snapshot],'restored-data'))==before
            results['full_dump_restore_preservation']=True
            # Independent synthetic auth-format fixture, with no saved key read.
            # This checks real VARCHAR width and opaque dump/restore, not the
            # complete auth schema or actual customer-key custody.
            env['PHONE_FORMAT_LEGACY_KEY']=base64.b64encode(secrets.token_bytes(32)).decode()
            env['PHONE_FORMAT_NEXT_KEY']=base64.b64encode(secrets.token_bytes(32)).decode()
            run([tools['createdb'],'--maintenance-db',base+'/postgres','phone_format_test'],'phone-create')
            env['PHONE_FORMAT_TEST_URL']=base+'/phone_format_test'
            run([tools['node'],'auth/test/phone_format_postgres.js','--seed'],'phone-seed-read')
            phone_dump=work/'phone-format.dump'
            run([tools['pg_dump'],'--dbname',env['PHONE_FORMAT_TEST_URL'],'--format=custom','--file',str(phone_dump)],'phone-dump')
            run([tools['createdb'],'--maintenance-db',base+'/postgres','phone_format_restored'],'phone-restore-create')
            env['PHONE_FORMAT_TEST_URL']=base+'/phone_format_restored'
            run([tools['pg_restore'],'--dbname',env['PHONE_FORMAT_TEST_URL'],'--exit-on-error',str(phone_dump)],'phone-restore')
            run([tools['node'],'auth/test/phone_format_postgres.js'],'phone-restored-read')
            results['synthetic_phone_formats_varchar255_and_dump_restore']=True

            final=json.loads(subprocess.check_output(['node','-e',"const s=require('./db/scripts/release_security_check').sourceSnapshot(process.cwd());console.log(JSON.stringify({candidate_sha256:s.candidate_sha256,file_count:s.file_count}));"],cwd=ROOT,text=True))
            assert binding==final
            results['source_unchanged']=True
            results['result']='passed'
            print('PASS: full migration/upgrade/replay, existing-data preservation, SQL role/quota/retry fixtures, multi-session guards and full dump/restore',flush=True)
        finally:
            if started:run([tools['pg_ctl'],'-D',str(cluster),'-m','immediate','stop'],'stop')
            results['logs_retained_in_git']=False
            (OUT/'postgres-results.json').write_text(json.dumps(results,indent=2)+'\n')

if __name__=='__main__': main()
