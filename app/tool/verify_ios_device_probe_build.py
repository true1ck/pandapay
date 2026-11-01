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
def has_compiled_text(value):
    # Dart one-byte strings use Latin-1, including the middle dot in the
    # version label. Other strings may use UTF-16 or UTF-8 representations.
    for encoding in ['utf-8', 'utf-16-le', 'latin-1']:
        try:
            if value.encode(encoding) in binary:
                return True
        except UnicodeEncodeError:
            pass
    return False

for marker in ['Live incoming SMS', 'Input received from Shortcut', 'Sender input vs inference', 'Without sender inference', 'Body-only inference comparison', 'PandaPay Sender Probe', 'Check today’s history', 'Latest range receiver', 'Sender received:', 'saved_without_sender', 'Export diagnostics', 'pandapay.sender_probe_diagnostics', 'capture_journal', 'Extracted message facts', 'Transaction extracted; sender unavailable', 'body_evidence']:
    assert has_compiled_text(marker), 'Probe UI is missing from the compiled Dart app'
assert b'Flutter Demo Home Page' not in binary, 'Flutter demo was compiled'
label = f"PandaPay Sender Probe · {info['CFBundleVersion']}"
assert has_compiled_text(label), 'Probe screen/build version mismatch'
assert b'PandaPayProbeExports' in (bundle / 'Runner').read_bytes(), 'Native JSON file writer is missing'
assert b'shareDiagnostics' in (bundle / 'Runner').read_bytes(), 'Native diagnostic share handler is missing'
assert b'readDiagnosticReplay' in (bundle / 'Runner').read_bytes(), 'Native local replay handler is missing'
assert b'SenderProbeReplaySummary.json' in (bundle / 'Runner').read_bytes(), 'Aggregate replay receipt is missing'
assert b'ProbeSenderTextResolver' in (bundle / 'Runner').read_bytes(), 'Explicit sender resolver is missing from the native binary'
assert b'pandapay.sender.v1:' in (bundle / 'Runner').read_bytes(), 'Typed sender conversion envelope is missing'
assert b'direct_intent_person_v1' in (bundle / 'Runner').read_bytes(), 'Direct typed Person acquisition is missing'
assert b'PANDAPAY SENDER CHECK' in (bundle / 'Runner').read_bytes(), 'Native launch registration for sender-test recipe is missing'
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
history = {p['name']: p for p in actions['CaptureDeviceHistoryRangeMessageIntent']['parameters']}
assert set(history) == {'request', 'body', 'senderPerson', 'senderText', 'senderType', 'receivedAt'}
assert history['senderPerson']['isOptional']
assert history['senderPerson']['valueType'] == {'intents': {'wrapper': {'typeIdentifier': 3}}}
assert history['senderText']['isOptional'] and history['senderText']['valueType'] == history['body']['valueType']
assert history['senderText']['inputConnectionBehavior'] == 1, 'New text diagnostic must not inherit a whole Message'
assert history['senderType']['isOptional'] and history['senderType']['valueType'] == history['body']['valueType']
assert history['senderType']['inputConnectionBehavior'] == 1
text_action = actions['CaptureDeviceHistoryRangeTextMessageIntent']
assert text_action['title']['key'] == 'Import PandaPay Range Message as Text'
assert text_action['openAppWhenRun'] is False
text = {p['name']: p for p in text_action['parameters']}
assert set(text) == {'request', 'body', 'senderText', 'senderType', 'receivedAt'}, 'Text-only diagnostic must not expose a Person input'
assert text['senderText']['isOptional'] and text['senderText']['valueType'] == text['body']['valueType']
assert 'primitive' in text['senderText']['valueType'] and not text['senderText']['typeSpecificMetadata']
assert text['senderType']['isOptional'] and text['senderType']['valueType'] == text['body']['valueType']
assert text['receivedAt']['isOptional'] and text['receivedAt']['valueType'] == history['receivedAt']['valueType']
assert all(p['inputConnectionBehavior'] == 1 for p in text.values())
contract_action = actions['ProbeMainAppHistoryInputIntent']
assert contract_action['title']['key'] == 'Probe Main-App History Input'
assert contract_action['openAppWhenRun'] is False
contract = {p['name']: p for p in contract_action['parameters']}
assert set(contract) == {'request', 'body', 'sender', 'receivedAt'}
assert all(p['inputConnectionBehavior'] == 1 for p in contract.values())
assert contract['sender']['isOptional'] and contract['body']['isOptional']
assert contract['sender']['valueType'] == text['senderText']['valueType']
assert not contract['sender']['typeSpecificMetadata']
direct_action = actions['ProbeDirectMessagePersonIntent']
assert direct_action['title']['key'] == 'Probe Message Sender Person'
assert direct_action['openAppWhenRun'] is False
direct = {p['name']: p for p in direct_action['parameters']}
assert set(direct) == {'request', 'body', 'sender', 'receivedAt'}, 'Direct Person probe field IDs changed'
assert all(p['inputConnectionBehavior'] == 1 for p in direct.values()), 'Direct fields must use explicitly selected inputs'
assert direct['sender']['isOptional'], 'Absent Person input must not prompt'
assert direct['body']['isOptional'] and direct['receivedAt']['isOptional']
assert not direct['request']['isOptional']
assert direct['sender']['valueType'] == {'intents': {'wrapper': {'typeIdentifier': 3}}}, 'Direct sender must be Person, not String'
assert direct['sender'].get('resolvableInputTypes', []) == [], 'Direct Person field must not use a String resolver'
assert 'emailOrPhone' not in json.dumps(direct['sender']['typeSpecificMetadata']), 'Direct Person must not narrow to email or phone'
for name in ['request', 'body', 'receivedAt']:
    assert direct[name]['valueType'] == contract[name]['valueType'], f'Direct Person probe changed {name} type'
if len(sys.argv) > 2:
    main_bundle = Path(sys.argv[2])
    main_actions = json.loads((main_bundle / 'Metadata.appintents/extract.actionsdata').read_bytes())['actions']
    main = {p['name']: p for p in main_actions['CapturePandaPayHistoryTextMessageIntent']['parameters']}
    for name in contract:
        for key in ['title', 'valueType', 'typeSpecificMetadata', 'isOptional', 'inputConnectionBehavior']:
            assert contract[name][key] == main[name][key], f'Probe/main input difference: {name}.{key}'
assert not any(name.startswith('CapturePandaPay') for name in actions), 'Main-app receivers leaked into the isolated probe'
print(f"PASS: probe {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), sender comparisons, demo absent, saved fields preserved, String converter retained and separate direct Person receiver verified; iPhone acquisition requires user verification")
