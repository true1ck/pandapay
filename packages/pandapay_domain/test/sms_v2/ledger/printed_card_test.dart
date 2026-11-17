import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';
import '../linker/helpers.dart' as h;

// What a bank printed about the card or account decides which one a message
// is about. A stored link that the message contradicts is never used.
void main() {
  final at = DateTime.utc(2026, 11, 7, 8).toIso8601String();
  final sbiCard = h.instrument('00000000-0000-4000-8000-000000000011', InstrumentKind.creditCard, 'sbi', '2837');
  final pnbCard = h.instrument('00000000-0000-4000-8000-000000000012', InstrumentKind.creditCard, 'pnb', '1260');
  final sbiOther = h.instrument('00000000-0000-4000-8000-000000000013', InstrumentKind.creditCard, 'sbi', '4400');
  final sbiNoNumber = h.instrument('00000000-0000-4000-8000-000000000014', InstrumentKind.creditCard, 'sbi', null);
  final all = {for (final i in [sbiCard, pnbCard, sbiOther]) i.instrumentId: i};

  InstrumentMention printed({String? bank = 'sbi', String? mask = '2837'}) =>
      InstrumentMention(kind: InstrumentKind.creditCard, issuerSlug: bank, maskDigits: mask, maskLength: mask?.length);

  group('printedCardRulesOut', () {
    test('another bank is ruled out', () => expect(printedCardRulesOut(printed(), pnbCard), isTrue));
    test('another number of the same bank is ruled out', () => expect(printedCardRulesOut(printed(), sbiOther), isTrue));
    test('the same card is not', () => expect(printedCardRulesOut(printed(), sbiCard), isFalse));
    test('one number printed shorter or longer is the same number', () {
      expect(printedCardRulesOut(printed(mask: '837'), sbiCard), isFalse);
      expect(printedCardRulesOut(printed(mask: '102837'), sbiCard), isFalse);
      expect(printedCardRulesOut(printed(mask: '836'), sbiCard), isTrue);
    });
    test('a message with no number fits any card of its bank', () {
      expect(printedCardRulesOut(printed(mask: null), sbiOther), isFalse);
      expect(printedCardRulesOut(printed(mask: null), pnbCard), isTrue);
    });
    test('a card with no number fits any message of its bank', () {
      expect(printedCardRulesOut(printed(), sbiNoNumber), isFalse);
    });
    test('a notice that names no bank is judged by its number alone', () {
      expect(printedCardRulesOut(printed(bank: null, mask: '2837'), sbiCard), isFalse);
      expect(printedCardRulesOut(printed(bank: null, mask: '2837'), pnbCard), isTrue);
    });
    test('a message that names no card rules nothing out', () {
      expect(printedCardRulesOut(null, pnbCard), isFalse);
    });
  });

  group('instrumentForFact', () {
    final fact = h.debit('purchase', 15644, at: at, inst: sbiCard);

    test('a stored link to another bank\'s card is ignored for the card the SMS names', () {
      expect(instrumentForFact(fact, all, instrumentIdByFactId: {fact.factId: pnbCard.instrumentId}), sbiCard);
    });
    test('a stored link to another number of the same bank is ignored too', () {
      expect(instrumentForFact(fact, all, instrumentIdByFactId: {fact.factId: sbiOther.instrumentId}), sbiCard);
    });
    test('a stored link that fits what the SMS printed is kept', () {
      expect(instrumentForFact(fact, all, instrumentIdByFactId: {fact.factId: sbiCard.instrumentId}), sbiCard);
    });
    test('a person\'s choice between cards of the same bank for an SMS with no number is kept', () {
      final noNumber = h.debit('purchase', 15644, at: at, inst: sbiNoNumber);
      expect(instrumentForFact(noNumber, all, instrumentIdByFactId: {noNumber.factId: sbiOther.instrumentId}), sbiOther);
    });
    test('when the card the SMS names is not known, nothing is guessed', () {
      final onlyPnb = {pnbCard.instrumentId: pnbCard};
      expect(instrumentForFact(fact, onlyPnb, instrumentIdByFactId: {fact.factId: pnbCard.instrumentId}), isNull);
    });
  });
}
