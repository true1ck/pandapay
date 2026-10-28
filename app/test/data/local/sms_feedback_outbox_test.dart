import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_feedback_outbox.dart';

void main() {
  test('detects multiple persisted facts before shared attribution', () {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    FinancialStore(database);
    final outbox = SmsFeedbackOutbox(database, namespace: 'account-a');
    final sourceKey = List<String>.filled(64, 'd').join();

    database.db.execute(
      'INSERT INTO financial_entities(namespace,entity,id,payload,observed_at,pending,source_key) '
      'VALUES(?,?,?,?,?,?,?)',
      ['account-a', 'transactions', 'txn-1', '{}', 1, 0, sourceKey],
    );
    expect(outbox.hasMultiplePersistedFacts(sourceKey), isFalse);

    database.db.execute(
      'INSERT INTO financial_entities(namespace,entity,id,payload,observed_at,pending,source_key) '
      'VALUES(?,?,?,?,?,?,?)',
      ['account-a', 'transactions', 'txn-2', '{}', 2, 0, sourceKey],
    );
    expect(outbox.hasMultiplePersistedFacts(sourceKey), isTrue);
  });

  test(
    'stores generalized sample patterns and consented structured corrections',
    () {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      final outbox = SmsFeedbackOutbox(database, namespace: 'account-a');
      final id = outbox.enqueue(
        sourceKey: 'a' * 64,
        action: 'edited',
        sender: 'HDFC1234',
        resolvedKind: 'transaction',
        occurredAt: '2026-10-27T10:00:00Z',
        consentGrantedAt: DateTime.utc(2026, 10, 27),
        sampleBody: 'Rs 420.50 was debited on 27-10-2026. Ref 12345; A/C 1234.',
        originalDecision: {
          'kind': 'transaction',
          'fields': {'amountPaise': 42050},
        },
        correctedFields: {'amountInr': 450},
      );

      final event = outbox.pending().single;
      expect(event.eventId, id);
      expect(event.payload['sampleBody'], contains('{n}'));
      expect(
        RegExp(r'\d').hasMatch(event.payload['sampleBody'] as String),
        isFalse,
      );
      expect(event.payload['correctedFields'], {'amountInr': 450});
      expect(event.payload['consentPurpose'], 'sms_shared_learning');
      expect(event.payload['consentPolicyVersion'], 'sms-shared-learning-v2');
    },
  );

  test('a repeated confirmation has one stable idempotent event', () {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final outbox = SmsFeedbackOutbox(database, namespace: 'account-a');
    final args = {
      'sourceKey': 'b' * 64,
      'action': 'confirmed',
      'sender': 'HDFCBK',
      'resolvedKind': 'transaction',
      'occurredAt': '2026-10-27T10:00:00Z',
      'consentGrantedAt': DateTime.utc(2026, 10, 27),
    };

    final first = outbox.enqueue(
      sourceKey: args['sourceKey'] as String,
      action: args['action'] as String,
      sender: args['sender'] as String,
      resolvedKind: args['resolvedKind'] as String,
      occurredAt: args['occurredAt'] as String,
      consentGrantedAt: args['consentGrantedAt'] as DateTime,
    );
    final second = outbox.enqueue(
      sourceKey: args['sourceKey'] as String,
      action: args['action'] as String,
      sender: args['sender'] as String,
      resolvedKind: args['resolvedKind'] as String,
      occurredAt: args['occurredAt'] as String,
      consentGrantedAt: args['consentGrantedAt'] as DateTime,
    );

    expect(first, second);
    expect(outbox.count(), 1);
  });

  test('a revised dismissal kind or reason gets a distinct stable event', () {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final outbox = SmsFeedbackOutbox(database, namespace: 'account-a');

    String record(String kind, String reason) => outbox.enqueue(
      sourceKey: 'f' * 64,
      action: 'dismissed',
      sender: 'HDFCBK',
      resolvedKind: 'transaction',
      occurredAt: '2026-10-27T10:00:00Z',
      consentGrantedAt: DateTime.utc(2026, 10, 27),
      originalDecision: {'kind': 'posted_movement'},
      correctionKind: kind,
      reason: reason,
    );

    final classification = record('false_transaction', 'not_financial');
    final preference = record('preference_only', 'do_not_track');

    expect(classification, isNot(preference));
    expect(record('preference_only', 'do_not_track'), preference);
    expect(outbox.count(), 2);
  });

  test('changed-back corrections and distinct message occurrences stay distinct', () {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final outbox = SmsFeedbackOutbox(database, namespace: 'account-a');
    String record({
      required String priorMerchant,
      required DateTime messageAt,
      String? eventId,
    }) =>
        outbox.enqueue(
          eventId: eventId,
          sourceKey: 'b' * 64,
          action: 'edited',
          sender: 'HDFCBK',
          resolvedKind: 'transaction',
          occurredAt: '2026-10-27T10:00:00Z',
          consentGrantedAt: DateTime.utc(2026, 10, 27),
          originalDecision: {'fields': {'merchant': priorMerchant}},
          correctedFields: {'merchant': 'Store A'},
          messageAt: messageAt,
        );

    final first = record(
      priorMerchant: 'Store A',
      messageAt: DateTime.utc(2026, 10, 27, 10),
    );
    final changedAway = record(
      priorMerchant: 'Store B',
      messageAt: DateTime.utc(2026, 10, 27, 10),
    );
    final changedBack = record(
      priorMerchant: 'Store A',
      messageAt: DateTime.utc(2026, 10, 28, 10),
    );
    final retry = record(
      priorMerchant: 'Store A',
      messageAt: DateTime.utc(2026, 10, 27, 10),
      eventId: first,
    );

    expect({first, changedAway, changedBack}, hasLength(3));
    expect(retry, first);
    expect(outbox.count(), 3);
  });

  test('offline correction waits for sync ack and clear removes it', () {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final outbox = SmsFeedbackOutbox(database, namespace: 'account-a');
    outbox.enqueueAfterSync(
      clientSeq: 12,
      payload: {
        'sourceKey': 'e' * 64,
        'action': 'edited',
        'consentGrantedAt': DateTime.utc(2026, 10, 27).toIso8601String(),
      },
    );

    expect(outbox.pendingAfterSync(), isEmpty);
    outbox.acknowledgeAfterSync(12);
    final acknowledged = outbox.pendingAfterSync();
    expect(acknowledged, hasLength(1));
    final retryId = acknowledged.single.payload['eventId'];
    expect(retryId, isA<String>());
    outbox.clear();
    expect(outbox.pendingAfterSync(), isEmpty);
  });

  test('generalized SMS evidence masks personal names outside greetings', () {
    final generalized = redactSmsLearningPattern(
      'Sujay Shantaram Kurtigkar, your payment of Rs. 200 to Swiggy is complete',
    );
    expect(generalized, isNot(contains('Sujay')));
    expect(generalized, isNot(contains('Shantaram')));
    expect(generalized, isNot(contains('Kurtigkar')));
    expect(generalized, contains('{name}'));
    expect(generalized, contains('{n}'));
  });

  test('carries the typed correction envelope', () {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final outbox = SmsFeedbackOutbox(database, namespace: 'account-a');
    outbox.enqueue(
      sourceKey: 'c' * 64,
      action: 'category_changed',
      sender: 'AD-HDFCBK',
      resolvedKind: 'transaction',
      occurredAt: '2026-10-27T10:00:00Z',
      consentGrantedAt: DateTime.utc(2026, 10, 27),
      correctedFields: {'categorySlug': 'dining'},
      correctionKind: 'misclassified_category',
      decisionOrigin: 'shared_rule',
      decisionRuleId: 'bundle-2026-10-21:r4',
      factIndex: 2,
      messageAt: DateTime.utc(2026, 10, 27, 9, 59),
    );

    final payload = outbox.pending().single.payload;
    expect(payload['correctionKind'], 'misclassified_category');
    expect(payload['decisionOrigin'], 'shared_rule');
    expect(payload['decisionRuleId'], 'bundle-2026-10-21:r4');
    expect(payload['factIndex'], 2);
    expect(payload['messageAt'], '2026-10-27T09:59:00.000Z');
  });

  test('rejects a correction kind or origin outside the server taxonomy', () {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final outbox = SmsFeedbackOutbox(database, namespace: 'account-a');
    expect(
      () => outbox.enqueue(
        sourceKey: 'd' * 64,
        action: 'edited',
        sender: 'AD-HDFCBK',
        resolvedKind: 'transaction',
        occurredAt: '2026-10-27T10:00:00Z',
        consentGrantedAt: DateTime.utc(2026, 10, 27),
        correctionKind: 'made_up_kind',
      ),
      throwsArgumentError,
    );
    expect(
      () => outbox.enqueue(
        sourceKey: 'd' * 64,
        action: 'edited',
        sender: 'AD-HDFCBK',
        resolvedKind: 'transaction',
        occurredAt: '2026-10-27T10:00:00Z',
        consentGrantedAt: DateTime.utc(2026, 10, 27),
        decisionOrigin: 'gemini',
      ),
      throwsArgumentError,
    );
    expect(outbox.count(), 0);
  });

  test('two facts in one message are distinct idempotent events', () {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final outbox = SmsFeedbackOutbox(database, namespace: 'account-a');
    String enqueue(int factIndex) => outbox.enqueue(
      sourceKey: 'e' * 64,
      action: 'edited',
      sender: 'AD-HDFCBK',
      resolvedKind: 'transaction',
      occurredAt: '2026-10-27T10:00:00Z',
      consentGrantedAt: DateTime.utc(2026, 10, 27),
      correctedFields: {'amountInr': 500},
      correctionKind: 'wrong_amount',
      factIndex: factIndex,
    );

    final first = enqueue(0);
    final second = enqueue(1);
    expect(first, isNot(second));
    expect(outbox.count(), 2);
    expect(enqueue(1), second);
    expect(outbox.count(), 2);
    expect(
      outbox.pending().map((event) => event.payload['factIndex']).toSet(),
      {0, 1},
    );
    expect(
      outbox.pending().map((event) => event.eventId).toSet(),
      {first, second},
    );
  });
}
