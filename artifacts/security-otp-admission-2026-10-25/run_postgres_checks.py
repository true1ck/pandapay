#!/usr/bin/env python3
"""Owned disposable loopback PG only; no .env or existing cluster/URLs."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent


def main():
    env = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'SYSTEMROOT') if k in os.environ}
    env.update(NODE_ENV='test', DB_SSL='false', LC_ALL='C', LANG='C', DOTENV_CONFIG_QUIET='true')
    pg = Path('/opt/homebrew/opt/postgresql@18/bin')
    if pg.exists():
        env['PATH'] = str(pg) + os.pathsep + env.get('PATH', '')
    binaries = {name: shutil.which(name, path=env.get('PATH')) for name in ('node', 'initdb', 'pg_ctl', 'psql')}
    if not all(binaries.values()):
        raise RuntimeError('Installed native PostgreSQL and Node are required')
    logs = []
    with tempfile.TemporaryDirectory(prefix='pandapay-otp-pg-', dir='/private/tmp') as work:
        folder = Path(work)

        def run(args, extra=None):
            result = subprocess.run(args, cwd=work, env=dict(env, **(extra or {})), capture_output=True, text=True, timeout=60)
            logs.append(result.stdout + result.stderr)
            if result.returncode:
                raise RuntimeError('Disposable PostgreSQL check failed; inspect protected local log')
            return result.stdout

        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        cluster = folder / 'cluster'
        started = False
        try:
            run([binaries['initdb'], '-D', str(cluster), '-A', 'trust', '--no-locale', '--encoding=UTF8', '-U', 'otp_fixture'])
            run([binaries['pg_ctl'], '-D', str(cluster), '-l', str(folder / 'server.log'), '-o', f'-p {port} -h 127.0.0.1 -k {work}', 'start'])
            started = True
            base = f'postgresql://otp_fixture:synthetic@127.0.0.1:{port}'
            version = run([binaries['psql'], base + '/postgres', '-X', '-Atc', 'SHOW server_version']).strip()
            for database in ['otp_purpose_test', 'auth_abuse_test']:
                run([binaries['psql'], base + '/postgres', '-X', '-v', 'ON_ERROR_STOP=1', '-c', f'CREATE DATABASE {database}'])
            run([binaries['node'], str(ROOT / 'auth/test/otp_purpose_postgres.js')], {'OTP_PURPOSE_TEST_DATABASE_URL': base + '/otp_purpose_test'})
            run([binaries['node'], str(ROOT / 'auth/test/auth_abuse_store_postgres.js')], {'AUTH_ABUSE_TEST_DATABASE_URL': base + '/auth_abuse_test'})
            (OUT / 'postgres-summary.json').write_text(json.dumps({'result': 'passed', 'version': version,
                'scope': 'synthetic-owned-loopback-cluster', 'fixtures': ['otp_purpose_postgres', 'auth_abuse_store_postgres'],
                'actual_provider_or_customer_data': False}, indent=2) + '\n')
        finally:
            if started:
                run([binaries['pg_ctl'], '-D', str(cluster), '-m', 'immediate', 'stop'])
            (OUT / 'postgres-checks.log').write_text('\n'.join(logs))
    print('PASS: disposable PostgreSQL OTP compatibility/capacity and shared abuse-store regressions')


if __name__ == '__main__':
    main()
