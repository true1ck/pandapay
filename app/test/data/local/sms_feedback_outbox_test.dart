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
      expect(event.payload['consentPolicyVersion'], 'sms-shared-learning-v1');
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
}
