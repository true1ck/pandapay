"""Synthetic public AppIntents sender-conversion tests; no device or customer data."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='pandapay-probe-sender-resolver-') as directory:
    target = Path(directory)
    (target / 'main.swift').write_bytes((root / 'test/native/probe_sender_resolver_test.swift').read_bytes())
    subprocess.run([
        'xcrun', 'swiftc',
        str(root / 'ios/Runner/ProbeSenderTextResolver.swift'),
        str(root / 'ios/Runner/SmsSecurityPolicy.swift'),
        str(root / 'ios/Runner/DeviceHistoryRange.swift'),
        str(root / 'ios/Runner/DeviceLiveMessageInbox.swift'),
        str(target / 'main.swift'), '-o', str(target / 'test'),
    ], check=True)
    subprocess.run([str(target / 'test')], check=True)
