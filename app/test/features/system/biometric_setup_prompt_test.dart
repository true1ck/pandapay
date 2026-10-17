import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart'
    show AuthMessages;
import 'package:pandapay/features/settings/account_settings_screen.dart'
    show biometricLockProvider;
import 'package:pandapay/features/system/biometric_setup_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeLocalAuth extends LocalAuthentication {
  final bool deviceSupported;
  final bool authResult;
  int authenticateCalls = 0;

  _FakeLocalAuth({this.deviceSupported = true, this.authResult = true});

  @override
  Future<bool> isDeviceSupported() async => deviceSupported;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<AuthMessages> authMessages = const <AuthMessages>[],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    authenticateCalls++;
    return authResult;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'offers a bottom-sheet enrollment prompt and enables the lock after confirmation',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final auth = _FakeLocalAuth();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: BiometricSetupPrompt(localAuth: auth)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Protect PandaPay'), findsOneWidget);
      expect(find.text('Enable fingerprint lock'), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);

      await tester.tap(find.text('Enable fingerprint lock'));
      await tester.pumpAndSettle();

      expect(auth.authenticateCalls, 1);
      expect(container.read(biometricLockProvider).valueOrNull, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('biometric_setup_prompt_seen_v1'), isTrue);
    },
  );

  testWidgets('Not now dismisses the prompt without enabling the lock', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final auth = _FakeLocalAuth();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: BiometricSetupPrompt(localAuth: auth)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(auth.authenticateCalls, 0);
    expect(container.read(biometricLockProvider).valueOrNull, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('biometric_setup_prompt_seen_v1'), isTrue);
  });
}
