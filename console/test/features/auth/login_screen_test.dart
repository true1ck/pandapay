import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_console/app/providers.dart';
import 'package:pandapay_console/data/private_admin_auth.dart';
import 'package:pandapay_console/features/auth/login_screen.dart';

Future<ProviderContainer> showLogin(
  WidgetTester tester,
  PrivateAdminAuthApi auth, {
  Size size = const Size(1280, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authApiProvider.overrideWithValue(auth)],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const LoginScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(LoginScreen)));
}

void main() {
  testWidgets(
    'approved account registers backup without a grant field or copied token',
    (tester) async {
      final paths = <String>[];
      final auth = PrivateAdminAuthApi(
        client: MockClient((request) async {
          paths.add(request.url.path);
          final body = switch (request.url.path) {
            '/browser/login/start' => {'version': 1, 'loginId': 'approved'},
            '/browser/login/verify-email' => {
              'version': 1,
              'next': 'enrollment',
              'enrollmentMode': 'approved',
              'enrolledSlots': ['primary'],
            },
            '/browser/enrollment/options' => {'version': 1, 'options': {}},
            '/browser/enrollment/verify' => {
              'version': 1,
              'enrolled': true,
              'enrolledSlots': ['primary', 'backup'],
            },
            _ => throw StateError('Unexpected request'),
          };
          if (request.url.path.endsWith('/options')) {
            expect(jsonDecode(request.body), {
              'loginId': 'approved',
              'mode': 'approved',
            });
          }
          return http.Response(jsonEncode(body), 200);
        }),
        passkey: (_, {required register}) async {
          expect(register, true);
          return {'id': 'synthetic-managed-backup'};
        },
      );
      final container = await showLogin(
        tester,
        auth,
        size: const Size(320, 568),
      );
      await tester.enterText(
        find.byKey(const Key('admin-account')),
        'owner@example.test',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin-email-code')),
        '123456',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Register your backup key.'), findsOneWidget);
      expect(find.byKey(const Key('admin-enrollment-grant')), findsNothing);
      expect(find.textContaining('43-character'), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('admin-login-submit')));
      await tester.tap(find.byKey(const Key('admin-login-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Ready for activation.'), findsOneWidget);
      expect(container.read(accessTokenProvider), isNull);
      expect(paths.length, 4);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact login can submit by keyboard without overflow', (
    tester,
  ) async {
    var requests = 0;
    final auth = PrivateAdminAuthApi(
      client: MockClient((request) async {
        requests++;
        expect(request.url.path, '/browser/login/start');
        expect(jsonDecode(request.body)['email'], 'owner@example.test');
        return http.Response('{"version":1,"loginId":"local-login"}', 202);
      }),
    );
    await showLogin(tester, auth, size: const Size(320, 568));
    expect(find.byKey(const Key('admin-workspace-panel')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('admin-account')),
      'owner@example.test',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.text('Check your inbox.'), findsOneWidget);
    expect(find.byKey(const Key('admin-email-code')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'invalid account email stays local and displays a useful field error',
    (tester) async {
      final auth = PrivateAdminAuthApi(
        client: MockClient((_) async {
          fail('Invalid email must not request an OTP');
        }),
      );
      await showLogin(tester, auth);
      expect(find.byKey(const Key('admin-workspace-panel')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('admin-account')),
        'not-an-email',
      );
      await tester.tap(find.byKey(const Key('admin-login-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
    },
  );

  testWidgets(
    'pending enrollment has one action and never creates a signed-in UI state',
    (tester) async {
      final paths = <String>[];
      final auth = PrivateAdminAuthApi(
        client: MockClient((request) async {
          paths.add(request.url.path);
          final body = switch (request.url.path) {
            '/browser/login/start' => {'version': 1, 'loginId': 'pending'},
            '/browser/login/verify-email' => {
              'version': 1,
              'next': 'enrollment',
            },
            '/browser/enrollment/options' => {
              'version': 1,
              'options': <String, dynamic>{},
            },
            '/browser/enrollment/verify' => {
              'version': 1,
              'enrolled': true,
              'enrolledSlots': ['primary'],
            },
            _ => throw StateError('Unexpected request'),
          };
          return http.Response(jsonEncode(body), 200);
        }),
        passkey: (_, {required register}) async {
          expect(register, true);
          return {'id': 'synthetic-test-credential'};
        },
      );
      final container = await showLogin(tester, auth);
      await tester.enterText(
        find.byKey(const Key('admin-account')),
        'owner@example.test',
      );
      await tester.tap(find.byKey(const Key('admin-login-submit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin-email-code')),
        '123456',
      );
      await tester.tap(find.byKey(const Key('admin-login-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Connect your security key.'), findsOneWidget);
      expect(find.text('Email verified'), findsOneWidget);
      expect(find.byKey(const Key('admin-email-code')), findsNothing);
      expect(find.text('Verify code'), findsNothing);
      expect(find.text('Register security key'), findsOneWidget);
      expect(
        find.text(
          'A one-use enrollment grant is required to register your security key.',
        ),
        findsNothing,
      );
      expect(container.read(accessTokenProvider), isNull);

      // An empty grant produces a field error, rather than a doomed network request.
      await tester.tap(find.byKey(const Key('admin-login-submit')));
      await tester.pumpAndSettle();
      expect(paths.length, 2);
      expect(
        find.text('Enter the enrollment grant provided for your account.'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin-enrollment-grant')),
        '12',
      );
      await tester.tap(find.byKey(const Key('admin-login-submit')));
      await tester.pumpAndSettle();
      expect(paths.length, 2);
      expect(
        find.text(
          'Paste the full 43-character enrollment grant, not your email code.',
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin-enrollment-grant')),
        'a' * 43,
      );
      await tester.tap(find.byKey(const Key('admin-login-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Primary key registered.'), findsOneWidget);
      expect(find.byKey(const Key('admin-account')), findsNothing);
      expect(
        find.text(
          'Open PandaPay Admin Setup on your Desktop. Choose option 2 to prepare your backup key, then option 3 to activate the account. Your primary grant has already been used.',
        ),
        findsOneWidget,
      );
      expect(container.read(accessTokenProvider), isNull);
      expect(paths, [
        '/browser/login/start',
        '/browser/login/verify-email',
        '/browser/enrollment/options',
        '/browser/enrollment/verify',
      ]);
      await tester.tap(find.byKey(const Key('admin-return-to-sign-in')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('admin-account')), findsOneWidget);
    },
  );

  testWidgets('rejected grant displays recovery guidance on compact enrollment', (
    tester,
  ) async {
    final auth = PrivateAdminAuthApi(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/options')) {
          return http.Response(
            '{"version":1,"error":"enrollment_denied"}',
            403,
          );
        }
        return http.Response(
          jsonEncode(
            request.url.path.endsWith('/start')
                ? {'version': 1, 'loginId': 'pending'}
                : {'version': 1, 'next': 'enrollment'},
          ),
          200,
        );
      }),
      passkey: (_, {required register}) async =>
          fail('Rejected grants must not open a passkey prompt'),
    );
    final container = await showLogin(tester, auth, size: const Size(320, 568));
    await tester.enterText(
      find.byKey(const Key('admin-account')),
      'owner@example.test',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('admin-email-code')), '123456');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin-enrollment-grant')),
      '123456',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Paste the full 43-character enrollment grant, not your email code.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.enterText(
      find.byKey(const Key('admin-enrollment-grant')),
      'a' * 43,
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Enrollment was not authorized. Your grant or email verification may have expired. Start again with a fresh grant and email code.',
      ),
      findsOneWidget,
    );
    expect(find.text('Start again'), findsOneWidget);
    expect(find.byKey(const Key('admin-enrollment-grant')), findsOneWidget);
    expect(container.read(accessTokenProvider), isNull);
    expect(tester.takeException(), isNull);
  });

  for (final slots in [
    <String>['primary'],
    <String>['primary', 'backup'],
  ]) {
    testWidgets('pending account shows the remaining setup for $slots', (
      tester,
    ) async {
      final paths = <String>[];
      final auth = PrivateAdminAuthApi(
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path == '/browser/enrollment/options') {
            return http.Response('{"version":1,"options":{}}', 200);
          }
          if (request.url.path == '/browser/enrollment/verify') {
            return http.Response(
              '{"version":1,"enrolled":true,"enrolledSlots":["primary","backup"]}',
              200,
            );
          }
          return http.Response(
            jsonEncode(
              request.url.path.endsWith('/start')
                  ? {'version': 1, 'loginId': 'pending'}
                  : {
                      'version': 1,
                      'next': 'enrollment',
                      'enrolledSlots': slots,
                    },
            ),
            200,
          );
        }),
        passkey: (_, {required register}) async {
          expect(register, true);
          return {'id': 'synthetic-backup-credential'};
        },
      );
      final container = await showLogin(
        tester,
        auth,
        size: const Size(320, 568),
      );
      await tester.enterText(
        find.byKey(const Key('admin-account')),
        'owner@example.test',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin-email-code')),
        '123456',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      if (slots.length == 1) {
        expect(find.text('Register your backup key.'), findsOneWidget);
        expect(find.text('Backup-key enrollment grant'), findsOneWidget);
        expect(find.byKey(const Key('admin-enrollment-grant')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('admin-enrollment-grant')),
          'a' * 43,
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.text('Ready for activation.'), findsOneWidget);
        expect(find.byKey(const Key('admin-account')), findsNothing);
        expect(find.byKey(const Key('admin-enrollment-grant')), findsNothing);
      } else {
        expect(find.text('Ready for activation.'), findsOneWidget);
        expect(find.byKey(const Key('admin-enrollment-grant')), findsNothing);
        expect(find.text('Register security key'), findsNothing);
        await expectLater(auth.enroll('a' * 43), throwsA(isA<Exception>()));
      }
      expect(container.read(accessTokenProvider), isNull);
      expect(paths.length, slots.length == 1 ? 4 : 2);
      expect(tester.takeException(), isNull);
    });
  }
}
