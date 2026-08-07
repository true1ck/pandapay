import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/home/home_alerts.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _card(String id, {List<CapRule> capRules = const []}) =>
    CardProduct(id: id, name: 'Card $id', network: CardNetwork.visa, capRules: capRules);

void main() {
  group('computeHomeAlerts', () {
    test('flags a cap at or above 90% consumed as nearly hit, priority 0', () {
      final cap = CapRule(id: 'cap1', label: 'Monthly cashback cap', capValue: Money.fromRupees(1000), measure: CapMeasure.rewardValue, period: CapPeriod.calendarMonth);
      final card = _card('c1', capRules: [cap]);
      final userCard = UserCard(id: 'uc1', cardProductId: 'c1', cardName: 'Card c1', isDefault: false, capConsumed: {'cap1': Money.fromRupees(920)});

      final alerts = computeHomeAlerts(wallet: [userCard], catalogue: [card], now: DateTime(2026, 8, 7));

      expect(alerts, hasLength(1));
      expect(alerts.first.kind, HomeAlertKind.capNearlyHit);
      expect(alerts.first.priority, 0);
    });

    test('does not flag a cap under 90% consumed', () {
      final cap = CapRule(id: 'cap1', label: 'Monthly cap', capValue: Money.fromRupees(1000), measure: CapMeasure.rewardValue, period: CapPeriod.calendarMonth);
      final card = _card('c1', capRules: [cap]);
      final userCard = UserCard(id: 'uc1', cardProductId: 'c1', cardName: 'Card c1', isDefault: false, capConsumed: {'cap1': Money.fromRupees(500)});

      expect(computeHomeAlerts(wallet: [userCard], catalogue: [card], now: DateTime(2026, 8, 7)), isEmpty);
    });

    test('flags an un-waived fee-waiver deadline within 7 days, priority 1', () {
      final card = _card('c1');
      final userCard = UserCard(
        id: 'uc1', cardProductId: 'c1', cardName: 'Card c1', isDefault: false,
        feeWaiverStates: [
          FeeWaiverProgress(
            feeWaiverRuleId: 'fw1',
            qualifiedSpend: Money.fromRupees(20000),
            thresholdSpend: Money.fromRupees(100000),
            waivesFee: Money.fromRupees(500),
            periodEnd: DateTime(2026, 8, 10),
          ),
        ],
      );

      final alerts = computeHomeAlerts(wallet: [userCard], catalogue: [card], now: DateTime(2026, 8, 7));

      expect(alerts, hasLength(1));
      expect(alerts.first.kind, HomeAlertKind.feeWaiverDeadline);
      expect(alerts.first.priority, 1);
    });

    test('an already-waived fee waiver is never flagged', () {
      final card = _card('c1');
      final userCard = UserCard(
        id: 'uc1', cardProductId: 'c1', cardName: 'Card c1', isDefault: false,
        feeWaiverStates: [
          FeeWaiverProgress(
            feeWaiverRuleId: 'fw1',
            qualifiedSpend: Money.fromRupees(120000),
            thresholdSpend: Money.fromRupees(100000),
            waivesFee: Money.fromRupees(500),
            waivedAt: DateTime(2026, 8, 1),
            periodEnd: DateTime(2026, 8, 10),
          ),
        ],
      );

      expect(computeHomeAlerts(wallet: [userCard], catalogue: [card], now: DateTime(2026, 8, 7)), isEmpty);
    });

    test('cap-nearly-hit sorts before fee-waiver-deadline when both apply', () {
      final cap = CapRule(id: 'cap1', label: 'cap', capValue: Money.fromRupees(1000), measure: CapMeasure.rewardValue, period: CapPeriod.calendarMonth);
      final card = _card('c1', capRules: [cap]);
      final userCard = UserCard(
        id: 'uc1', cardProductId: 'c1', cardName: 'Card c1', isDefault: false,
        capConsumed: {'cap1': Money.fromRupees(950)},
        feeWaiverStates: [
          FeeWaiverProgress(feeWaiverRuleId: 'fw1', qualifiedSpend: Money.fromRupees(20000), thresholdSpend: Money.fromRupees(100000), waivesFee: Money.fromRupees(500), periodEnd: DateTime(2026, 8, 10)),
        ],
      );

      final alerts = computeHomeAlerts(wallet: [userCard], catalogue: [card], now: DateTime(2026, 8, 7));

      expect(alerts.map((a) => a.kind), [HomeAlertKind.capNearlyHit, HomeAlertKind.feeWaiverDeadline]);
    });

    test('caps at 2 alerts client-side while still returning the full ranked set from the pure function', () {
      // computeHomeAlerts itself returns the full ranked set (per its
      // contract) — capping to 2 is the caller's job (_AlertsStrip). This
      // proves 3+ simultaneous alert conditions produce a fully ranked list
      // that a caller can safely .take(2) from.
      final cap1 = CapRule(id: 'cap1', label: 'cap1', capValue: Money.fromRupees(1000), measure: CapMeasure.rewardValue, period: CapPeriod.calendarMonth);
      final cap2 = CapRule(id: 'cap2', label: 'cap2', capValue: Money.fromRupees(1000), measure: CapMeasure.rewardValue, period: CapPeriod.calendarMonth);
      final card = _card('c1', capRules: [cap1, cap2]);
      final userCard = UserCard(
        id: 'uc1', cardProductId: 'c1', cardName: 'Card c1', isDefault: false,
        capConsumed: {
          'cap1': Money.fromRupees(950),
          'cap2': Money.fromRupees(960),
        },
        feeWaiverStates: [
          FeeWaiverProgress(feeWaiverRuleId: 'fw1', qualifiedSpend: Money.fromRupees(20000), thresholdSpend: Money.fromRupees(100000), waivesFee: Money.fromRupees(500), periodEnd: DateTime(2026, 8, 10)),
        ],
      );

      final alerts = computeHomeAlerts(wallet: [userCard], catalogue: [card], now: DateTime(2026, 8, 7));

      expect(alerts, hasLength(3));
      expect(alerts.map((a) => a.kind), [
        HomeAlertKind.capNearlyHit,
        HomeAlertKind.capNearlyHit,
        HomeAlertKind.feeWaiverDeadline,
      ]);
      final capped = alerts.take(2).toList();
      expect(capped, hasLength(2));
      expect(capped.every((a) => a.kind == HomeAlertKind.capNearlyHit), isTrue);
    });

    test('a fee-waiver deadline more than 7 days out is not flagged', () {
      final card = _card('c1');
      final userCard = UserCard(
        id: 'uc1', cardProductId: 'c1', cardName: 'Card c1', isDefault: false,
        feeWaiverStates: [
          FeeWaiverProgress(feeWaiverRuleId: 'fw1', qualifiedSpend: Money.fromRupees(20000), thresholdSpend: Money.fromRupees(100000), waivesFee: Money.fromRupees(500), periodEnd: DateTime(2026, 8, 20)),
        ],
      );

      expect(computeHomeAlerts(wallet: [userCard], catalogue: [card], now: DateTime(2026, 8, 7)), isEmpty);
    });

    test('a fee-waiver deadline already in the past is not flagged', () {
      final card = _card('c1');
      final userCard = UserCard(
        id: 'uc1', cardProductId: 'c1', cardName: 'Card c1', isDefault: false,
        feeWaiverStates: [
          FeeWaiverProgress(feeWaiverRuleId: 'fw1', qualifiedSpend: Money.fromRupees(20000), thresholdSpend: Money.fromRupees(100000), waivesFee: Money.fromRupees(500), periodEnd: DateTime(2026, 8, 1)),
        ],
      );

      expect(computeHomeAlerts(wallet: [userCard], catalogue: [card], now: DateTime(2026, 8, 7)), isEmpty);
    });
  });
}
