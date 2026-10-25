#!/usr/bin/env python3
"""Full synthetic migration/encrypted restore; owns and stops two temp clusters.

Requires native PostgreSQL server/client binaries, age, Node and auth npm deps.
No existing DB, .env, production credential or customer record is used.
"""
import base64
import json
import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run(args, env, *, stdin=None):
    result = subprocess.run(args, cwd=ROOT, env=env, input=stdin, text=True, capture_output=True)
    if result.returncode:
        # Only synthetic fixtures are used; retain tool detail for CI debugging.
        raise RuntimeError(f"{Path(args[0]).name} failed: {result.stderr[-3000:]}\n{result.stdout[-1000:]}")
    return result.stdout


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def main():
    for tool in ('initdb', 'pg_ctl', 'psql', 'pg_dumpall', 'age', 'age-keygen', 'node'):
        if not shutil.which(tool):
            raise SystemExit(f'Required integration-test tool is missing: {tool}')
    # backup_common.sh supports macOS's shasum as well as GNU sha256sum.
    # Match that contract so the local recovery rehearsal can run on a Mac.
    if not (shutil.which('sha256sum') or shutil.which('shasum')):
        raise SystemExit('Required integration-test tool is missing: sha256sum or shasum')
    with tempfile.TemporaryDirectory(prefix='pp-security-', dir='/tmp') as temporary:
        work = Path(temporary)
        basic = {name: os.environ[name] for name in ('PATH','HOME','TMPDIR','SYSTEMROOT') if name in os.environ}
        env = dict(basic, LC_ALL='C', LANG='C', NODE_ENV='test', DB_SSL='false', ENCRYPTION_ENABLED='true',
                   ENCRYPTION_KEY=base64.b64encode(bytes([9]) * 32).decode(),
                   PHONE_LOOKUP_HMAC_KEY='synthetic-security-recovery-hmac-key-32bytes',
                   APP_USER_PASSWORD='synthetic-app-password', REWARD_WORKER_DB_PASSWORD='synthetic-worker-password',
                   BACKUP_STATUS_WRITER_DB_PASSWORD='synthetic-backup-status-password-32bytes',
                   SEED_DEMO_DATA='false', DB_SSL_CA='', DB_SSL_CA_FILE='', BACKUP_MAX_USAGE_PERCENT='99',
                   MIGRATION_ADOPT_LEGACY_CHECKSUMS='false', MIGRATION_LEGACY_BASELINE_FILE='')
        # Never inherit a caller's live libpq defaults into this fixture.
        for name in list(env):
            if name.startswith('PG'):
                env.pop(name)
        clusters = []
        try:
            source_port, target_port = port(), port()
            for name, number in [('source', source_port), ('recovery', target_port)]:
                folder = work / name
                run(['initdb', '-D', str(folder), '-A', 'trust', '--no-locale', '--encoding=UTF8', '-U', 'security_test'], env)
                run(['pg_ctl', '-D', str(folder), '-l', str(work / f'{name}.log'), '-o', f'-p {number} -h 127.0.0.1 -k {work}', 'start'], env)
                clusters.append(folder)
            source = f'postgresql://security_test@127.0.0.1:{source_port}'
            target = f'postgresql://security_test@127.0.0.1:{target_port}'
            run(['psql', source + '/postgres', '-X', '-v', 'ON_ERROR_STOP=1', '-c', 'CREATE DATABASE product_test', '-c', 'CREATE DATABASE auth_test', '-c', 'CREATE DATABASE otp_purpose_test',
                 '-c', 'CREATE DATABASE auth_contact_unique_test', '-c', 'CREATE DATABASE auth_contact_conflict_test',
                 '-c', 'CREATE DATABASE auth_abuse_test', '-c', 'CREATE DATABASE auth_runtime_permissions_test',
                 '-c', 'CREATE DATABASE schema_fingerprint_test'], env)
            env.update(ADMIN_DATABASE_URL=source + '/product_test', PRODUCT_DATABASE_URL=source + '/product_test',
                       AUTH_MIGRATION_DATABASE_URL=source + '/auth_test', AUTH_DATABASE_URL=source + '/auth_test')
            otp_env = dict(env, OTP_PURPOSE_TEST_DATABASE_URL=source + '/otp_purpose_test')
            run(['node', 'auth/test/otp_purpose_postgres.js'], otp_env)
            contact_env = dict(env,
                AUTH_CONTACT_UNIQUENESS_TEST_DATABASE_URL=source + '/auth_contact_unique_test',
                AUTH_CONTACT_UNIQUENESS_CONFLICT_TEST_DATABASE_URL=source + '/auth_contact_conflict_test')
            run(['node', 'auth/test/contact_uniqueness_postgres.js'], contact_env)
            run(['node', 'auth/test/auth_abuse_store_postgres.js'],
                dict(env, AUTH_ABUSE_TEST_DATABASE_URL=source + '/auth_abuse_test'))
            run(['node', 'auth/test/auth_runtime_permissions_postgres.js'],
                dict(env, AUTH_RUNTIME_PERMISSION_TEST_URL=
                     f'postgresql://security_test:synthetic-fixture-password@127.0.0.1:{source_port}/auth_runtime_permissions_test'))
            run(['node', 'db/tests/schema_fingerprint_postgres.js'],
                dict(env, SCHEMA_FINGERPRINT_TEST_URL=
                     f'postgresql://security_test:synthetic-fixture-password@127.0.0.1:{source_port}/schema_fingerprint_test'))
            run(['bash', 'db/scripts/migrate.sh'], env)
            fixture = r"""
const {Client}=require('./auth/node_modules/pg');
const {encryptPhoneNumber}=require('./auth/src/utils/fieldEncryption');
(async()=>{const a=new Client({connectionString:process.env.AUTH_DATABASE_URL});
const p=new Client({connectionString:process.env.PRODUCT_DATABASE_URL});await a.connect();await p.connect();
try {for(const [id,phone] of [['00000000-0000-4000-8000-000000000001','+919876543210'],['00000000-0000-4000-8000-000000000002','+918765432109']]) {
await a.query('INSERT INTO users(id,phone_number,is_phone_verified) VALUES ($1,$2,true)',[id,id.endsWith('1')?encryptPhoneNumber(phone):phone]);
await p.query('INSERT INTO profiles(id,display_name) VALUES ($1,$2)',[id,'Synthetic recovery\nfixture']);
}}finally{await a.end();await p.end()}})().catch(e=>{console.error(e.message);process.exitCode=1});
"""
            run(['node', '-'], env, stdin=fixture)
            run(['psql', source + '/product_test', '-X', '-v', 'ON_ERROR_STOP=1', '-c',
                 "CREATE ROLE pgbouncer NOLOGIN; CREATE SCHEMA pgbouncer AUTHORIZATION pgbouncer; "
                 "CREATE TABLE pgbouncer.recovery_probe(id integer PRIMARY KEY, note text); "
                 "INSERT INTO pgbouncer.recovery_probe VALUES (1,E'first line\\nsecond line'); "
                 "ALTER TABLE pgbouncer.recovery_probe OWNER TO pgbouncer; "
                 "CREATE ROLE extension_operator NOLOGIN; "
                 "GRANT CREATE ON DATABASE product_test TO extension_operator; "
                 "SET SESSION AUTHORIZATION extension_operator; CREATE EXTENSION hstore; "
                 "RESET SESSION AUTHORIZATION; "
                 "CREATE SCHEMA provider_initial AUTHORIZATION security_test; "
                 "GRANT USAGE ON SCHEMA provider_initial TO app_user WITH GRANT OPTION; "
                 "INSERT INTO pg_init_privs(objoid,classoid,objsubid,privtype,initprivs) "
                 "SELECT oid,'pg_namespace'::regclass,0,'i',nspacl FROM pg_namespace "
                 "WHERE nspname='provider_initial'"], env)
            run(['bash', 'db/scripts/migrate.sh'], env)  # legacy phone backfill
            run(['bash', 'db/scripts/migrate.sh'], env)  # idempotent repeat
            ledger_access = run(['psql', source + '/product_test', '-X', '-qAt', '-c', "SELECT has_table_privilege('app_user','public.schema_migrations','INSERT')"], env)
            assert ledger_access.strip() == 'f', 'Runtime role can still change migration history'
            # PostgreSQL 15+ cluster-level parameter ACL: include a known
            # grantor/grantee/grant-option tuple in the encrypted backup.
            run(['psql', source + '/postgres', '-X', '-v', 'ON_ERROR_STOP=1', '-c',
                 'GRANT SET ON PARAMETER log_min_messages TO app_user WITH GRANT OPTION'], env)
            bad = dict(env, PHONE_LOOKUP_HMAC_KEY='wrong-synthetic-hmac-key-that-is-long-enough')
            if subprocess.run(['node', 'auth/scripts/migrate.js'], cwd=ROOT, env=bad, capture_output=True).returncode == 0:
                raise AssertionError('Wrong retained HMAC key unexpectedly passed')
            roles = run(['pg_dumpall', '--database', source + '/postgres', '--roles-only', '--no-role-passwords'], env)
            roles = '\n'.join(line for line in roles.splitlines() if not line.startswith(('CREATE ROLE security_test;', 'ALTER ROLE security_test ')))
            (work / 'roles.sql').write_text(roles)
            # The target is a newly initialized, isolated disposable cluster.
            # Seed one unrelated parameter ACL so restore must reconcile its
            # parameter ACL policy to the source inventory.
            run(['psql', target + '/postgres', '-X', '-v', 'ON_ERROR_STOP=1', '-c',
                 'CREATE ROLE recovery_extra NOLOGIN; '
                 'GRANT SET ON PARAMETER log_min_messages TO recovery_extra'], env)
            run(['age-keygen', '-o', str(work / 'identity.txt')], env)
            recipient = run(['age-keygen', '-y', str(work / 'identity.txt')], env)
            (work / 'recipients.txt').write_text(recipient)
            for name in ('backups', 'offsite-a', 'offsite-b', 'status'):
                (work / name).mkdir()
            env.update(BACKUP_DIR=str(work / 'backups'), BACKUP_DESTINATION_A=str(work / 'offsite-a'),
                       BACKUP_DESTINATION_B=str(work / 'offsite-b'), BACKUP_AGE_RECIPIENTS_FILE=str(work / 'recipients.txt'))
            # Mutate synthetic source rows after snapshot export but before
            # pg_dump reads them. Inventory must still describe the dump, not
            # the newer live table; otherwise this round trip fails digests.
            native_dump, native_psql = shutil.which('pg_dump'), shutil.which('psql')
            bin_dir = work / 'bin'; bin_dir.mkdir()
            wrapper = bin_dir / 'pg_dump'
            wrapper.write_text('#!/usr/bin/env python3\nimport os,sys,subprocess\n' +
                f'subprocess.run([{native_psql!r},os.environ["PRODUCT_DATABASE_URL"],"-X","-q","-v","ON_ERROR_STOP=1","-c","UPDATE profiles SET display_name=\'Synthetic concurrent change\'"],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)\n' +
                f'os.execv({native_dump!r},[{native_dump!r}]+sys.argv[1:])\n')
            wrapper.chmod(0o755)
            env['PATH'] = str(bin_dir) + os.pathsep + env['PATH']
            run(['bash', 'db/scripts/backup.sh'], env)
            sets = list((work / 'offsite-a').glob('*/OFFSITE_COMPLETE'))
            assert len(sets) == 1
            backup_manifest = json.loads(run(['age', '-d', '-i', str(work / 'identity.txt'),
                str(sets[0].parent / 'manifest.json.age')], env))
            product_inventory = backup_manifest['archives']['product.dump']['database']
            assert product_inventory['exact_row_counts']['pgbouncer.recovery_probe'] == 1
            assert 'pgbouncer' in product_inventory['required_roles']
            # The first GRANT materializes PostgreSQL's default bootstrap-owner
            # SET/ALTER SYSTEM entries as well as the explicit application grant.
            expected_parameter_grants = [['log_min_messages', [
                ['security_test', 'app_user', 'SET', True],
                ['security_test', 'security_test', 'ALTER SYSTEM', False],
                ['security_test', 'security_test', 'SET', False],
            ]]]
            assert product_inventory['parameter_grants'] == expected_parameter_grants, product_inventory.get('parameter_grants')
            assert backup_manifest['archives']['auth.dump']['database']['parameter_grants'] == expected_parameter_grants
            manifest_text = run(['age', '-d', '-i', str(work / 'identity.txt'),
                                 str(sets[0].parent / 'manifest.json.age')], env)
            profile_count = json.loads(manifest_text)['archives']['product.dump']['database']['exact_row_counts']['public.profiles']
            assert profile_count == 2, f'COPY physical-line inventory expected 2 profiles, got {profile_count}'
            env.update(BACKUP_SET_DIR=str(sets[0].parent), RESTORE_ADMIN_DATABASE_URL=target + '/postgres',
                       RESTORE_PRODUCT_DATABASE_URL=target + '/product_template', RESTORE_AUTH_DATABASE_URL=target + '/auth_template',
                       RESTORE_AGE_IDENTITY_FILE=str(work / 'identity.txt'), RESTORE_ROLE_BOOTSTRAP_FILE=str(work / 'roles.sql'),
                       RESTORE_STATUS_DIR=str(work / 'status'), RESTORE_APPLICATION_CHECK=str(ROOT / 'db/scripts/verify_recovery.js'))
            env['RESTORE_EXTENSION_BOOTSTRAP_ATTESTATION'] = 'THIS_IS_AN_ISOLATED_DISPOSABLE_RECOVERY_CLUSTER'
            without_parameter_attestation = dict(env)
            without_parameter_attestation.pop('RESTORE_PARAMETER_ACL_ATTESTATION', None)
            missing_attestation = subprocess.run(['bash', 'db/scripts/restore_drill.sh'], cwd=ROOT,
                                                 env=without_parameter_attestation, capture_output=True, text=True)
            if missing_attestation.returncode == 0:
                raise AssertionError('Restore accepted global parameter ACL replay without isolated-cluster attestation')
            target_databases = run(['psql', target + '/postgres', '-X', '-qAt', '-c',
                "SELECT datname FROM pg_database WHERE datname NOT LIKE 'template%' ORDER BY datname"], env).splitlines()
            assert target_databases == ['postgres'], f'Missing-attestation gate mutated target: {target_databases}'
            env['RESTORE_PARAMETER_ACL_ATTESTATION'] = 'I_HAVE_VERIFIED_FRESH_ISOLATED_RECOVERY_CLUSTER'
            run(['psql', target + '/postgres', '-X', '-v', 'ON_ERROR_STOP=1', '-c',
                 'CREATE DATABASE recovery_unexpected'], env)
            rejected = subprocess.run(['bash', 'db/scripts/restore_drill.sh'], cwd=ROOT,
                                      env=env, capture_output=True, text=True)
            if rejected.returncode == 0:
                raise AssertionError('Restore accepted a target cluster containing an unrelated database')
            target_databases = run(['psql', target + '/postgres', '-X', '-qAt', '-c',
                "SELECT datname FROM pg_database WHERE datname IN ('product_template','auth_template','recovery_unexpected') ORDER BY datname"], env).splitlines()
            assert target_databases == ['recovery_unexpected'], f'Preflight mutated target before rejecting it: {target_databases}'
            run(['psql', target + '/postgres', '-X', '-v', 'ON_ERROR_STOP=1', '-c',
                 'DROP DATABASE recovery_unexpected'], env)
            run(['bash', 'db/scripts/restore_drill.sh'], env)
            proof_file = sets[0].parent / 'RESTORE_VERIFIED'
            proof = dict(line.split('=', 1) for line in proof_file.read_text().splitlines())
            import hashlib
            assert proof['proof_format'] == 'pandapay-paired-postgresql-restore-proof-v1'
            for filename, field in [('manifest.json.age', 'manifest_ciphertext_sha256'),
                                    ('product.dump.age', 'product_ciphertext_sha256'),
                                    ('auth.dump.age', 'auth_ciphertext_sha256')]:
                assert proof[field] == hashlib.sha256((sets[0].parent / filename).read_bytes()).hexdigest()
            publication_env = dict(env,
                BACKUP_STATUS_DATABASE_URL=f'postgresql://backup_status_runtime:synthetic-backup-status-password-32bytes@127.0.0.1:{source_port}/product_test',
                BACKUP_STATUS_DB_SSL='false', BACKUP_STATUS_AGE_IDENTITY_FILE=str(work / 'identity.txt'))
            published = run(['node', 'db/scripts/publish_backup_status.js', '--set-dir', str(sets[0].parent)], publication_env)
            assert 'BACKUP_STATUS_PUBLICATION=verified' in published
            count = run(['psql', source + '/product_test', '-X', '-qAt', '-c', 'SELECT count(*) FROM backup_status.attestations'], env)
            assert count.strip() == '1', 'Verified restore status was not published by the narrow publisher'
            status = next((work / 'status').glob('RESTORE_VERIFIED-*')).read_text()
            assert 'application_check=passed' in status
            # The owner's initial destination is a local PC: exercise the same
            # real encrypted format without claiming off-host copies.
            local_dir = work / 'local-pc-sets'; local_dir.mkdir()
            local_env = dict(env, BACKUP_MODE='local', BACKUP_DIR=str(local_dir))
            local_output = run(['bash', 'db/scripts/backup.sh'], local_env)
            assert 'status=local_saved copies=1' in local_output
            local_sets = list(local_dir.glob('*/LOCAL_COMPLETE'))
            assert len(local_sets) == 1
            assert not list(local_dir.glob('*/OFFSITE_COMPLETE'))
            # This same recovery cluster already has the reviewed fixture roles.
            (work / 'roles-already-provisioned.sql').write_text('-- application roles already provisioned by the preceding drill\n')
            local_env.update(BACKUP_SET_DIR=str(local_sets[0].parent),
                RESTORE_ROLE_BOOTSTRAP_FILE=str(work / 'roles-already-provisioned.sql'))
            run(['bash', 'db/scripts/restore_drill.sh'], local_env)
            assert (local_sets[0].parent / 'RESTORE_VERIFIED').is_file()
            wrong_host = dict(env, RESTORE_ADMIN_DATABASE_URL=source + '/postgres',
                              RESTORE_PRODUCT_DATABASE_URL=source + '/product_template', RESTORE_AUTH_DATABASE_URL=source + '/auth_template')
            if subprocess.run(['bash', 'db/scripts/restore_drill.sh'], cwd=ROOT, env=wrong_host, capture_output=True).returncode == 0:
                raise AssertionError('Restore incorrectly accepted the source host')
            assert not list((work / 'backups').rglob('*.dump'))
            assert not list((work / 'backups').rglob('manifest.json'))
            print('PASS: empty-install, repeat, mixed legacy phone backfill, wrong-key rejection, runtime ledger denial, snapshot consistency under writes, paired age-encrypted v5 export, independent PostgreSQL restore, table/schema/ACL/global-parameter comparison, grantor/grant-option preservation, fresh-cluster attestation and preflight refusal, key/identity verification, hash-bound restore proof and narrow verified-status publication, local PC mode and source-host restore rejection')
        finally:
            for folder in reversed(clusters):
                subprocess.run(['pg_ctl', '-D', str(folder), '-m', 'immediate', 'stop'], env=env, capture_output=True)


if __name__ == '__main__':
    main()
