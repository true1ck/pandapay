import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/features/auth/login_screen.dart';
import 'package:pandapay/features/auth/phone_gate_provider.dart';
import 'package:pandapay/features/auth/product_activation_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A brand-new person finishes sign-up on the real sign-up route inside the
/// real router. Once the code is accepted they must land on Activate account.
/// The reported bug: "Code accepted" stayed on screen and Continue did nothing.
http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<void> _pumpBounded(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// [viaPush] is how the person reached the sign-up page: Welcome's button
/// pushes it on top of /welcome; an invite link `go`es straight to it.
Future<void> _signUp(
  WidgetTester tester, {
  required bool viaPush,
}) async {
  SharedPreferences.setMockInitialValues({
    'pandapay_app.onboarding_complete_v1': false,
  });
  final auth = AuthApi(
    authBaseUrl: 'https://auth.test',
    client: MockClient((request) async {
      final path = request.url.path;
      if (path == '/auth/request-email-otp') return _json({'ok': true});
      if (path == '/auth/verify-email-otp') {
        return _json({'access_token': 'access', 'refresh_token': 'refresh'});
      }
      if (path == '/users/me/phone' && request.method == 'GET') {
        return _json({
          'claimed': false,
          'verified': false,
          'required': false,
          'needs_phone': false,
        });
      }
      return _json({});
    }),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authApiProvider.overrideWithValue(auth),
        sessionInitProvider.overrideWith((ref) => Future<void>.value()),
        accountDeviceIdProvider.overrideWith((ref) async => 'test-device'),
        deviceMetadataProvider.overrideWith(
          (ref) async => const {'platform': 'test'},
        ),
        phoneGateProvider.overrideWith((ref) => PhoneGateController(ref)),
      ],
      child: Consumer(
        builder: (context, ref, _) => MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: ref.watch(goRouterProvider),
        ),
      ),
    ),
  );
  await _pumpBounded(tester);
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  final router = container.read(goRouterProvider);
  if (viaPush) {
    // Welcome's button pushes the route (welcome_screen.dart).
    unawaited(router.push(AppRoute.signUp));
  } else {
    router.go(AppRoute.signUp);
  }
  await _pumpBounded(tester, 5);
  expect(find.byType(LoginScreen), findsOneWidget);

  await tester.enterText(find.byType(TextField).at(0), 'new.person@example.test');
  await tester.enterText(find.byType(TextField).at(1), '98765 43210');
  for (final i in [0, 1]) {
    await tester.ensureVisible(find.byType(CheckboxListTile).at(i));
    await tester.tap(find.byType(CheckboxListTile).at(i));
  }
  await tester.pump();
  final send = find.text('Send verification code');
  await tester.ensureVisible(send);
  await tester.tap(send);
  await _pumpBounded(tester, 5);
  await tester.enterText(find.byType(TextField), '1234');
  await tester.ensureVisible(find.text('Verify & continue'));
  await tester.tap(find.text('Verify & continue'));
  await _pumpBounded(tester, 20);
}

void main() {
  testWidgets(
    'sign-up opened from Welcome (pushed) lands on Activate account once the code is accepted',
    (tester) async {
      await _signUp(tester, viaPush: true);
      expect(find.byType(ProductActivationScreen), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'sign-up opened by an invite link (go) lands on Activate account once the code is accepted',
    (tester) async {
      await _signUp(tester, viaPush: false);
      expect(find.byType(ProductActivationScreen), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
