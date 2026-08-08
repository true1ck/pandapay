import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/settings/storage_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('computeDirectorySize', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('storage_util_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('returns 0 for a missing directory', () async {
      final missing = Directory('${tempDir.path}/does_not_exist');
      expect(await computeDirectorySize(missing), 0);
    });

    test('returns 0 for an empty directory', () async {
      expect(await computeDirectorySize(tempDir), 0);
    });

    test('sums file sizes recursively, including nested subdirectories', () async {
      await File('${tempDir.path}/a.txt').writeAsBytes(List.filled(100, 0));
      final sub = await Directory('${tempDir.path}/sub').create();
      await File('${sub.path}/b.txt').writeAsBytes(List.filled(250, 0));

      expect(await computeDirectorySize(tempDir), 350);
    });
  });

  group('clearDirectoryContents', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('storage_util_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('deletes files and subdirectories but keeps the root directory itself', () async {
      await File('${tempDir.path}/a.txt').writeAsBytes([1, 2, 3]);
      await Directory('${tempDir.path}/sub').create();

      await clearDirectoryContents(tempDir);

      expect(await tempDir.exists(), isTrue);
      expect(await tempDir.list().toList(), isEmpty);
    });

    test('no-ops on a missing directory rather than throwing', () async {
      final missing = Directory('${tempDir.path}/does_not_exist');
      await expectLater(clearDirectoryContents(missing), completes);
    });
  });

  group('formatBytes', () {
    test('formats sub-KB values in bytes', () {
      expect(formatBytes(512), '512 B');
    });

    test('formats KB with one decimal below 10 KB', () {
      expect(formatBytes(2048), '2.0 KB');
    });

    test('formats KB with no decimal at or above 10 KB', () {
      expect(formatBytes(20 * 1024), '20 KB');
    });

    test('formats MB values', () {
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    });
  });

  group('clearPreferencesExceptPrefixes', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('removes keys not matching any preserved prefix, keeps the rest', () async {
      SharedPreferences.setMockInitialValues({
        'pandapay_app.access_token': 'tok',
        'pandapay_app.refresh_token': 'refresh',
        'onboarding_seen_v1': true,
        'biometric_lock_enabled_v1': false,
      });
      final prefs = await SharedPreferences.getInstance();

      final removed = await clearPreferencesExceptPrefixes(prefs, const ['pandapay_app.']);

      expect(removed, containsAll(['onboarding_seen_v1', 'biometric_lock_enabled_v1']));
      expect(prefs.getString('pandapay_app.access_token'), 'tok');
      expect(prefs.getString('pandapay_app.refresh_token'), 'refresh');
      expect(prefs.containsKey('onboarding_seen_v1'), isFalse);
      expect(prefs.containsKey('biometric_lock_enabled_v1'), isFalse);
    });

    test('preserves nothing when no prefixes are given', () async {
      SharedPreferences.setMockInitialValues({'a': 1, 'b': 2});
      final prefs = await SharedPreferences.getInstance();

      final removed = await clearPreferencesExceptPrefixes(prefs, const []);

      expect(removed, containsAll(['a', 'b']));
      expect(prefs.getKeys(), isEmpty);
    });
  });
}
