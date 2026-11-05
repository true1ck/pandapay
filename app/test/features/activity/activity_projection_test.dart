import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/activity_projection.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry entry(
  String id,
  int paise,
  DateTime day, {
  TxnEntryKind kind = TxnEntryKind.spend,
  String status = 'active',
}) => TransactionEntry(
  id: id,
  amount: Money.fromPaise(paise),
  occurredAt: day,
  entryKind: kind,
  source: 'manual',
  status: status,
);

void main() {
  test('groups days newest first and preserves order within a day', () {
    final older = DateTime(2026, 10, 30);
    final newer = DateTime(2026, 10, 31);
    final projection = ActivityProjection.build([
      entry('old', 100, older),
      entry('new-one', 200, newer),
      entry('new-two', 300, newer),
    ]);

    expect(projection.rows.map((row) => row.kind), [
      ActivityRowKind.summary,
      ActivityRowKind.dayHeader,
      ActivityRowKind.transaction,
      ActivityRowKind.transaction,
      ActivityRowKind.spacer,
      ActivityRowKind.dayHeader,
      ActivityRowKind.transaction,
      ActivityRowKind.spacer,
    ]);
    expect(projection.rows[1].day, newer);
    expect(projection.rows[2].entry!.id, 'new-one');
    expect(projection.rows[3].entry!.id, 'new-two');
    expect(projection.rows[5].day, older);
  });

  test('summary retains active positive income/spend/investment semantics', () {
    final day = DateTime(2026, 10, 31);
    final projection = ActivityProjection.build([
      entry('income', 500, day, kind: TxnEntryKind.income),
      entry('spend', 100, day),
      entry('investment', 200, day, kind: TxnEntryKind.investment),
      entry('deleted', 900, day, status: 'deleted'),
      entry('zero', 0, day),
      entry('negative', -50, day),
    ]);

    expect(projection.totalIncoming.paise, 500);
    expect(projection.totalOutgoing.paise, 300);
    expect(projection.activeCount, 5);
    expect(projection.visibleSelectedCount({'income', 'spend', 'hidden'}), 2);
    expect(() => projection.rows.clear(), throwsUnsupportedError);
  });

  test('received UPI credit flows into the Activity Money in total', () {
    final transaction = entry(
      'credit',
      50000,
      DateTime(2026, 10, 30, 13, 37),
      kind: TxnEntryKind.income,
    );
    final projection = ActivityProjection.build([transaction]);

    expect(projection.totalIncoming.paise, 50000);
    expect(projection.totalOutgoing.paise, 0);
  });

  test(
    'one-entry cache reuses the same snapshot across selection rebuilds',
    () {
      final cache = ActivityProjectionCache();
      final rows = [entry('one', 100, DateTime(2026, 10, 31))];
      final first = cache.resolve(
        rows,
        scope: ('user:a', 'session:a', 'month'),
      );
      expect(
        identical(
          first,
          cache.resolve(rows, scope: ('user:a', 'session:a', 'month')),
        ),
        isTrue,
      );
      final revised = cache.resolve(
        [...rows, entry('two', 200, DateTime(2026, 10, 31))],
        scope: ('user:a', 'session:a', 'month'),
      );
      expect(identical(first, revised), isFalse);
      expect(revised.totalOutgoing.paise, 300);
      final base = cache.resolve(rows, scope: ('user:a', 'session:a', 'month'));
      final account = cache.resolve(
        rows,
        scope: ('user:b', 'session:b', 'month'),
      );
      expect(identical(base, account), isFalse);
      final session = cache.resolve(
        rows,
        scope: ('user:b', 'session:new', 'month'),
      );
      expect(identical(account, session), isFalse);
      final query = cache.resolve(
        rows,
        scope: ('user:b', 'session:new', 'year'),
      );
      expect(identical(session, query), isFalse);
      // Only the last scope is retained; returning to the old scope rebuilds.
      expect(
        identical(
          first,
          cache.resolve(rows, scope: ('user:a', 'session:a', 'month')),
        ),
        isFalse,
      );
    },
  );

  test('large snapshots retain exact totals and lazy row metadata', () {
    for (final size in [3000, 10000]) {
      final day = DateTime(2026, 10, 31);
      final rows = [for (var i = 0; i < size; i++) entry('row:$i', 101, day)];
      final projection = ActivityProjection.build(rows);
      expect(projection.totalOutgoing.paise, size * 101);
      expect(projection.activeCount, size);
      expect(projection.rows.length, size + 3);
      expect(projection.visibleSelectedCount({'row:0', 'row:${size - 1}'}), 2);
    }
  });

  test('selection counting preserves duplicate-row snapshot semantics', () {
    final row = entry('one', 100, DateTime(2026, 10, 31));
    final projection = ActivityProjection.build([row, row]);
    expect(projection.visibleSelectedCount({'one'}), 2);
    expect(projection.totalOutgoing.paise, 200);
  });
}
