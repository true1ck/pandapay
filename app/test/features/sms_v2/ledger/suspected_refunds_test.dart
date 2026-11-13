import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/suspected_refund_banner.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay/features/sms_v2/ledger/suspected_refunds.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _hex(String seed) => seed.codeUnits
    .map((c) => c.toRadixString(16).padLeft(2, '0'))
    .join()
    .padRight(64, '0')
    .substring(0, 64);

Map<String, Object?> _fixture(String name) =>
    (jsonDecode(
              File('../contracts/sms/v2/fixtures/valid/fact/$name.json')
                  .readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>();

Fact _reading(String id, String at, int rupees, {String mask = '4321'}) {
  final j = _fixture('balance_snapshot.available_credit');
  j['factId'] = _hex(id);
  j['sourceKey'] = 'sms:$id';
  j['observedAt'] = at;
  j['occurredAt'] = at;
  (j['attrs'] as Map)['asOf'] = at;
  (j['instrument'] as Map)['maskDigits'] = mask;
  (j['amounts'] as List)[0] = {
    'role': 'available_credit',
    'minor': rupees * 100,
    'unit': 'INR',
  };
  return Fact.fromJson(j);
}

TransactionEntry _row(
  String id,
  String at,
  int rupees, {
  TxnEntryKind kind = TxnEntryKind.spend,
  String last4 = '4321',
  TxnInstrument instrument = TxnInstrument.creditCard,
  String status = 'active',
}) => TransactionEntry(
  id: id,
  eventId: 'event-$id',
  amount: Money.fromRupees(rupees.toDouble()),
  occurredAt: DateTime.parse(at),
  cardLast4: last4,
  instrument: instrument,
  entryKind: kind,
  merchantName: 'FLIPKART',
  source: 'sms',
  status: status,
  pipelineVersion: 2,
);

LedgerReadModel _model(List<Fact> facts, List<TransactionEntry> rows) =>
    LedgerReadModel(
      ledger: LedgerSnapshot(entries: const [], events: const []),
      facts: facts,
      transactions: rows,
    );

void main() {
  group('suspectedRefundsFromModel', () {
    test('the Axis case: a 78,000 spend and the limit back at 78,500 with nothing between', () {
      final found = suspectedRefundsFromModel(
        _model(
          [
            _reading('after-spend', '2026-10-12T10:30:00Z', 500),
            _reading('weeks-later', '2026-11-03T12:00:00Z', 78500),
          ],
          [
            _row('small', '2026-10-12T10:00:00Z', 1200),
            _row('big', '2026-10-12T10:30:00Z', 78000),
          ],
        ),
      );
      expect(found.keys, ['event-big']);
      expect(found['event-big']!.cardLast4, '4321');
      expect(found['event-big']!.limitRoseByMinor, 7800000);
    });

    test('a card payment in between explains the rise: nothing is asked', () {
      final found = suspectedRefundsFromModel(
        _model(
          [
            _reading('after-spend', '2026-10-12T10:30:00Z', 500),
            _reading('weeks-later', '2026-11-03T12:00:00Z', 78500),
          ],
          [
            _row('big', '2026-10-12T10:30:00Z', 78000),
            _row('pay', '2026-11-01T10:00:00Z', 78000, kind: TxnEntryKind.transfer),
          ],
        ),
      );
      expect(found, isEmpty);
    });

    test('a refund message for the same amount means it is already known', () {
      final found = suspectedRefundsFromModel(
        _model(
          [
            _reading('after-spend', '2026-10-12T10:30:00Z', 500),
            _reading('weeks-later', '2026-11-03T12:00:00Z', 78500),
          ],
          [
            _row('big', '2026-10-12T10:30:00Z', 78000),
            _row('refund', '2026-10-26T10:00:00Z', 78000, kind: TxnEntryKind.refund),
          ],
        ),
      );
      expect(found, isEmpty);
    });

    test('another card, a debit card and an ignored spend never produce a question', () {
      final readings = [
        _reading('a', '2026-10-12T10:30:00Z', 500),
        _reading('b', '2026-11-03T12:00:00Z', 78500),
      ];
      expect(
        suspectedRefundsFromModel(_model(readings, [_row('x', '2026-10-12T10:30:00Z', 78000, last4: '5678')])),
        isEmpty,
      );
      expect(
        suspectedRefundsFromModel(_model(readings, [_row('x', '2026-10-12T10:30:00Z', 78000, instrument: TxnInstrument.debitCard)])),
        isEmpty,
      );
      // An ignored spend is not a spend any more: nothing to pair the rise with.
      expect(
        suspectedRefundsFromModel(_model(readings, [_row('x', '2026-10-12T10:30:00Z', 78000, status: 'ignored')])),
        isEmpty,
      );
    });

    test('an empty ledger is safe', () {
      expect(suspectedRefundsFromModel(_model(const [], const [])), isEmpty);
    });
  });

  group('SuspectedRefundBanner', () {
    final info = SuspectedRefundInfo(
      spendEventId: 'event-big',
      cardLast4: '4321',
      spendAmountMinor: 7800000,
      limitRoseByMinor: 7800000,
      noticedAt: _noticed,
    );

    Future<void> pump(WidgetTester tester, Future<void> Function() onYes) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SuspectedRefundBanner(info: info, onConfirmRefunded: onYes),
            ),
          ),
        );

    testWidgets('asks the question, names the card, and Yes hands off', (tester) async {
      SharedPreferences.setMockInitialValues({});
      var confirmed = 0;
      await pump(tester, () async => confirmed++);
      await tester.pumpAndSettle();
      expect(find.text('Was this refunded?'), findsOneWidget);
      expect(find.textContaining('4321'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('suspected-refund-yes')));
      await tester.pumpAndSettle();
      expect(confirmed, 1);
    });

    testWidgets('No hides it and remembers, so it is never asked again', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pump(tester, () async {});
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('suspected-refund-no')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('suspected-refund-banner')), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(SuspectedRefundBanner.dismissKey('event-big')), isTrue);

      // A fresh screen for the same spend stays quiet.
      await pump(tester, () async {});
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('suspected-refund-banner')), findsNothing);
    });
  });
}

final DateTime _noticed = DateTime.utc(2026, 11, 5);
