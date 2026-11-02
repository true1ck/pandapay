#!/usr/bin/env python3
"""Verify the real app entry point and exported production SMS action schema."""
import json
import plistlib
import subprocess
import sys
from pathlib import Path

bundle = Path(sys.argv[1])
info = plistlib.loads((bundle / 'Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'app.pandapay.pandapay', 'Wrong app bundle'
assert 'processing' in info.get('UIBackgroundModes', []), 'SMS background processing mode missing'
assert {'app.pandapay.pandapay.sms-processing', 'app.pandapay.pandapay.sms-import'} <= set(info.get('BGTaskSchedulerPermittedIdentifiers', [])), 'SMS background task identifiers missing'
binary = (bundle / 'Frameworks/App.framework/App').read_bytes()
def has_compiled_text(text):
    # Dart stores strings containing arrows/other non-Latin characters as
    # UTF-16. Check both representations, including substrings of help copy.
    return text.encode('utf-8') in binary or text.encode('utf-16-le') in binary

for marker in [b'SMS on iPhone', b'Your spending, up to date.', b'Live bank alerts',
               b'History permissions', b'Allow Sharing Large Amounts of Data', b'Start import',
               b'Capture PandaPay History SMS', b'End reached PandaPay',
               b'Start new import', b'Replaces the current check. Saved messages stay.',
               b'Sender unavailable', b'Sender wasn\xe2\x80\x99t provided. Check this message before adding it.',
               b'sender received', b'sender missing', b'No messages received yet',
               b'Last completed import', b'Capture received by build',
               b'Last sender input:', b'Message sender supplied without an address',
               b'Handoff: Returning to the existing Shortcuts run',
               b'Handoff: Returning to PandaPay during import']:
    assert has_compiled_text(marker.decode()), f'Production SMS setup UI missing from compiled app: {marker.decode()}'
assert not has_compiled_text('Flutter Demo Home Page'), 'Flutter demo was compiled'
for marker in ['iosSmsBackgroundMain', 'Retry processing', 'Processing saved messages', 'Processing needs attention']:
    assert has_compiled_text(marker), f'Import recovery missing from compiled app: {marker}'
assert not has_compiled_text('PandaPay History Probe'), 'Probe entry point was compiled'
for marker in [b'Face ID', b'Touch ID']:
    assert has_compiled_text(marker.decode()), 'Device-aware biometric labels missing from compiled app'
assert not has_compiled_text('Your biometric data stays with Android.'), 'Android-only enrollment copy remains in the iOS app'
actions = json.loads((bundle / 'Metadata.appintents/extract.actionsdata').read_bytes())['actions']
expected = {
    'CapturePandaPayMessageIntent', 'BeginPandaPaySmsWindowIntent',
    'PandaPaySmsWindowStartIntent', 'PandaPaySmsWindowEndIntent',
    'CapturePandaPayWindowMessageIntent', 'FinishPandaPaySmsWindowIntent',
    'PreparePandaPaySmsCatchupIntent',
    'FinishPandaPayHistoryImportIntent',
    'CapturePandaPayHistoryMessageIntent', 'CapturePandaPayHistoryTextMessageIntent',
}
assert expected <= actions.keys(), 'Production actions missing'
assert not any('Prototype' in name or 'DeviceFinancial' in name for name in actions), 'Probe actions leaked into main app'
for name in expected:
    foreground = name == 'FinishPandaPayHistoryImportIntent'
    assert actions[name]['openAppWhenRun'] is foreground, f'{name} has the wrong foreground mode'
    for parameter in actions[name]['parameters']:
        # Apple's extractor encodes InputConnectionBehavior.never as 1.
        # Inspect the compiled schema, not only the Swift source: a blank
        # optional sender must not inherit the preceding whole Message result.
        expected_connection = 1
        assert parameter['inputConnectionBehavior'] == expected_connection, (
            f"{name}.{parameter['name']} has the wrong input-connection mode"
        )
for name in ['CapturePandaPayMessageIntent', 'CapturePandaPayWindowMessageIntent', 'CapturePandaPayHistoryMessageIntent', 'CapturePandaPayHistoryTextMessageIntent']:
    parameters = {p['name']: p for p in actions[name]['parameters']}
    sender = parameters['sender']
    assert sender['isOptional'] and parameters['body']['isOptional']
    assert sender['valueType'] == parameters['body']['valueType']
    assert 'primitive' in sender['valueType'] and not sender['typeSpecificMetadata']
    assert parameters['receivedAt']['isOptional']
    assert parameters['receivedAt']['valueType'] == {'primitive': {'wrapper': {'typeIdentifier': 8}}}, 'Saved Date input type changed'
live = {p['name']: p for p in actions['CapturePandaPayMessageIntent']['parameters']}
assert 'estimated' in json.dumps(live['dateSource']['typeSpecificMetadata'])
interactive_finish = actions['FinishPandaPayHistoryImportIntent']
quiet_finish = actions['FinishPandaPaySmsWindowIntent']
def input_contract(action):
    fields = ['title', 'valueType', 'typeSpecificMetadata', 'isOptional', 'inputConnectionBehavior']
    return {p['name']: {key: p[key] for key in fields} for p in action['parameters']}
assert input_contract(interactive_finish) == input_contract(quiet_finish), 'Interactive and background finishes have different input contracts'
assert interactive_finish['outputType'] == quiet_finish['outputType'], 'Finish result types diverged'
interactive_capture = actions['CapturePandaPayHistoryMessageIntent']
# The iOS 26 extractor encodes background + dynamic foreground as 9. The
# action must start in background; only the admitted app session can opt in.
assert interactive_capture.get('supportedModes') == 9, 'History Capture must support conditional foreground continuation'
text_capture = actions['CapturePandaPayHistoryTextMessageIntent']
assert text_capture.get('supportedModes') == 9, 'Text history must preserve admitted foreground return'
text_parameters = {p['name']: p for p in text_capture['parameters']}
assert set(text_parameters) == {'request', 'body', 'sender', 'receivedAt'}, 'Text-only Capture must have no Person/contact input'
assert text_capture['title']['key'] == 'Capture PandaPay History SMS as Text'
assert text_capture['outputType'] == interactive_capture['outputType']
assert has_compiled_text('payment_method'), 'Explicit UPI source evidence is missing'
quiet_capture = actions['CapturePandaPayWindowMessageIntent']
history_parameters = {p['name']: p for p in interactive_capture['parameters']}
assert set(history_parameters) == {'request', 'body', 'sender', 'senderPerson', 'receivedAt'}, 'History Capture must retain the four saved fields plus the optional direct Person input'
assert history_parameters['body']['isOptional'], 'History body must preserve optional text input compatibility'
assert history_parameters['sender']['isOptional'] and history_parameters['receivedAt']['isOptional']
assert history_parameters['sender']['valueType'] == history_parameters['body']['valueType'], 'Saved history sender text must not change to a Person'
assert not history_parameters['sender']['typeSpecificMetadata'], 'History sender must not trigger contact/phone/email conversion'
# The old String parameter stays compatible; the new Person is additive.
# Inspect the compiled Person contract after extraction as well as source.
person = history_parameters['senderPerson']
assert person['isOptional'], 'New Person input must remain optional for saved recipes'
assert person['valueType'] == {'intents': {'wrapper': {'typeIdentifier': 3}}}, 'Direct Sender must remain an IntentPerson, not a text coercion'
assert person['typeSpecificMetadata'] == ['LNValueTypeMetadataKeyPersonParameterMode', {'string': {'wrapper': 'emailOrPhone'}}], 'Direct Sender must use the probe-compatible person mode'
assert person['title']['key'] == 'Sender from Message'
assert b'SmsSenderInput' in (bundle / 'Runner').read_bytes(), 'Direct sender extraction missing from native app'
assert history_parameters['body']['valueType'] == history_parameters['request']['valueType']
assert interactive_capture['outputType'] == quiet_capture['outputType'], 'Capture result types diverged'
for key in ['NSCameraUsageDescription', 'NSMicrophoneUsageDescription', 'NSLocationWhenInUseUsageDescription', 'NSFaceIDUsageDescription']:
    assert info.get(key), f'Missing permission explanation: {key}'
native_symbols = subprocess.check_output(['xcrun', 'nm', '-gU', str(bundle / 'Runner')], text=True)
for strategy in ['AudioVideoPermissionStrategy', 'NotificationPermissionStrategy', 'LocationPermissionStrategy']:
    assert strategy in native_symbols, f'Native permission handler was compiled out: {strategy}'
print(f"PASS: main PandaPay {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), "
      'production UI, conditional foreground History Capture plus interactive history finish, separate text-only history sender plus compatible legacy Person, native message receipts, estimated-date default, '
      'native permission handlers, probe/demo absent')
