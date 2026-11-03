import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

LedgerEntry row(String id, String event) => LedgerEntry(
  entryId: id.padLeft(64, '0'),
  eventId: event.padLeft(64, '0'),
  from: const OwnUnresolvedEndpoint(InstrumentKind.bankAccount),
  to: const ExternalEndpoint('SWIGGY'),
  amountMinor: 10000,
  unit: LedgerUnit.inr,
  occurredAt: DateTime.utc(2026, 11, 5),
  category: 'dining',
  categorySource: CategorySource.user,
  countsAsTransaction: true,
  isSpend: true,
  isIncome: false,
  isInvestment: false,
);

void main() {
  late Database db;
  late LedgerStore store;
  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    store = LedgerStore(db, namespace: 'user:a');
  });
  tearDown(() => db.dispose());
  test('event replacement is atomic, idempotent and namespace scoped', () {
    final a = row('1', '1'), b = row('2', '1');
    final other = LedgerStore(db, namespace: 'user:b');
    other.replaceForEvent(a.eventId, [a]);
    store.replaceForEvent(a.eventId, [a, b]);
    store.replaceForEvent(a.eventId, [a]);
    expect(store.list(), [a]);
    expect(other.list(), [a]);
    store.replaceForEvent(a.eventId, []);
    expect(store.list(), isEmpty);
    expect(other.list(), [a]);
  });
  test('dirty flags and half-open period queries survive round-trip', () {
    final a = row('1', '1');
    store.replaceForEvent(a.eventId, [a]);
    expect(store.dirty(), [a]);
    store.markClean([a.entryId]);
    expect(store.dirty(), isEmpty);
    expect(
      store.list(
        from: a.occurredAt,
        to: a.occurredAt.add(const Duration(days: 1)),
      ),
      [a],
    );
    expect(store.list(to: a.occurredAt), isEmpty);
    expect(store.get(a.entryId), a);
  });
  test(
    'refund decisions survive reopening without leaking metadata onto the wire',
    () {
      final a = row('1', '1');
      store.replaceForEvent(
        a.eventId,
        [a],
        category: const CategoryDecision(
          slug: 'dining',
          source: CategorySource.user,
          confidence: 1,
        ),
      );
      final reopened = LedgerStore(db, namespace: 'user:a');
      expect(reopened.categoryDecisions()[a.eventId]?.slug, 'dining');
      expect(reopened.get(a.entryId)!.validate().ok, isTrue);
      expect(
        reopened.get(a.entryId)!.toJson().containsKey('_categoryDecision'),
        isFalse,
      );
      expect(LedgerStore(db, namespace: 'user:b').categoryDecisions(), isEmpty);
    },
  );
}
