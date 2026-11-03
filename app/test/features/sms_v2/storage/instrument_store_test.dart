import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

int _n = 0;

Instrument _instrument({
  InstrumentKind kind = InstrumentKind.creditCard,
  String issuer = 'hdfc',
  String? mask = '5678',
  InstrumentStatus status = InstrumentStatus.detected,
  String? id,
  DateTime? lastSeen,
  String? userCardId,
}) {
  final t = lastSeen ?? DateTime.utc(2026, 11, 1);
  return Instrument(
    instrumentId:
        id ??
        '00000000-0000-4000-8000-${(_n++).toRadixString(16).padLeft(12, '0')}',
    kind: kind,
    issuerSlug: issuer,
    maskDigits: mask,
    displayName: 'x',
    status: status,
    userCardId: userCardId,
    firstSeenAt: t,
    lastSeenAt: t,
    evidenceCount: 1,
  );
}

void main() {
  late Database db;
  late InstrumentStore store;

  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    store = InstrumentStore(db, namespace: 'user:a');
  });
  tearDown(() => db.dispose());

  test('round trip: upsert then get returns an equal instrument', () {
    final i = _instrument(mask: '1234', kind: InstrumentKind.bankAccount)
        .copyWith(
          availableMinor: 123456,
          availableAt: DateTime.utc(2026, 11, 2),
          aliases: InstrumentAliases(
            senders: ['HDFCBK'],
            productNames: ['Savings'],
          ),
        );
    store.upsert(i);
    final back = store.get(i.instrumentId)!;
    expect(back.toJson(), i.toJson());
    expect(back.validate().ok, isTrue);
    expect(store.get('00000000-0000-4000-8000-ffffffffffff'), isNull);
  });

  test(
    'upsert by key updates the same row; a second id for the same key is refused',
    () {
      final i = _instrument(mask: '5678');
      store.upsert(i);
      store.upsert(
        i.copyWith(displayName: 'Renamed', status: InstrumentStatus.confirmed),
      );
      expect(store.count(), 1);
      expect(store.get(i.instrumentId)!.displayName, 'Renamed');

      final twin = _instrument(mask: '5678');
      expect(() => store.upsert(twin), throwsA(isA<InstrumentKeyConflict>()));
      expect(store.count(), 1);
    },
  );

  test('a card and an account with the same digits are two rows', () {
    store.upsert(_instrument(kind: InstrumentKind.creditCard, mask: '1234'));
    store.upsert(_instrument(kind: InstrumentKind.bankAccount, mask: '1234'));
    expect(store.count(), 2);
    expect(
      store.findByKey(InstrumentKind.bankAccount, 'hdfc', '1234')!.kind,
      InstrumentKind.bankAccount,
    );
    expect(
      store.findByKey(InstrumentKind.creditCard, 'hdfc', '1234')!.kind,
      InstrumentKind.creditCard,
    );
    expect(store.findByKey(InstrumentKind.creditCard, 'icici', '1234'), isNull);
  });

  test('instruments without a mask are told apart by id', () {
    final a = _instrument(
      kind: InstrumentKind.wallet,
      issuer: 'paytm',
      mask: null,
    );
    final b = _instrument(
      kind: InstrumentKind.creditCard,
      issuer: 'hdfc',
      mask: null,
    );
    final c = _instrument(
      kind: InstrumentKind.creditCard,
      issuer: 'hdfc',
      mask: null,
    );
    store
      ..upsert(a)
      ..upsert(b)
      ..upsert(c);
    expect(store.count(), 3);
    expect(
      store.findByKey(InstrumentKind.wallet, 'paytm', null)!.instrumentId,
      a.instrumentId,
    );
  });

  test('list by status and by kind', () {
    final a = _instrument(
      kind: InstrumentKind.bankAccount,
      mask: '1111',
      status: InstrumentStatus.confirmed,
    );
    final b = _instrument(
      kind: InstrumentKind.creditCard,
      mask: '2222',
      status: InstrumentStatus.detected,
    );
    final c = _instrument(
      kind: InstrumentKind.creditCard,
      mask: '3333',
      status: InstrumentStatus.rejected,
    );
    store
      ..upsert(a)
      ..upsert(b)
      ..upsert(c);
    expect(
      store.listByStatus(InstrumentStatus.detected).map((i) => i.instrumentId),
      [b.instrumentId],
    );
    expect(
      store.listByStatus(InstrumentStatus.rejected).map((i) => i.instrumentId),
      [c.instrumentId],
    );
    expect(store.listByKind(InstrumentKind.creditCard).length, 2);
    expect(
      store.list(
        status: InstrumentStatus.detected,
        kind: InstrumentKind.bankAccount,
      ),
      isEmpty,
    );
    expect(store.list().length, 3);
  });

  test('dirty and clean for sync', () {
    final a = _instrument(mask: '1111');
    final b = _instrument(mask: '2222');
    store
      ..upsert(a)
      ..upsert(b, dirty: false);
    expect(store.dirty().map((i) => i.instrumentId), [a.instrumentId]);
    store.markClean([a.instrumentId]);
    expect(store.dirty(), isEmpty);
    store.markDirty([b.instrumentId]);
    expect(store.dirty().map((i) => i.instrumentId), [b.instrumentId]);
    store.upsert(b.copyWith(displayName: 'again'));
    expect(store.dirty().length, 1);
  });

  test('limit history is kept beside the instrument and stripped from get', () {
    final i = _instrument(mask: '1111');
    final history = [
      LimitChangeRecord(
        minor: 100,
        at: DateTime.utc(2026, 10, 1),
        reason: LimitChangeReason.assigned,
      ),
      LimitChangeRecord(
        minor: 200,
        previousMinor: 100,
        at: DateTime.utc(2026, 11, 1),
        reason: LimitChangeReason.increase,
      ),
    ];
    store.upsert(i, limitHistory: history);
    expect(store.limitHistory(i.instrumentId).map((r) => r.minor), [100, 200]);
    // an update without history keeps it
    store.upsert(i.copyWith(displayName: 'n'));
    expect(store.limitHistory(i.instrumentId).length, 2);
    expect(store.get(i.instrumentId)!.validate().ok, isTrue);
  });

  test('find by user card id', () {
    final i = _instrument(
      mask: '1111',
      userCardId: '11111111-1111-4111-8111-111111111111',
    );
    store
      ..upsert(i)
      ..upsert(_instrument(mask: '2222'));
    expect(
      store
          .findByUserCardId('11111111-1111-4111-8111-111111111111')!
          .instrumentId,
      i.instrumentId,
    );
    expect(
      store.findByUserCardId('22222222-2222-4222-8222-222222222222'),
      isNull,
    );
  });

  test('namespace isolation: every query is scoped to the account', () {
    final other = InstrumentStore(db, namespace: 'user:b');
    final mine = _instrument(
      mask: '1111',
      userCardId: '11111111-1111-4111-8111-111111111111',
    );
    store.upsert(mine);

    expect(other.get(mine.instrumentId), isNull);
    expect(other.list(), isEmpty);
    expect(other.listByKind(InstrumentKind.creditCard), isEmpty);
    expect(other.listByStatus(InstrumentStatus.detected), isEmpty);
    expect(other.dirty(), isEmpty);
    expect(other.findByKey(InstrumentKind.creditCard, 'hdfc', '1111'), isNull);
    expect(
      other.findByUserCardId('11111111-1111-4111-8111-111111111111'),
      isNull,
    );
    expect(other.count(), 0);

    // The other account may hold the same key without a conflict, and marking
    // clean in one account does not touch the other.
    final theirs = _instrument(mask: '1111');
    other.upsert(theirs);
    expect(other.count(), 1);
    expect(store.count(), 1);
    other.markClean([mine.instrumentId, theirs.instrumentId]);
    expect(store.dirty().map((i) => i.instrumentId), [mine.instrumentId]);
    expect(other.dirty(), isEmpty);
  });
}
