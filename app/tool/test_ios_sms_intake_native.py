#!/usr/bin/env python3
"""Synthetic production handoff tests; no device, account, SMS or network needed."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='pandapay-sms-intake-') as directory:
    target = Path(directory)
    (target / 'main.swift').write_bytes((root / 'test/native/incoming_sms_spool_test.swift').read_bytes())
    subprocess.run(['xcrun', 'swiftc', str(root / 'ios/Runner/SmsSecurityPolicy.swift'),
                    str(root / 'ios/Runner/IncomingSmsSpool.swift'), str(root / 'ios/Runner/SmsShortcutLaunch.swift'), str(target / 'main.swift'),
                    '-o', str(target / 'test')], check=True)
    subprocess.run([str(target / 'test')], check=True)
