// A bill paid through a bill-pay app: the bank debit names only the app. The card's own issuer then sends
// "repayment received for the <issuer> credit card" with no card number. Joined to the debit as evidence, it
// names the destination card when exactly one card of that issuer exists, and never guesses between two.
// Synthetic facts only.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';

import '../linker/helpers.dart' as h;

final at = DateTime.utc(2026, 9, 4, 4, 26);

void main() {
  final projector = DefaultLedgerProjector();
  final sliceCard = h.instrument('00000000-0000-4000-8000-0000000000a1', InstrumentKind.creditCard, 'slice', '9080');
  final sliceTwin = h.instrument('00000000-0000-4000-8000-0000000000a2', InstrumentKind.creditCard, 'slice', '1111');

  final bankDebit = h.debit(
    'card_payment',
    402519,
    at: at.toIso8601String(),
    inst: h.hdfcAcct,
    counterparty: h.party(name: 'SOME BILLPAY APP', kind: 'merchant'),
    sourceKey: 'sms:bank-debit',
  );
  final receipt = h.debit(
    'bill_payment',
    402519,
    at: at.add(const Duration(seconds: 30)).toIso8601String(),
    evidenceOnly: true,
    mention: const InstrumentMention(kind: InstrumentKind.creditCard, issuerSlug: 'slice'),
    sourceKey: 'sms:issuer-receipt',
  );
  final event = Event(
    eventId: bankDebit.factId,
    type: EventType.cardBillPayment,
    status: EventStatus.complete,
    legs: [
      EventLeg(factId: bankDebit.factId, role: LegRole.debitLeg),
      EventLeg(factId: receipt.factId, role: LegRole.duplicateNotice),
    ],
    confidence: .99,
    occurredAt: at,
    amountMinor: 402519,
  );
  final byId = {bankDebit.factId: bankDebit, receipt.factId: receipt};

  LedgerEndpoint destination(Map<String, Instrument> cards) =>
      projector.project(event, byId, {...h.allInstruments, ...cards}, null).single.to;

  test('the issuer\'s receipt without a number picks the one card of that issuer', () {
    final to = destination({sliceCard.instrumentId: sliceCard});
    expect(to, isA<InstrumentEndpoint>());
    expect((to as InstrumentEndpoint).instrumentId, sliceCard.instrumentId);
  });

  test('two cards of that issuer: nothing is guessed, the person is asked', () {
    final to = destination({sliceCard.instrumentId: sliceCard, sliceTwin.instrumentId: sliceTwin});
    expect(to, isA<OwnUnresolvedEndpoint>());
  });

  test('no card of that issuer on the phone: still unresolved', () {
    expect(destination({}), isA<OwnUnresolvedEndpoint>());
  });

  test('a rejected card is never the destination', () {
    final rejected = h.instrument(sliceCard.instrumentId, InstrumentKind.creditCard, 'slice', '9080', status: InstrumentStatus.rejected);
    expect(destination({rejected.instrumentId: rejected}), isA<OwnUnresolvedEndpoint>());
  });
}
