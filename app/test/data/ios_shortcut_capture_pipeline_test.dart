import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_listener_service.dart';

class _NoAndroidInbox extends SmsListenerService {
  @override
  Future<int> inboxHeadId() async =>
      throw StateError('iOS must not read Android inbox');
  @override
  Future<bool> hasPermissions() async => false;
}

void main() {
  test(
    'Shortcut input joins the existing capture owner and unchanged batch API',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = openInMemoryForTesting();
      final cache = ResponseCache(db);
      const namespace = 'user:account-a';
      const body =
          'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.\nRef TEST-42';
      const sender = 'VM-ICICIB';
      final occurredAt = DateTime.utc(2026, 9, 30, 14, 40, 51, 277);
      final uploads = <Map<String, dynamic>>[];
      final client = AuthenticatedHttpClient(
        refreshAccessToken: () async => null,
        inner: MockClient((request) async {
          if (request.method == 'POST') {
            expect(request.url.path, '/transactions/from-sms/batch');
            uploads.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({
                'summary': {'imported': 1},
                'results': [
                  {
                    'index': 0,
                    'outcome': 'imported',
                    'transactionId': 'server-1',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'transactions': [
                {
                  'id': 'server-1',
                  'source_key': smsSourceKey(namespace, sender, body),
                  'amount_inr': 250,
                  'occurred_at': occurredAt.toIso8601String(),
                  'status': 'active',
                  'source': 'sms',
                },
              ],
            }),
            200,
          );
        }),
      );
      final token =
          'e30.${base64Url.encode(utf8.encode('{"sub":"account-a"}')).replaceAll('=', '')}.sig';
      final scope = ProviderContainer(
        overrides: [
          accessTokenProvider.overrideWith((ref) => token),
          responseCacheProvider.overrideWith((ref) async => cache),
          smsListenerServiceProvider.overrideWithValue(_NoAndroidInbox()),
          authenticatedHttpClientProvider.overrideWithValue(client),
          isOnlineProvider.overrideWith((ref) => Stream.value(true)),
        ],
      );
      addTearDown(() {
        scope.dispose();
        client.close();
        cache.financialStore.dispose();
        db.close();
      });
      await scope.read(isOnlineProvider.future);
      final owner = scope.read(smsAutoImportProvider);
      final result = await owner.captureShortcutMessages(
        expectedNamespace: namespace,
        records: [
          {
            'body': body,
            'sender': sender,
            'receivedAt': '2026-09-30T20:10:51.277+05:30',
          },
        ],
      );
      expect(result.messages, hasLength(1));
      expect(uploads, isEmpty);
      final saved = SmsIntakeRepository(db).pending(namespace).single.message;
      expect(saved.body, body);
      expect(saved.sender, sender);
      expect(saved.receivedAt.toUtc(), occurredAt);
      await owner.syncPendingMessages();
      expect(uploads, [
        {
          'backfill': true,
          'messages': [
            {
              'sender': sender,
              'body': body,
              'occurredAt': occurredAt.toIso8601String(),
            },
          ],
        },
      ]);
      expect(SmsIntakeRepository(db).pending(namespace), isEmpty);
      await expectLater(
        owner.captureShortcutMessages(
          expectedNamespace: 'user:other-account',
          records: [],
        ),
        throwsStateError,
      );
    },
  );
}
