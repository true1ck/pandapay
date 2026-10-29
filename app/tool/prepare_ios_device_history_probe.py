"""Prepare an isolated Flutter wrapper from an existing `flutter create` app.

Copies the current parser dependency closure without changing its behavior.
No customer messages are read or copied by this developer utility.
"""
import json
import plistlib
import re
import shutil
import sys
from pathlib import Path

source = Path(__file__).resolve().parents[1]
target = Path(sys.argv[1]).resolve()
if not (target / 'ios/Runner.xcodeproj/project.pbxproj').is_file():
    raise SystemExit('First create a disposable Flutter iOS project at the target.')

root = source / 'lib'
pending = [root / 'main_ios_history_device_probe.dart']
copied = set()
packages = set()
while pending:
    file = pending.pop().resolve()
    if file in copied:
        continue
    if not file.is_relative_to(root):
        raise SystemExit(f'Unexpected source outside lib: {file}')
    copied.add(file)
    text = file.read_text()
    for imported in re.findall(r"(?:import|export)\s+['\"]([^'\"]+)['\"]", text):
        if imported.startswith('dart:'):
            continue
        if imported.startswith('package:pandapay/'):
            pending.append(root / imported.removeprefix('package:pandapay/'))
        elif imported.startswith('package:'):
            packages.add(imported.split('/')[0].removeprefix('package:'))
        else:
            pending.append(file.parent / imported)
    destination = target / 'lib' / file.relative_to(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text)

(target / 'pubspec.yaml').write_text(f'''name: pandapay
publish_to: none
version: 1.0.0+1
environment:
  sdk: ^3.12.2
dependencies:
  flutter:
    sdk: flutter
  pandapay_domain:
    path: {source.parent / 'packages/pandapay_domain'}
  crypto: ^3.0.7
  http: ^1.2.2
  google_fonts: ^6.2.1
  path: ^1.9.0
  path_provider: ^2.1.6
  shared_preferences: ^2.3.3
  sqlite3: ^2.9.4
  sqlite3_flutter_libs: ^0.5.42
  uuid: ^4.6.0
flutter:
  uses-material-design: true
''')
shutil.copyfile(source / 'ios/Runner/PrototypeBankMessageIntent.swift',
                target / 'ios/Runner/PrototypeBankMessageIntent.swift')
(target / 'ios/Runner/AppDelegate.swift').write_text('''import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(_ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    DeviceHistoryProbeBridge.register(messenger: engineBridge.applicationRegistrar.messenger())
  }
}
''')

project = target / 'ios/Runner.xcodeproj/project.pbxproj'
text = project.read_text()
# Flutter's current template uses ordinary PBX file references.
# Isolate this wrapper even when created with Flutter's default app identifier.
text = re.sub(r'PRODUCT_BUNDLE_IDENTIFIER = [^;]+;', lambda match:
    'PRODUCT_BUNDLE_IDENTIFIER = app.pandapay.iosimportprobe.RunnerTests;'
    if 'RunnerTests' in match.group(0) else
    'PRODUCT_BUNDLE_IDENTIFIER = app.pandapay.iosimportprobe;', text)
if 'PrototypeBankMessageIntent.swift' not in text:
    text = text.replace('/* Begin PBXBuildFile section */', '''/* Begin PBXBuildFile section */
        6A170510A000000000000002 /* PrototypeBankMessageIntent.swift in Sources */ = {isa = PBXBuildFile; fileRef = 6A170510A000000000000001 /* PrototypeBankMessageIntent.swift */; };''')
    text = text.replace('/* Begin PBXFileReference section */', '''/* Begin PBXFileReference section */
        6A170510A000000000000001 /* PrototypeBankMessageIntent.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PrototypeBankMessageIntent.swift; sourceTree = "<group>"; };''')
    text = re.sub(r'(\s+\w+ /\* AppDelegate.swift \*/,)',
        r'\1\n                6A170510A000000000000001 /* PrototypeBankMessageIntent.swift */,', text)
    text = re.sub(r'(\s+\w+ /\* AppDelegate.swift in Sources \*/,)',
        r'\1\n                6A170510A000000000000002 /* PrototypeBankMessageIntent.swift in Sources */,', text)
# Add the separately testable range protocol source.
shutil.copyfile(source / 'ios/Runner/DeviceHistoryRange.swift', target / 'ios/Runner/DeviceHistoryRange.swift')
if 'DeviceHistoryRange.swift in Sources' not in text:
    text = text.replace('/* Begin PBXBuildFile section */', '''/* Begin PBXBuildFile section */
        6A170510A000000000000004 /* DeviceHistoryRange.swift in Sources */ = {isa = PBXBuildFile; fileRef = 6A170510A000000000000003 /* DeviceHistoryRange.swift */; };''')
    text = text.replace('/* Begin PBXFileReference section */', '''/* Begin PBXFileReference section */
        6A170510A000000000000003 /* DeviceHistoryRange.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeviceHistoryRange.swift; sourceTree = "<group>"; };''')
    text = re.sub(r'(\s+\w+ /\* AppDelegate.swift \*/,)', r'\1\n                6A170510A000000000000003 /* DeviceHistoryRange.swift */,', text)
    text = re.sub(r'(\s+\w+ /\* AppDelegate.swift in Sources \*/,)', r'\1\n                6A170510A000000000000004 /* DeviceHistoryRange.swift in Sources */,', text)
# Live receiver is separate from range/bulk traffic and testable on macOS.
shutil.copyfile(source / 'ios/Runner/DeviceLiveMessageInbox.swift', target / 'ios/Runner/DeviceLiveMessageInbox.swift')
if 'DeviceLiveMessageInbox.swift in Sources' not in text:
    text = text.replace('/* Begin PBXBuildFile section */', '''/* Begin PBXBuildFile section */
        6A170510A000000000000006 /* DeviceLiveMessageInbox.swift in Sources */ = {isa = PBXBuildFile; fileRef = 6A170510A000000000000005 /* DeviceLiveMessageInbox.swift */; };''')
    text = text.replace('/* Begin PBXFileReference section */', '''/* Begin PBXFileReference section */
        6A170510A000000000000005 /* DeviceLiveMessageInbox.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeviceLiveMessageInbox.swift; sourceTree = "<group>"; };''')
    text = re.sub(r'(\s+\w+ /\* AppDelegate.swift \*/,)', r'\1\n                6A170510A000000000000005 /* DeviceLiveMessageInbox.swift */,', text)
    text = re.sub(r'(\s+\w+ /\* AppDelegate.swift in Sources \*/,)', r'\1\n                6A170510A000000000000006 /* DeviceLiveMessageInbox.swift in Sources */,', text)
project.write_text(text)

info = target / 'ios/Runner/Info.plist'
data = plistlib.loads(info.read_bytes())
data['CFBundleDisplayName'] = 'PandaPay History Probe'
data['UIApplicationSupportsIndirectInputEvents'] = True
info.write_bytes(plistlib.dumps(data))
profile = target / 'ios/Flutter/Release.xcconfig'
settings = profile.read_text()
if 'PANDAPAY_DEVICE_IMPORT_PROBE' not in settings:
    profile.write_text(settings + '\nSWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) PANDAPAY_DEVICE_IMPORT_PROBE\n')
(target / 'probe-source-manifest.json').write_text(json.dumps({
    'sourceFiles': sorted(str(p.relative_to(source)) for p in copied),
    'packages': sorted(packages),
    'bundleId': 'app.pandapay.iosimportprobe',
    'rawMessageStorage': 'process memory only',
    'nativeFiles': ['ios/Runner/PrototypeBankMessageIntent.swift', 'ios/Runner/DeviceHistoryRange.swift', 'ios/Runner/DeviceLiveMessageInbox.swift'],
    'rangeShortcut': 'PANDAPAY SELECTED RANGE V2',
}, indent=2) + '\n')
print(f'Prepared {len(copied)} current Dart source files in {target}')
