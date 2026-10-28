import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/consents_api.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/auto_resolved_history_repository.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sms_feedback_outbox.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local/sms_learning_feedback.dart';
import 'package:pandapay/data/local/sms_rule_exposure_outbox.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/sms_learning_capture.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

const _namespace = 'user:matrix';
const _sender = 'HDFCBK';
const _body = 'Rs 1,500.00 debited to SWIGGY from A/C  XXXX4321 on 28-10-2026';
final _occurredAt = DateTime.utc(2026, 10, 28, 6, 30);

// Derived, never pasted: capture() keys the intake row with this exact
// function, so a literal here would silently drift from what is stored.
final _sourceKey = smsSourceKey(_namespace, _sender, _body);

class _RecordingRepository implements UserCardsRepository {
  int flushes = 0;

  @override
  Future<int> flushSmsLearningFeedbackQueue() {
    flushes++;
    return Future.value(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Harness extends ConsumerStatefulWidget {
  const _Harness({required this.onRef});
  final ValueChanged<WidgetRef> onRef;

  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  @override
  void initState() {
    super.initState();
    widget.onRef(ref);
  }

  @override
  Widget build(BuildContext context) {
    // The capture path reads these synchronously with ref.read(...).valueOrNull.
    // Unwatched they are still AsyncLoading and the code under test would take
    // a different branch than it does on a mounted screen.
    ref.watch(categoriesProvider);
    ref.watch(isOnlineProvider);
    ref.watch(smsSharedLearningConsentProvider);
    return const SizedBox.shrink();
  }
}

class _Fixture {
  _Fixture({
    required this.ref,
    required this.database,
    required this.repository,
  });

  final WidgetRef ref;
  final AppDatabase database;
  final _RecordingRepository repository;

  SmsFeedbackOutbox get outbox =>
      SmsFeedbackOutbox(database, namespace: _namespace);
}

Future<_Fixture> _pump(
  WidgetTester tester, {
  required ConsentRecord? consent,
  required AppDatabase database,
  List<SpendCategory> categories = const [],
  bool online = true,
}) async {
  late final WidgetRef capturedRef;
  final repository = _RecordingRepository();
  final cache = ResponseCache(database);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        cacheNamespaceProvider.overrideWithValue(_namespace),
        responseCacheProvider.overrideWith((ref) async => cache),
        userCardsRepositoryProvider.overrideWithValue(repository),
        categoriesProvider.overrideWith((ref) async => categories),
        isOnlineProvider.overrideWith((ref) => Stream.value(online)),
        smsSharedLearningConsentProvider.overrideWith((ref) async => consent),
      ],
      child: MaterialApp(
        home: _Harness(onRef: (ref) => capturedRef = ref),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Fixture(ref: capturedRef, database: database, repository: repository);
}

ConsentRecord _granted({
  String policyVersion = smsSharedLearningPolicyVersion,
  DateTime? grantedAt,
}) => ConsentRecord(
  purpose: smsSharedLearningPurpose,
  granted: true,
  grantedAt: grantedAt ?? DateTime.utc(2026, 10, 1),
  policyVersion: policyVersion,
);

TransactionEntry _smsEntry({
  String id = 't-sms',
  String source = 'sms',
  String? sourceKey,
  String? categoryId = 'cat-dining',
}) => TransactionEntry(
  id: id,
  sourceKey: sourceKey ?? _sourceKey,
  amount: Money.fromRupees(1500),
  occurredAt: _occurredAt,
  merchantName: 'SWIGGY from A/C',
  categoryId: categoryId,
  source: source,
  status: 'active',
);

void main() {
  const canonicalCategories = [
    SpendCategory(id: 'cat-dining', slug: 'dining', name: 'Dining'),
    SpendCategory(id: 'cat-online', slug: 'online', name: 'Online Shopping'),
  ];

  Future<void> captureSms(
    AppDatabase database, {
    String sender = _sender,
    String body = _body,
  }) async {
    SmsIntakeRepository(database).capture(
      _namespace,
      QueuedSms(sender: sender, body: body, receivedAt: _occurredAt),
    );
    expect(
      SmsIntakeRepository(database)
          .capturedById(_namespace, smsSourceKey(_namespace, sender, body)),
      isNotNull,
    );
  }

  testWidgets('no consent keeps the correction entirely local', (tester) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    final fixture = await _pump(
      tester,
      database: database,
      consent: null,
      categories: canonicalCategories,
    );
    await queueSmsTransactionCorrection(
      ref: fixture.ref,
      original: _smsEntry(),
      action: 'category_changed',
      correctedFields: const {'categorySlug': 'dining'},
      correctionKind: 'misclassified_category',
    );

    expect(fixture.outbox.count(), 0);
    expect(fixture.repository.flushes, 0);
  });

  testWidgets(
    'repeated identical SMS occurrences abstain from shared learning for every fact',
    (tester) async {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      await captureSms(database);
      final intake = SmsIntakeRepository(database);
      expect(intake.hasRepeatedOccurrence(_namespace, _sourceKey), isFalse);
      intake.capture(
        _namespace,
        QueuedSms(
          sender: _sender,
          body: _body,
          receivedAt: _occurredAt.add(const Duration(days: 1)),
        ),
      );
      expect(intake.hasRepeatedOccurrence(_namespace, _sourceKey), isTrue);
      expect(
        intake
                .capturedById(_namespace, _sourceKey)!
                .message
                .receivedAt
                .millisecondsSinceEpoch,
        _occurredAt.millisecondsSinceEpoch,
      );

      final fixture = await _pump(
        tester,
        database: database,
        consent: _granted(),
        categories: canonicalCategories,
      );
      await queueSmsLearningEvent(
        ref: fixture.ref,
        sourceKey: _sourceKey,
        action: 'edited',
        resolvedKind: 'transaction',
        occurredAtIso: _occurredAt.toIso8601String(),
        factIndex: 1,
      );
      await queueSmsTransactionCorrection(
        ref: fixture.ref,
        original: _smsEntry(),
        action: 'category_changed',
        correctedFields: const {'categorySlug': 'dining'},
        correctionKind: 'misclassified_category',
      );

      expect(fixture.outbox.count(), 0);
      expect(fixture.repository.flushes, 0);
    },
  );

  testWidgets(
    'consent on a stale policy version keeps it local',
    (tester) async {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      await captureSms(database);
      final fixture = await _pump(
        tester,
        database: database,
        consent: _granted(policyVersion: 'sms-shared-learning-v1'),
        categories: canonicalCategories,
      );

      await queueSmsTransactionCorrection(
        ref: fixture.ref,
        original: _smsEntry(),
        action: 'category_changed',
        correctedFields: const {'categorySlug': 'dining'},
        correctionKind: 'misclassified_category',
      );

      expect(fixture.outbox.count(), 0);
    },
  );

  testWidgets(
    'parser-origin category edit queues the full envelope',
    (tester) async {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      await captureSms(database);
      final fixture = await _pump(
        tester,
        database: database,
        consent: _granted(),
        categories: canonicalCategories,
      );

      await queueSmsTransactionCorrection(
        ref: fixture.ref,
        original: _smsEntry(),
        action: 'category_changed',
        correctedFields: const {'categorySlug': 'dining'},
        correctionKind: 'misclassified_category',
      );
      await tester.pump();

      final pending = fixture.outbox.pending();
      expect(pending, hasLength(1));
      final payload = pending.single.payload;
      expect(payload['sourceKey'], _sourceKey);
      expect(payload['action'], 'category_changed');
      expect(payload['correctionKind'], 'misclassified_category');
      expect(payload['decisionOrigin'], 'parser');
      expect(payload['resolvedKind'], 'transaction');
      expect(payload['sender'], 'HDFCBK');
      expect(payload['consentPurpose'], 'sms_shared_learning');
      expect(payload['consentPolicyVersion'], smsSharedLearningPolicyVersion);
      expect(payload['consentGrantedAt'], '2026-10-01T00:00:00.000Z');
      expect(payload['factIndex'], 0);
      expect(payload['correctedFields'], {'categorySlug': 'dining'});

      final originalDecision =
          payload['originalDecision'] as Map<String, dynamic>;
      expect(originalDecision['kind'], 'posted_movement');
      expect(originalDecision['origin'], 'parser');
      final fields =
          originalDecision['fields'] as Map<String, dynamic>;
      expect(fields['categorySlug'], 'dining');
      expect(fields['merchant'], 'SWIGGY from A/C');
      expect(fields['amountInr'], 1500);

      // The raw SMS never leaves the device unredacted.
      final sampleBody = payload['sampleBody'] as String;
      expect(sampleBody, isNot(contains('4321')));
      expect(sampleBody, isNot(contains('1,500')));
      expect(fixture.repository.flushes, 1);
    },
  );

  testWidgets('AI-origin transaction reports an ai decision origin', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    final fixture = await _pump(
      tester,
      database: database,
      consent: _granted(),
      categories: canonicalCategories,
    );
    AutoResolvedHistoryRepository(
      database,
      namespace: _namespace,
    ).record(
      AutoResolvedHistoryEntry(
        id: 'ai:$_sourceKey',
        namespace: _namespace,
        sourceKey: _sourceKey,
        factIndex: 9,
        sender: _sender,
        resolvedKind: 'transaction',
        title: 'SWIGGY',
        amountPaise: 150000,
        occurredAt: _occurredAt.toIso8601String(),
        confidence: 0.95,
        autoResolvedAt: 1,
      ),
    );

    await queueSmsTransactionCorrection(
      ref: fixture.ref,
      original: _smsEntry(id: 'local-ai:t1'),
      action: 'edited',
      correctedFields: const {'amountInr': 1200.0},
      correctionKind: 'wrong_amount',
    );
    await tester.pump();

    final payload = fixture.outbox.pending().single.payload;
    expect(payload['decisionOrigin'], 'ai');
    expect(payload['factIndex'], 9);
    expect(payload['correctionKind'], 'wrong_amount');
    final originalDecision =
        payload['originalDecision'] as Map<String, dynamic>;
    expect(originalDecision['origin'], 'ai');
  });

  testWidgets('legacy AI transaction without receipt fact index abstains', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    final fixture = await _pump(
      tester,
      database: database,
      consent: _granted(),
      categories: canonicalCategories,
    );
    AutoResolvedHistoryRepository(
      database,
      namespace: _namespace,
    ).record(
      AutoResolvedHistoryEntry(
        id: 'ai:$_sourceKey',
        namespace: _namespace,
        sourceKey: _sourceKey,
        sender: _sender,
        resolvedKind: 'transaction',
        title: 'SWIGGY',
        amountPaise: 150000,
        occurredAt: _occurredAt.toIso8601String(),
        confidence: 0.95,
        autoResolvedAt: 1,
      ),
    );

    await queueSmsTransactionCorrection(
      ref: fixture.ref,
      original: _smsEntry(id: 'local-ai:t1'),
      action: 'edited',
      correctedFields: const {'amountInr': 1200.0},
      correctionKind: 'wrong_amount',
    );

    expect(fixture.outbox.count(), 0);
    expect(fixture.repository.flushes, 0);
  });

  testWidgets('a non-SMS transaction never queues a learning event', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    final fixture = await _pump(
      tester,
      database: database,
      consent: _granted(),
      categories: canonicalCategories,
    );

    await queueSmsTransactionCorrection(
      ref: fixture.ref,
      original: _smsEntry(source: 'manual'),
      action: 'edited',
      correctedFields: const {'merchantName': 'Correct Store'},
      correctionKind: 'wrong_merchant',
    );

    expect(fixture.outbox.count(), 0);
    expect(fixture.repository.flushes, 0);
  });

  testWidgets('a malformed source key never queues a learning event', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    final fixture = await _pump(
      tester,
      database: database,
      consent: _granted(),
      categories: canonicalCategories,
    );

    await queueSmsTransactionCorrection(
      ref: fixture.ref,
      original: _smsEntry(sourceKey: 'local-not-a-hash'),
      action: 'edited',
      correctedFields: const {'merchantName': 'Correct Store'},
      correctionKind: 'wrong_merchant',
    );

    expect(fixture.outbox.count(), 0);
  });

  testWidgets(
    'an SMS no longer on the device keeps the correction local',
    (tester) async {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      // Deliberately skip captureSms: no intake row exists for _sourceKey.
      final fixture = await _pump(
        tester,
        database: database,
        consent: _granted(),
        categories: canonicalCategories,
      );

      await queueSmsTransactionCorrection(
        ref: fixture.ref,
        original: _smsEntry(),
        action: 'category_changed',
        correctedFields: const {'categorySlug': 'travel'},
        correctionKind: 'misclassified_category',
      );

      expect(fixture.outbox.count(), 0);
      expect(fixture.repository.flushes, 0);
    },
  );

  testWidgets('offline edit queues locally without a flush attempt', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    final fixture = await _pump(
      tester,
      database: database,
      consent: _granted(),
      categories: canonicalCategories,
      online: false,
    );

    await queueSmsTransactionCorrection(
      ref: fixture.ref,
      original: _smsEntry(),
      action: 'category_changed',
      correctedFields: const {'categorySlug': 'dining'},
      correctionKind: 'misclassified_category',
    );
    await tester.pump();

    expect(fixture.outbox.count(), 1);
    expect(fixture.repository.flushes, 0);
  });

  testWidgets('a custom category contributes no canonical slug', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    final fixture = await _pump(
      tester,
      database: database,
      consent: _granted(),
      // The transaction's category is absent from the canonical catalogue.
      categories: const [],
    );

    await queueSmsTransactionCorrection(
      ref: fixture.ref,
      original: _smsEntry(),
      action: 'category_changed',
      correctedFields: const {'userCategoryId': 'uc-custom'},
      correctionKind: 'misclassified_category',
    );
    await tester.pump();

    final payload = fixture.outbox.pending().single.payload;
    final fields =
        (payload['originalDecision'] as Map<String, dynamic>)['fields']
            as Map<String, dynamic>;
    expect(fields.containsKey('categorySlug'), isFalse);
    expect(payload['correctedFields'], {'userCategoryId': 'uc-custom'});
  });

  testWidgets(
    'a false-transaction dispute and a preference-only edit stay distinct',
    (tester) async {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      await captureSms(database);
      final fixture = await _pump(
        tester,
        database: database,
        consent: _granted(),
        categories: canonicalCategories,
      );

      await queueSmsTransactionCorrection(
        ref: fixture.ref,
        original: _smsEntry(),
        action: 'moved_to_review',
        correctedFields: const {},
        correctionKind: 'false_transaction',
        reason: 'not a real purchase',
        factIndex: 0,
      );
      await queueSmsTransactionCorrection(
        ref: fixture.ref,
        original: _smsEntry(),
        action: 'moved_to_review',
        correctedFields: const {},
        correctionKind: 'preference_only',
        reason: 'just tidying up',
        factIndex: 1,
      );
      await tester.pump();

      final byKind = {
        for (final entry in fixture.outbox.pending())
          entry.payload['correctionKind'] as String: entry.payload,
      };
      expect(byKind.keys, {'false_transaction', 'preference_only'});
      expect(byKind['false_transaction']!['reason'], 'not a real purchase');
      // Only disputes about correctness may train a shared rule.
      expect(smsNonTrainingCorrectionKinds, contains('preference_only'));
      expect(
        smsNonTrainingCorrectionKinds,
        isNot(contains('false_transaction')),
      );
    },
  );

  testWidgets('an identical retry collapses to one event', (tester) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    final fixture = await _pump(
      tester,
      database: database,
      consent: _granted(),
      categories: canonicalCategories,
    );

    for (var attempt = 0; attempt < 2; attempt++) {
      await queueSmsTransactionCorrection(
        ref: fixture.ref,
        original: _smsEntry(),
        action: 'moved_to_review',
        correctedFields: const {},
        correctionKind: 'false_transaction',
        reason: 'not a real purchase',
      );
      await tester.pump();
    }

    // A stable-id action must not double-count when the client retries.
    expect(fixture.outbox.pending(), hasLength(1));
  });

  testWidgets('a revised reason for the same fact is a new event', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    final fixture = await _pump(
      tester,
      database: database,
      consent: _granted(),
      categories: canonicalCategories,
    );

    for (final kind in ['false_transaction', 'preference_only']) {
      await queueSmsTransactionCorrection(
        ref: fixture.ref,
        original: _smsEntry(),
        action: 'moved_to_review',
        correctedFields: const {},
        correctionKind: kind,
      );
      await tester.pump();
    }

    // Same sourceKey and factIndex, but the user changed what they meant, so
    // the later classification has to reach the server too.
    final pending = fixture.outbox.pending();
    expect(pending, hasLength(2));
    expect(
      pending.map((entry) => entry.payload['correctionKind']).toSet(),
      {'false_transaction', 'preference_only'},
    );
  });

  testWidgets('two facts from one message stay distinct events', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    final fixture = await _pump(
      tester,
      database: database,
      consent: _granted(),
      categories: canonicalCategories,
    );

    await queueSmsLearningEvent(
      ref: fixture.ref,
      sourceKey: _sourceKey,
      action: 'edited',
      resolvedKind: 'bill_obligation',
      occurredAtIso: _occurredAt.toIso8601String(),
      correctionKind: 'wrong_bill_fields',
      decisionOrigin: 'parser',
      factIndex: 0,
    );
    await queueSmsLearningEvent(
      ref: fixture.ref,
      sourceKey: _sourceKey,
      action: 'edited',
      resolvedKind: 'bill_obligation',
      occurredAtIso: _occurredAt.toIso8601String(),
      correctionKind: 'wrong_bill_fields',
      decisionOrigin: 'parser',
      factIndex: 1,
    );
    await tester.pump();

    final pending = fixture.outbox.pending();
    expect(pending, hasLength(2));
    expect(
      pending.map((entry) => entry.payload['eventId']).toSet(),
      hasLength(2),
    );
    expect(
      pending.map((entry) => entry.payload['factIndex']).toSet(),
      {0, 1},
    );
  });

  void recordAppliedCandidate(
    AppDatabase database, {
    required String candidateId,
    required String family,
  }) => SmsRuleExposureOutbox(database).enqueue(
    _namespace,
    candidateId: candidateId,
    sourceKey: _sourceKey,
    stage: 'outcome',
    matched: true,
    applied: true,
    outcome: 'accepted',
    candidateFamily: family,
  );

  testWidgets('an attributed decision reports shared_rule, not parser', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    recordAppliedCandidate(database, candidateId: 'cand-7', family: 'posted_movement');
    final fixture = await _pump(
      tester,
      database: database,
      consent: _granted(),
      categories: canonicalCategories,
    );

    await queueSmsTransactionCorrection(
      ref: fixture.ref,
      original: _smsEntry(),
      action: 'category_changed',
      correctedFields: const {'categorySlug': 'travel'},
      correctionKind: 'misclassified_category',
    );
    await tester.pump();

    final payload = fixture.outbox.pending().single.payload;
    expect(payload['decisionOrigin'], 'shared_rule');
    expect(payload['decisionRuleId'], 'cand-7');
    final originalDecision =
        payload['originalDecision'] as Map<String, dynamic>;
    expect(originalDecision['origin'], 'shared_rule');
    expect(originalDecision['ruleId'], 'cand-7');
  });

  testWidgets('a candidate that produced a different fact is not blamed', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    // The message's bill fact came from the candidate; the spend fact did not.
    recordAppliedCandidate(
      database,
      candidateId: 'cand-bill',
      family: 'bill_obligation',
    );
    final fixture = await _pump(
      tester,
      database: database,
      consent: _granted(),
      categories: canonicalCategories,
    );

    await queueSmsTransactionCorrection(
      ref: fixture.ref,
      original: _smsEntry(),
      action: 'category_changed',
      correctedFields: const {'categorySlug': 'travel'},
      correctionKind: 'misclassified_category',
    );
    await tester.pump();

    final payload = fixture.outbox.pending().single.payload;
    expect(payload['decisionOrigin'], 'parser');
    expect(payload['decisionRuleId'], isNull);
    expect(
      (payload['originalDecision'] as Map<String, dynamic>)['origin'],
      'parser',
    );
  });

  testWidgets('a manual decision keeps its own origin despite an attribution', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    recordAppliedCandidate(database, candidateId: 'cand-7', family: 'posted_movement');
    final fixture = await _pump(tester, database: database, consent: _granted());

    await queueSmsLearningEvent(
      ref: fixture.ref,
      sourceKey: _sourceKey,
      action: 'edited',
      resolvedKind: 'transaction',
      occurredAtIso: _occurredAt.toIso8601String(),
      originalDecision: const {
        'kind': 'posted_movement',
        'origin': 'manual',
        'fields': {'amountInr': 1500},
      },
      correctedFields: const {'amountInr': 1200},
      correctionKind: 'wrong_amount',
      decisionOrigin: 'manual',
    );
    await tester.pump();

    final payload = fixture.outbox.pending().single.payload;
    expect(payload['decisionOrigin'], 'manual');
    expect(payload['decisionRuleId'], isNull);
    expect(
      (payload['originalDecision'] as Map<String, dynamic>)['origin'],
      'manual',
    );
  });

  testWidgets(
    'a canonical correction trains the on-device rule even with consent off',
    (tester) async {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      await captureSms(database);
      final fixture = await _pump(
        tester,
        database: database,
        consent: null,
        categories: canonicalCategories,
      );

      await queueSmsTransactionCorrection(
        ref: fixture.ref,
        original: _smsEntry(),
        action: 'category_changed',
        correctedFields: const {'categorySlug': 'dining'},
        correctionKind: 'misclassified_category',
      );

      // Local learning is personal preference; only the upload is consented.
      expect(fixture.outbox.count(), 0);
      expect(fixture.repository.flushes, 0);
      expect(
        SmsLearningFeedback(database, namespace: _namespace)
            .loadRulesSync()
            .values,
        contains('dining'),
      );
    },
  );

  testWidgets('a non-canonical slug records no shared-learning rule', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await captureSms(database);
    final fixture = await _pump(
      tester,
      database: database,
      consent: _granted(),
      categories: canonicalCategories,
    );

    await queueSmsTransactionCorrection(
      ref: fixture.ref,
      original: _smsEntry(),
      action: 'category_changed',
      correctedFields: const {'categorySlug': 'Weekend Treats'},
      correctionKind: 'misclassified_category',
    );
    await tester.pump();

    expect(
      SmsLearningFeedback(database, namespace: _namespace)
          .loadRulesSync()
          .values,
      isEmpty,
    );
    expect(fixture.outbox.count(), 1);
  });
}
