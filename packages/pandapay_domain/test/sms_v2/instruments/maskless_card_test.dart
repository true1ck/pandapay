// Some credit cards never print their number in an SMS (the alert says "your
// <product> credit card" and nothing else). When money actually moved on such a
// card, the card is the source: it must become an instrument, once, without a
// number. This must hold for any issuer, must not invent cards from weak
// evidence, and must not leave a duplicate when a numbered message arrives
// later. Synthetic mentions only.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final _t = DateTime.utc(2026, 11, 2, 9);

void main() {
  late DefaultInstrumentResolver resolver;
  var n = 0;

  setUp(() {
    n = 0;
    resolver = DefaultInstrumentResolver(
      idGenerator: () => '22222222-2222-4222-8222-${(n++).toRadixString(16).padLeft(12, '0')}',
    );
  });

  InstrumentOutcome run(
    InstrumentMention m,
    List<Instrument> known, {
    bool createWithoutMask = true,
    bool adoptNumberlessCard = true,
    String? brand,
  }) => resolver.resolveDetailed(
    m,
    known,
    profileId: 'p',
    observedAt: _t,
    senderBrand: brand,
    createWithoutMask: createWithoutMask,
    adoptNumberlessCard: adoptNumberlessCard,
  );

  Instrument created(InstrumentOutcome o) {
    expect(o, isA<InstrumentResolved>(), reason: '$o');
    final r = (o as InstrumentResolved).resolution;
    expect(r.created, isTrue);
    return r.instrument;
  }

  Instrument matched(InstrumentOutcome o) {
    expect(o, isA<InstrumentResolved>(), reason: '$o');
    final r = (o as InstrumentResolved).resolution;
    expect(r.created, isFalse);
    return r.instrument;
  }

  InstrumentMention card({String issuer = 'federal', String? mask, String? product}) => mention(
    kind: InstrumentKind.creditCard,
    issuer: issuer,
    mask: mask,
    product: product,
  );

  group('creating a card that has no number', () {
    test('by default nothing is created (a number is the identity)', () {
      final out = run(card(), [], createWithoutMask: false);
      expect(out, isA<InstrumentNotCreated>());
      expect((out as InstrumentNotCreated).reason, InstrumentNotCreatedReason.noIdentity);
    });

    test('money moved on a card of an issuer with no card yet: one numberless card', () {
      final c = created(run(card(product: 'Scapia Federal Visa'), []));
      expect(c.kind, InstrumentKind.creditCard);
      expect(c.issuerSlug, 'federal');
      expect(c.maskDigits, isNull);
      expect(c.status, InstrumentStatus.detected);
      expect(c.aliases.productNames, ['Scapia Federal Visa']);
    });

    test('the next numberless message finds that card, no second card appears', () {
      final first = created(run(card(), []));
      expect(matched(run(card(), [first])).instrumentId, first.instrumentId);
    });

    test('works for any issuer, not one brand', () {
      for (final issuer in ['federal', 'slice', 'onecard', 'amex', 'au_small_finance', 'idfc_first']) {
        final c = created(run(card(issuer: issuer), []));
        expect(c.issuerSlug, issuer);
        expect(c.maskDigits, isNull);
      }
    });

    test('one numbered card of that issuer: the numberless message belongs to it', () {
      final existing = instrument(issuer: 'federal', kind: InstrumentKind.creditCard, mask: '4321');
      expect(matched(run(card(), [existing])).instrumentId, existing.instrumentId);
    });

    test('two numbered cards of that issuer: not guessed, sent to review', () {
      final a = instrument(issuer: 'federal', kind: InstrumentKind.creditCard, mask: '4321');
      final b = instrument(issuer: 'federal', kind: InstrumentKind.creditCard, mask: '8765');
      final out = run(card(), [a, b]);
      expect(out, isA<InstrumentReviewNeeded>());
      expect((out as InstrumentReviewNeeded).reason, InstrumentReviewReason.ambiguous);
    });

    test('a card of another issuer is no reason to attach: this issuer gets its own', () {
      final other = instrument(issuer: 'hdfc', kind: InstrumentKind.creditCard, mask: '4321');
      final c = created(run(card(issuer: 'federal'), [other]));
      expect(c.issuerSlug, 'federal');
      expect(c.instrumentId, isNot(other.instrumentId));
    });

    test('an account of the same issuer is not a card', () {
      final acct = instrument(issuer: 'federal', kind: InstrumentKind.bankAccount, mask: '4321');
      final c = created(run(card(), [acct]));
      expect(c.kind, InstrumentKind.creditCard);
    });

    test('a card the user rejected is never brought back by a numberless message', () {
      final rejected = instrument(
        issuer: 'federal',
        kind: InstrumentKind.creditCard,
        mask: null,
        status: InstrumentStatus.rejected,
      );
      final out = run(card(), [rejected]);
      expect(out, isA<InstrumentReviewNeeded>());
      expect((out as InstrumentReviewNeeded).reason, InstrumentReviewReason.rejected);
    });

    test('no issuer: nothing is created', () {
      final out = run(mention(kind: InstrumentKind.creditCard, issuer: null, mask: null), []);
      expect((out as InstrumentNotCreated).reason, InstrumentNotCreatedReason.noIssuer);
    });

    test('a garbled number is not "no number": it never creates a phantom card', () {
      for (final bad in ['1234567', '9', '12345678901']) {
        final out = run(
          InstrumentMention(kind: InstrumentKind.creditCard, issuerSlug: 'federal', maskDigits: bad),
          [],
        );
        expect(out, isA<InstrumentNotCreated>(), reason: bad);
        expect((out as InstrumentNotCreated).reason, InstrumentNotCreatedReason.noIdentity);
      }
    });

    test('only credit cards: accounts, debit cards, prepaid cards and loans stay unidentified', () {
      for (final kind in [
        InstrumentKind.bankAccount,
        InstrumentKind.debitCard,
        InstrumentKind.prepaidCard,
        InstrumentKind.loan,
      ]) {
        final out = run(mention(kind: kind, issuer: 'federal', mask: null), []);
        expect(out, isA<InstrumentNotCreated>(), reason: '$kind');
        expect((out as InstrumentNotCreated).reason, InstrumentNotCreatedReason.noIdentity);
      }
    });

    test('a message with a kind-less, number-less mention creates nothing', () {
      final out = run(mention(kind: null, issuer: 'federal', mask: null), []);
      expect((out as InstrumentNotCreated).reason, InstrumentNotCreatedReason.emptyMention);
    });
  });

  group('a numbered message arrives after a numberless card exists', () {
    Instrument numberless({
      String issuer = 'federal',
      List<String> products = const [],
      String? userCardId,
      InstrumentStatus status = InstrumentStatus.detected,
      String? name,
    }) {
      final base = instrument(issuer: issuer, kind: InstrumentKind.creditCard, mask: null, status: status);
      return base.copyWith(
        aliases: InstrumentAliases(productNames: products),
        userCardId: userCardId,
        displayName: name ?? base.displayName,
      );
    }

    test('it becomes that card: same id, the number is added, no duplicate', () {
      final old = numberless();
      final out = matched(run(card(mask: '4321'), [old]));
      expect(out.instrumentId, old.instrumentId);
      expect(out.maskDigits, '4321');
      expect(out.displayName, 'Federal credit card ••4321');
      expect(out.status, InstrumentStatus.detected);
    });

    test('the user name for the card is kept', () {
      final old = numberless(name: 'My travel card');
      expect(matched(run(card(mask: '4321'), [old])).displayName, 'My travel card');
    });

    test('a confirmed card stays confirmed', () {
      final old = numberless(status: InstrumentStatus.confirmed);
      expect(matched(run(card(mask: '4321'), [old])).status, InstrumentStatus.confirmed);
    });

    test('the same product keeps one card, a different product is another card', () {
      final old = numberless(products: ['Scapia Federal Visa']);
      expect(
        matched(run(card(mask: '4321', product: 'Scapia'), [old])).instrumentId,
        old.instrumentId,
      );
      final other = created(run(card(mask: '9999', product: 'Signet Visa'), [old]));
      expect(other.instrumentId, isNot(old.instrumentId));
      expect(other.maskDigits, '9999');
    });

    test('a card the user linked from the catalogue is not taken over by a guess', () {
      final old = numberless(userCardId: '33333333-3333-4333-8333-333333333333');
      final out = created(run(card(mask: '4321'), [old]));
      expect(out.instrumentId, isNot(old.instrumentId));
    });

    test('a rejected numberless card is not revived', () {
      final old = numberless(status: InstrumentStatus.rejected);
      final out = created(run(card(mask: '4321'), [old]));
      expect(out.instrumentId, isNot(old.instrumentId));
    });

    test('when the issuer already has a numbered card too, a new number is a new card', () {
      final old = numberless();
      final numbered = instrument(issuer: 'federal', kind: InstrumentKind.creditCard, mask: '1111');
      final out = created(run(card(mask: '2222'), [old, numbered]));
      expect(out.maskDigits, '2222');
    });

    test('another issuer\'s numberless card is untouched', () {
      final old = numberless(issuer: 'slice');
      final out = created(run(card(issuer: 'federal', mask: '4321'), [old]));
      expect(out.issuerSlug, 'federal');
    });

    test('a number on a payment receipt (the card ACCOUNT number) does not complete the card', () {
      final old = numberless();
      final out = run(card(mask: '4321'), [old], adoptNumberlessCard: false);
      expect(created(out).instrumentId, isNot(old.instrumentId));
    });

    test('the same number printed again finds the card the usual way', () {
      final old = numberless();
      final adopted = matched(run(card(mask: '4321'), [old]));
      expect(matched(run(card(mask: '4321'), [adopted])).instrumentId, old.instrumentId);
    });

    test('wallets are not touched: a numbered wallet is still its own instrument', () {
      final wallet = instrument(issuer: 'pluxee', kind: InstrumentKind.wallet, mask: null);
      final out = created(
        run(mention(kind: InstrumentKind.wallet, issuer: 'pluxee', mask: '6546'), [wallet]),
      );
      expect(out.maskDigits, '6546');
    });
  });
}
