import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/projection_writer.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';

/// The rail a message names (NEFT, IMPS, RTGS, cheque, auto-debit) becomes the
/// payment method on the row. Spending is not touched by it.
void main() {
  TransactionEntry? project(String? rail) {
    final json =
        (jsonDecode(
                  File(
                    '../contracts/sms/v2/fixtures/valid/fact/movement.card_spend.json',
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>();
    (json['attrs'] as Map)['rail'] = rail;
    final f = Fact.fromJson(json);
    final e = Event(
      eventId: f.factId,
      type: EventType.purchase,
      status: EventStatus.complete,
      legs: [EventLeg(factId: f.factId, role: LegRole.debitLeg)],
      confidence: .99,
      occurredAt: f.effectiveAt,
      amountMinor: f.amounts.first.minor,
    );
    final rows = DefaultLedgerProjector().project(
      e,
      {f.factId: f},
      const {},
      const CategoryDecision(slug: 'other', source: CategorySource.user, confidence: 1),
    );
    return transactionForEvent(e, rows, {f.factId: f}, const {});
  }

  for (final (rail, method) in [
    ('upi', 'upi'),
    ('neft', 'neft'),
    ('imps', 'imps'),
    ('rtgs', 'rtgs'),
    ('cheque', 'cheque'),
    ('nach', 'auto_debit'),
    ('card', null),
    ('unknown', null),
  ]) {
    test('rail $rail gives payment method $method and still counts as spend', () {
      final row = project(rail);
      expect(row, isNotNull);
      expect(row!.paymentMethod, method);
      expect(row.entryKind, TxnEntryKind.spend);
    });
  }
}
