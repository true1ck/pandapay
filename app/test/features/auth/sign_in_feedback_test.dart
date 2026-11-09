import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/features/auth/auth_feedback.dart';
import 'package:pandapay/features/auth/login_screen.dart';

ApiException _api(int status, Map<String, Object?> body) =>
    ApiException('OTP verify failed: $status ${jsonEncode(body)}');

void main() {
  group('describeAuthFailure', () {
    const email = 'person@example.test';

    test('a wrong code says so and counts the tries left', () {
      final notice = describeAuthFailure(
        _api(400, {'error': 'Invalid or expired code'}),
        stage: AuthStage.verifyCode,
        email: email,
        codeTimeLeft: const Duration(seconds: 80),
        attemptsLeft: 3,
      );
      expect(notice.kind, AuthFailureKind.wrongCode);
      expect(notice.title, 'Incorrect code');
      expect(notice.message, contains('3 tries left'));
    });

    test('the same server reply after the timer ran out reads as expired', () {
      final notice = describeAuthFailure(
        _api(400, {'error': 'Invalid or expired code'}),
        stage: AuthStage.verifyCode,
        email: email,
        codeTimeLeft: Duration.zero,
      );
      expect(notice.kind, AuthFailureKind.expiredCode);
    });

    test('no tries left reads as a locked code', () {
      final notice = describeAuthFailure(
        _api(400, {'error': 'Invalid or expired code'}),
        stage: AuthStage.verifyCode,
        email: email,
        codeTimeLeft: const Duration(seconds: 40),
        attemptsLeft: 0,
      );
      expect(notice.kind, AuthFailureKind.codeLocked);
    });

    test('a lost verify reply warns that the code may be used up', () {
      final notice = describeAuthFailure(
        TimeoutException('slow'),
        stage: AuthStage.verifyCode,
        email: email,
      );
      expect(notice.kind, AuthFailureKind.timeout);
      expect(notice.message, contains('Resend code'));
    });

    test('offline says it is the connection and how long the code lasts', () {
      final notice = describeAuthFailure(
        http.ClientException('Connection refused'),
        stage: AuthStage.verifyCode,
        email: email,
        codeTimeLeft: const Duration(seconds: 65),
      );
      expect(notice.title, 'No connection');
      expect(notice.message, contains('still valid for 1:05'));
    });

    test('a server outage says it is on our side, with a reference', () {
      final notice = describeAuthFailure(
        _api(503, {
          'success': false,
          'message':
              'Authentication is temporarily unavailable. Please try again shortly.',
        }),
        stage: AuthStage.sendCode,
        email: email,
      );
      expect(notice.kind, AuthFailureKind.serviceUnavailable);
      expect(notice.message, contains('on our side'));
      expect(notice.reference, 'HTTP 503');
    });

    test('an unknown account offers the next step', () {
      final notice = describeAuthFailure(
        _api(404, {'error': 'Account not found. Please sign up first.'}),
        stage: AuthStage.sendCode,
        email: email,
      );
      expect(notice.kind, AuthFailureKind.accountNotFound);
      expect(notice.message, contains(email));
    });

    test(
      'an app-side crash gets a support reference, not a blame on Wi-Fi',
      () {
        final notice = describeAuthFailure(
          TypeError(),
          stage: AuthStage.finishSignIn,
          email: email,
        );
        expect(notice.message, isNot(contains('connection')));
        expect(notice.message, contains('Continue'));
        expect(notice.reference, startsWith('Ref finishSignIn/'));
      },
    );

    test('countdown text', () {
      expect(formatCountdown(const Duration(seconds: 120)), '2:00');
      expect(formatCountdown(const Duration(seconds: 65)), '1:05');
      expect(formatCountdown(const Duration(seconds: 9)), '0:09');
      expect(formatCountdown(const Duration(seconds: -3)), '0:00');
    });
  });

  group('code screen', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    late DateTime now;
    late List<String> calls;

    Future<void> mount(
      WidgetTester tester, {
      required Future<http.Response> Function(http.Request) verify,
      Future<http.Response> Function(http.Request)? profile,
    }) async {
      now = DateTime(2026, 11, 2, 10);
      calls = [];
      final auth = AuthApi(
        authBaseUrl: 'https://auth.test',
        now: () => now,
        client: MockClient((request) async {
          calls.add(request.url.path);
          if (request.url.path == '/auth/request-email-otp') {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return verify(request);
        }),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authApiProvider.overrideWithValue(auth),
            localDeviceIdProvider.overrideWith((ref) async => 'test-device'),
            deviceMetadataProvider.overrideWith(
              (ref) async => const {'platform': 'test'},
            ),
            if (profile != null)
              profileApiProvider.overrideWith(
                (ref) => ProfileApi(
                  apiBaseUrl: 'https://api.test',
                  accessToken: 'access',
                  client: MockClient(profile),
                ),
              ),
          ],
          child: const MaterialApp(home: Scaffold(body: LoginScreen())),
        ),
      );
      await tester.enterText(
        find.byType(TextField).at(0),
        'person@example.test',
      );
      await tester.pump();
      await tester.tap(find.text('Send code'));
      await tester.pumpAndSettle();
    }

    /// Moves the screen's clock and lets the one-second ticker run.
    Future<void> elapse(WidgetTester tester, Duration duration) async {
      now = now.add(duration);
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('counts down, then offers a new code once expired', (
      tester,
    ) async {
      await mount(tester, verify: (_) async => http.Response('{}', 500));
      expect(find.text('Code expires in 1:00'), findsOneWidget);
      expect(find.text('Resend in 1:00'), findsOneWidget);

      await elapse(tester, const Duration(seconds: 35));
      expect(find.text('Code expires in 0:25'), findsOneWidget);

      await elapse(tester, const Duration(seconds: 30));
      expect(find.text('Code expired'), findsOneWidget);
      expect(find.text('Send a new code'), findsOneWidget);
      expect(find.text('Verify & continue'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a wrong code explains itself and clears the boxes', (
      tester,
    ) async {
      await mount(
        tester,
        verify: (_) async => http.Response(
          jsonEncode({'error': 'Invalid or expired code'}),
          400,
        ),
      );
      await tester.enterText(find.byType(TextField), '1234');
      await tester.ensureVisible(find.text('Verify & continue'));
      await tester.tap(find.text('Verify & continue'));
      await tester.pumpAndSettle();

      expect(find.text('Incorrect code'), findsOneWidget);
      expect(find.textContaining('4 tries left'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'a failure after the code is accepted retries without reusing the code',
      (tester) async {
        var profileCalls = 0;
        await mount(
          tester,
          verify: (_) async => http.Response(
            jsonEncode({'access_token': 'access', 'refresh_token': 'refresh'}),
            200,
          ),
          profile: (_) async {
            profileCalls++;
            return profileCalls == 1
                ? http.Response(
                    jsonEncode({'error': 'Internal server error'}),
                    500,
                  )
                : http.Response(
                    jsonEncode({
                      'profile': {'id': 'p1'},
                    }),
                    201,
                  );
          },
        );
        await tester.enterText(find.byType(TextField), '1234');
        await tester.ensureVisible(find.text('Verify & continue'));
        await tester.tap(find.text('Verify & continue'));
        await tester.pumpAndSettle();

        expect(find.text('PandaPay is having trouble'), findsOneWidget);
        expect(find.text('Code accepted'), findsOneWidget);
        expect(find.text('Continue'), findsOneWidget);

        await tester.ensureVisible(find.text('Continue'));
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        expect(
          calls.where((path) => path == '/auth/verify-email-otp'),
          hasLength(1),
        );
        expect(profileCalls, 2);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}
