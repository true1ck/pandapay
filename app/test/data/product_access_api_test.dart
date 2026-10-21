import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/product_access_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
