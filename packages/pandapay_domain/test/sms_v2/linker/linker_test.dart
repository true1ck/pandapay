import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Event _only(LinkResult r) {
  final all = eventsOf(r);
  expect(all, hasLength(1), reason: shapes(r).toString());
  return all.single;
}

Event _of(LinkResult r, EventType type) =>
    eventsOf(r).singleWhere((e) => e.type == type);

void main() {
  group('LINK-CARD-BILL', () {
    final debitD = debit(
      'card_payment',
      2500000,
      at: '2026-11-10T09:00:00Z',
      inst: hdfcAcct,
      counterparty: party(kind: 'own', mask: '5678'),
    );
    final creditC = credit(
      'card_payment',
      2500000,
      at: '2026-11-10T09:02:00Z',
      inst: hdfcCard,
    );

    test('bank debit then card "payment received" make one transfer event', () {
      final r = linkAll([debitD, creditC]);
      final e = _only(r);
      expect(shape(e), 'card_bill_payment[credit_leg,debit_leg]');
      expect(e.eventId, debitD.factId);
      expect(e.linkRuleId, 'LINK-CARD-BILL');
      expect(e.status, EventStatus.complete);
      expect(e.amountMinor, 2500000);
      expect(e.validate().ok, isTrue);
    });

    test('legs arriving in either order give the same pair', () {
      final early = credit(
        'card_payment',
        2500000,
        at: '2026-11-10T08:00:00Z',
        inst: hdfcCard,
      );
      final r = linkAll([debitD, early]);
      final e = _only(r);
      expect(shape(e), 'card_bill_payment[credit_leg,debit_leg]');
      expect(e.eventId, early.factId, reason: 'the earlier fact anchors');
      expect(e.legs.first.factId, e.eventId);
    });

    test('a different amount does not join', () {
      final other = credit(
        'card_payment',
        2400000,
        at: '2026-11-10T09:02:00Z',
        inst: hdfcCard,
      );
      expect(shapes(linkAll([debitD, other])), [
        'card_bill_payment[credit_leg]',
        'card_bill_payment[debit_leg]',
      ]);
    });

    test('a debit naming another card does not join', () {
      final elsewhere = debit(
        'card_payment',
        2500000,
        at: '2026-11-10T09:00:00Z',
        inst: hdfcAcct,
        counterparty: party(kind: 'own', mask: '4444'),
      );
      expect(eventsOf(linkAll([elsewhere, creditC])), hasLength(2));
    });

    test('a leg arriving after the 72-hour window stays separate', () {
      final late = credit(
        'card_payment',
        2500000,
        at: '2026-11-14T09:00:00Z',
        inst: hdfcCard,
      );
      expect(shapes(linkAll([debitD, late])), [
        'card_bill_payment[credit_leg]',
        'card_bill_payment[debit_leg]',
      ]);
    });

    test(
      'CHEQ or CRED debit with no card receipt is still a card bill payment',
      () {
        final cheq = debit(
          'card_payment',
          1850000,
          at: '2026-11-12T10:15:00Z',
          inst: hdfcAcct,
          counterparty: party(vpa: 'cheq.hdfccard@icici', kind: 'own'),
          references: {'upiRef': '432100998877'},
        );
        final e = _only(linkAll([cheq]));
        expect(shape(e), 'card_bill_payment[debit_leg]');
        expect(e.status, EventStatus.complete);
      },
    );
  });

  group('LINK-CARD-BILL with a bill-payment debit', () {
    // A bank's "bill pay" debit does not say what was paid. A card receipt for
    // the same amount shortly after says it was a card bill.
    final billDebit = debit(
      'bill_payment',
      93000,
      at: '2026-11-19T12:44:00Z',
      inst: hdfcAcct,
    );
    final cardReceipt = credit(
      'card_payment',
      93000,
      at: '2026-11-19T13:03:00Z',
      inst: hdfcCard,
    );

    test('the debit and the card receipt are one card bill payment', () {
      final e = _only(linkAll([billDebit, cardReceipt]));
      expect(shape(e), 'card_bill_payment[credit_leg,debit_leg]');
      expect(e.amountMinor, 93000);
    });

    test('the receipt first gives the same pair', () {
      final e = _only(linkAll([cardReceipt, billDebit]));
      expect(shape(e), 'card_bill_payment[credit_leg,debit_leg]');
    });

    test('a bill-payment debit with no card receipt is a plain bill payment', () {
      expect(shapes(linkAll([billDebit])), ['bill_payment[debit_leg]']);
    });

    test('a different amount does not join', () {
      final other = credit(
        'card_payment',
        90000,
        at: '2026-11-19T13:03:00Z',
        inst: hdfcCard,
      );
      expect(shapes(linkAll([billDebit, other])), [
        'bill_payment[debit_leg]',
        'card_bill_payment[credit_leg]',
      ]);
    });

    test('a debit typed as a card payment still stands alone as a card bill', () {
      final typed = debit(
        'card_payment',
        93000,
        at: '2026-11-19T12:44:00Z',
        inst: hdfcAcct,
        counterparty: party(kind: 'own'),
      );
      expect(shapes(linkAll([typed])), ['card_bill_payment[debit_leg]']);
    });
  });

  group('LINK-WALLET-TOPUP', () {
    test(
      'bank top-up and wallet credit pair; the wallet purchase is the spend',
      () {
        final d = debit(
          'wallet_topup',
          50000,
          at: '2026-11-01T09:00:00Z',
          inst: hdfcAcct,
          counterparty: party(vpa: 'add-money@paytm', kind: 'own'),
        );
        final c = credit(
          'wallet_topup',
          50000,
          at: '2026-11-01T09:01:00Z',
          inst: paytmWallet,
        );
        final spend = debit(
          'purchase',
          12000,
          at: '2026-11-02T08:30:00Z',
          inst: paytmWallet,
          counterparty: party(name: 'Chai Point', kind: 'merchant'),
        );
        final r = linkAll([spend, c, d]);
        expect(shapes(r), [
          'purchase[debit_leg]',
          'wallet_topup[credit_leg,debit_leg]',
        ]);
        expect(_of(r, EventType.walletTopup).eventId, d.factId);
      },
    );

    test('a credit into a different wallet does not join', () {
      final d = debit(
        'wallet_topup',
        50000,
        at: '2026-11-01T09:00:00Z',
        inst: hdfcAcct,
        counterparty: party(vpa: 'add-money@paytm', kind: 'own'),
      );
      final c = credit(
        'wallet_topup',
        50000,
        at: '2026-11-01T09:01:00Z',
        mention: const InstrumentMention(
          kind: InstrumentKind.wallet,
          issuerSlug: 'phonepe',
        ),
      );
      expect(shapes(linkAll([d, c])), [
        'wallet_topup[credit_leg]',
        'wallet_topup[debit_leg]',
      ]);
    });

    test(
      'Amazon Pay top-up is a purchase; balance payments are wallet activity only',
      () {
        final topup = debit(
          'wallet_topup',
          100000,
          at: '2026-11-03T11:00:00Z',
          inst: hdfcAcct,
          counterparty: party(vpa: 'amazonpay@apl', kind: 'own'),
        );
        final balancePay = debit(
          'purchase',
          49900,
          at: '2026-11-04T09:30:00Z',
          mention: const InstrumentMention(
            kind: InstrumentKind.wallet,
            issuerSlug: 'amazonpay',
          ),
          counterparty: party(kind: 'merchant'),
          evidenceOnly: true,
        );
        final r = linkAll([topup, balancePay]);
        expect(shape(_only(r)), 'purchase[debit_leg]');
        expect(
          r.ambiguous,
          isEmpty,
          reason: 'no review for partial-wallet activity',
        );
      },
    );
  });

  group('LINK-IPO', () {
    final block = hold(
      'placed',
      1425000,
      at: '2026-11-22T09:00:00Z',
      inst: hdfcAcct,
      issue: 'TATA TECHNOLOGIES LTD',
    );

    test('block then allotment: one investment, amount from the debit', () {
      final allot = debit(
        'investment',
        1425000,
        at: '2026-11-30T09:00:00Z',
        inst: hdfcAcct,
        counterparty: party(name: 'TATA TECHNOLOGIES', kind: 'merchant'),
      );
      final e = _only(linkAll([block, allot]));
      expect(shape(e), 'ipo_application[debit_leg,hold_placed]');
      expect(e.status, EventStatus.complete);
      expect(e.amountMinor, 1425000);
      expect(e.eventId, block.factId);
    });

    test('block then release: never money', () {
      final release = hold(
        'released',
        1425000,
        at: '2026-11-30T09:00:00Z',
        inst: hdfcAcct,
      );
      final e = _only(linkAll([block, release]));
      expect(shape(e), 'ipo_application[hold_placed,hold_released]');
      expect(e.status, EventStatus.complete);
      expect(
        e.amountMinor,
        0,
        reason: 'the held amount is never the investment',
      );
    });

    test('a block alone waits for its leg, and expires to complete', () {
      final r = linkAll([block]);
      final e = _only(r);
      expect(e.status, EventStatus.awaitingLeg);
      final ctx = RuleLinkContext(
        recentFacts: [block],
        openEvents: [e],
        instrumentsById: allInstruments,
      );
      final early = testLinker().expire(
        now: DateTime.utc(2026, 12, 1),
        context: ctx,
        rules: baselineLinkRules(),
      );
      expect(early.updated, isEmpty);
      final late = testLinker().expire(
        now: DateTime.utc(2026, 12, 31),
        context: ctx,
        rules: baselineLinkRules(),
      );
      expect(late.updated.single.status, EventStatus.complete);
      expect(late.updated.single.legs, e.legs);
    });

    test(
      'partial allotment: smaller debit, then the release of the rest also joins',
      () {
        final big = hold(
          'placed',
          1500000,
          at: '2026-11-22T09:00:00Z',
          inst: hdfcAcct,
          issue: 'ACME',
        );
        final allot = debit(
          'investment',
          500000,
          at: '2026-11-30T09:00:00Z',
          inst: hdfcAcct,
          counterparty: party(name: 'ACME'),
        );
        final rest = hold(
          'released',
          1000000,
          at: '2026-11-30T10:00:00Z',
          inst: hdfcAcct,
        );
        // Incremental: one message per call, the store carrying open events.
        final store = MemoryEvents();
        final seen = <Fact>[];
        for (final f in [big, allot, rest]) {
          final r = testLinker().link(
            incoming: [f],
            context: RuleLinkContext(
              recentFacts: [...seen],
              openEvents: store.open,
              instrumentsById: allInstruments,
              knownEvents: store.all,
            ),
            rules: baselineLinkRules(),
          );
          store.apply(r);
          seen.add(f);
          if (f == allot) {
            expect(store.byId[big.factId]!.status, EventStatus.awaitingLeg);
          }
        }
        expect(store.all, hasLength(1));
        final e = store.all.single;
        expect(
          shape(e),
          'ipo_application[debit_leg,hold_placed,hold_released]',
        );
        expect(e.status, EventStatus.complete);
        expect(e.amountMinor, 500000);
      },
    );

    test(
      'a debit larger than the hold, or for another issue, is a separate investment',
      () {
        final bigger = debit(
          'investment',
          2000000,
          at: '2026-11-30T09:00:00Z',
          inst: hdfcAcct,
        );
        expect(shapes(linkAll([block, bigger])), [
          'investment[debit_leg]',
          'ipo_application[hold_placed]',
        ]);
        final broker = debit(
          'investment',
          1425000,
          at: '2026-11-25T09:00:00Z',
          inst: hdfcAcct,
          counterparty: party(name: 'ZERODHA BROKING'),
        );
        expect(shapes(linkAll([block, broker])), [
          'investment[debit_leg]',
          'ipo_application[hold_placed]',
        ]);
      },
    );

    test('a UPI one-time IPO mandate joins its hold, never a subscription', () {
      final key = 'sms:upi-ipo-block';
      final upiBlock = hold(
        'placed',
        1425000,
        at: '2026-11-22T09:00:00Z',
        inst: hdfcAcct,
        purpose: 'upi_mandate_block',
        sourceKey: key,
      );
      final upiMandate = mandate(
        'created',
        at: '2026-11-22T09:00:00Z',
        ceiling: 1425000,
        oneTime: true,
        purpose: 'ipo',
        inst: hdfcAcct,
        sourceKey: key,
      );
      final r = linkAll([upiMandate, upiBlock]);
      final e = _only(r);
      expect(shape(e), 'ipo_application[hold_placed,original]');
      expect(e.amountMinor, 0);
      final charge = debit(
        'purchase',
        1425000,
        at: '2026-11-25T09:00:00Z',
        inst: hdfcAcct,
        mandateRef: 'X1',
      );
      final r2 = linkAll([upiMandate, upiBlock, charge]);
      expect(
        eventsOf(
          r2,
        ).where((e) => e.type == EventType.subscriptionCharge).single.legs,
        hasLength(1),
      );
    });
  });

  group('LINK-MANDATE-CHARGE', () {
    final netflix = mandate(
      'created',
      at: '2026-11-01T08:00:00Z',
      merchant: 'NETFLIX',
      ceiling: 149900,
    );

    test('a debit with mandateRef joins its mandate as original', () {
      final charge = debit(
        'purchase',
        64900,
        at: '2026-11-05T06:00:00Z',
        inst: hdfcAcct,
        counterparty: party(name: 'NETFLIX', kind: 'merchant'),
        mandateRef: '9876',
        references: {'umrn': '9876'},
      );
      final e = _only(linkAll([netflix, charge]));
      expect(shape(e), 'subscription_charge[charge,original]');
      expect(e.eventId, charge.factId);
      expect(e.amountMinor, 64900);
    });

    test(
      "a debit naming an active mandate's merchant is a subscription charge",
      () {
        final charge = debit(
          'purchase',
          64900,
          at: '2026-12-05T06:00:00Z',
          inst: hdfcCard,
          counterparty: party(name: 'Netflix', kind: 'merchant'),
        );
        expect(
          shape(_only(linkAll([netflix, charge]))),
          'subscription_charge[charge,original]',
        );
      },
    );

    test('every monthly charge shares the same mandate', () {
      final c1 = debit(
        'purchase',
        64900,
        at: '2026-11-05T06:00:00Z',
        inst: hdfcAcct,
        counterparty: party(name: 'NETFLIX'),
        mandateRef: '9876',
      );
      final c2 = debit(
        'purchase',
        64900,
        at: '2026-12-05T06:00:00Z',
        inst: hdfcAcct,
        counterparty: party(name: 'NETFLIX'),
        mandateRef: '9876',
      );
      expect(shapes(linkAll([netflix, c1, c2])), [
        'subscription_charge[charge,original]',
        'subscription_charge[charge,original]',
      ]);
    });

    test(
      'a revoked mandate, an unrelated merchant or an over-ceiling debit is not joined',
      () {
        final revoked = mandate(
          'revoked',
          at: '2026-11-03T08:00:00Z',
          merchant: 'NETFLIX',
        );
        final later = debit(
          'purchase',
          64900,
          at: '2026-11-05T06:00:00Z',
          inst: hdfcCard,
          counterparty: party(name: 'NETFLIX'),
        );
        expect(shapes(linkAll([netflix, revoked, later])), [
          'purchase[debit_leg]',
        ]);
        final other = debit(
          'purchase',
          64900,
          at: '2026-11-05T06:00:00Z',
          inst: hdfcCard,
          counterparty: party(name: 'SPOTIFY'),
        );
        expect(shapes(linkAll([netflix, other])), ['purchase[debit_leg]']);
        final over = debit(
          'purchase',
          200000,
          at: '2026-11-05T06:00:00Z',
          inst: hdfcCard,
          counterparty: party(name: 'NETFLIX'),
        );
        expect(shapes(linkAll([netflix, over])), ['purchase[debit_leg]']);
      },
    );

    test('one-time, IPO and SIP mandates never make a subscription', () {
      for (final m in [
        mandate(
          'created',
          at: '2026-11-01T08:00:00Z',
          merchant: 'ACME',
          oneTime: true,
        ),
        mandate(
          'created',
          at: '2026-11-01T08:00:00Z',
          merchant: 'ACME',
          purpose: 'ipo',
        ),
        mandate(
          'created',
          at: '2026-11-01T08:00:00Z',
          merchant: 'ACME',
          purpose: 'sip',
        ),
      ]) {
        final d = debit(
          'purchase',
          50000,
          at: '2026-11-05T06:00:00Z',
          inst: hdfcAcct,
          counterparty: party(name: 'ACME'),
        );
        expect(shapes(linkAll([m, d])), ['purchase[debit_leg]']);
      }
      final sip = debit(
        'investment',
        500000,
        at: '2026-11-05T06:00:00Z',
        inst: hdfcAcct,
        mandateRef: 'S1',
      );
      expect(shapes(linkAll([sip])), ['investment[debit_leg]']);
    });
  });

  group('LINK-REFUND', () {
    final buy = debit(
      'purchase',
      49900,
      at: '2026-11-01T12:31:00Z',
      inst: hdfcCard,
      counterparty: party(name: 'SWIGGY', kind: 'merchant'),
    );

    test('a refund links to its purchase, which stays its own event', () {
      final refund = credit(
        'refund',
        49900,
        at: '2026-11-03T10:00:00Z',
        inst: hdfcCard,
      );
      final r = linkAll([buy, refund]);
      expect(shapes(r), ['purchase[debit_leg]', 'refund[original,reversal]']);
      final e = _of(r, EventType.refund);
      expect(e.eventId, refund.factId);
      expect(e.amountMinor, 49900);
      expect(
        doubleCounted(eventsOf(r), {buy.factId: buy, refund.factId: refund}),
        isEmpty,
      );
    });

    test('a refund larger than the purchase stays unlinked', () {
      final big = credit(
        'refund',
        60000,
        at: '2026-11-03T10:00:00Z',
        inst: hdfcCard,
      );
      expect(shapes(linkAll([buy, big])), [
        'purchase[debit_leg]',
        'refund[credit_leg]',
      ]);
    });

    test(
      'a refund to another card or from another merchant stays unlinked',
      () {
        final other = credit(
          'refund',
          49900,
          at: '2026-11-03T10:00:00Z',
          inst: iciciCard,
        );
        expect(shapes(linkAll([buy, other])), [
          'purchase[debit_leg]',
          'refund[credit_leg]',
        ]);
        final zomato = credit(
          'refund',
          49900,
          at: '2026-11-03T10:00:00Z',
          inst: hdfcCard,
          counterparty: party(name: 'ZOMATO'),
        );
        expect(shapes(linkAll([buy, zomato])), [
          'purchase[debit_leg]',
          'refund[credit_leg]',
        ]);
      },
    );

    test(
      'partial refunds naming the merchant link until they reach the purchase amount',
      () {
        final swiggy = party(name: 'SWIGGY');
        final r1 = credit(
          'refund',
          20000,
          at: '2026-11-02T10:00:00Z',
          inst: hdfcCard,
          counterparty: swiggy,
        );
        final r2 = credit(
          'refund',
          29900,
          at: '2026-11-03T10:00:00Z',
          inst: hdfcCard,
          counterparty: swiggy,
        );
        final r3 = credit(
          'refund',
          100,
          at: '2026-11-04T10:00:00Z',
          inst: hdfcCard,
          counterparty: swiggy,
        );
        expect(shapes(linkAll([buy, r1, r2, r3])), [
          'purchase[debit_leg]',
          'refund[credit_leg]',
          'refund[original,reversal]',
          'refund[original,reversal]',
        ]);
      },
    );

    test('a partial refund naming no merchant is not guessed', () {
      final part = credit(
        'refund',
        20000,
        at: '2026-11-02T10:00:00Z',
        inst: hdfcCard,
      );
      final r = linkAll([buy, part]);
      expect(shapes(r), ['purchase[debit_leg]', 'refund[credit_leg]']);
      expect(r.ambiguous, isEmpty);
    });
  });

  group('LINK-OWN-TRANSFER', () {
    final out = debit(
      'transfer',
      2000000,
      at: '2026-11-01T10:00:00Z',
      inst: hdfcAcct,
      counterparty: party(kind: 'own', mask: '9999'),
      references: {'impsRef': '432112345678'},
    );
    final inn = credit(
      'p2p',
      2000000,
      at: '2026-11-01T10:00:30Z',
      inst: hdfcSaving,
      counterparty: party(name: 'A'),
    );

    test('a debit to an own account and its credit are one own transfer', () {
      final e = _only(linkAll([out, inn]));
      expect(shape(e), 'own_transfer[credit_leg,debit_leg]');
    });

    test(
      'the credit first: the later debit turns it into the own transfer',
      () {
        final early = credit(
          'p2p',
          2000000,
          at: '2026-11-01T09:59:00Z',
          inst: hdfcSaving,
          counterparty: party(name: 'A'),
        );
        final e = _only(linkAll([out, early]));
        expect(shape(e), 'own_transfer[credit_leg,debit_leg]');
        expect(e.eventId, early.factId);
      },
    );

    test(
      'paying a friend and being paid the same amount are not a transfer',
      () {
        final friend = debit(
          'p2p',
          50000,
          at: '2026-11-01T10:00:00Z',
          inst: hdfcAcct,
          counterparty: party(name: 'RAVI'),
        );
        final back = credit(
          'p2p',
          50000,
          at: '2026-11-01T11:00:00Z',
          inst: hdfcSaving,
          counterparty: party(name: 'ANU'),
        );
        expect(shapes(linkAll([friend, back])), [
          'p2p_in[credit_leg]',
          'p2p_out[debit_leg]',
        ]);
      },
    );

    test('an own debit with no credit seen is still an own transfer', () {
      expect(shapes(linkAll([out])), ['own_transfer[debit_leg]']);
    });

    // A bank prints the holder's name on both sides of a transfer, so the
    // user's own name (or the same name on two of their accounts) marks it.
    final toSelf = debit(
      'purchase',
      3000000,
      at: '2026-11-02T10:00:00Z',
      inst: hdfcAcct,
      counterparty: party(name: 'ASHA MARIA'),
    );
    final fromSelf = credit(
      'p2p',
      3000000,
      at: '2026-11-02T10:01:00Z',
      inst: hdfcSaving,
      counterparty: party(name: 'ASHA MARIA RAO'),
    );

    test('a debit to the owner\'s own name is an own transfer', () {
      expect(
        shapes(linkAll([toSelf], ownerNames: const ['Asha Maria Rao'])),
        ['own_transfer[debit_leg]'],
      );
    });

    test('without the owner\'s name a lone debit to a person stays a payment', () {
      expect(shapes(linkAll([toSelf])), ['purchase[debit_leg]']);
    });

    test('a credit from the owner\'s own name is an own transfer', () {
      expect(
        shapes(linkAll([fromSelf], ownerNames: const ['Asha Maria Rao'])),
        ['own_transfer[credit_leg]'],
      );
    });

    test('the same name on a debit and a credit across two accounts pairs', () {
      expect(shapes(linkAll([toSelf, fromSelf])), [
        'own_transfer[credit_leg,debit_leg]',
      ]);
    });

    test('the same name on one account only does not pair', () {
      final sameAccount = credit(
        'p2p',
        3000000,
        at: '2026-11-02T10:01:00Z',
        inst: hdfcAcct,
        counterparty: party(name: 'ASHA MARIA RAO'),
      );
      expect(shapes(linkAll([toSelf, sameAccount])), [
        'p2p_in[credit_leg]',
        'purchase[debit_leg]',
      ]);
    });

    test('a look-alike name with another surname does not pair', () {
      final other = credit(
        'p2p',
        3000000,
        at: '2026-11-02T10:01:00Z',
        inst: hdfcSaving,
        counterparty: party(name: 'ASHA IYER'),
      );
      expect(shapes(linkAll([toSelf, other])), [
        'p2p_in[credit_leg]',
        'purchase[debit_leg]',
      ]);
    });

    test('a look-alike surname is not the owner', () {
      expect(
        shapes(linkAll([
          debit(
            'purchase',
            3000000,
            at: '2026-11-02T10:00:00Z',
            inst: hdfcAcct,
            counterparty: party(name: 'ASHA IYER'),
          ),
        ], ownerNames: const ['Asha Maria Rao'])),
        ['purchase[debit_leg]'],
      );
    });
  });

  group('LINK-DUP-NOTIFY', () {
    test('joins a bank debit and a UPI app notice', () {
      final bank = debit(
        'purchase',
        25000,
        at: '2026-11-05T13:00:00Z',
        occurredAt: '2026-11-04T18:30:00Z',
        inst: hdfcAcct,
        counterparty: party(vpa: 'chaipoint@okaxis'),
        references: {'upiRef': '432100000001'},
        ruleId: 'HDFC-UPI-DEBIT-VPA',
      );
      final app = debit(
        'purchase',
        25000,
        at: '2026-11-05T13:01:00Z',
        counterparty: party(name: 'Chai Point'),
        references: {'upiRef': '432100000001'},
        ruleId: 'GPAY-PAID-01',
      );
      final r = linkAll([bank, app]);
      final e = _only(r);
      expect(shape(e), 'purchase[debit_leg,duplicate_notice]');
      expect(
        e.legs.firstWhere((l) => l.role == LegRole.debitLeg).factId,
        bank.factId,
      );
      expect(
        doubleCounted(eventsOf(r), {bank.factId: bank, app.factId: app}),
        isEmpty,
      );
    });

    test(
      'the app notice first: the bank debit still becomes the money leg',
      () {
        final app = debit(
          'purchase',
          25000,
          at: '2026-11-05T12:59:00Z',
          counterparty: party(name: 'Chai Point'),
          ruleId: 'GPAY',
        );
        final bank = debit(
          'purchase',
          25000,
          at: '2026-11-05T13:00:00Z',
          inst: hdfcAcct,
          ruleId: 'HDFC',
        );
        final e = _only(linkAll([bank, app]));
        expect(e.eventId, app.factId);
        expect(
          e.legs.firstWhere((l) => l.role == LegRole.debitLeg).factId,
          bank.factId,
        );
        expect(
          e.legs.firstWhere((l) => l.role == LegRole.duplicateNotice).factId,
          app.factId,
        );
      },
    );

    test(
      'two real payments from one account, or 15 minutes apart, stay two events',
      () {
        final a = debit(
          'purchase',
          25000,
          at: '2026-11-05T13:00:00Z',
          inst: hdfcAcct,
          ruleId: 'R',
        );
        final b = debit(
          'purchase',
          25000,
          at: '2026-11-05T13:05:00Z',
          inst: hdfcAcct,
          ruleId: 'R',
        );
        expect(eventsOf(linkAll([a, b])), hasLength(2));
        final c = debit(
          'purchase',
          25000,
          at: '2026-11-05T13:15:00Z',
          ruleId: 'GPAY',
        );
        expect(eventsOf(linkAll([a, c])), hasLength(2));
      },
    );
  });

  group('LINK-RECEIPT', () {
    final pay = debit(
      'bill_payment',
      89900,
      at: '2026-11-07T10:00:00Z',
      inst: hdfcAcct,
      counterparty: party(name: 'ACT FIBERNET'),
    );
    final receipt = debit(
      'bill_payment',
      89900,
      at: '2026-11-07T10:05:00Z',
      counterparty: party(name: 'ACT Fibernet'),
      evidenceOnly: true,
    );

    test('a receipt joins the debit it confirms and never counts', () {
      for (final order in [
        [pay, receipt],
        [receipt, pay],
      ]) {
        final r = linkAll(order);
        final e = _only(r);
        expect(shape(e), 'bill_payment[debit_leg,duplicate_notice]');
        expect(e.eventId, pay.factId);
        expect(r.ambiguous, isEmpty);
        expect(
          doubleCounted(eventsOf(r), {
            pay.factId: pay,
            receipt.factId: receipt,
          }),
          isEmpty,
        );
      }
    });

    test(
      'a receipt with no payment in 3 days becomes a review item, not an event',
      () {
        // 12 Nov 2026: the same calendar month as the receipt (Lane X).
        final now = DateTime.utc(2026, 11, 12);
        final linker = testLinker(now: now);
        final r = linker.link(
          incoming: [receipt],
          context: RuleLinkContext(
            recentFacts: const [],
            openEvents: const [],
            instrumentsById: allInstruments,
          ),
          rules: baselineLinkRules(),
        );
        expect(eventsOf(r), isEmpty);
        final asked = linker.reviewReceipts(
          now: now,
          context: RuleLinkContext(
            recentFacts: [receipt],
            openEvents: const [],
            instrumentsById: allInstruments,
          ),
          rules: baselineLinkRules(),
        );
        final item = asked.ambiguous.single;
        expect(item.kind, ReviewKind.event);
        expect(item.payload['reason'], 'receipt_without_payment');
        expect(
          item.payload['message'],
          'Did you pay this bill? We found a receipt for a payment of ₹899 on '
          '7 Nov 2026 through ACT Fibernet, but no matching debit in your '
          'messages. Was this paid from one of your accounts?',
        );
      },
    );

    test('a receipt from an earlier month is skipped silently', () {
      final r = linkAll([receipt]); // testNow is June 2027
      expect(eventsOf(r), isEmpty);
      expect(r.ambiguous, isEmpty);
    });

    test('inside the window the receipt waits quietly', () {
      final r = testLinker(now: DateTime.utc(2026, 11, 8)).link(
        incoming: [receipt],
        context: RuleLinkContext(
          recentFacts: const [],
          openEvents: const [],
          instrumentsById: allInstruments,
        ),
        rules: baselineLinkRules(),
      );
      expect(eventsOf(r), isEmpty);
      expect(r.ambiguous, isEmpty);
    });
  });

  group('ambiguity', () {
    test('two possible legs make an ambiguous event and a review item', () {
      final d1 = debit(
        'card_payment',
        1000000,
        at: '2026-11-10T09:00:00Z',
        inst: hdfcAcct,
        counterparty: party(kind: 'own'),
      );
      final d2 = debit(
        'card_payment',
        1000000,
        at: '2026-11-10T11:00:00Z',
        inst: hdfcSaving,
        counterparty: party(kind: 'own'),
      );
      final c = credit(
        'card_payment',
        1000000,
        at: '2026-11-10T12:00:00Z',
        inst: hdfcCard,
      );
      final r = linkAll([d1, d2, c]);
      final amb = eventsOf(r).singleWhere((e) => e.eventId == c.factId);
      expect(amb.status, EventStatus.ambiguous);
      final item = r.ambiguous.single;
      expect(item.payload['reason'], 'ambiguous_link');
      expect(item.payload['eventId'], c.factId);
      expect([
        for (final x in item.payload['candidates'] as List)
          (x as Map)['factId'],
      ], unorderedEquals([d1.factId, d2.factId]));
    });

    test('a shared reference breaks the tie', () {
      final d1 = debit(
        'card_payment',
        1000000,
        at: '2026-11-10T09:00:00Z',
        inst: hdfcAcct,
        counterparty: party(kind: 'own'),
        references: {'txnId': 'A1'},
      );
      final d2 = debit(
        'card_payment',
        1000000,
        at: '2026-11-10T11:00:00Z',
        inst: hdfcSaving,
        counterparty: party(kind: 'own'),
        references: {'txnId': 'B2'},
      );
      final c = credit(
        'card_payment',
        1000000,
        at: '2026-11-10T12:00:00Z',
        inst: hdfcCard,
        references: {'txnId': 'B2'},
      );
      final r = linkAll([d1, d2, c]);
      expect(r.ambiguous, isEmpty);
      expect(
        eventsOf(r).singleWhere((e) => e.eventId == d2.factId).legs,
        hasLength(2),
      );
    });
  });

  group('purpose typing (no rule joins)', () {
    final cases = <(Fact, String)>[
      (
        credit('salary', 8500000, at: '2026-11-01T07:00:00Z', inst: hdfcAcct),
        'income[credit_leg]',
      ),
      (
        credit('interest', 1200, at: '2026-11-01T07:00:00Z', inst: hdfcAcct),
        'income[credit_leg]',
      ),
      (
        credit('dividend', 120000, at: '2026-11-01T07:00:00Z', inst: hdfcAcct),
        'dividend[credit_leg]',
      ),
      (
        credit(
          'investment',
          300000,
          at: '2026-11-01T07:00:00Z',
          inst: hdfcAcct,
          counterparty: party(name: 'ZERODHA'),
        ),
        'investment_withdrawal[credit_leg]',
      ),
      (
        debit('investment', 300000, at: '2026-11-01T07:00:00Z', inst: hdfcAcct),
        'investment[debit_leg]',
      ),
      (
        debit('atm', 500000, at: '2026-11-01T07:00:00Z', inst: hdfcAcct),
        'atm_withdrawal[debit_leg]',
      ),
      (
        debit('fee', 5900, at: '2026-11-01T07:00:00Z', inst: hdfcCard),
        'fee[debit_leg]',
      ),
      (
        debit('emi', 1500000, at: '2026-11-01T07:00:00Z', inst: hdfcAcct),
        'emi[debit_leg]',
      ),
      (
        debit(
          'bill_payment',
          89900,
          at: '2026-11-01T07:00:00Z',
          inst: hdfcAcct,
        ),
        'bill_payment[debit_leg]',
      ),
      (
        credit('cashback', 5000, at: '2026-11-01T07:00:00Z', inst: hdfcCard),
        'cashback[credit_leg]',
      ),
      (
        debit('p2p', 50000, at: '2026-11-01T07:00:00Z', inst: hdfcAcct),
        'p2p_out[debit_leg]',
      ),
      (
        debit(
          'transfer',
          50000,
          at: '2026-11-01T07:00:00Z',
          inst: hdfcAcct,
          counterparty: party(mask: '7777'),
        ),
        'p2p_out[debit_leg]',
      ),
      // A confident reading with no stated reason is still money that moved.
      (
        debit('unknown', 50000, at: '2026-11-01T07:00:00Z', inst: hdfcAcct),
        'purchase[debit_leg]',
      ),
      (
        credit('unknown', 50000, at: '2026-11-01T07:00:00Z', inst: hdfcAcct),
        'p2p_in[credit_leg]',
      ),
      (
        debit(
          'purchase',
          50000,
          at: '2026-11-01T07:00:00Z',
          inst: hdfcAcct,
          mandateRef: 'M1',
        ),
        'subscription_charge[charge]',
      ),
    ];
    for (final (f, want) in cases) {
      test(want, () => expect(shapes(linkAll([f])), [want]));
    }

    test('an unsure reading with no stated reason stays unknown (the person is asked)', () {
      Fact unsure(Fact f) => Fact.fromJson({...f.toJson(), 'confidence': 0.6});
      expect(
        shapes(linkAll([unsure(debit('unknown', 50000, at: '2026-11-01T07:00:00Z', inst: hdfcAcct))])),
        ['unknown[debit_leg]'],
      );
      expect(
        shapes(linkAll([unsure(credit('unknown', 50000, at: '2026-11-01T07:00:00Z', inst: hdfcAcct))])),
        ['unknown[credit_leg]'],
      );
    });

    test(
      'attempts, rewards, balances, receipts on credits and non-IPO holds make no event',
      () {
        final r = linkAll([
          reward(50, at: '2026-11-01T07:00:00Z', inst: hdfcCard),
          credit('refund', 100, at: '2026-11-01T07:00:00Z', evidenceOnly: true),
          hold(
            'placed',
            100000,
            at: '2026-11-01T07:00:00Z',
            inst: hdfcCard,
            purpose: 'preauth',
          ),
          mandate('created', at: '2026-11-01T07:00:00Z', merchant: 'NETFLIX'),
        ]);
        expect(eventsOf(r), isEmpty);
      },
    );
  });

  group('stability', () {
    List<Fact> sample() => [
      debit(
        'card_payment',
        2500000,
        at: '2026-11-10T09:00:00Z',
        inst: hdfcAcct,
        counterparty: party(kind: 'own', mask: '5678'),
      ),
      credit(
        'card_payment',
        2500000,
        at: '2026-11-10T09:02:00Z',
        inst: hdfcCard,
      ),
      debit(
        'purchase',
        49900,
        at: '2026-11-01T12:31:00Z',
        inst: hdfcCard,
        counterparty: party(name: 'SWIGGY'),
      ),
      credit('refund', 49900, at: '2026-11-03T10:00:00Z', inst: hdfcCard),
      hold('placed', 1425000, at: '2026-11-22T09:00:00Z', inst: hdfcAcct),
      debit('investment', 1425000, at: '2026-11-30T09:00:00Z', inst: hdfcAcct),
      debit(
        'transfer',
        2000000,
        at: '2026-11-01T10:00:00Z',
        inst: hdfcAcct,
        counterparty: party(kind: 'own', mask: '9999'),
      ),
      credit('p2p', 2000000, at: '2026-11-01T10:00:30Z', inst: hdfcSaving),
      debit(
        'bill_payment',
        89900,
        at: '2026-11-07T10:05:00Z',
        evidenceOnly: true,
      ),
      debit('bill_payment', 89900, at: '2026-11-07T10:00:00Z', inst: hdfcAcct),
    ];

    test('every event is valid, anchored at its first leg', () {
      for (final e in eventsOf(linkAll(sample()))) {
        expect(e.validate().errors, isEmpty, reason: e.toString());
        expect(e.legs.first.factId, e.eventId);
      }
    });

    test(
      'input order does not matter, and a full re-run gives identical events',
      () {
        final facts = sample();
        final a = [for (final e in eventsOf(linkAll(facts))) e.toJson()];
        final b = [
          for (final e in eventsOf(linkAll(facts.reversed.toList())))
            e.toJson(),
        ];
        expect(b, unorderedEquals(a));
        final c = [for (final e in eventsOf(linkAll(facts))) e.toJson()];
        expect(c, a);
      },
    );

    test('re-running over the stored events changes nothing', () {
      final facts = sample();
      final first = linkAll(facts);
      final store = MemoryEvents()..apply(first);
      final again = testLinker().link(
        incoming: facts,
        context: RuleLinkContext(
          recentFacts: facts,
          openEvents: store.open,
          instrumentsById: allInstruments,
          knownEvents: store.all,
        ),
        rules: baselineLinkRules(),
      );
      expect(again.created, isEmpty);
      expect(again.updated, isEmpty);
      expect(again.ambiguous, isEmpty);
    });

    test(
      'one message at a time gives the same events, and legs never shrink',
      () {
        final facts = sample();
        final batch = {
          for (final e in eventsOf(linkAll(facts))) e.eventId: shape(e),
        };
        final store = MemoryEvents();
        final seen = <Fact>[];
        final sorted = [...facts]
          ..sort((x, y) => x.effectiveAt.compareTo(y.effectiveAt));
        for (final f in sorted) {
          final r = testLinker().link(
            incoming: [f],
            context: RuleLinkContext(
              recentFacts: [...seen],
              openEvents: store.open,
              instrumentsById: allInstruments,
              knownEvents: store.all,
            ),
            rules: baselineLinkRules(),
          );
          for (final e in r.updated) {
            final before = store.byId[e.eventId]!;
            for (final l in before.legs) {
              expect(e.legs.map((x) => x.factId), contains(l.factId));
            }
            expect(e.legs.first.factId, before.legs.first.factId);
          }
          store.apply(r);
          seen.add(f);
        }
        expect({for (final e in store.all) e.eventId: shape(e)}, batch);
      },
    );

    test('user_confirmed events are never changed', () {
      final c = credit(
        'card_payment',
        2500000,
        at: '2026-11-10T09:02:00Z',
        inst: hdfcCard,
      );
      final confirmed = Event(
        eventId: c.factId,
        type: EventType.cardBillPayment,
        status: EventStatus.userConfirmed,
        legs: [EventLeg(factId: c.factId, role: LegRole.creditLeg)],
        confidence: 1,
        occurredAt: c.effectiveAt,
        amountMinor: 2500000,
      );
      final d = debit(
        'card_payment',
        2500000,
        at: '2026-11-10T09:05:00Z',
        inst: hdfcAcct,
        counterparty: party(kind: 'own', mask: '5678'),
      );
      final r = testLinker().link(
        incoming: [c, d],
        context: RuleLinkContext(
          recentFacts: [c],
          openEvents: const [],
          instrumentsById: allInstruments,
          knownEvents: [confirmed],
        ),
        rules: baselineLinkRules(),
      );
      expect(r.updated, isEmpty);
      expect(r.created.single.eventId, d.factId);
    });

    test(
      'a plain LinkContext never joins a recent fact it cannot see is free',
      () {
        final c = credit(
          'card_payment',
          2500000,
          at: '2026-11-10T09:02:00Z',
          inst: hdfcCard,
        );
        final d = debit(
          'card_payment',
          2500000,
          at: '2026-11-10T09:05:00Z',
          inst: hdfcAcct,
          counterparty: party(kind: 'own', mask: '5678'),
        );
        final r = testLinker().link(
          incoming: [d],
          context: LinkContext(
            recentFacts: [c],
            openEvents: const [],
            instrumentsById: allInstruments,
          ),
          rules: baselineLinkRules(),
        );
        expect(shapes(r), ['card_bill_payment[debit_leg]']);
      },
    );

    test('a fact already linked is skipped on the next call', () {
      final facts = sample();
      final first = linkAll(facts);
      final store = MemoryEvents()..apply(first);
      final r = testLinker().link(
        incoming: [facts.first],
        context: RuleLinkContext(
          recentFacts: facts,
          openEvents: store.open,
          instrumentsById: allInstruments,
          knownEvents: store.all,
        ),
        rules: baselineLinkRules(),
      );
      expect(eventsOf(r), isEmpty);
    });
  });

  test(
    'mentions resolve against known instruments when no fact map is given',
    () {
      final r = testLinker().link(
        incoming: [
          debit(
            'card_payment',
            100000,
            at: '2026-11-10T09:00:00Z',
            mention: on(hdfcAcct),
            counterparty: party(kind: 'own'),
          ),
          credit(
            'card_payment',
            100000,
            at: '2026-11-10T09:05:00Z',
            mention: on(hdfcCard),
          ),
        ],
        context: LinkContext(
          recentFacts: const [],
          openEvents: const [],
          instrumentsById: allInstruments,
        ),
        rules: baselineLinkRules(),
      );
      expect(shapes(r), ['card_bill_payment[credit_leg,debit_leg]']);
    },
  );

  test('linkRuleKindOf reads the baseline rules', () {
    expect(
      {for (final r in baselineLinkRules()) r.id: linkRuleKindOf(r)},
      {
        'LINK-IPO': LinkRuleKind.ipo,
        'LINK-MANDATE-CHARGE': LinkRuleKind.mandateCharge,
        'LINK-CARD-BILL': LinkRuleKind.cardBill,
        'LINK-WALLET-TOPUP': LinkRuleKind.walletTopup,
        'LINK-FEE-ON-TXN': LinkRuleKind.feeCharge,
        'LINK-REFUND': LinkRuleKind.refund,
        'LINK-OWN-TRANSFER': LinkRuleKind.ownTransfer,
        'LINK-RECEIPT': LinkRuleKind.receipt,
        'LINK-DUP-NOTIFY': LinkRuleKind.duplicateNotice,
        'LINK-DUP-INVEST-DEBIT': LinkRuleKind.duplicateNotice,
        'LINK-DUP-INVEST-CREDIT': LinkRuleKind.duplicateNotice,
        'LINK-DUP-ACCOUNT-CREDIT': LinkRuleKind.duplicateNotice,
        'LINK-DUP-CARD-PAYMENT': LinkRuleKind.duplicateNotice,
      },
    );
  });
}
