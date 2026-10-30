#!/usr/bin/env python3
"""Run synthetic live-receiver tests without Flutter/iPhone or private SMS."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='pandapay-native-live-') as directory:
    target = Path(directory)
    (target / 'main.swift').write_bytes((root / 'test/native/live_message_test.swift').read_bytes())
    subprocess.run(['xcrun', 'swiftc', str(root / 'ios/Runner/SmsSecurityPolicy.swift'), str(root / 'ios/Runner/DeviceHistoryRange.swift'),
                    str(root / 'ios/Runner/DeviceLiveMessageInbox.swift'), str(target / 'main.swift'),
                    '-o', str(target / 'test')], check=True)
    subprocess.run([str(target / 'test')], check=True)
# Both existing action entrypoints must use live instrumentation; bulk/range
# must not call it. This complements the Foundation tests, not a device test.
source = (root / 'ios/Runner/PrototypeBankMessageIntent.swift').read_text()
assert source.count('DeviceLiveMessageInbox.shared.capture(') == 2
for name in ['InspectDeviceFinancialMessageIntent', 'InspectDeviceFinancialMessagePersonIntent']:
    action = source.split('struct ' + name + ': AppIntent {')[1].split('\n@available')[0]
    assert 'DeviceLiveMessageInbox.shared.capture(' in action
    assert '@Parameter(title: "Message body") var body: String?' in action
print('PASS: both existing single-message action bindings instrumented, optional missing body supported')
