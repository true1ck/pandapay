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
      idGenerator: () => '11111111-1111-4111-8111-${(n++).toRadixString(16).padLeft(12, '0')}',
    );
  });

  InstrumentOutcome run(InstrumentMention m, List<Instrument> known, {String? brand}) =>
      resolver.resolveDetailed(m, known, profileId: 'p', observedAt: _t, senderBrand: brand);

  Instrument created(InstrumentOutcome o) {
    expect(o, isA<InstrumentResolved>());
    final r = (o as InstrumentResolved).resolution;
    expect(r.created, isTrue);
    return r.instrument;
  }

  Instrument matched(InstrumentOutcome o) {
    expect(o, isA<InstrumentResolved>());
    final r = (o as InstrumentResolved).resolution;
    expect(r.created, isFalse);
    return r.instrument;
  }

  group('step 1: exact key match', () {
    test('kind, issuer and mask match one instrument', () {
      final a = instrument(kind: InstrumentKind.creditCard, mask: '5678');
      final b = instrument(kind: InstrumentKind.creditCard, mask: '1111');
      expect(matched(run(mention(mask: '5678'), [a, b])).instrumentId, a.instrumentId);
    });

    test('a card and an account with the same digits stay separate', () {
      final acct = instrument(kind: InstrumentKind.bankAccount, mask: '1234');
      final card = created(run(mention(kind: InstrumentKind.creditCard, mask: '1234'), [acct]));
      expect(card.kind, InstrumentKind.creditCard);
      expect(card.instrumentId, isNot(acct.instrumentId));
      // and the account is still found by its own kind
      expect(
        matched(
          run(mention(kind: InstrumentKind.bankAccount, mask: '1234'), [acct, card]),
        ).instrumentId,
        acct.instrumentId,
      );
    });

    test('debit card and credit card with the same digits stay separate', () {
      final credit = instrument(kind: InstrumentKind.creditCard, mask: '4321');
      final debit = created(run(mention(kind: InstrumentKind.debitCard, mask: '4321'), [credit]));
      expect(debit.kind, InstrumentKind.debitCard);
    });

    test('never merges across issuers', () {
      final hdfc = instrument(issuer: 'hdfc', kind: InstrumentKind.bankAccount, mask: '1234');
      final icici = created(
        run(mention(kind: InstrumentKind.bankAccount, issuer: 'icici', mask: '1234'), [hdfc]),
      );
      expect(icici.issuerSlug, 'icici');
      expect(icici.instrumentId, isNot(hdfc.instrumentId));
    });

    test('a 4-digit maskLength is not a card length and is not part of identity', () {
      final acct = instrument(kind: InstrumentKind.bankAccount, mask: '1234');
      // Same account, mention printed 4 digits; another message printed length 16.
      expect(
        matched(
          run(mention(kind: InstrumentKind.bankAccount, mask: '1234', maskLength: 4), [acct]),
        ).instrumentId,
        acct.instrumentId,
      );
      expect(
        matched(
          run(mention(kind: InstrumentKind.bankAccount, mask: '1234', maskLength: 16), [acct]),
        ).instrumentId,
        acct.instrumentId,
      );
    });

    test('identity ignores the sender id: two senders, one account', () {
      final first = created(
        run(
          mention(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '4455'),
          [],
          brand: 'SBIINB',
        ),
      );
      final second = matched(
        run(mention(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '4455'), [
          first,
        ], brand: 'SBICRD'),
      );
      expect(second.instrumentId, first.instrumentId);
    });
  });

  group('one number printed to different lengths', () {
    // SBI prints XXXXX728648 in one message and X8648 in another.
    test('a longer print of a known account is the same account', () {
      final known = instrument(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '8648');
      final out = run(mention(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '728648'), [known]);
      expect(matched(out).instrumentId, known.instrumentId);
    });

    test('a shorter print of a known account is the same account', () {
      final known = instrument(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '728648');
      final out = run(mention(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '8648'), [known]);
      expect(matched(out).instrumentId, known.instrumentId);
    });

    test('a mention without a kind finds it too', () {
      final known = instrument(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '8648');
      expect(matched(run(mention(kind: null, issuer: 'sbi', mask: '728648'), [known])).instrumentId, known.instrumentId);
    });

    test('different numbers, short masks and other issuers are never merged', () {
      final known = instrument(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '8648');
      // a different number that does not end with it
      expect(created(run(mention(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '728649'), [known])).maskDigits, '728649');
      // under four digits there is too little to call it the same number
      final short = instrument(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '48');
      expect(created(run(mention(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '8648'), [short])).maskDigits, '8648');
      // another issuer
      expect(created(run(mention(kind: InstrumentKind.bankAccount, issuer: 'icici', mask: '728648'), [known])).issuerSlug, 'icici');
      // a card is not an account
      expect(created(run(mention(kind: InstrumentKind.creditCard, issuer: 'sbi', mask: '728648'), [known])).kind, InstrumentKind.creditCard);
    });
  });

  group('a wallet first seen without a number', () {
    test('the numbered wallet is chosen over its number-less duplicate', () {
      final numbered = instrument(kind: InstrumentKind.wallet, issuer: 'pluxee', mask: '6546');
      final bare = instrument(kind: InstrumentKind.wallet, issuer: 'pluxee', mask: null);
      final out = run(mention(kind: InstrumentKind.wallet, issuer: 'pluxee', mask: null), [bare, numbered]);
      expect(matched(out).instrumentId, numbered.instrumentId);
    });

    test('two numbered wallets are still ambiguous', () {
      final a = instrument(kind: InstrumentKind.wallet, issuer: 'pluxee', mask: '6546');
      final b = instrument(kind: InstrumentKind.wallet, issuer: 'pluxee', mask: '1111');
      final out = run(mention(kind: InstrumentKind.wallet, issuer: 'pluxee', mask: null), [a, b]);
      expect(out, isA<InstrumentReviewNeeded>());
    });
  });

  group('step 2: mention without a kind', () {
    test('the one instrument with that issuer and mask', () {
      final a = instrument(kind: InstrumentKind.creditCard, mask: '5678');
      final b = instrument(kind: InstrumentKind.creditCard, mask: '9999');
      expect(matched(run(mention(kind: null, mask: '5678'), [a, b])).instrumentId, a.instrumentId);
    });

    test('a card and an account with those digits is ambiguous and creates nothing', () {
      final card = instrument(kind: InstrumentKind.creditCard, mask: '1234');
      final acct = instrument(kind: InstrumentKind.bankAccount, mask: '1234');
      final out = run(mention(kind: null, mask: '1234'), [card, acct]);
      expect(out, isA<InstrumentReviewNeeded>());
      final review = out as InstrumentReviewNeeded;
      expect(review.reason, InstrumentReviewReason.ambiguous);
      expect(
        review.candidates.map((c) => c.instrumentId),
        unorderedEquals([card.instrumentId, acct.instrumentId]),
      );
    });

    test('nothing fits: needs a kind to create, so review', () {
      final out = run(mention(kind: null, mask: '5678'), []);
      expect(out, isA<InstrumentReviewNeeded>());
      expect((out as InstrumentReviewNeeded).reason, InstrumentReviewReason.kindUnknown);
    });

    test('another issuer with the same digits is not a candidate', () {
      final other = instrument(issuer: 'icici', kind: InstrumentKind.creditCard, mask: '5678');
      final out = run(mention(kind: null, issuer: 'hdfc', mask: '5678'), [other]);
      expect(out, isA<InstrumentReviewNeeded>());
      expect((out as InstrumentReviewNeeded).reason, InstrumentReviewReason.kindUnknown);
    });
  });

  group('step 3: mention without a mask', () {
    test('the one instrument with that issuer and kind', () {
      final card = instrument(kind: InstrumentKind.creditCard, mask: '5678');
      final acct = instrument(kind: InstrumentKind.bankAccount, mask: '1234');
      expect(matched(run(mention(mask: null), [card, acct])).instrumentId, card.instrumentId);
    });

    test('two cards of that issuer is ambiguous and creates nothing', () {
      final a = instrument(kind: InstrumentKind.creditCard, mask: '5678');
      final b = instrument(kind: InstrumentKind.creditCard, mask: '1111');
      final out = run(mention(mask: null), [a, b]);
      expect(out, isA<InstrumentReviewNeeded>());
      expect((out as InstrumentReviewNeeded).reason, InstrumentReviewReason.ambiguous);
    });

    test('a card without a mask and no card of that issuer creates nothing', () {
      final out = run(mention(mask: null), []);
      expect(out, isA<InstrumentNotCreated>());
      expect((out as InstrumentNotCreated).reason, InstrumentNotCreatedReason.noIdentity);
    });

    test('a wallet needs no mask: one per issuer and kind', () {
      final w = created(run(mention(kind: InstrumentKind.wallet, issuer: 'paytm', mask: null), []));
      expect(w.kind, InstrumentKind.wallet);
      expect(w.maskDigits, isNull);
      expect(
        matched(
          run(mention(kind: InstrumentKind.wallet, issuer: 'paytm', mask: null), [w]),
        ).instrumentId,
        w.instrumentId,
      );
    });

    test('a broker needs no mask either', () {
      final b = created(run(mention(kind: InstrumentKind.broker, issuer: 'groww', mask: null), []));
      expect(b.kind, InstrumentKind.broker);
    });
  });

  group('step 4: creation', () {
    test('a new instrument is detected, has a uuid v4, default name and the sender alias', () {
      final i = created(
        run(
          mention(
            kind: InstrumentKind.creditCard,
            issuer: 'hdfc',
            mask: '5678',
            product: 'Regalia',
          ),
          [],
          brand: 'HDFCBK',
        ),
      );
      expect(i.status, InstrumentStatus.detected);
      expect(
        i.instrumentId,
        matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
      expect(i.displayName, 'HDFC credit card ••5678');
      expect(i.aliases.senders, ['HDFCBK']);
      expect(i.aliases.productNames, ['Regalia']);
      expect(i.firstSeenAt, _t);
      expect(i.lastSeenAt, _t);
      expect(i.evidenceCount, 0);
      expect(i.validate().ok, isTrue, reason: '${i.validate().errors}');
    });

    test('the default id generator makes valid, distinct uuid v4 values', () {
      final r = DefaultInstrumentResolver();
      final a = created(r.resolveDetailed(mention(), [], profileId: 'p', observedAt: _t));
      final b = created(
        r.resolveDetailed(
          mention(mask: '1111'),
          [],
          profileId: 'p',
          observedAt: _t,
        ),
      );
      expect(a.validate().ok, isTrue);
      expect(a.instrumentId, isNot(b.instrumentId));
    });

    test('maskLength is kept only when it says more than the mask', () {
      final printed = created(
        run(
          mention(kind: InstrumentKind.bankAccount, issuer: 'axis', mask: '1234', maskLength: 4),
          [],
        ),
      );
      expect(printed.maskLength, isNull);
      final full = created(
        run(
          mention(kind: InstrumentKind.creditCard, issuer: 'axis', mask: '1234', maskLength: 16),
          [],
        ),
      );
      expect(full.maskLength, 16);
    });

    test('no issuer creates nothing', () {
      final out = run(mention(issuer: null), []);
      expect((out as InstrumentNotCreated).reason, InstrumentNotCreatedReason.noIssuer);
    });

    test('no kind and no mask creates nothing', () {
      final out = run(mention(kind: null, mask: null), []);
      expect((out as InstrumentNotCreated).reason, InstrumentNotCreatedReason.emptyMention);
    });

    test('a mask that is not 2 to 6 digits counts as no mask', () {
      final bad = const InstrumentMention(
        kind: InstrumentKind.creditCard,
        issuerSlug: 'hdfc',
        maskDigits: '1234567',
      );
      expect((run(bad, []) as InstrumentNotCreated).reason, InstrumentNotCreatedReason.noIdentity);
    });

    test('the interface method returns a resolution, or throws with the outcome', () {
      final r = resolver.resolve(mention(), [], profileId: 'p', observedAt: _t);
      expect(r.created, isTrue);
      expect(
        () => resolver.resolve(mention(issuer: null), [], profileId: 'p', observedAt: _t),
        throwsA(isA<InstrumentNotResolvedException>()),
      );
    });
  });

  group('UPI-app senders', () {
    test('never create a bank account from a mask alone', () {
      final out = run(
        mention(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '9876'),
        [],
        brand: 'SBIUPI',
      );
      expect(out, isA<InstrumentNotCreated>());
      expect((out as InstrumentNotCreated).reason, InstrumentNotCreatedReason.upiAppMask);
    });

    test('any brand containing UPI counts', () {
      final out = run(
        mention(kind: InstrumentKind.bankAccount, issuer: 'bob', mask: '9876'),
        [],
        brand: 'BOBUPI',
      );
      expect((out as InstrumentNotCreated).reason, InstrumentNotCreatedReason.upiAppMask);
    });

    test('may still match an account the user already has', () {
      final acct = instrument(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '9876');
      expect(
        matched(
          run(mention(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '9876'), [
            acct,
          ], brand: 'SBIUPI'),
        ).instrumentId,
        acct.instrumentId,
      );
    });

    test('do not stop a bank sender creating the same account', () {
      final i = created(
        run(
          mention(kind: InstrumentKind.bankAccount, issuer: 'sbi', mask: '9876'),
          [],
          brand: 'SBIINB',
        ),
      );
      expect(i.maskDigits, '9876');
    });

    test('a counterparty mask is not an instrument mention', () {
      // Rules put a counterparty\'s digits in counterparty.accountMask; a fact
      // with no instrument mention has nothing to resolve.
      final f = fact(
        'movement',
        observedAt: '2026-11-01T10:00:00Z',
        counterparty: {'name': 'X', 'vpa': null, 'kind': 'person', 'accountMask': '9876'},
        amounts: [
          {'role': 'posted', 'minor': 100, 'unit': 'INR'},
        ],
        attrs: {'direction': 'debit', 'purpose': 'p2p', 'rail': 'upi'},
      );
      expect(f.instrument, isNull);
    });
  });

  group('wallets with partial visibility', () {
    test('Amazon Pay balance activity never creates an instrument', () {
      final r = DefaultInstrumentResolver(partialWalletIssuers: {'amazonpay'});
      final out = r.resolveDetailed(
        mention(kind: InstrumentKind.wallet, issuer: 'amazonpay', mask: null),
        [],
        profileId: 'p',
        observedAt: _t,
      );
      expect((out as InstrumentNotCreated).reason, InstrumentNotCreatedReason.partialWallet);
    });

    test('a full-visibility wallet is still created', () {
      final r = DefaultInstrumentResolver(partialWalletIssuers: {'amazonpay'});
      final out = r.resolveDetailed(
        mention(kind: InstrumentKind.wallet, issuer: 'paytm', mask: null),
        [],
        profileId: 'p',
        observedAt: _t,
      );
      expect(out, isA<InstrumentResolved>());
    });
  });

  group('rejected instruments', () {
    test('later facts for a rejected key go to review; the instrument stays', () {
      final rejected = instrument(
        kind: InstrumentKind.bankAccount,
        mask: '1234',
        status: InstrumentStatus.rejected,
      );
      final out = run(mention(kind: InstrumentKind.bankAccount, mask: '1234'), [rejected]);
      expect(out, isA<InstrumentReviewNeeded>());
      final review = out as InstrumentReviewNeeded;
      expect(review.reason, InstrumentReviewReason.rejected);
      expect(review.candidates.single.instrumentId, rejected.instrumentId);
    });

    test('archived instruments still resolve', () {
      final archived = instrument(status: InstrumentStatus.archived);
      expect(matched(run(mention(), [archived])).instrumentId, archived.instrumentId);
    });
  });

  group('probe formats resolve to one account each', () {
    // Digits as the engine reports them for these printed forms.
    final cases = <String, ({String issuer, String mask})>{
      'Axis A/c no. XX123456': (issuer: 'axis', mask: '123456'),
      'Kotak AC X1234': (issuer: 'kotak', mask: '1234'),
      'ICICI Acct XX1234': (issuer: 'icici', mask: '1234'),
    };
    cases.forEach((label, c) {
      test(label, () {
        final m = mention(kind: InstrumentKind.bankAccount, issuer: c.issuer, mask: c.mask);
        final first = created(run(m, []));
        expect(first.issuerSlug, c.issuer);
        expect(first.maskDigits, c.mask);
        expect(matched(run(m, [first])).instrumentId, first.instrumentId);
      });
    });

    test('same digits at three issuers make three accounts', () {
      var known = <Instrument>[];
      for (final issuer in ['axis', 'kotak', 'icici']) {
        known = [
          ...known,
          created(
            run(mention(kind: InstrumentKind.bankAccount, issuer: issuer, mask: '1234'), known),
          ),
        ];
      }
      expect(known.length, 3);
    });
  });
}
