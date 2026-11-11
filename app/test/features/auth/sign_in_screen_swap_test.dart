import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/features/auth/login_screen.dart';

/// In the real app the login screen is shown only while signed out, so setting
/// the access token removes it from the tree and disposes its `ref`. Sign-in
/// must still finish. On a real network the screen is disposed while the
/// profile request is in flight, so the steps after it used to throw "Cannot
/// use ref after the widget was disposed": the profile provider was never
/// refreshed and a false "Sign-in failed" was logged.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'sign-in still ensures the profile when the screen is swapped out',
    (tester) async {
      var profileCalls = 0;
      final logs = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      final auth = AuthApi(
        authBaseUrl: 'https://auth.test',
        client: MockClient((request) async {
          if (request.url.path == '/auth/request-email-otp') {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response(
            jsonEncode({'access_token': 'access', 'refresh_token': 'refresh'}),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authApiProvider.overrideWithValue(auth),
            accountDeviceIdProvider.overrideWith((ref) async => 'test-device'),
            deviceMetadataProvider.overrideWith(
              (ref) async => const {'platform': 'test'},
            ),
            profileApiProvider.overrideWith(
              (ref) => ProfileApi(
                apiBaseUrl: 'https://api.test',
                accessToken: 'access',
                client: MockClient((request) async {
                  profileCalls++;
                  // A real request takes time; frames (and the swap) happen here.
                  await Future<void>.delayed(const Duration(milliseconds: 300));
                  return http.Response(
                    jsonEncode({
                      'profile': {'id': 'p1'},
                    }),
                    201,
                  );
                }),
              ),
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) =>
                  ref.watch(accessTokenProvider) == null
                  ? const Scaffold(body: LoginScreen())
                  : const Scaffold(body: Text('Signed-in home')),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byType(TextField).at(0),
        'person@example.test',
      );
      await tester.pump();
      await tester.tap(find.text('Send code'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1234');
      await tester.ensureVisible(find.text('Verify & continue'));
      await tester.tap(find.text('Verify & continue'));
      // Let the in-flight profile request finish (the screen is swapped out
      // while it is pending), then settle.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      // The framework requires foundation debug hooks restored inside the test.
      debugPrint = originalDebugPrint;

      expect(find.text('Signed-in home'), findsOneWidget);
      expect(profileCalls, 1, reason: 'ensureProfile must run after the swap');
      expect(tester.takeException(), isNull);
      expect(
        logs.where((line) => line.contains('Sign-in failed')),
        isEmpty,
        reason: 'a completed sign-in must not be reported as failed',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
