// Two cards of one bank must never be taught one set of dates. An old build did
// exactly that: a bill that named no card (a card app, an issuer-wide reminder)
// set the billing and due day of every card of the bank, so two different cards
// showed the same "6th monthly / 8th monthly". Every path that can attach a
// bill to a card is checked here with two HDFC-style cards. Synthetic only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/bills_projection_api.dart';
import 'package:pandapay/data/card_bill_ledger.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay/features/sms_v2/ledger/card_cycle_days.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';

Fact fixture(String name, Map<String, Object?> changes) => Fact.fromJson(
  (jsonDecode(
            jsonEncode({
              ...(jsonDecode(
                        File(
                          '../contracts/sms/v2/fixtures/valid/fact/$name.json',
                        ).readAsStringSync(),
                      )
                      as Map)
                  .cast<String, Object?>(),
              ...changes,
            }),
          )
          as Map)
      .cast<String, Object?>(),
);

String _id(String s) =>
    s.codeUnits.map((c) => c.toRadixString(16)).join().padRight(64, '0');

Map<String, Object?> _card(String? mask) => {
  'kind': 'credit_card',
  'issuerSlug': 'hdfc',
  'maskDigits': mask,
  'maskLength': null,
  'productName': null,
  'raw': null,
};

/// One monthly bill: observed on [day] of [month], due on [due] of the next.
Fact bill(String key, {required int month, required int day, required int due, String? mask, String? stmt}) =>
    fixture('bill_due.total_only', {
      'factId': _id(key),
      'sourceKey': 'sms:$key',
      'observedAt': '2026-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}T06:00:00Z',
      'occurredAt': null,
      'instrument': _card(mask),
      'attrs': {
        'dueDate': '2026-${(month + 1).toString().padLeft(2, '0')}-${due.toString().padLeft(2, '0')}',
        if (stmt != null) 'statementDate': '2026-${month.toString().padLeft(2, '0')}-$stmt',
      },
      'amounts': [
        {'role': 'due_total', 'minor': 100000 + month, 'unit': 'INR'},
      ],
    });

Instrument wallet(String id, String mask, String cardId) => Instrument(
  instrumentId: id,
  kind: InstrumentKind.creditCard,
  issuerSlug: 'hdfc',
  maskDigits: mask,
  status: InstrumentStatus.confirmed,
  displayName: 'HDFC card $mask',
  userCardId: cardId,
  firstSeenAt: DateTime.utc(2026, 1),
  lastSeenAt: DateTime.utc(2026, 11),
  evidenceCount: 1,
);

UserCard userCard(String id, String name, String last4) => UserCard(
  id: id,
  cardProductId: 'p-$id',
  cardName: name,
  isDefault: false,
  last4: last4,
);

void main() {
  final instruments = [
    wallet('00000000-0000-4000-8000-000000000a01', '8708', 'moneyback'),
    wallet('00000000-0000-4000-8000-000000000a02', '1366', 'tataneu'),
  ];

  group('a bill that names no card', () {
    // Three monthly reminders from a card app, none naming a card.
    final nameless = [
      for (var m = 8; m <= 10; m++)
        bill('nameless$m', month: m, day: 6, due: 8, stmt: '06'),
    ];

    test('is attached to neither of two cards of the bank', () {
      final ledgers = cardBillLedgersFromFacts(nameless, const [], instruments);
      expect(ledgers, isEmpty);
      expect(learnedDaysByCard(ledgers), isEmpty);
    });

    test('and the cards then show no days at all, not each other\'s', () {
      final shown = cardsWithTrustedDays(
        [
          userCard('moneyback', 'MoneyBack+ Credit Card', '8708'),
          userCard('tataneu', 'Tata Neu Plus HDFC Bank Credit Card', '1366'),
        ],
        learnedDaysByCard(cardBillLedgersFromFacts(nameless, const [], instruments)),
      );
      expect(shown.map((c) => c.dueDay), [null, null]);
    });
  });

  group('bills that name their card', () {
    test('each card learns its own days, and they differ', () {
      final facts = [
        for (var m = 8; m <= 10; m++) ...[
          bill('mb$m', month: m, day: 6, due: 8, mask: '8708', stmt: '06'),
          bill('tn$m', month: m, day: 20, due: 5, mask: '1366', stmt: '20'),
        ],
      ];
      final learned = learnedDaysByCard(
        cardBillLedgersFromFacts(facts, const [], instruments),
      );
      expect(learned['moneyback']!.statementDay, 6);
      expect(learned['moneyback']!.dueDay, 8);
      expect(learned['tataneu']!.statementDay, 20);
      expect(learned['tataneu']!.dueDay, 5);
    });

    test('one card with bills and one without: only the first learns', () {
      final facts = [
        for (var m = 8; m <= 10; m++)
          bill('mb$m', month: m, day: 6, due: 8, mask: '8708', stmt: '06'),
      ];
      final learned = learnedDaysByCard(
        cardBillLedgersFromFacts(facts, const [], instruments),
      );
      expect(learned.keys, ['moneyback']);
    });
  });

  group('the older bill logic', () {
    test('a bill with no digits from the card app is not given to either card', () {
      final cards = [
        userCard('moneyback', 'HDFC MoneyBack+ Credit Card', '8708'),
        userCard('tataneu', 'HDFC Tata Neu Plus Credit Card', '1366'),
      ];
      CardBillEvidence orphan(int m) => CardBillEvidence(
        sourceId: 'o$m',
        cardLast4: null,
        family: 'MYTNEU',
        statementDate: DateTime(2026, m, 6),
        statementDateExplicit: false,
        dueDate: DateTime(2026, m + 1, 8),
        amountDue: Money.fromPaise(100000),
        minimumDue: null,
        confidence: 0.9,
      );
      final ledgers = deriveCardBills(
        cards: cards,
        evidence: [orphan(9), orphan(10)],
        payments: const [],
        now: DateTime(2026, 11, 15),
      );
      expect(ledgers, isEmpty);
    });
  });

  group('a server bill with only a bank or app label', () {
    BillProjection projection(String biller) => BillProjection(
      id: 'bp',
      projectionKind: 'bill_obligation',
      projectionKey: 'k',
      status: 'active',
      projection: {'billerName': biller, 'amountInr': 8331.0, 'dueDate': '2026-11-08T00:00:00.000'},
      sourceKey: 's',
      sourceFactIds: const [],
      projectionVersion: 1,
      updatedAt: null,
    );

    test('matches neither of two cards of that bank', () {
      final cards = [
        userCard('moneyback', 'MoneyBack+ Credit Card', ''),
        userCard('tataneu', 'Tata Neu Plus HDFC Bank Credit Card', ''),
      ];
      for (final label in ['Tata Neu HDFC Credit Card', 'HDFC Bank Credit Card']) {
        expect(findMatchingCardForCentralBill(projection(label), cards), isNull, reason: label);
      }
    });

    test('still matches the one card the label names', () {
      final cards = [
        userCard('moneyback', 'MoneyBack+ Credit Card', ''),
        userCard('tataneu', 'Tata Neu Plus HDFC Bank Credit Card', ''),
      ];
      expect(
        findMatchingCardForCentralBill(projection('MoneyBack+ Credit Card'), cards)?.id,
        'moneyback',
      );
    });
  });
}
