#!/usr/bin/env python3
"""Owned disposable PG and credential-free source copy; never read .env/live URLs."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
MIGRATION = '20261025151350_legacy_sync_context_isolation.sql'


def main():
    binding = subprocess.run(['node', '-e', "const {sourceSnapshot}=require('./db/scripts/release_security_check'); const s=sourceSnapshot(process.cwd());console.log(JSON.stringify({candidate_sha256:s.candidate_sha256,file_count:s.file_count}));"], cwd=ROOT, capture_output=True, text=True, check=True)
    candidate_binding = json.loads(binding.stdout)
    with tempfile.TemporaryDirectory(prefix='pandapay-sync-isolation-', dir='/private/tmp') as temporary:
        work = Path(temporary)
        candidate = work / 'candidate'
        candidate.mkdir()
        for name in ['api', 'auth']:
            for folder in ['src', 'test', 'scripts', 'db']:
                source = ROOT / name / folder
                if source.exists():
                    shutil.copytree(source, candidate / name / folder, ignore=shutil.ignore_patterns('node_modules', '.env*', '.temp', '__pycache__'))
            for filename in ['package.json', 'package-lock.json']:
                shutil.copyfile(ROOT / name / filename, candidate / name / filename)
            (candidate / name / 'node_modules').symlink_to(ROOT / name / 'node_modules', target_is_directory=True)
        shutil.copytree(ROOT / 'db', candidate / 'db', ignore=shutil.ignore_patterns('node_modules', '.env*', '.temp', '__pycache__'))
        migration = candidate / 'db/supabase/migrations' / MIGRATION
        pending = migration.read_bytes()
        migration.unlink()
        env = {k: os.environ[k] for k in ('PATH', 'HOME', 'SYSTEMROOT') if k in os.environ}
        env.update(PATH='/opt/homebrew/opt/postgresql@18/bin:' + env.get('PATH', ''), LC_ALL='C', LANG='C',
                   TMPDIR=str(work), NODE_ENV='test', DB_SSL='false', DOTENV_CONFIG_QUIET='true',
                   APP_USER_PASSWORD='synthetic-app-isolation-password', REWARD_WORKER_DB_PASSWORD='synthetic-worker-isolation-password',
                   SMS_LEARNING_WORKER_DB_PASSWORD='synthetic-learning-isolation-password')
        tools = {name: shutil.which(name, path=env['PATH']) for name in ['initdb', 'pg_ctl', 'psql', 'pg_dump', 'pg_restore', 'createdb', 'node']}
        if not all(tools.values()):
            raise RuntimeError('Installed PostgreSQL18 and Node required')
        results = {'scope': 'synthetic-owned-loopback-only', 'customer_data_or_live_provider': False, 'source': candidate_binding}

        def run(args, label, stdin=None):
            result = subprocess.run(args, cwd=candidate, env=env, input=stdin, text=True, capture_output=True, timeout=180)
            (OUT / (label + '.log')).write_text(result.stdout + result.stderr)
            if result.returncode:
                raise RuntimeError('Synthetic ' + label + ' failed; inspect synthetic-only saved log')
            return result.stdout

        def sql(query, label, url):
            return run([tools['psql'], '-X', '--dbname', url, '-At', '-v', 'ON_ERROR_STOP=1', '-c', query], label)

        def data_digest(url, label):
            # Reuse the canonical sorted-row/cursor fingerprints. Physical row
            # order can change after a rolled-back request; sequences advance
            # on rollback by PostgreSQL design and are compared separately.
            env['ISOLATION_SNAPSHOT_URL'] = url
            source = """
const {Client}=require('./api/node_modules/pg');
const {createHash}=require('node:crypto');
const {captureProductState}=require('./db/scripts/rehearse_product_upgrade');
(async()=>{const c=new Client({connectionString:process.env.ISOLATION_SNAPSHOT_URL,ssl:false});await c.connect();try{
 const state=await captureProductState(c);
 const seq=(await c.query("SELECT schemaname,sequencename,last_value::text FROM pg_sequences WHERE schemaname !~ '^pg_' ORDER BY schemaname,sequencename")).rows;
 const hash=value=>createHash('sha256').update(JSON.stringify(value)).digest('hex');
 console.log(JSON.stringify({tables:state.tables.size,table_data_sha256:hash([...state.fingerprints]),sequence_state_sha256:hash(seq)}));
}finally{await c.end();}})().catch(()=>{console.error('Synthetic fingerprint failed');process.exitCode=1;});
"""
            return json.loads(run([tools['node'], '-e', source], label))

        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        cluster = work / 'cluster'
        started = False
        try:
            run([tools['initdb'], '-D', str(cluster), '-A', 'trust', '--no-locale', '--encoding=UTF8', '-U', 'isolation_fixture'], 'pg-init')
            run([tools['pg_ctl'], '-D', str(cluster), '-l', str(work / 'server.log'), '-o', f'-p {port} -h 127.0.0.1 -k {work}', 'start'], 'pg-start')
            started = True
            base = f'postgresql://isolation_fixture:synthetic@127.0.0.1:{port}'
            results['postgres_version'] = sql('SHOW server_version', 'pg-version', base + '/postgres').strip()
            upgrade = base + '/sync_isolation_upgrade_test'
            run([tools['createdb'], '--maintenance-db', base + '/postgres', 'sync_isolation_upgrade_test'], 'upgrade-create')
            env['ADMIN_DATABASE_URL'] = upgrade
            run([tools['node'], 'db/scripts/product_migrate.js'], 'pre-isolation-migration')
            env['PANDAPAY_SYNC_ISOLATION_TEST_URL'] = upgrade
            run([tools['node'], 'api/test/sync_isolation_postgres.js', '--seed'], 'upgrade-seed')
            before = data_digest(upgrade, 'upgrade-data-before')
            function_oids = sql("SELECT oid::text FROM pg_proc WHERE pronamespace='pandapay'::regnamespace AND proname IN ('register_sync_device','sync_apply_change','sync_pull','sync_ack','sync_insert_user_category','sync_apply_user_merchant_category_rule') ORDER BY oid", 'upgrade-oids-before', upgrade)
            migration.write_bytes(pending)
            run([tools['node'], 'db/scripts/product_migrate.js'], 'isolation-upgrade-migration')
            assert before == data_digest(upgrade, 'upgrade-data-after')
            after_oids = sql("SELECT oid::text FROM pg_proc WHERE pronamespace='pandapay'::regnamespace AND proname IN ('register_sync_device','sync_apply_change','sync_pull','sync_ack','sync_insert_user_category','sync_apply_user_merchant_category_rule') ORDER BY oid", 'upgrade-oids-after', upgrade)
            assert function_oids == after_oids
            run([tools['node'], 'db/scripts/product_migrate.js'], 'isolation-migration-repeat')
            assert before == data_digest(upgrade, 'repeat-data-after')
            run([tools['node'], 'api/test/sync_isolation_postgres.js'], 'independent-login-isolation')
            after_requests = data_digest(upgrade, 'isolation-data-after')
            assert before['table_data_sha256'] == after_requests['table_data_sha256']
            results['seeded_upgrade'] = {'all_nonledger_data_digest_equal': True, 'routine_oids_preserved': True, 'repeat_passed': True, 'before_state': before, 'request_rollback_table_rows_preserved': True, 'sequence_gaps_after_rolled_back_writes_expected': True}
            results['independent_login_guards'] = 'passed'
            dump = work / 'product.dump'
            run([tools['pg_dump'], '--dbname', upgrade, '--format=custom', '--file', str(dump)], 'product-dump')
            restored = base + '/sync_transport_test'
            run([tools['createdb'], '--maintenance-db', base + '/postgres', 'sync_transport_test'], 'restore-create')
            run([tools['pg_restore'], '--dbname', restored, '--exit-on-error', str(dump)], 'product-restore')
            assert after_requests == data_digest(restored, 'restored-data')
            env['PANDAPAY_SYNC_ISOLATION_TEST_URL'] = restored
            run([tools['node'], 'api/test/sync_isolation_postgres.js'], 'restored-isolation')
            results['full_dump_restore_and_isolation_reopen'] = 'passed'
            # Independent fresh migrated DB for existing route and financial
            # regression fixtures, which deliberately refuse seeded profiles.
            run([tools['psql'], '--dbname', base + '/postgres', '-X', '-v', 'ON_ERROR_STOP=1', '-c', 'DROP DATABASE sync_transport_test'], 'owned-restore-drop')
            run([tools['createdb'], '--maintenance-db', base + '/postgres', 'sync_transport_test'], 'fresh-create')
            env['ADMIN_DATABASE_URL'] = restored
            run([tools['node'], 'db/scripts/product_migrate.js'], 'fresh-migration')
            env.update(PANDAPAY_SYNC_TRANSPORT_TEST_URL=restored, PANDAPAY_SYNC_TYPED_TEST_URL=restored, PANDAPAY_SYNC_FINANCIAL_TEST_URL=restored)
            for label, file in [('legacy-transport', 'sync_transport_postgres.js'), ('typed-sync', 'sync_typed_changes_postgres.js'), ('financial-sync', 'sync_financial_postgres.js')]:
                run([tools['node'], 'api/test/' + file], label)
                results[label] = 'passed'
            print('PASS: seeded upgrade/repeat/OIDs/data, independent LOGIN guards, full synthetic dump/restore/reopen, fresh migration and legacy/typed/financial sync regressions', flush=True)
            results['result'] = 'passed'
            final = subprocess.run(['node', '-e', "const {sourceSnapshot}=require('./db/scripts/release_security_check');console.log(sourceSnapshot(process.cwd()).candidate_sha256);"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
            results['source_unchanged'] = final == candidate_binding['candidate_sha256']
            assert results['source_unchanged']
        finally:
            if started:
                run([tools['pg_ctl'], '-D', str(cluster), '-m', 'immediate', 'stop'], 'pg-stop')
            (OUT / 'postgres-results.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
