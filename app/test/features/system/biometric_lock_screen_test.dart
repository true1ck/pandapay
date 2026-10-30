import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart'
    show AuthMessages;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/system/biometric_lock_screen.dart';

class _FakeLocalAuth extends LocalAuthentication {
  final bool deviceSupported;
  final bool authResult;
  final LocalAuthException? authException;
  final List<BiometricType> biometrics;
  int authenticateCalls = 0;
  String? lastReason;

  _FakeLocalAuth({
    this.deviceSupported = true,
    this.authResult = true,
    this.authException,
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
    if (authException != null) throw authException!;
    return authResult;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('a successful authentication unlocks the app', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final auth = _FakeLocalAuth(authResult: true);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: BiometricLockScreen(localAuth: auth)),
      ),
    );
    // Let the cold-start unlock delay elapse before checking authentication.
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();

    expect(auth.authenticateCalls, 1);
    expect(container.read(biometricUnlockedProvider), isTrue);
  });

  testWidgets(
    'a cancelled authentication (authenticate returns false) offers a retry, does not unlock',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final auth = _FakeLocalAuth(authResult: false);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: BiometricLockScreen(localAuth: auth)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();

      expect(container.read(biometricUnlockedProvider), isFalse);
      expect(find.text('Try again'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(auth.authenticateCalls, 2);
    },
  );

  testWidgets(
    'a device with no lock configured shows the escape hatch, not a dead end',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final auth = _FakeLocalAuth(deviceSupported: false);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: BiometricLockScreen(localAuth: auth)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();

      expect(find.text('Turn off biometric lock and continue'), findsOneWidget);
      // Never even attempted authenticate() — isDeviceSupported() said no.
      expect(auth.authenticateCalls, 0);

      await tester.tap(find.text('Turn off biometric lock and continue'));
      await tester.pumpAndSettle();

      expect(container.read(biometricUnlockedProvider), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('biometric_lock_enabled_v1'), isFalse);
    },
  );

  testWidgets('a noBiometricsEnrolled exception also shows the escape hatch', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final auth = _FakeLocalAuth(
      authException: const LocalAuthException(
        code: LocalAuthExceptionCode.noBiometricsEnrolled,
      ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: BiometricLockScreen(localAuth: auth)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();

    expect(find.text('Turn off biometric lock and continue'), findsOneWidget);
  });

  testWidgets(
    'an unexpected exception shows a generic retry, not the escape hatch',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final auth = _FakeLocalAuth(
        authException: const LocalAuthException(
          code: LocalAuthExceptionCode.timeout,
        ),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: BiometricLockScreen(localAuth: auth)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();

      expect(find.text('Turn off biometric lock and continue'), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
      expect(container.read(biometricUnlockedProvider), isFalse);
    },
  );

  testWidgets(
    'Face ID iPhone uses face icon and prompt, without automatic retries',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final auth = _FakeLocalAuth(
        authResult: false,
        biometrics: const [BiometricType.face],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: BiometricLockScreen(localAuth: auth)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(auth.lastReason, 'Use Face ID to unlock PandaPay');
      expect(find.byIcon(Icons.face_rounded), findsOneWidget);
      expect(find.byIcon(Icons.fingerprint_rounded), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(auth.authenticateCalls, 1);
      expect(container.read(biometricUnlockedProvider), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
