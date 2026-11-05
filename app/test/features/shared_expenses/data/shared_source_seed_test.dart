import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_source_seed.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

const owner = '11111111-1111-4111-8111-111111111111',
    canonical = '22222222-2222-4222-8222-222222222222';
void main() {
  TransactionEntry entry({
    String id = canonical,
    int pipeline = 1,
    String? event,
    TxnEntryKind kind = TxnEntryKind.spend,
  }) => TransactionEntry(
    id: id,
    amount: const Money.fromPaise(10001),
    occurredAt: DateTime(2026, 11, 4),
    pipelineVersion: pipeline,
    eventId: event,
    entryKind: kind,
    source: 'manual',
    status: 'active',
  );
  test(
    'legacy intent preserves exact paise and does not manufacture a source version',
    () {
      final seed = SharedSourceSeed.fromTransaction(owner, entry());
      expect(seed.amountText, '100.01');
      expect(seed.reference.toJson()['sourceVersion'], 'pending');
      expect(
        SharedSourceSeed.fromTransaction(owner, entry()).expenseId,
        seed.expenseId,
      );
    },
  );
  test(
    'v2 local identity remains a hash reference until the server maps it',
    () {
      final event = 'a' * 64;
      final local = SharedSourceSeed.fromTransaction(
        owner,
        entry(id: 'v2:$event', pipeline: 2, event: event),
      );
      expect(local.reference.toJson()['canonicalTransactionId'], isNull);
      final mapped = SharedSourceSeed.fromTransaction(
        owner,
        entry(pipeline: 2, event: event),
      );
      expect(mapped.expenseId, local.expenseId);
      expect(mapped.reference.toJson()['canonicalTransactionId'], canonical);
    },
  );
  test(
    'income and unknown local identities cannot be promoted to purchases',
    () {
      expect(
        () => SharedSourceSeed.fromTransaction(
          owner,
          entry(kind: TxnEntryKind.income),
        ),
        throwsFormatException,
      );
      expect(
        () =>
            SharedSourceSeed.fromTransaction(owner, entry(id: 'unknown-local')),
        throwsFormatException,
      );
    },
  );
}
