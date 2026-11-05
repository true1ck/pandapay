import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/card_snapshots.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../support/v2_catalogue_fixtures.dart';

/// WP9 "never mix measures": a v2-shaped card's snapshot carries native
/// `consumed_native` in `capConsumed` and leaves `capRemaining` empty; a null
/// `consumed_native` is unknown, not empty; the v1 `consumed` is never turned
/// into native units.
final _now = DateTime(2026, 11, 15);

// v2 card: 5 pts/₹100 rule, base 1 pt/₹100, point value ₹0.25, and a
// 1,500-point monthly bonus cap (the v1 `cap_value` field is ₹375).
CardProduct _v2Product() => parseCard(v2CardJson('p'));

UserCard _owned(List<Map<String, dynamic>> capStates) =>
    parseUserCard(userCardJson('uc', 'p', capStates: capStates));

Map<String, dynamic> _row({
  Object? consumedV1 = 350,
  Object? native,
  String? kind = 'bonus_points',
  Object? amount = 1500,
  String start = '2026-11-01',
  String end = '2026-11-30',
}) => capStateRowJson(
  'p-cap',
  consumed: consumedV1,
  consumedNative: native,
  capKind: kind,
  capAmount: amount,
  periodStart: start,
  periodEnd: end,
);

/// Points earned for ₹10,000 at no category: 5 pts/₹100 on the rule, base
/// 1 pt/₹100, so 500 total of which 400 is bonus.
double _points(CardSnapshot snapshot) {
  final rec = const RecommendationEngine().rank(
    RecommendationContext(
      amount: const Money.fromPaise(1000000),
      rail: TxnRail.swipe,
      now: _now,
    ),
    [snapshot],
  ).single;
  return rec.reward!.points!;
}

void main() {
  group('v2-shaped card: native units, capRemaining empty', () {
    test('known row: capConsumed is consumed_native, capRemaining is empty',
        () {
      final snapshot = buildCardSnapshot(
        _v2Product(),
        owned: _owned([_row(native: 1400)]),
        now: _now,
      );
      expect(snapshot.capConsumed, {'p-cap': 1400});
      expect(snapshot.capRemaining, isEmpty);
      expect(snapshot.v2CapConsumed, {'p-cap': 1400});
    });

    test('the engine reads the native figure, not the v1 ₹ measure', () {
      // 1,400 of 1,500 points used -> 100 points of bonus headroom. The v1
      // `consumed` is ₹350 (1,400 x ₹0.25) against the v1 cap_value of ₹375:
      // read as the same measure it would leave 25, not 100.
      final snapshot = buildCardSnapshot(
        _v2Product(),
        owned: _owned([_row(native: 1400)]),
        now: _now,
      );
      // base 100 + bonus min(400, 100) = 200.
      expect(_points(snapshot), 200);
    });

    test('no row for the cap: nothing consumed, full headroom', () {
      final snapshot = buildCardSnapshot(
        _v2Product(),
        owned: _owned(const []),
        now: _now,
      );
      expect(snapshot.capConsumed, isEmpty);
      expect(snapshot.capRemaining, isEmpty);
      expect(_points(snapshot), 500);
    });

    test('a card the user does not hold is fresh', () {
      final snapshot = buildCardSnapshot(_v2Product(), now: _now);
      expect(snapshot.capConsumed, isEmpty);
      expect(_points(snapshot), 500);
    });

    test('null consumed_native is unknown: consumed = cap_amount, no bonus',
        () {
      // A row written before the owner's recompute: v1 `consumed` only.
      final owned = _owned([
        _row(native: null, kind: null, amount: null, start: '2026-11-01'),
      ]);
      final snapshot = buildCardSnapshot(_v2Product(), owned: owned, now: _now);
      expect(snapshot.capConsumed, {'p-cap': 1500});
      expect(snapshot.capRemaining, isEmpty);
      // Nothing of the capped bonus is promised: base only.
      expect(_points(snapshot), 100);
    });

    test('the v1 consumed is never used as a native figure', () {
      // Whatever v1 `consumed` says (0, 350, 99999), an unknown native stays
      // unknown.
      for (final v1 in [0, 350, 99999]) {
        final owned = _owned([_row(consumedV1: v1, native: null, kind: null)]);
        final snapshot = buildCardSnapshot(
          _v2Product(),
          owned: owned,
          now: _now,
        );
        expect(snapshot.capConsumed['p-cap'], 1500, reason: 'v1=$v1');
      }
    });

    test('a v1 figure with no row at all is unknown, not empty', () {
      final owned = UserCard(
        id: 'uc',
        cardProductId: 'p',
        cardName: 'Wallet Card',
        isDefault: false,
        capConsumed: const {'p-cap': Money.fromPaise(35000)},
      );
      final snapshot = buildCardSnapshot(_v2Product(), owned: owned, now: _now);
      expect(snapshot.capConsumed['p-cap'], 1500);
    });

    test('a native figure for a period that has ended is unknown', () {
      final owned = _owned([
        _row(native: 200, start: '2026-10-01', end: '2026-10-31'),
      ]);
      final snapshot = buildCardSnapshot(_v2Product(), owned: owned, now: _now);
      expect(snapshot.capConsumed['p-cap'], 1500);
    });

    test('the last day of the period still counts', () {
      final owned = _owned([_row(native: 200)]);
      final snapshot = buildCardSnapshot(
        _v2Product(),
        owned: owned,
        now: DateTime(2026, 11, 30, 23, 59),
      );
      expect(snapshot.capConsumed['p-cap'], 200);
    });

    test('a row recorded for a different cap kind is unknown', () {
      final owned = _owned([_row(native: 10, kind: 'total_points')]);
      final snapshot = buildCardSnapshot(_v2Product(), owned: owned, now: _now);
      expect(snapshot.capConsumed['p-cap'], 1500);
    });

    test('an unreadable native value is unknown, never a thrown error', () {
      final owned = _owned([_row(native: 'lots')]);
      expect(owned.capStates['p-cap']!.consumedNative, isNull);
      final snapshot = buildCardSnapshot(_v2Product(), owned: owned, now: _now);
      expect(snapshot.capConsumed['p-cap'], 1500);
    });

    test('a legacy cap with no amount to feed is exhausted, not skipped', () {
      // A v1 cap row on a v2-shaped card (cap_kind absent): the engine
      // converts it itself, so the snapshot cannot name its native amount.
      final json = v2CardJson('p');
      (json['cap_rules'] as List).add({
        'id': 'legacy',
        'reward_rule_id': null,
        'category_id': null,
        'label': 'Legacy cap',
        'measure': 'reward_value',
        'period': 'calendar_month',
        'cap_value': 100,
        'post_cap_unit': null,
        'post_cap_rate': null,
      });
      final product = parseCard(json);
      final owned = _owned([
        capStateRowJson('legacy', consumed: 5, consumedNative: null),
      ]);
      final snapshot = buildCardSnapshot(product, owned: owned, now: _now);
      expect(snapshot.capConsumed['legacy'], kCapExhaustedSentinel);
    });

    test('v2 cards are not de-duplicated: every cap by id', () {
      final json = v2CardJson('p');
      final caps = json['cap_rules'] as List;
      final second = Map<String, dynamic>.from(caps.single as Map)
        ..['id'] = 'p-cap-2';
      caps.add(second);
      final product = parseCard(json);
      final owned = _owned([
        capStateRowJson(
          'p-cap-2',
          consumed: 1,
          consumedNative: 7,
          capKind: 'bonus_points',
          capAmount: 1500,
          periodStart: '2026-11-01',
          periodEnd: '2026-11-30',
        ),
      ]);
      final snapshot = buildCardSnapshot(product, owned: owned, now: _now);
      expect(snapshot.capConsumed, {'p-cap-2': 7});
    });
  });

  group('v1-shaped card: today\'s behaviour, unchanged', () {
    CardProduct v1Product() => parseCard(v1CardJson('p', withCap: true));

    test('capRemaining is cap_value minus the v1 consumed; capConsumed empty',
        () {
      final owned = parseUserCard(
        userCardJson(
          'uc',
          'p',
          capStates: [capStateRowJson('p-cap', consumed: 120)],
        ),
      );
      final snapshot = buildCardSnapshot(v1Product(), owned: owned, now: _now);
      expect(snapshot.capRemaining['p-cap'], Money.fromRupees(380));
      expect(snapshot.capConsumed, isEmpty);
    });

    test('a v1 card ignores native fields entirely', () {
      final owned = parseUserCard(
        userCardJson(
          'uc',
          'p',
          capStates: [
            capStateRowJson(
              'p-cap',
              consumed: 120,
              consumedNative: 999999,
              capKind: 'bonus_points',
            ),
          ],
        ),
      );
      final snapshot = buildCardSnapshot(v1Product(), owned: owned, now: _now);
      expect(snapshot.capRemaining['p-cap'], Money.fromRupees(380));
      expect(snapshot.capConsumed, isEmpty);
    });

    test('an unowned v1 card has no cap state', () {
      final snapshot = buildCardSnapshot(v1Product(), now: _now);
      expect(snapshot.capRemaining, isEmpty);
    });

    test('milestone progress and the override id pass through', () {
      final owned = UserCard(
        id: 'uc',
        cardProductId: 'p',
        cardName: 'x',
        isDefault: false,
        milestoneQualifiedSpend: const {'m1': Money.fromPaise(5000)},
      );
      final snapshot = buildCardSnapshot(
        v1Product(),
        owned: owned,
        now: _now,
        forcedOverrideCardId: 'p',
      );
      expect(snapshot.milestoneProgress['m1'], const Money.fromPaise(5000));
      expect(snapshot.forcedOverrideCardId, 'p');
    });
  });

  group('UserCard cap_states parsing', () {
    test('a v2 row keeps v1 consumed as-is and adds the native fields', () {
      final owned = _owned([_row(consumedV1: '350.00', native: '1400.00')]);
      expect(owned.capConsumed['p-cap'], Money.fromRupees(350));
      final row = owned.capStates['p-cap']!;
      expect(row.consumedNative, 1400);
      expect(row.capKind, CapKind.bonusPoints);
      expect(row.capAmount, 1500);
      expect(row.periodStart, DateTime(2026, 11, 1));
      expect(row.periodEnd, DateTime(2026, 11, 30));
      expect(row.approximateWindow, isFalse);
    });

    test('a v1 row has no native fields', () {
      final owned = _owned([
        capStateRowJson('p-cap', consumed: 12.5),
      ]);
      expect(owned.capConsumed['p-cap'], Money.fromRupees(12.5));
      final row = owned.capStates['p-cap']!;
      expect(row.consumedNative, isNull);
      expect(row.capKind, isNull);
      expect(row.periodEnd, isNull);
    });

    test('rows without any v2 key (an older server) still parse', () {
      final owned = parseUserCard({
        'id': 'uc',
        'card_product_id': 'p',
        'card_name': 'x',
        'cap_states': [
          {'cap_rule_id': 'p-cap', 'consumed': '10.00'},
        ],
      });
      expect(owned.capConsumed['p-cap'], Money.fromRupees(10));
      expect(owned.capStates['p-cap']!.consumedNative, isNull);
    });

    test('garbled v2 fields never fail the wallet', () {
      final owned = _owned([
        capStateRowJson(
          'p-cap',
          consumed: 1,
          consumedNative: {'oops': true},
          capKind: 'bonus_points',
          capAmount: 'many',
          periodStart: 'yesterday',
          periodEnd: 5,
        ),
      ]);
      final row = owned.capStates['p-cap']!;
      expect(row.consumedNative, isNull);
      expect(row.capAmount, isNull);
      expect(row.periodStart, isNull);
      expect(row.periodEnd, isNull);
    });

    test('toJson -> fromJson keeps every native field (offline cache)', () {
      final owned = _owned([
        _row(native: 1240.5),
        capStateRowJson('other', consumed: 3),
      ]);
      final again = parseUserCard(owned.toJson());
      expect(again.capConsumed, owned.capConsumed);
      final a = owned.capStates['p-cap']!;
      final b = again.capStates['p-cap']!;
      expect(b.consumedNative, a.consumedNative);
      expect(b.capKindWire, a.capKindWire);
      expect(b.capAmount, a.capAmount);
      expect(b.periodStart, a.periodStart);
      expect(b.periodEnd, a.periodEnd);
      expect(b.approximateWindow, a.approximateWindow);
      // A v1 row stays a v1 row: still unknown, not turned into 0.
      expect(again.capStates['other']!.consumedNative, isNull);
    });

    test('a v1-only wallet serialises exactly as before (no v2 keys)', () {
      final owned = _owned([capStateRowJson('p-cap', consumed: 4)]);
      final row =
          (owned.toJson()['cap_states'] as List).single as Map<String, dynamic>;
      expect(row.keys.toSet(), {'cap_rule_id', 'consumed'});
    });

    test('approximate_window round trips', () {
      final owned = _owned([
        capStateRowJson(
          'p-cap',
          consumed: 1,
          consumedNative: 2,
          capKind: 'txn_count',
          capAmount: 3,
          periodStart: '2026-11-01',
          periodEnd: '2026-11-30',
          approximate: true,
        ),
      ]);
      final again = parseUserCard(owned.toJson());
      expect(again.capStates['p-cap']!.approximateWindow, isTrue);
    });
  });
}
