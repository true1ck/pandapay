// Two ways a number alone is evidence, and the care taken with each. Synthetic
// issuers, numbers and amounts only.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import '../linker/helpers.dart';

Instrument acct(String id, String issuer, String mask, {InstrumentStatus status = InstrumentStatus.confirmed}) =>
    instrument(id, InstrumentKind.bankAccount, issuer, mask, status: status);

Instrument card(String id, String issuer, String mask) =>
    instrument(id, InstrumentKind.creditCard, issuer, mask);

String uuid(int n) => '00000000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';

void main() {
  group('a mention with a number and no bank', () {
    final resolver = DefaultInstrumentResolver(idGenerator: () => uuid(999));
    InstrumentOutcome resolve(InstrumentMention m, List<Instrument> known) =>
        resolver.resolveDetailed(m, known, profileId: 'p', observedAt: DateTime.utc(2026, 11, 1));

    const mention = InstrumentMention(kind: InstrumentKind.bankAccount, maskDigits: '8648');

    test('points at the one account of that kind that ends in the number', () {
      final a = acct(uuid(1), 'alphabank', '8648');
      final other = acct(uuid(2), 'betabank', '2211');
      final out = resolve(mention, [a, other]);
      expect(out, isA<InstrumentResolved>());
      final res = (out as InstrumentResolved).resolution;
      expect(res.instrument.instrumentId, a.instrumentId);
      expect(res.created, isFalse);
    });

    test('a longer printed number still finds the account', () {
      final a = acct(uuid(1), 'alphabank', '648');
      expect(
        resolve(const InstrumentMention(kind: InstrumentKind.bankAccount, maskDigits: '2648'), [a]),
        isA<InstrumentNotCreated>(), // 648 is shorter than four digits, so not the same number
      );
      final full = acct(uuid(3), 'alphabank', '8648');
      expect(
        resolve(const InstrumentMention(kind: InstrumentKind.bankAccount, maskDigits: '728648'), [full]),
        isA<InstrumentResolved>(),
      );
    });

    test('never creates an account', () {
      expect(resolve(mention, const []), isA<InstrumentNotCreated>());
    });

    test('two accounts with the same ending are not guessed between', () {
      final a = acct(uuid(1), 'alphabank', '8648');
      final c = acct(uuid(3), 'gammabank', '8648');
      expect(resolve(mention, [a, c]), isA<InstrumentNotCreated>());
    });

    test('a rejected account is not a candidate', () {
      final a = acct(uuid(1), 'alphabank', '8648');
      final rejected = acct(uuid(3), 'gammabank', '8648', status: InstrumentStatus.rejected);
      final out = resolve(mention, [a, rejected]);
      expect(out, isA<InstrumentResolved>());
    });

    test('a card with the same digits is a different kind', () {
      final c = card(uuid(4), 'alphabank', '8648');
      expect(resolve(mention, [c]), isA<InstrumentNotCreated>());
    });

    test('without a number or a kind it names nothing', () {
      final a = acct(uuid(1), 'alphabank', '8648');
      expect(resolve(const InstrumentMention(kind: InstrumentKind.bankAccount), [a]), isA<InstrumentNotCreated>());
      expect(resolve(const InstrumentMention(maskDigits: '8648'), [a]), isA<InstrumentNotCreated>());
    });
  });

  group('notMineSuggestions', () {
    MovementFact pay(String who, String at) => move(
      'debit', 'p2p', 10000, at: at, counterparty: party(name: who, kind: 'person'),
    );

    test('suggests only a detected account whose money never names the owner or an own account', () {
      final stranger = acct(uuid(20), 'alphabank', '1111', status: InstrumentStatus.detected);
      final mine = acct(uuid(21), 'alphabank', '2222', status: InstrumentStatus.detected);
      final moved = acct(uuid(22), 'alphabank', '3333', status: InstrumentStatus.detected);
      final confirmed = acct(uuid(23), 'alphabank', '4444');
      final f1 = pay('ASHA RAO', '2026-11-01T10:00:00Z');
      final f2 = pay('RAVI MOHAN PATIL', '2026-11-02T10:00:00Z');
      final f3 = pay('ASHA RAO', '2026-11-03T10:00:00Z');
      final f4 = pay('ASHA RAO', '2026-11-04T10:00:00Z');
      final byFact = {
        f1.factId: stranger.instrumentId,
        f2.factId: mine.instrumentId,
        f3.factId: moved.instrumentId,
        f4.factId: confirmed.instrumentId,
      };
      final transfer = Event(
        eventId: 'e1',
        type: EventType.ownTransfer,
        status: EventStatus.complete,
        legs: [EventLeg(factId: f3.factId, role: LegRole.debitLeg)],
        confidence: 1,
        occurredAt: DateTime.utc(2026, 11, 3),
        amountMinor: 10000,
      );
      Set<String> ask(OwnerIdentity who) => notMineSuggestions(
        instruments: [stranger, mine, moved, confirmed],
        facts: [f1, f2, f3, f4],
        instrumentIdByFactId: byFact,
        events: [transfer],
        identity: who,
      );
      final owner = OwnerIdentity.fromEntries(['Ravi Mohan Patil']);
      expect(ask(owner), {stranger.instrumentId});
      expect(ask(OwnerIdentity()), isEmpty); // no owner name known: no hint
    });
  });

  group('a card payment notice and a new number', () {
    final cardA = card(uuid(10), 'alphabank', '9008');
    final bankAcct = acct(uuid(12), 'alphabank', '7788');

    MovementFact payment({String issuer = 'alphabank', String mask = '1724', String purpose = 'card_payment', String direction = 'credit', InstrumentKind kind = InstrumentKind.creditCard}) => move(
      direction,
      purpose,
      5062532,
      at: '2026-11-02T10:00:00Z',
      mention: InstrumentMention(kind: kind, issuerSlug: issuer, maskDigits: mask),
    );

    test('does not create a second card for an issuer that already has one', () {
      expect(cardPaymentMayCreateCard(payment(), [cardA]), isFalse);
    });

    test('creates the first card of an issuer', () {
      expect(cardPaymentMayCreateCard(payment(), const []), isTrue);
      expect(cardPaymentMayCreateCard(payment(issuer: 'betabank'), [cardA]), isTrue);
    });

    test('a rejected card does not count as one the issuer has', () {
      final rejected = instrument(uuid(13), InstrumentKind.creditCard, 'alphabank', '9008', status: InstrumentStatus.rejected);
      expect(cardPaymentMayCreateCard(payment(), [rejected]), isTrue);
    });

    test('a spend alert, a statement or an account may always create', () {
      expect(cardPaymentMayCreateCard(payment(purpose: 'purchase', direction: 'debit'), [cardA]), isTrue);
      expect(cardPaymentMayCreateCard(payment(kind: InstrumentKind.bankAccount, mask: '4455'), [cardA, bankAcct]), isTrue);
    });
  });
}
