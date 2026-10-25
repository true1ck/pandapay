#!/usr/bin/env python3
"""Run remaining-security role fixtures on one owned, disposable cluster.

Never reads .env or existing database URLs. initdb/pg_ctl point only into this
invocation's temporary directory; no existing server is started or stopped.
"""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(args, env):
    result = subprocess.run(args, cwd=ROOT, env=env, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"{Path(args[0]).name} fixture failed:\n{result.stderr[-4000:]}\n{result.stdout[-2000:]}")
    return result.stdout


def main():
    for tool in ('initdb', 'pg_ctl', 'psql', 'node'):
        if not shutil.which(tool):
            raise SystemExit(f'Required disposable fixture tool is missing: {tool}')
    with tempfile.TemporaryDirectory(prefix='pandapay-remaining-pg-', dir='/private/tmp' if Path('/private/tmp').exists() else '/tmp') as temporary:
        work = Path(temporary)
        # Pass only basic executable/runtime settings and synthetic test values.
        env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR', 'SYSTEMROOT') if key in os.environ}
        env.update(NODE_ENV='test', DB_SSL='false', LC_ALL='C', LANG='C')
        # Resolve only an installed executable from the sanitized PATH; never
        # inherit ambient keys/URLs while enabling the owned age/PG fixture.
        age_binary=shutil.which('age',path=env.get('PATH'))
        if age_binary: env['LIFECYCLE_JOURNAL_AGE_TEST_BIN']=age_binary
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        cluster = work / 'cluster'
        started = False
        try:
            run(['initdb', '-D', str(cluster), '-A', 'trust', '--no-locale', '--encoding=UTF8', '-U', 'remaining_test'], env)
            try:
                run(['pg_ctl', '-D', str(cluster), '-l', str(work / 'postgres.log'), '-o', f'-p {port} -h 127.0.0.1 -k {work}', 'start'], env)
            except RuntimeError as error:
                log = work / 'postgres.log'
                raise RuntimeError(f'{error}\n{log.read_text()[-4000:] if log.exists() else "No fixture server log"}') from error
            started = True
            base = f'postgresql://remaining_test:synthetic-fixture-password@127.0.0.1:{port}'
            print(run(['psql', base + '/postgres', '-X', '-Atc', 'SHOW server_version'], env).strip())
            for database in ('lounge_usage_test', 'auth_runtime_permissions_test', 'partner_conversion_test', 'backup_status_test', 'auth_google_identity_test', 'auth_admin_capability_test', 'imap_worker_test', 'auth_retention_test', 'console_browser_test', 'account_lifecycle_test', 'auth_account_lifecycle_test', 'runtime_privileges_test', 'data_cleanup_review_test', 'runtime_privilege_repair_test', 'maintenance_test'):
                run(['psql', base + '/postgres', '-X', '-v', 'ON_ERROR_STOP=1', '-c', f'CREATE DATABASE {database}'], env)
            print(run(['node', 'api/test/lounge_usage_postgres.js'], dict(env, LOUNGE_USAGE_TEST_URL=base + '/lounge_usage_test')).strip())
            print(run(['node', 'auth/test/auth_runtime_permissions_postgres.js'], dict(env, AUTH_RUNTIME_PERMISSION_TEST_URL=base + '/auth_runtime_permissions_test')).strip())
            print(run(['node', 'api/test/partner_conversion_postgres.js'], dict(env, PARTNER_CONVERSION_TEST_URL=base + '/partner_conversion_test')).strip())
            print(run(['node', 'api/test/backup_status_postgres.js'], dict(env, BACKUP_STATUS_TEST_URL=base + '/backup_status_test')).strip())
            print(run(['node', 'auth/test/google_identity_postgres.js'], dict(env, AUTH_GOOGLE_IDENTITY_TEST_URL=base + '/auth_google_identity_test')).strip())
            print(run(['node', 'auth/test/admin_capability_postgres.js'], dict(env, AUTH_ADMIN_CAPABILITY_TEST_URL=base + '/auth_admin_capability_test')).strip())
            print(run(['node', 'api/test/imap_worker_postgres.js'], dict(env, IMAP_WORKER_TEST_URL=base + '/imap_worker_test')).strip())
            print(run(['node','auth/test/retention_postgres.js'],dict(env,AUTH_RETENTION_TEST_URL=base+'/auth_retention_test')).strip())
            print(run(['node','auth/test/console_browser_postgres.js'],dict(env,CONSOLE_BROWSER_TEST_URL=base+'/console_browser_test')).strip())
            print(run(['node','api/test/account_lifecycle_postgres.js'],dict(env,ACCOUNT_LIFECYCLE_TEST_URL=base+'/account_lifecycle_test',AUTH_ACCOUNT_LIFECYCLE_TEST_URL=base+'/auth_account_lifecycle_test')).strip())
            print(run(['node','db/tests/runtime_privileges_postgres.js'],dict(env,RUNTIME_PRIVILEGES_TEST_URL=base+'/runtime_privileges_test')).strip())
            print(run(['node','db/tests/runtime_privilege_repair_postgres.js'],dict(env,RUNTIME_PRIVILEGE_REPAIR_TEST_URL=base+'/runtime_privilege_repair_test')).strip())
            print(run(['node','api/test/maintenance_postgres.js'],dict(env,MAINTENANCE_TEST_URL=base+'/maintenance_test')).strip())
            print(run(['node','db/tests/data_cleanup_review_postgres.js'],dict(env,DATA_CLEANUP_REVIEW_TEST_URL=base+'/data_cleanup_review_test')).strip())
        finally:
            if started:
                run(['pg_ctl', '-D', str(cluster), '-m', 'immediate', 'stop'], env)


if __name__ == '__main__':
    main()
