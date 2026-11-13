import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/projection_writer.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';

/// The bank's own cashback credit ("Cashback of INR 120 has been credited to
/// your Axis Bank Flipkart Credit Card") is a confirmed reward from the bank,
/// not income from an unknown payer.
void main() {
  Map<String, Object?> fixture() =>
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/fact/movement.card_spend.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();

  TransactionEntry? project({required bool asCashback}) {
    final json = fixture();
    (json['attrs'] as Map)['direction'] = 'credit';
    (json['attrs'] as Map)['purpose'] = asCashback ? 'cashback' : 'refund';
    json['counterparty'] = null;
    final f = Fact.fromJson(json);
    final i = Instrument(
      instrumentId: '00000000-0000-4000-8000-000000000001',
      kind: InstrumentKind.creditCard,
      issuerSlug: f.instrument!.issuerSlug!,
      maskDigits: f.instrument!.maskDigits,
      displayName: 'My card',
      status: InstrumentStatus.confirmed,
      userCardId: '00000000-0000-4000-8000-000000000002',
      firstSeenAt: f.observedAt,
      lastSeenAt: f.observedAt,
      evidenceCount: 1,
    );
    final e = Event(
      eventId: f.factId,
      type: asCashback ? EventType.cashback : EventType.refund,
      status: EventStatus.complete,
      legs: [EventLeg(factId: f.factId, role: LegRole.creditLeg)],
      confidence: .99,
      occurredAt: f.effectiveAt,
      amountMinor: f.amounts.first.minor,
    );
    final rows = DefaultLedgerProjector().project(
      e,
      {f.factId: f},
      {i.instrumentId: i},
      const CategoryDecision(
        slug: 'other',
        source: CategorySource.user,
        confidence: 1,
      ),
    );
    return transactionForEvent(e, rows, {f.factId: f}, {i.instrumentId: i});
  }

  test('a cashback credit reads "Cashback received" and is a confirmed reward', () {
    final row = project(asCashback: true);
    expect(row, isNotNull);
    expect(row!.merchantName, 'Cashback received');
    expect(row.rewardState, 'confirmed');
    expect(row.entryKind, TxnEntryKind.income);
  });

  test('an ordinary refund keeps the estimate state and is never labelled cashback', () {
    final row = project(asCashback: false);
    expect(row, isNotNull);
    expect(row!.merchantName, isNot('Cashback received'));
    expect(row.rewardState, 'estimated');
    expect(row.entryKind, TxnEntryKind.refund);
  });
}
