import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/user_settings_api.dart';
import 'package:pandapay/features/settings/settings_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Plan Phase 1.1. The behaviour under test is the merge direction, which is
/// the only part of preference sync that can lose a user's data if it's wrong:
///
///   * a key the SERVER has wins locally (that's what makes a new device
///     inherit the account's preferences), and
///   * a key only the DEVICE has is pushed up rather than wiped (that's what
///     stops the first sync after an update from resetting an existing user).
///
/// Getting either backwards produces a bug that looks exactly like "the app
/// forgot my settings", which is the complaint this whole phase exists to
/// remove — so both directions are asserted explicitly, not inferred from a
/// single round trip.
void main() {
  const onboardingKey = 'pandapay_app.onboarding_complete_v1';
  const themeKey = 'appearance_theme_mode_v1';
  const scaleKey = 'appearance_text_scale_v1';
  const remindersKey = 'pandapay_app.due_date_reminders_v1';

  /// Builds a container whose UserSettingsApi is backed by [handler], and
  /// records every PATCH body the sync pushes so a test can assert on it.
  (ProviderContainer, List<Map<String, dynamic>>) harness({
    required Map<String, Object?> serverSettings,
  }) {
    final pushes = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode({'settings': serverSettings, 'revision': 1, 'updatedAt': null}),
          200,
        );
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final patch = (body['settings'] as Map).cast<String, dynamic>();
      pushes.add(patch);
      // Mirror the server's real merge semantics so a follow-up GET in the
      // same test sees what a real server would have stored.
      patch.forEach((k, v) {
        if (v == null) {
          serverSettings.remove(k);
        } else {
          serverSettings[k] = v;
        }
      });
      return http.Response(
        jsonEncode({'settings': serverSettings, 'revision': 2, 'updatedAt': null}),
        200,
      );
    });

    final container = ProviderContainer(
      overrides: [
        userSettingsApiProvider.overrideWithValue(
          UserSettingsApi(apiBaseUrl: 'http://test', accessToken: 'token', client: client),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container, pushes);
  }

  test('a key the server has is applied to this device', () async {
    SharedPreferences.setMockInitialValues({themeKey: 'system'});
    final (container, _) = harness(serverSettings: {themeKey: 'dark', onboardingKey: true});

    final applied = await container.read(settingsSyncProvider).pullAndApply();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(themeKey), 'dark');
    expect(prefs.getBool(onboardingKey), isTrue);
    expect(applied, containsAll([themeKey, onboardingKey]));
  });

  test('a key only this device has is pushed up, not wiped', () async {
    // The migration case: an existing user on their existing phone, syncing
    // for the first time against an empty server blob.
    SharedPreferences.setMockInitialValues({
      themeKey: 'dark',
      scaleKey: 1.15,
      onboardingKey: true,
    });
    final (container, pushes) = harness(serverSettings: {});

    await container.read(settingsSyncProvider).pullAndApply();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(themeKey), 'dark', reason: 'local value must survive an empty server');
    expect(prefs.getDouble(scaleKey), 1.15);
    expect(pushes, hasLength(1));
    expect(pushes.single, containsPair(themeKey, 'dark'));
    expect(pushes.single, containsPair(scaleKey, 1.15));
    expect(pushes.single, containsPair(onboardingKey, true));
  });

  test('server and device values merge per key rather than either side winning wholesale', () async {
    SharedPreferences.setMockInitialValues({scaleKey: 1.3});
    final (container, pushes) = harness(serverSettings: {themeKey: 'light'});

    await container.read(settingsSyncProvider).pullAndApply();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(themeKey), 'light', reason: 'server-only key comes down');
    expect(prefs.getDouble(scaleKey), 1.3, reason: 'device-only key is untouched');
    expect(pushes.single.keys, contains(scaleKey));
    expect(pushes.single.keys, isNot(contains(themeKey)));
  });

  test('a string list round-trips as a set, and identical membership is not a change', () async {
    SharedPreferences.setMockInitialValues({
      remindersKey: ['card-b', 'card-a'],
    });
    final (container, _) = harness(
      serverSettings: {
        remindersKey: ['card-a', 'card-b'],
      },
    );

    final applied = await container.read(settingsSyncProvider).pullAndApply();

    // Same two ids in a different order is the same preference. Reporting it
    // as changed would invalidate providers on every single sign-in.
    expect(applied, isNot(contains(remindersKey)));
  });

  test('a server value of the wrong type is skipped instead of throwing', () async {
    // Can only happen when a newer build has stored something this one
    // doesn't understand. A preference blob must never be able to break
    // sign-in on an older client.
    SharedPreferences.setMockInitialValues({onboardingKey: true});
    final (container, _) = harness(serverSettings: {onboardingKey: 'yes-please'});

    final applied = await container.read(settingsSyncProvider).pullAndApply();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(onboardingKey), isTrue, reason: 'local value is left alone');
    expect(applied, isEmpty);
  });

  test('signed out, sync is a no-op rather than an error', () async {
    SharedPreferences.setMockInitialValues({themeKey: 'dark'});
    final container = ProviderContainer(
      overrides: [userSettingsApiProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    expect(await container.read(settingsSyncProvider).pullAndApply(), isEmpty);
  });

  test('the biometric lock is deliberately never synced', () async {
    // A statement about one handset's enrolled biometrics. Carrying it across
    // would either disable a lock the user believes is on, or enable one the
    // new device cannot satisfy.
    expect(
      kSyncedPrefs.map((p) => p.key),
      isNot(contains('settings_biometric_lock_v1')),
    );
    expect(kDeliberatelyDeviceLocalPrefs, contains('settings_biometric_lock_v1'));
  });
}
