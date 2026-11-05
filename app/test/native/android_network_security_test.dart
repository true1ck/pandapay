import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Lane O (security audit LO-06): a release APK must not permit cleartext HTTP to
// anything, including the development loopback hosts. Those hosts are allowed
// by a debug-only resource that replaces the main one in debug builds.
void main() {
  final main = File('android/app/src/main/res/xml/network_security_config.xml');
  final debug = File('android/app/src/debug/res/xml/network_security_config.xml');

  test('the shipped network security config denies all cleartext traffic', () {
    final xml = main.readAsStringSync().replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    expect(xml, contains('<base-config cleartextTrafficPermitted="false"'));
    expect(xml, isNot(contains('cleartextTrafficPermitted="true"')));
    expect(xml, isNot(contains('<domain')));
    expect(xml, isNot(contains('trust-anchors')));
  });

  test('development loopback cleartext lives in the debug source set only', () {
    final xml = debug.readAsStringSync();
    expect(xml, contains('<domain-config cleartextTrafficPermitted="true">'));
    expect(xml, contains('10.0.2.2'));
    expect(xml, contains('localhost'));
    expect(xml, isNot(contains('user')), reason: 'no user-installed CA trust');
  });

  test('the manifest wires the config and keeps backups off', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:networkSecurityConfig="@xml/network_security_config"'));
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, isNot(contains('usesCleartextTraffic="true"')));
    expect(manifest, isNot(contains('android:debuggable="true"')));
  });
}
