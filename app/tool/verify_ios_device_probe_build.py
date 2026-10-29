#!/usr/bin/env python3
"""Inspect the built probe and its exported Shortcuts schema before install."""
import json
import plistlib
import sys
from pathlib import Path

bundle = Path(sys.argv[1])
info = plistlib.loads((bundle / 'Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'app.pandapay.iosimportprobe', 'Wrong app bundle'
binary = (bundle / 'Frameworks/App.framework/App').read_bytes()
for marker in [b'Live incoming SMS', b'Input received from Shortcut']:
    assert marker in binary, 'Probe UI is missing from the compiled Dart app'
assert b'Flutter Demo Home Page' not in binary, 'Flutter demo was compiled'
actions = json.loads((bundle / 'Metadata.appintents/extract.actionsdata').read_bytes())['actions']
action = actions['InspectDeviceFinancialMessagePersonIntent']
assert action['title']['key'] == 'Inspect Financial Message With Sender'
assert action['openAppWhenRun'] is False, 'Action must not open the app'
parameters = {parameter['name']: parameter for parameter in action['parameters']}
assert set(parameters) == {'body', 'senderPerson', 'receivedAt'}, 'Saved parameter IDs changed'
sender = parameters['senderPerson']
assert sender['isOptional'], 'Missing sender must not require a prompt'
assert sender['title']['key'] == 'Sender (text)'
assert sender['valueType'] == parameters['body']['valueType'], 'Sender must have the same text type as body'
assert 'primitive' in sender['valueType'], 'Sender must not require a Person conversion'
assert not sender['typeSpecificMetadata'], 'Sender must not require contact/phone/email resolution'
print('PASS: isolated probe UI compiled, demo absent, saved action IDs preserved, optional text sender exported, no person conversion')
