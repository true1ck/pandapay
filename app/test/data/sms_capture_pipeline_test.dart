import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_inbox_scanner.dart';
import 'package:pandapay/features/sms_import/sms_listener_service.dart';

class _Inbox extends SmsListenerService {
  final rows = <InboxSms>[];
  final queries = <int>[];
  int heads = 0;
  @override
  Future<bool> hasPermissions() async => true;
  @override
  Future<int> inboxHeadId() async {
    heads++;
    return rows.isEmpty ? 0 : rows.last.id!;
  }

  @override
  Future<SmsInboxPage> readInboxPage({
    required int afterId,
    required int throughId,
    int pageSize = 200,
  }) async {
    queries.add(afterId);
    final page = rows
        .where((r) => r.id! > afterId && r.id! <= throughId)
        .take(pageSize)
        .toList();
    return SmsInboxPage(page, page.last.id!, page.length);
  }
}

void main() {
  test(
    'offline capture is finalized locally and API retries never rescan the inbox',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = openInMemoryForTesting();
      final cache = ResponseCache(db);
      final inbox = _Inbox();
      const namespace = 'user:account-a';
      const body = 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY.';
      inbox.rows.add(
        InboxSms(
          id: 1,
          sender: 'VM-ICICIB',
          body: body,
          receivedAt: DateTime.now(),
        ),
      );
      var requests = 0;
      var uploads = 0;
      var online = false;
      var failApi = true;
      final client = AuthenticatedHttpClient(
        refreshAccessToken: () async => null,
        inner: MockClient((request) async {
          requests++;
          if (request.method == 'POST') uploads++;
          if (failApi) throw http.ClientException('API unavailable');
          if (request.method == 'POST') {
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
                  'source_key': smsSourceKey(namespace, 'VM-ICICIB', body),
                  'amount_inr': 250,
                  'occurred_at': DateTime.now().toIso8601String(),
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
          smsListenerServiceProvider.overrideWithValue(inbox),
          authenticatedHttpClientProvider.overrideWithValue(client),
          isOnlineProvider.overrideWith((ref) => Stream.value(online)),
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
      await Future.wait([
        owner.captureExistingInbox(),
        owner.captureExistingInbox(),
      ]);
      expect(inbox.queries, [0]);
      expect(requests, 0);
      expect(SmsInboxProgress(db).initialComplete(namespace), isTrue);
      expect(SmsInboxProgress(db).lastId(namespace), 1);
      expect(
        (await scope.read(pendingRecoveryStatusProvider.future))['sms'],
        1,
      );
      expect(
        cache.financialStore
            .transactions(namespace, const TransactionQuery())!
            .rows
            .single
            .amount
            .rupees,
        250,
      );
      await owner.syncPendingMessages();
      expect(requests, 0);

      online = true;
      scope.invalidate(isOnlineProvider);
      await scope.read(isOnlineProvider.future);
      await owner.syncPendingMessages();
      expect(requests, 1);
      expect(SmsIntakeRepository(db).pending(namespace), hasLength(1));
      expect(SmsInboxProgress(db).lastId(namespace), 1);
      expect(await owner.capturedSmsBodies(), [body]);
      expect(inbox.queries, [0]);

      failApi = false;
      // Advance the persisted retry deadline without waiting on wall-clock time.
      db.db.execute('UPDATE sms_intake SET next_attempt=0 WHERE namespace=?', [
        namespace,
      ]);
      await owner.syncPendingMessages();
      expect(SmsIntakeRepository(db).pending(namespace), isEmpty);
      expect(
        (await scope.read(pendingRecoveryStatusProvider.future))['sms'],
        0,
      );
      expect(SmsIntakeRepository(db).capturedBodies(namespace), [body]);
      expect(
        cache.financialStore
            .transactions(namespace, const TransactionQuery())!
            .rows
            .single
            .id,
        'server-1',
      );
      final afterUpload = uploads;
      await owner.syncPendingMessages();
      await owner.capturedSmsBodies();
      expect(uploads, afterUpload);
      expect(inbox.queries, [0]);
    },
  );

  test(
    'unmatched financial SMS stays in Needs Review when Gemini queue accepts or refuses it',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = openInMemoryForTesting();
      final cache = ResponseCache(db);
      final inbox = _Inbox();
      const namespace = 'user:account-a';
      const sender = 'VM-HDFCBK';
      var aiIndex = 0;
      final requests = <http.Request>[];
      final client = AuthenticatedHttpClient(
        refreshAccessToken: () async => null,
        inner: MockClient((request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/transactions/from-sms/batch':
              return http.Response(
                jsonEncode({
                  'summary': {'needsReview': 2},
                  'results': [
                    {
                      'index': 0,
                      'outcome': 'needs_review',
                      'reason': 'ambiguous_account_debit',
                    },
                    {
                      'index': 1,
                      'outcome': 'needs_review',
                      'reason': 'unparseable_amount',
                    },
                  ],
                }),
                200,
              );
            case '/transactions':
              return http.Response(jsonEncode({'transactions': []}), 200);
            case '/ai/jobs':
              return http.Response(
                jsonEncode({'jobId': 'synthetic-job', 'reused': false}),
                [200, 503][aiIndex++],
              );
            default:
              return http.Response('unexpected ${request.method} ${request.url.path}', 404);
          }
        }),
      );
      final token =
          'e30.${base64Url.encode(utf8.encode('{"sub":"account-a"}')).replaceAll('=', '')}.sig';
      final scope = ProviderContainer(
        overrides: [
          accessTokenProvider.overrideWith((ref) => token),
          responseCacheProvider.overrideWith((ref) async => cache),
          smsListenerServiceProvider.overrideWithValue(inbox),
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

      final bodies = [
        'Your credit card XX1234 was charged at AMAZON on 24-10-26.',
        'Your credit card XX5678 was charged at SWIGGY on 24-10-26.',
      ];
      for (var i = 0; i < bodies.length; i++) {
        inbox.rows.add(
          InboxSms(
            id: i + 1,
            sender: sender,
            body: bodies[i],
            receivedAt: DateTime(2026, 10, 24, 10, i),
          ),
        );
      }
      final owner = scope.read(smsAutoImportProvider);
      await owner.captureExistingInbox();
      final summary = await owner.syncPendingMessages();
      await Future<void>.delayed(Duration.zero);

      expect(summary.needsReview, 2);
      final aiRequests = requests
          .where((request) => request.url.path == '/ai/jobs')
          .toList();
      expect(aiRequests, hasLength(2));
      for (var i = 0; i < bodies.length; i++) {
        final body = bodies[i];
        final aiBody = jsonDecode(aiRequests[i].body) as Map<String, dynamic>;
        expect(aiBody['sourceKey'], smsSourceKey(namespace, sender, body));
        expect(aiBody['body'], body);
      }
      final reviewItems = await scope
          .read(needsReviewRepositoryProvider)
          .fetchAll();
      expect(reviewItems.map((item) => item.body).toSet(), bodies.toSet());
      expect(SmsIntakeRepository(db).pending(namespace), isEmpty);
      expect(inbox.queries, [0]);
    },
  );
}
