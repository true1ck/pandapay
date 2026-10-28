import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_feedback_outbox.dart';

void main() {
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
  });
}
