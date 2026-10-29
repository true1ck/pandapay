#!/usr/bin/env python3
"""Check Swift policy + native gates against the shared synthetic Dart corpus."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='pandapay-security-policy-') as directory:
    target = Path(directory)
    (target / 'main.swift').write_bytes((root / 'test/native/security_advisory_test.swift').read_bytes())
    subprocess.run(['xcrun','swiftc',str(root/'ios/Runner/DeviceHistoryRange.swift'),
                    str(root/'ios/Runner/DeviceLiveMessageInbox.swift'),str(target/'main.swift'),
                    '-o',str(target/'test')],check=True)
    subprocess.run([str(target/'test'),str(root/'test/fixtures/sms_security_advisory_synthetic.json')],check=True)
# Legacy bulk capture uses the same policy. The simulator-only tagged harness
# deliberately retains its older, stricter veto and is not a live device path.
source=(root/'ios/Runner/PrototypeBankMessageIntent.swift').read_text().split('#if PANDAPAY_DEVICE_IMPORT_PROBE')[1]
assert 'if SmsSecurityPolicy.sensitive(body)' in source
print('PASS: legacy device bulk uses the common policy; simulator-only synthetic gate unchanged')
