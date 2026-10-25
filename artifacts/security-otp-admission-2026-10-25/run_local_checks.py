#!/usr/bin/env python3
"""Local tests in empty working directories with a synthetic allowlisted env."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent


def main():
    node = shutil.which('node')
    if not node:
        raise RuntimeError('Installed Node is required')
    env = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'SYSTEMROOT') if k in os.environ}
    env.update(NODE_ENV='test', DATABASE_URL='postgresql://synthetic:synthetic@127.0.0.1:1/unused',
               JWT_ACCESS_SECRET='synthetic-local-access-secret', JWT_REFRESH_SECRET='synthetic-local-refresh-secret',
               PHONE_LOOKUP_HMAC_KEY='synthetic-local-phone-lookup-hmac-32bytes', DOTENV_CONFIG_QUIET='true')
    summary = {'node': subprocess.check_output([node, '--version'], text=True).strip(), 'groups': {}}
    for name, relative in [('auth', 'auth/test'), ('tools', 'db/tests')]:
        files = sorted((ROOT / relative).glob('*.test.js'))
        with tempfile.TemporaryDirectory(prefix='pandapay-otp-check-') as work:
            result = subprocess.run([node, '--test', '--test-reporter=tap', *map(str, files)],
                                    cwd=work, env=env, capture_output=True, text=True, timeout=120)
        log = result.stdout + result.stderr
        (OUT / f'{name}-tests.log').write_text(log)
        counts = {key: int(value) for key, value in re.findall(r'^# (tests|pass|fail|skipped) (\d+)$', log, re.M)}
        summary['groups'][name] = {'exit_code': result.returncode, **counts, 'scope': relative + '/*.test.js'}
        if result.returncode or not counts.get('tests') or counts.get('fail') != 0:
            (OUT / 'test-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            raise RuntimeError(f'{name} tests failed; inspect the saved log')
        print(f'{name}: {counts}', flush=True)
    (OUT / 'test-summary.json').write_text(json.dumps(summary, indent=2) + '\n')


if __name__ == '__main__':
    main()
