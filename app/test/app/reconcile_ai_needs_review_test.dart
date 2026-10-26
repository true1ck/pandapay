import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_listener_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestInbox extends SmsListenerService {
  @override
  Future<bool> hasPermissions() async => true;

  @override
  void listenForeground(
    void Function(String sender, String body, DateTime receivedAt) onSms,
  ) {}

  @override
  Future<int> inboxHeadId() async => 0;

  @override
  Future<SmsInboxPage> readInboxPage({
    required int afterId,
    required int throughId,
    int pageSize = 200,
  }) async {
    return const SmsInboxPage([], 0, 0);
  }
}

class _MockUserCardsRepository extends UserCardsRepository {
  _MockUserCardsRepository()
    : super(
        apiBaseUrl: 'https://api.test',
        accessToken: 'session-token',
        client: MockClient((_) async => http.Response('{}', 200)),
      );

  Future<Map<String, dynamic>?> Function(String sourceKey)? onFetchAiJobStatus;
  Future<String?> Function({
    required String sourceKey,
    required String sender,
    required String body,
    DateTime? occurredAt,
    bool? retryFailed,
  })?
  onSubmitAiJob;

  int fetchStatusCalls = 0;
  int submitJobCalls = 0;

  @override
  Future<Map<String, dynamic>?> fetchAiJobStatus(String sourceKey) async {
    fetchStatusCalls++;
    if (onFetchAiJobStatus != null) {
      return onFetchAiJobStatus!(sourceKey);
    }
    return null;
  }

  @override
  Future<String?> submitAiJob({
    required String sourceKey,
    required String sender,
    required String body,
    DateTime? occurredAt,
    bool retryFailed = false,
  }) async {
    submitJobCalls++;
    if (onSubmitAiJob != null) {
      return onSubmitAiJob!(
        sourceKey: sourceKey,
        sender: sender,
        body: body,
        occurredAt: occurredAt,
        retryFailed: retryFailed ?? false,
      );
    }
    return 'default-job-id';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const namespace = 'user:reconcile-ai-test';
  final testItemId = List.filled(64, 'e').join();
  const testSender = 'VM-HDFCBK';
  const testBody =
      'INR 1,200.00 spent on your card ending 9876 at STARBUCKS on 2026-10-24. Avl bal: INR 45,000.';

  late AppDatabase db;
  late ResponseCache cache;
  late AuthenticatedHttpClient httpClient;
  late _MockUserCardsRepository mockRepo;
  late ProviderContainer container;

  setUp(() async {
    final repairKey = 'pandapay_app.sms_history_repaired_at_v2_$namespace';
    final reviewKey =
        'pandapay_app.sms_review_replayed_${LocalSmsParser.version}_$namespace';
    SharedPreferences.setMockInitialValues({repairKey: 1, reviewKey: true});

    db = openInMemoryForTesting();
    cache = ResponseCache(db);
    httpClient = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((_) async => http.Response('{}', 200)),
    );
    mockRepo = _MockUserCardsRepository();

    container = ProviderContainer(
      overrides: [
        cacheNamespaceProvider.overrideWithValue(namespace),
        appDatabaseProvider.overrideWith((ref) async => db),
        responseCacheProvider.overrideWith((ref) async => cache),
        isOnlineProvider.overrideWith((ref) => Stream.value(true)),
        smsListenerServiceProvider.overrideWithValue(_TestInbox()),
        authenticatedHttpClientProvider.overrideWithValue(httpClient),
        userCardsRepositoryProvider.overrideWithValue(mockRepo),
        myCardsProvider.overrideWith((ref) async => []),
      ],
    );

    // Read the background flush provider so its listeners and startup pass activate.
    container.read(smsBackgroundFlushProvider);
    // Allow startup pass to settle.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  tearDown(() {
    container.dispose();
    httpClient.close();
    cache.financialStore.dispose();
    db.close();
  });

  NeedsReviewItem makeReviewItem({
    AiReviewStatus aiStatus = AiReviewStatus.notChecked,
  }) {
    return NeedsReviewItem(
      id: testItemId,
      sender: testSender,
      receivedAt: DateTime.utc(2026, 10, 24, 10, 30),
      body: testBody,
      aiStatus: aiStatus,
    );
  }

  test(
    'a transient network exception during fetchAiJobStatus does NOT mark review item as unavailable',
    () async {
      final reviewRepo = container.read(needsReviewRepositoryProvider);
      await reviewRepo.add(makeReviewItem(aiStatus: AiReviewStatus.notChecked));

      final completer = Completer<void>();
      mockRepo.onFetchAiJobStatus = (sourceKey) {
        if (!completer.isCompleted) completer.complete();
        throw const SocketException(
          'Transient network error: connection refused',
        );
      };

      container.read(smsFlushTriggerProvider.notifier).state++;
      await completer.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mockRepo.fetchStatusCalls, greaterThanOrEqualTo(1));
      final items = await reviewRepo.fetchAll();
      expect(items, hasLength(1));
      expect(
        items.single.aiStatus,
        AiReviewStatus.notChecked,
        reason:
            'A transient network exception during fetchAiJobStatus must leave '
            'the item in its current status for retry, not mark it as unavailable.',
      );
    },
  );

  test(
    'a transient network exception during submitAiJob does NOT mark review item as unavailable',
    () async {
      final reviewRepo = container.read(needsReviewRepositoryProvider);
      await reviewRepo.add(makeReviewItem(aiStatus: AiReviewStatus.notChecked));

      final completer = Completer<void>();
      mockRepo.onFetchAiJobStatus = (sourceKey) async => null;
      mockRepo.onSubmitAiJob =
          ({
            required sourceKey,
            required sender,
            required body,
            occurredAt,
            retryFailed,
          }) {
            if (!completer.isCompleted) completer.complete();
            throw const SocketException(
              'Transient network error: host unreachable',
            );
          };

      container.read(smsFlushTriggerProvider.notifier).state++;
      await completer.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mockRepo.fetchStatusCalls, greaterThanOrEqualTo(1));
      expect(mockRepo.submitJobCalls, greaterThanOrEqualTo(1));
      final items = await reviewRepo.fetchAll();
      expect(items, hasLength(1));
      expect(
        items.single.aiStatus,
        AiReviewStatus.notChecked,
        reason:
            'A transient network exception during submitAiJob must leave '
            'the item in its current status for retry, not mark it as unavailable.',
      );
    },
  );

  test(
    'an explicit failure or refusal marks the review item as unavailable',
    () async {
      final reviewRepo = container.read(needsReviewRepositoryProvider);
      await reviewRepo.add(makeReviewItem(aiStatus: AiReviewStatus.notChecked));

      final completer = Completer<void>();
      mockRepo.onFetchAiJobStatus = (sourceKey) async => null;
      mockRepo.onSubmitAiJob =
          ({
            required sourceKey,
            required sender,
            required body,
            occurredAt,
            retryFailed,
          }) async {
            if (!completer.isCompleted) completer.complete();
            // Server explicit refusal: 429 quota exhausted or 400 bad format returns null
            return null;
          };

      container.read(smsFlushTriggerProvider.notifier).state++;
      await completer.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mockRepo.fetchStatusCalls, greaterThanOrEqualTo(1));
      expect(mockRepo.submitJobCalls, greaterThanOrEqualTo(1));
      final items = await reviewRepo.fetchAll();
      expect(items, hasLength(1));
      expect(
        items.single.aiStatus,
        AiReviewStatus.unavailable,
        reason:
            'An explicit server refusal or job rejection must mark the item as unavailable.',
      );
    },
  );

  test(
    'a terminal server failed status is not resubmitted and stays unavailable',
    () async {
      final reviewRepo = container.read(needsReviewRepositoryProvider);
      await reviewRepo.add(makeReviewItem(aiStatus: AiReviewStatus.notChecked));

      final completer = Completer<void>();
      mockRepo.onFetchAiJobStatus = (sourceKey) async {
        if (!completer.isCompleted) completer.complete();
        return {'status': 'failed'};
      };

      container.read(smsFlushTriggerProvider.notifier).state++;
      await completer.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final items = await reviewRepo.fetchAll();
      expect(items, hasLength(1));
      expect(mockRepo.submitJobCalls, 0);
      expect(
        items.single.aiStatus,
        AiReviewStatus.unavailable,
        reason:
            'A terminal failed job must not be reopened during reconciliation.',
      );
    },
  );

  test(
    'incrementing smsFlushTriggerProvider triggers flushAndRetry and reconciles pending items',
    () async {
      final reviewRepo = container.read(needsReviewRepositoryProvider);
      await reviewRepo.add(makeReviewItem(aiStatus: AiReviewStatus.notChecked));

      // Before triggering, item is not checked.
      var items = await reviewRepo.fetchAll();
      expect(items.single.aiStatus, AiReviewStatus.notChecked);

      final completer = Completer<void>();
      mockRepo.onFetchAiJobStatus = (sourceKey) async => null;
      mockRepo.onSubmitAiJob =
          ({
            required sourceKey,
            required sender,
            required body,
            occurredAt,
            retryFailed,
          }) async {
            if (!completer.isCompleted) completer.complete();
            return 'job-queued-789';
          };

      // Trigger on-demand flush.
      container.read(smsFlushTriggerProvider.notifier).state++;
      await completer.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mockRepo.fetchStatusCalls, greaterThanOrEqualTo(1));
      expect(mockRepo.submitJobCalls, 1);

      items = await reviewRepo.fetchAll();
      expect(items, hasLength(1));
      expect(
        items.single.aiStatus,
        AiReviewStatus.queued,
        reason:
            'Incrementing smsFlushTriggerProvider should trigger flushAndRetry '
            'and transition pending items to queued.',
      );
    },
  );

  test(
    'completed Gemini decision files the transaction and creates Auto-Resolved history',
    () async {
      final reviewRepo = container.read(needsReviewRepositoryProvider);
      await reviewRepo.add(makeReviewItem(aiStatus: AiReviewStatus.notChecked));
      final completed = Completer<void>();
      mockRepo.onFetchAiJobStatus = (sourceKey) async {
        if (!completed.isCompleted) completed.complete();
        return {
          'status': 'done',
          'decision': {
            'topic': 'card_spend',
            'shouldConsider': true,
            'rejectionReason': 'none',
          },
          'result': {'confidenceScore': 0.99, 'reviewRequired': false},
          'suggestions': [
            {
              'factIndex': 0,
              'factType': 'posted_movement',
              'payload': {
                'amountRole': 'posted',
                'entryKind': 'spend',
                'amountInr': 1200.0,
                'occurredAt': '2026-10-24T00:00:00.000Z',
                'instrument': 'upi_bank',
                'accountLast4': '9876',
                'issuerName': 'HDFC Bank',
                'merchant': 'STARBUCKS',
                'category': 'dining',
                'isComplete': true,
                'confidence': 0.99,
              },
            },
          ],
        };
      };

      container.read(smsFlushTriggerProvider.notifier).state++;
      await completed.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mockRepo.submitJobCalls, 0);
      expect(await reviewRepo.fetchAll(), isEmpty);
      expect(
        cache.financialStore.entities(namespace, 'transactions'),
        hasLength(1),
      );
      expect(
        db.db.select(
          'SELECT resolved_kind, title FROM local_auto_resolved_history WHERE namespace=?',
          [namespace],
        ),
        hasLength(1),
      );
    },
  );
}
