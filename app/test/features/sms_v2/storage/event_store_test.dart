import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

String _id(int n) => n.toRadixString(16).padLeft(64, '0');

Event _event(
  int anchor, {
  List<(int, LegRole)> more = const [],
  EventStatus status = EventStatus.complete,
  EventType type = EventType.purchase,
  DateTime? at,
}) => Event(
  eventId: _id(anchor),
  type: type,
  status: status,
  legs: [
    EventLeg(factId: _id(anchor), role: LegRole.debitLeg),
    for (final (n, role) in more) EventLeg(factId: _id(n), role: role),
  ],
  linkRuleId: more.isEmpty ? null : 'LINK-CARD-BILL',
  confidence: 0.9,
  occurredAt: at ?? DateTime.utc(2026, 11, 1),
  amountMinor: 1000,
);

void main() {
  late Database db;
  late EventStore store;

  setUp(() {
    db = sqlite3.openInMemory();
    SmsV2Schema.ensure(db);
    store = EventStore(db, namespace: 'user:a');
  });

  tearDown(() => db.dispose());

  test('upsert, get and count, scoped to the namespace', () {
    store.upsert(_event(1));
    expect(store.get(_id(1)), _event(1));
    expect(store.count(), 1);
    final other = EventStore(db, namespace: 'user:b');
    expect(other.get(_id(1)), isNull);
    expect(other.count(), 0);
    expect(other.findByFactId(_id(1)), isEmpty);
  });

  test('find by fact id, including a shared original leg', () {
    store.upsert(_event(1));
    store.upsert(
      _event(2, type: EventType.refund, more: [(1, LegRole.original)]),
    );
    store.upsert(_event(3, more: [(4, LegRole.creditLeg)]));
    expect(
      [for (final e in store.findByFactId(_id(1))) e.eventId],
      [_id(1), _id(2)],
    );
    expect([for (final e in store.findByFactId(_id(4))) e.eventId], [_id(3)]);
    expect(store.findByFactId(_id(9)), isEmpty);
    expect(store.findByFactIds([_id(2), _id(4)]).length, 2);
  });

  test('legs never shrink, and a new leg is added', () {
    store.upsert(_event(1, more: [(2, LegRole.creditLeg)]));
    final stored = store.upsert(
      _event(1, more: [(3, LegRole.duplicateNotice)]),
    );
    expect([for (final l in stored.legs) l.factId], [_id(1), _id(3), _id(2)]);
    expect(store.get(_id(1))!.legs, hasLength(3));
  });

  test('an explicit user correction can remove a wrong link', () {
    store.upsert(_event(1, more: [(2, LegRole.creditLeg)]));
    store.upsert(_event(1, status: EventStatus.userConfirmed), fromUser: true);
    expect(store.get(_id(1))!.legs.map((leg) => leg.factId), [_id(1)]);
    store.upsert(_event(1, more: [(2, LegRole.creditLeg)]));
    expect(store.get(_id(1))!.legs.map((leg) => leg.factId), [_id(1)]);
  });

  test('a user_confirmed event changes only through the user', () {
    store.upsert(_event(1, status: EventStatus.userConfirmed), fromUser: true);
    final kept = store.upsert(_event(1, more: [(2, LegRole.creditLeg)]));
    expect(kept.status, EventStatus.userConfirmed);
    expect(store.get(_id(1))!.legs, hasLength(1));
    store.upsert(
      _event(1, status: EventStatus.userConfirmed, type: EventType.refund),
      fromUser: true,
    );
    expect(store.get(_id(1))!.type, EventType.refund);
  });

  test('open events within a window, and events since a time', () {
    store.upsert(
      _event(1, status: EventStatus.awaitingLeg, at: DateTime.utc(2026, 10, 1)),
    );
    store.upsert(
      _event(2, status: EventStatus.awaitingLeg, at: DateTime.utc(2026, 11, 5)),
    );
    store.upsert(_event(3, at: DateTime.utc(2026, 11, 6)));
    expect([for (final e in store.listOpen()) e.eventId], [_id(1), _id(2)]);
    expect(
      [
        for (final e in store.listOpen(from: DateTime.utc(2026, 11, 1)))
          e.eventId,
      ],
      [_id(2)],
    );
    expect(
      [
        for (final e in store.listOpen(to: DateTime.utc(2026, 10, 31)))
          e.eventId,
      ],
      [_id(1)],
    );
    expect(
      [for (final e in store.listSince(DateTime.utc(2026, 11, 1))) e.eventId],
      [_id(2), _id(3)],
    );
  });

  test('dirty flags', () {
    store.upsertAll([_event(1), _event(2)]);
    store.upsert(_event(3), dirty: false);
    expect([for (final e in store.dirty()) e.eventId], [_id(1), _id(2)]);
    store.markClean([_id(1)]);
    expect([for (final e in store.dirty()) e.eventId], [_id(2)]);
    store.markDirty([_id(3)]);
    expect(store.dirty(), hasLength(2));
  });

  test('stores what the linker produces and feeds it back', () {
    final rules = [
      LinkRule.fromJson({
        'id': 'LINK-CARD-BILL',
        'eventType': 'card_bill_payment',
        'legs': [
          {
            'role': 'debit_leg',
            'match': {
              'factType': 'movement',
              'direction': 'debit',
              'purpose': ['card_payment'],
            },
          },
          {
            'role': 'credit_leg',
            'match': {
              'factType': 'movement',
              'direction': 'credit',
              'purpose': ['card_payment'],
            },
          },
        ],
        'join': {
          'amountRole': 'posted',
          'amountTolerancePct': 0,
          'windowHours': 72,
        },
        'singleLeg': 'complete',
        'priority': 100,
      }),
    ];
    Fact move(int n, String direction) => Fact.fromJson({
      'contractVersion': '2.0',
      'factId': _id(100 + n),
      'sourceKey': 'sms:$n',
      'factType': 'movement',
      'observedAt': '2026-11-10T09:0$n:00Z',
      'occurredAt': null,
      'instrument': null,
      'counterparty': null,
      'amounts': [
        {'role': 'posted', 'minor': 2500000, 'unit': 'INR'},
      ],
      'references': <String, Object?>{},
      'attrs': {
        'direction': direction,
        'purpose': 'card_payment',
        'rail': 'unknown',
      },
      'provenance': {
        'engine': 'rules',
        'ruleId': 'SYN',
        'ruleVersion': 1,
        'bundleVersion': 1,
        'engineVersion': '2.0.0',
        'appVersion': '1.0.0+1',
      },
      'evidence': <Object?>[],
      'confidence': 0.9,
    });
    final linker = RuleDrivenLinker();
    final debit = move(1, 'debit');
    final credit = move(2, 'credit');
    final first = linker.link(
      incoming: [debit],
      context: RuleLinkContext(
        recentFacts: const [],
        openEvents: const [],
        instrumentsById: const {},
      ),
      rules: rules,
    );
    store.upsertAll([...first.created, ...first.updated]);
    final second = linker.link(
      incoming: [credit],
      context: RuleLinkContext(
        recentFacts: [debit],
        openEvents: store.listOpen(),
        instrumentsById: const {},
        knownEvents: store.listSince(DateTime.utc(2026, 7, 1)),
      ),
      rules: rules,
    );
    store.upsertAll([...second.created, ...second.updated]);
    expect(store.count(), 1);
    expect(store.get(debit.factId)!.legs, hasLength(2));
  });
}
