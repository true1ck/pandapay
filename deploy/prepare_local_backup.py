"""Provision an explicitly approved local backup using a public recipient only.

Run over the existing deployment SSH channel. The private identity stays on
the operator computer. Existing recipients and backup mode are never rotated.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def configure(root, recipients, recipient):
    if not re.fullmatch(r'age1[a-z0-9]{50,80}', recipient):
        raise ValueError('A valid public age recipient is required')
    env = root / '.env'
    lines = env.read_text().splitlines()
    wanted = {'BACKUP_MODE': 'local', 'BACKUP_AGE_RECIPIENTS_FILE': str(recipients)}
    for key, value in wanted.items():
        existing = [line.split('=', 1)[1].strip().strip('\"\x27')
                    for line in lines if line.startswith(key + '=')]
        if len(existing) > 1 or (existing and existing[0] not in ('', value)):
            raise ValueError(f'Refusing to replace existing {key} configuration')
    if recipients.exists() and recipients.read_text().strip() != recipient:
        raise ValueError('Existing backup recipient differs; preserve its recovery key')
    recipients.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not recipients.exists():
        descriptor = os.open(recipients, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as output:
            output.write(recipient + '\n')
    updated = [line for line in lines if not any(line.startswith(key + '=') for key in wanted)]
    updated.extend(f'{key}={value}' for key, value in wanted.items())
    descriptor, temporary = tempfile.mkstemp(prefix='.env.backup-mode-', dir=root)
    try:
        with os.fdopen(descriptor, 'w') as output:
            output.write('\n'.join(updated) + '\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, env)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == '__main__':
    version = subprocess.check_output(['docker', 'compose', 'version', '--short'], text=True)
    numbers = re.search(r'(\d+)\.(\d+)\.(\d+)', version)
    if not numbers or tuple(map(int, numbers.groups())) < (2, 24, 4):
        raise SystemExit('Docker Compose >=2.24.4 is required before configuring local backups')
    configure(Path('/home/ubuntu/apps/pandapay'),
              Path('/home/ubuntu/.config/pandapay-backup/public-recipients.txt'), sys.argv[1])
    print('Local encrypted backup configured; private identity remains off-server. Services unchanged.')
