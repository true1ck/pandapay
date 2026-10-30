import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart'
    show AuthMessages;
import 'package:pandapay/features/settings/account_settings_screen.dart'
    show biometricLockProvider;
import 'package:pandapay/features/system/biometric_setup_prompt.dart';
import 'package:pandapay/app/providers.dart' show biometricUnlockedProvider;
import 'package:shared_preferences/shared_preferences.dart';

class _FakeLocalAuth extends LocalAuthentication {
  final bool deviceSupported;
  final bool authResult;
  final List<BiometricType> biometrics;
  int authenticateCalls = 0;
  String? lastReason;
  bool? lastBiometricOnly;

  _FakeLocalAuth({
    required this.deviceSupported,
    required this.authResult,
    this.biometrics = const [BiometricType.fingerprint],
  });

  @override
  Future<bool> isDeviceSupported() async => deviceSupported;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => biometrics;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<AuthMessages> authMessages = const <AuthMessages>[],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    authenticateCalls++;
    lastReason = localizedReason;
    lastBiometricOnly = biometricOnly;
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
      final auth = _FakeLocalAuth(deviceSupported: true, authResult: true);

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
      expect(find.text('Enable fingerprint'), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);

      var unlockedWhenEnabled = false;
      container.listen(biometricLockProvider, (_, next) {
        if (next.valueOrNull == true) {
          unlockedWhenEnabled = container.read(biometricUnlockedProvider);
        }
      });
      await tester.tap(find.text('Enable fingerprint'));
      await tester.pumpAndSettle();

      expect(auth.authenticateCalls, 1);
      expect(container.read(biometricLockProvider).valueOrNull, isTrue);
      expect(unlockedWhenEnabled, isTrue);
      expect(container.read(biometricUnlockedProvider), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('biometric_setup_prompt_seen_v1'), isTrue);
    },
  );

  testWidgets('Not now dismisses the prompt without enabling the lock', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final auth = _FakeLocalAuth(deviceSupported: true, authResult: true);

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

  for (final entry in [
    (BiometricType.face, 'Face ID', Icons.face_rounded),
    (BiometricType.fingerprint, 'Touch ID', Icons.fingerprint_rounded),
  ]) {
    testWidgets(
      'iOS enrollment detects ${entry.$2} and verifies only once',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final auth = _FakeLocalAuth(
          deviceSupported: true,
          authResult: true,
          biometrics: [entry.$1],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(body: BiometricSetupPrompt(localAuth: auth)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Enable ${entry.$2}'), findsOneWidget);
        expect(find.byIcon(entry.$3), findsOneWidget);
        expect(find.textContaining('Android'), findsNothing);
        await tester.tap(find.text('Enable ${entry.$2}'));
        await tester.pumpAndSettle();
        expect(auth.authenticateCalls, 1);
        expect(auth.lastReason, 'Use ${entry.$2} to protect PandaPay');
        expect(auth.lastBiometricOnly, isFalse);
        expect(container.read(biometricUnlockedProvider), isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'iOS with no enrolled biometry describes the device passcode',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final auth = _FakeLocalAuth(
        deviceSupported: true,
        authResult: false,
        biometrics: const [],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: BiometricSetupPrompt(localAuth: auth)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Enable device lock'), findsOneWidget);
      expect(find.textContaining('device passcode'), findsOneWidget);
      expect(find.byIcon(Icons.fingerprint_rounded), findsNothing);
      await tester.tap(find.text('Enable device lock'));
      await tester.pumpAndSettle();
      expect(container.read(biometricUnlockedProvider), isFalse);
      expect(container.read(biometricLockProvider).valueOrNull, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
