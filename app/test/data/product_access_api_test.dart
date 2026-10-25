import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/product_access_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'onboarding timeout covers a stalled response body and allows retry',
    () {
      fakeAsync((clock) {
        final body = StreamController<List<int>>();
        var calls = 0;
        final client = MockClient.streaming((request, _) async {
          calls++;
          expect(request.method, 'POST');
          expect(request.url.path, '/onboarding/complete');
          expect(request.headers['authorization'], 'Bearer user-session');
          return http.StreamedResponse(
            calls == 1
                ? body.stream
                : Stream.value(utf8.encode('{"completed":true}')),
            200,
          );
        });
        final api = ProductAccessApi(
          apiBaseUrl: 'https://api.test',
          accessToken: 'user-session',
          client: client,
        );
        Object? error;
        var completed = false;
        api.completeOnboarding().then<void>(
          (_) {
            completed = true;
          },
          onError: (Object value) {
            error = value;
          },
        );
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 14));
        expect(error, isNull);
        expect(completed, isFalse);
        clock.elapse(const Duration(seconds: 1));
        expect(error, isA<TimeoutException>());
        expect(completed, isFalse);

        api.completeOnboarding().then((_) => completed = true);
        clock.flushMicrotasks();
        expect(calls, 2);
        expect(completed, isTrue);
        body.add(utf8.encode('{"completed":true}'));
        body.close();
        clock.flushMicrotasks();
        client.close();
      });
    },
  );

  test('onboarding requires a successful server acknowledgement', () async {
    for (final response in [
      http.Response('{"completed":false}', 200),
      http.Response('{"completed":true}', 500),
    ]) {
      final client = MockClient((_) async => response);
      addTearDown(client.close);
      final api = ProductAccessApi(
        apiBaseUrl: 'https://api.test',
        accessToken: 'user-session',
        client: client,
      );
      await expectLater(api.completeOnboarding(), throwsA(isA<ApiException>()));
    }
  });

  test(
    'recovers from required_terms_missing by granting terms consent and retrying',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.method == 'POST' &&
            request.url.path == '/onboarding/complete') {
          if (requests
                  .where((r) => r.url.path == '/onboarding/complete')
                  .length ==
              1) {
            return http.Response(
              jsonEncode({'error': 'required_terms_missing'}),
              409,
            );
          }
          return http.Response(jsonEncode({'completed': true}), 200);
        }
        if (request.method == 'POST' && request.url.path == '/consents') {
          return http.Response(jsonEncode({'status': 'created'}), 201);
        }
        return http.Response('Not Found', 404);
      });
      addTearDown(client.close);

      final api = ProductAccessApi(
        apiBaseUrl: 'https://api.test',
        accessToken: 'user-session',
        client: client,
      );

      await api.completeOnboarding();

      expect(requests.length, 3);
      expect(requests[0].url.path, '/onboarding/complete');
      expect(requests[0].method, 'POST');
      expect(requests[0].headers['authorization'], 'Bearer user-session');

      expect(requests[1].url.path, '/consents');
      expect(requests[1].method, 'POST');
      expect(requests[1].headers['authorization'], 'Bearer user-session');
      final consentBody = jsonDecode(requests[1].body) as Map<String, dynamic>;
      expect(consentBody, {
        'purpose': 'terms',
        'granted': true,
        'policyVersion': appProductTermsVersion,
        'sourceScreen': 'onboarding_complete',
      });

      expect(requests[2].url.path, '/onboarding/complete');
      expect(requests[2].method, 'POST');
      expect(requests[2].headers['authorization'], 'Bearer user-session');
    },
  );

  test(
    'throws ApiException if consent retry fails after required_terms_missing',
    () async {
      final client = MockClient((request) async {
        if (request.url.path == '/onboarding/complete') {
          return http.Response(
            jsonEncode({'error': 'required_terms_missing'}),
            409,
          );
        }
        if (request.url.path == '/consents') {
          return http.Response(jsonEncode({'error': 'consent_failed'}), 500);
        }
        return http.Response('Not Found', 404);
      });
      addTearDown(client.close);

      final api = ProductAccessApi(
        apiBaseUrl: 'https://api.test',
        accessToken: 'user-session',
        client: client,
      );

      await expectLater(
        api.completeOnboarding(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having(
                (e) => e.errorCode,
                'errorCode',
                'required_terms_missing',
              ),
        ),
      );
    },
  );

  group('friendlyMessageFrom', () {
    test(
      'formats required_terms_missing into a user-friendly message rather than snake_case',
      () {
        const errorJson =
            'POST /onboarding/complete failed: 409 {"error":"required_terms_missing"}';
        final message = ApiException.friendlyMessageFrom(errorJson);
        expect(message, 'Please accept the terms to complete setup.');
        expect(message.contains('required_terms_missing'), isFalse);

        final exception = ApiException(errorJson);
        expect(
          exception.userMessage,
          'Please accept the terms to complete setup.',
        );
        expect(exception.errorCode, 'required_terms_missing');
        expect(exception.statusCode, 409);
      },
    );

    test('formats required_terms_missing from message property as well', () {
      const errorJson =
          'POST /onboarding/complete failed: 409 {"message":"required_terms_missing"}';
      expect(
        ApiException.friendlyMessageFrom(errorJson),
        'Please accept the terms to complete setup.',
      );
    });

    test('formats other raw snake_case errors into generic friendly message', () {
      const errorJson =
          'POST /onboarding/complete failed: 400 {"error":"unknown_error_code"}';
      final message = ApiException.friendlyMessageFrom(errorJson);
      expect(message, 'Something went wrong. Please try again.');
      expect(message.contains('unknown_error_code'), isFalse);
    });
  });

  group('invitation link handling', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('accepts only PandaPay invite links and normalizes their code', () {
      expect(
        invitationCodeFromUri(Uri.parse('https://pandapay.app/i/panda-abc123')),
        'PANDA-ABC123',
      );
      expect(
        invitationCodeFromUri(Uri.parse('pandapay://i/PANDA-ABC123')),
        'PANDA-ABC123',
      );
      expect(
        invitationCodeFromUri(Uri.parse('https://example.com/i/PANDA-ABC123')),
        isNull,
      );
      expect(
        invitationCodeFromUri(Uri.parse('pandapay://assistant/wallet')),
        isNull,
      );
    });

    test(
      'does not replace a captured invite without explicit confirmation',
      () async {
        final store = PendingInvitationStore();
        final first = await store.capture('PANDA-AAA111');
        final second = await store.capture('PANDA-BBB222');

        expect(first?.status, InvitationCaptureStatus.stored);
        expect(second?.status, InvitationCaptureStatus.conflict);
        expect(second?.existingCode, 'PANDA-AAA111');
        expect(await store.read(), 'PANDA-AAA111');

        expect(await store.replace('PANDA-BBB222'), 'PANDA-BBB222');
        expect(await store.clearIfMatches('PANDA-AAA111'), isFalse);
        expect(await store.clearIfMatches('PANDA-BBB222'), isTrue);
        expect(await store.read(), isNull);
      },
    );
  });

  test(
    'activation sends only explicit true choices and a checked invite',
    () async {
      late Map<String, dynamic> sentBody;
      final api = ProductAccessApi(
        apiBaseUrl: 'https://api.test',
        accessToken: 'user-session',
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/profile');
          expect(request.headers['authorization'], 'Bearer user-session');
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({'state': 'active'}), 201);
        }),
      );

      await api.activate(
        invitationCode: 'panda-abc123',
        invitationPreviewToken: 'signed-preview',
        acceptRewardTerms: false,
        acceptAccessOnly: true,
        acceptProductTerms: true,
        productTermsVersion: 'terms-v1',
      );

      expect(sentBody, {
        'invitationCode': 'PANDA-ABC123',
        'invitationPreviewToken': 'signed-preview',
        'acceptAccessOnly': true,
        'acceptProductTerms': true,
        'productTermsVersion': 'terms-v1',
      });
      expect(sentBody.containsKey('acceptRewardTerms'), isFalse);
    },
  );

  test('activation refuses an invite code that was not previewed', () async {
    final api = ProductAccessApi(
      apiBaseUrl: 'https://api.test',
      accessToken: 'user-session',
      client: MockClient((_) async => http.Response('{}', 201)),
    );

    await expectLater(
      api.activate(invitationCode: 'PANDA-ABC123'),
      throwsFormatException,
    );
  });
}
