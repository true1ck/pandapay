import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/data/consents_api.dart';
import 'package:pandapay/features/auth/login_screen.dart';
import 'package:pandapay/data/product_access_api.dart';
import 'package:pandapay/features/auth/product_activation_screen.dart';
import 'package:pandapay/app/router.dart';

class _AlreadyActiveProductAccess implements ProductAccessRepository {
  @override
  Future<ProductAccessPolicy> loadPolicy() async =>
      const ProductAccessPolicy(admissionMode: 'open');

  @override
  Future<ProductAccessState> loadAccess() async =>
      const ProductAccessState(state: 'active');

  @override
  Future<InvitationPreview?> validateInvitation(String code) async => null;

  @override
  Future<Map<String, dynamic>> activate({
    String? invitationCode,
    String? invitationPreviewToken,
    bool? acceptRewardTerms,
    bool? acceptAccessOnly,
    bool? acceptProductTerms,
    String? productTermsVersion,
  }) async => const {};

  @override
  Future<void> completeOnboarding() async {}
}

/// A4: DPDP §8.2 purpose-specific consent checkboxes on sign-up. Verifies
/// (1) the required Terms checkbox actually gates submission, and (2) a
/// successful sign-up carries purpose choices across OTP and records one POST
/// /consents call per purpose only after server activation.
void main() {
  setUp(() {
    // TokenStore reads real SharedPreferences on every save() call
    // (_verifyOtp's success path) — without mock initial values the
    // platform channel call in a widget test can hang pumpAndSettle.
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap({
    required List<Override> overrides,
    AuthMode mode = AuthMode.signUp,
  }) {
    // router.dart wraps LoginScreen in a Scaffold for real (see its own
    // GoRoute for AppRoute.signUp) — LoginScreen itself is a bare Container,
    // so TextField/CheckboxListTile need that same Material ancestor here.
    return ProviderScope(
      overrides: [
        // OTP verification attaches device metadata in production. Keep this
        // widget test independent of the host's native package-info channel.
        localDeviceIdProvider.overrideWith((ref) async => 'test-device'),
        deviceMetadataProvider.overrideWith(
          (ref) async => const {'platform': 'test'},
        ),
        ...overrides,
      ],
      child: MaterialApp(
        home: Scaffold(body: LoginScreen(mode: mode)),
      ),
    );
  }

  testWidgets(
    'an active OTP opens the code field instead of trapping the user on Send code',
    (tester) async {
      final authApi = AuthApi(
        authBaseUrl: 'http://auth.test',
        client: MockClient((req) async {
          return http.Response(
            jsonEncode({
              'success': false,
              'message':
                  'An OTP is already active. Please wait a moment before requesting a new one.',
            }),
            429,
          );
        }),
      );

      await tester.pumpWidget(
        wrap(
          mode: AuthMode.logIn,
          overrides: [authApiProvider.overrideWithValue(authApi)],
        ),
      );
      await tester.enterText(find.byType(TextField).at(0), 'sujay@example.com');
      await tester.enterText(find.byType(TextField).at(1), '9876543210');
      await tester.tap(find.text('Send code'));
      await tester.pumpAndSettle();

      expect(find.text('Verification code'), findsOneWidget);
      expect(
        find.text('A code was already sent. Enter that code below.'),
        findsOneWidget,
      );
      expect(find.text('Verify & continue'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      final codeField = tester.widget<TextField>(find.byType(TextField));
      expect(codeField.autofillHints, const [AutofillHints.oneTimeCode]);
      expect(codeField.focusNode?.hasFocus, isTrue);
      await tester.enterText(find.byType(TextField), '12a345');
      expect(codeField.controller!.text, '1234');
    },
  );

  testWidgets(
    'Send code is a no-op and shows a validation message when Terms is unchecked',
    (tester) async {
      var otpRequested = false;
      final authApi = AuthApi(
        authBaseUrl: 'http://auth.test',
        client: MockClient((req) async {
          otpRequested = true;
          return http.Response('{}', 200);
        }),
      );

      await tester.pumpWidget(
        wrap(overrides: [authApiProvider.overrideWithValue(authApi)]),
      );

      await tester.enterText(
        find.byType(TextField).at(0),
        'newuser@example.com',
      );
      await tester.enterText(find.byType(TextField).at(1), '9876543210');
      // Terms checkbox left unchecked deliberately.
      await tester.ensureVisible(find.text('Send verification code'));
      await tester.tap(find.text('Send verification code'));
      await tester.pumpAndSettle();

      expect(otpRequested, isFalse);
      expect(find.textContaining('accept the Terms'), findsOneWidget);
    },
  );

  testWidgets(
    'sign-up stores consent choices at OTP and records them after activation',
    (tester) async {
      final otpClient = MockClient((req) async {
        if (req.url.path.contains('request-email-otp')) {
          return http.Response('{}', 200);
        }
        if (req.url.path.contains('verify-email-otp')) {
          return http.Response(
            jsonEncode({'access_token': 'tok-abc', 'refresh_token': 'ref-abc'}),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      final authApi = AuthApi(
        authBaseUrl: 'http://auth.test',
        client: otpClient,
      );

      final consentCalls = <Map<String, dynamic>>[];
      final consentsClient = MockClient((req) async {
        consentCalls.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response('{"consent":{}}', 201);
      });

      await tester.pumpWidget(
        wrap(
          overrides: [
            authApiProvider.overrideWithValue(authApi),
            consentsApiProvider.overrideWithValue(
              ConsentsApi(
                apiBaseUrl: 'http://api.test',
                accessToken: 'tok-abc',
                client: consentsClient,
              ),
            ),
          ],
        ),
      );

      await tester.enterText(
        find.byType(TextField).at(0),
        'newuser@example.com',
      );
      await tester.enterText(find.byType(TextField).at(1), '9876543210');
      await tester.ensureVisible(find.byType(CheckboxListTile).at(0));
      await tester.tap(find.byType(CheckboxListTile).at(0)); // required Terms
      await tester.pump();
      await tester.ensureVisible(find.text('Send verification code'));
      await tester.tap(find.text('Send verification code'));
      await tester.pumpAndSettle();

      // OTP step now showing.
      expect(find.text('Verification code'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '1234');
      await tester.tap(find.text('Verify & continue'));
      await tester.pumpAndSettle();

      // OTP verification does not create a profile or write the audit trail;
      // it safely persists the explicit choices across the activation gate.
      expect(consentCalls, isEmpty);
      final savedChoices = await PendingSignupChoicesStore().read();
      expect(savedChoices?.acceptProductTerms, isTrue);
      expect(savedChoices?.optInCrowdsource, isFalse);
      expect(savedChoices?.optInMarketing, isFalse);

      final router = GoRouter(
        initialLocation: AppRoute.productActivation,
        routes: [
          GoRoute(
            path: AppRoute.productActivation,
            builder: (_, _) => const ProductActivationScreen(),
          ),
          GoRoute(
            path: AppRoute.permissions,
            builder: (_, _) => const Scaffold(body: Text('Permissions')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('activation-provider-scope'),
          overrides: [
            accessTokenProvider.overrideWith((ref) => 'tok-abc'),
            productAccessApiProvider.overrideWithValue(
              _AlreadyActiveProductAccess(),
            ),
            consentsApiProvider.overrideWithValue(
              ConsentsApi(
                apiBaseUrl: 'http://api.test',
                accessToken: 'tok-abc',
                client: consentsClient,
              ),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(consentCalls.length, 3);
      final purposes = consentCalls.map((c) => c['purpose']).toSet();
      expect(purposes, {'terms', 'crowdsource', 'marketing'});

      final terms = consentCalls.firstWhere((c) => c['purpose'] == 'terms');
      expect(terms['granted'], isTrue);
      expect(terms['sourceScreen'], 'A4');

      // Crowdsource/marketing were left unchecked in this test.
      final crowdsource = consentCalls.firstWhere(
        (c) => c['purpose'] == 'crowdsource',
      );
      expect(crowdsource['granted'], isFalse);
      expect(await PendingSignupChoicesStore().read(), isNull);
    },
  );
}
