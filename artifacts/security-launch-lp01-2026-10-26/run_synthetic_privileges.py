#!/usr/bin/env python3
"""Own and remove a synthetic local cluster; never read saved database URLs."""
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
    with tempfile.TemporaryDirectory(prefix='pandapay-launch-privileges-') as temporary:
        work = Path(temporary)
        env = {name: os.environ[name] for name in ('PATH', 'HOME', 'SYSTEMROOT') if name in os.environ}
        env.update(TMPDIR=str(work), LC_ALL='C', LANG='C', NODE_ENV='test')
        bins = {name: shutil.which(name, path=env.get('PATH')) for name in ('initdb', 'pg_ctl', 'psql', 'createdb', 'node')}
        if not all(bins.values()):
            raise RuntimeError('Installed PostgreSQL and Node are required')

        def run(command, label):
            result = subprocess.run(command, cwd=work, env=env, capture_output=True, text=True, timeout=120)
            (OUT / (label + '.log')).write_text(result.stdout + result.stderr)
            if result.returncode:
                raise RuntimeError('Synthetic fixture failed: ' + label)
            return result.stdout

        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        data = work / 'data'
        started = False
        try:
            run([bins['initdb'], '-D', str(data), '-A', 'trust', '--no-locale', '--encoding=UTF8', '-U', 'launch_fixture'], 'pg-init')
            run([bins['pg_ctl'], '-D', str(data), '-l', str(work / 'server.log'), '-o', f'-p {port} -h 127.0.0.1 -k {work}', 'start'], 'pg-start')
            started = True
            base = f'postgresql://launch_fixture@127.0.0.1:{port}'
            version = run([bins['psql'], base + '/postgres', '-X', '-At', '-c', 'SHOW server_version'], 'pg-version').strip()
            run([bins['createdb'], '--maintenance-db', base + '/postgres', 'runtime_privileges_test'], 'pg-create-fixture')
            env['RUNTIME_PRIVILEGES_TEST_URL'] = base + '/runtime_privileges_test'
            result = run([bins['node'], str(ROOT / 'db/tests/runtime_privileges_postgres.js')], 'privilege-fixture')
            summary = {'result': 'passed', 'postgres_version': version, 'data_scope': 'synthetic-owned-loopback-cluster',
                'real_non_owner_login': True, 'dangerous_exposure_role_refused': True, 'catalog_only': True,
                'data_and_grants_preserved_by_audit': True, 'live_credentials_or_customer_data_read': False,
                'checks': result.strip()}
        finally:
            if started:
                run([bins['pg_ctl'], '-D', str(data), '-m', 'immediate', 'stop'], 'pg-stop')
        summary['owned_cluster_removed'] = True
    (OUT / 'postgres-results.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
