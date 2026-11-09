import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_solver.dart';
import 'package:test/test.dart';

const _packPath = '../../rules/sms/solver/pack.json';
final _observed = DateTime.utc(2026, 11, 9, 6); // 11:30 IST on 9 Nov 2026

Map<String, dynamic> _packJson() =>
    jsonDecode(File(_packPath).readAsStringSync()) as Map<String, dynamic>;
EvidenceSolver _solver() => EvidenceSolver(SolverPack.fromJson(_packJson()));

SolverDecision _solve(String body) =>
    _solver().solve(body, observedAt: _observed);

SolverFactResult _facts(SolverDecision d, {String? issuer}) {
  final r = SolverFacts.build(
    d,
    sourceKey: 'k',
    observedAt: _observed,
    issuerSlug: issuer,
    packVersion: 2,
    bundleVersion: 7,
    engineVersion: smsEngineVersion,
    appVersion: '2.0.0',
  );
  expect(r, isNotNull, reason: 'a valid fact: $d ${d.reasons}');
  return r!;
}

/// A placeholder bundle (no rules) that carries the solver pack.
RuleBundle _bundle({Map<String, Object?>? pack, bool withPack = true}) =>
    RuleBundle.fromJson({
      'schema': 'pandapay.sms.rules/2',
      'bundleVersion': 0,
      'createdAt': '2026-11-01T00:00:00Z',
      'expiresAt': '2099-01-01T00:00:00Z',
      'minEngineVersion': '2.0.0',
      'taxonomyVersion': 1,
      'senders': [
        {
          'brand': 'SAMPLEWAL',
          'issuerSlug': 'samplewal',
          'issuerKind': 'wallet',
          'aliases': <String>[],
        },
        {
          'brand': 'KNOWNBK',
          'issuerSlug': 'knownbk',
          'issuerKind': 'bank',
          'aliases': <String>[],
        },
      ],
      'ignoreRules': <Object?>[],
      'rules': <Object?>[],
      'counterpartyPurposes': <Object?>[],
      'linkRules': <Object?>[],
      'categoryRules': <Object?>[],
      'merchantAliases': <Object?>[],
      if (withPack) 'solverPack': pack ?? _packJson(),
      'signature': null,
    });

SmsMessage _msg(String sender, String body, {String key = 'm1'}) => SmsMessage(
  sender: sender,
  body: body,
  observedAt: _observed,
  sourceKey: key,
);

void main() {
  group('dates', () {
    final ref = DateTime.utc(2026, 11, 9);
    test('reads Indian-order dates in every common printing', () {
      for (final s in [
        '20-Nov-2026',
        '20 Nov 2026',
        '20/11/2026',
        '20-11-26',
        '2026-11-20',
        '20Nov26',
        'Nov 20, 2026',
        '20 November 2026',
      ]) {
        expect(parseSolverDate(s, ref)?.iso, '2026-11-20', reason: s);
      }
    });

    test('a date with no year takes the nearest sensible year', () {
      expect(parseSolverDate('20 Nov', ref)?.iso, '2026-11-20');
      expect(
        parseSolverDate('05 Jan', ref)?.iso,
        '2027-01-05',
      ); // a due date is ahead
      expect(
        parseSolverDate('05 Oct', ref)?.iso,
        '2026-10-05',
      ); // within 90 days back
      expect(
        parseSolverDate('05 Jan', ref, preferFuture: false)?.iso,
        '2026-01-05',
      );
    });

    test('a time of day and an impossible date are not dates', () {
      expect(parseSolverDate('14:05', ref), isNull);
      expect(parseSolverDate('31-02-2026', ref), isNull);
      expect(parseSolverDate('45/13/2026', ref), isNull);
    });
  });

  group('bills (before payment)', () {
    test('a statement carries total, minimum, due date and statement date', () {
      final d = _solve(
        'Your credit card statement for card ending 4410 dated 01-Nov-2026 is generated. '
        'Total amount due Rs 23,540.00, minimum amount due Rs 1,177.00, payment due date 20-Nov-2026.',
      );
      expect(d.read, SolverRead.billDue);
      expect(d.accepted, isTrue);
      final f = _facts(d).facts.single as BillDueFact;
      expect(f.dueDate, '2026-11-20');
      expect(f.statementDate, '2026-11-01');
      expect(f.amount(AmountRole.dueTotal)!.minor, 2354000);
      expect(f.amount(AmountRole.dueMinimum)!.minor, 117700);
      expect(f.instrument?.kind, InstrumentKind.creditCard);
      expect(f.instrument?.maskDigits, '4410');
    });

    test(
      '"due tomorrow" and "due today" are read against the day the message arrived',
      () {
        expect(
          _solve(
            'Reminder: your bill of Rs 800 for card ending 1188 is due tomorrow.',
          ).dueDate?.iso,
          '2026-11-10',
        );
        expect(
          _solve(
            'Your card XX4410 payment of Rs 800 is due today. Pay now.',
          ).dueDate?.iso,
          '2026-11-09',
        );
      },
    );

    test('a due date with no year is placed ahead of the message', () {
      expect(
        _solve(
          'Your bill of Rs 1,250 is generated. Pay before 20 Nov to avoid disconnection.',
        ).dueDate?.iso,
        '2026-11-20',
      );
    });

    test(
      'an overdue notice with no date, or only a minimum due, is left for review',
      () {
        expect(
          _solve(
            'Final reminder: Rs 23,540 on credit card XX4410 is overdue. Please pay immediately.',
          ).accepted,
          isFalse,
        );
        expect(
          _solve(
            'Minimum amount due Rs 215.00 on your credit card XX1188. Pay by 21-Nov-2026.',
          ).accepted,
          isFalse,
        );
      },
    );

    test(
      'a message reporting a payment and a new bill together is not trusted',
      () {
        final d = _solve(
          'Thank you for your payment of Rs 5,000 received on 05-Nov. Your new bill of Rs 3,200 is due on 25-Nov.',
        );
        expect(d.accepted, isFalse);
      },
    );

    test('utilities, insurance, EMI and wellness dues read as bills', () {
      for (final body in [
        'Dear Consumer, your electricity bill of Rs 1,420.00 for consumer no 100234 has been generated. Due date 12-Nov-2026.',
        'Premium of Rs 7,400 for your health policy is due on 20-Nov-26. Renew now to avoid lapse.',
        'Your EMI of Rs 4,500 for loan LN8812 is due on 05-Dec-2026.',
        'Your wellness membership fee of Rs 2,999 is due on 25-Nov-2026. Pay at the front desk or online.',
      ]) {
        final d = _solve(body);
        expect(d.read, SolverRead.billDue, reason: body);
        expect(d.accepted, isTrue, reason: '$body ${d.reasons}');
        expect(_facts(d).facts.single, isA<BillDueFact>());
      }
    });
  });

  group('bills (after payment) and receipts', () {
    test('a biller\'s receipt is evidence only, never counted by itself', () {
      for (final body in [
        'Payment of Rs 1,420.00 received for your electricity bill, consumer no 100234. Thank you. Receipt no 5566.',
        'We have received your premium of Rs 7,400 for policy 887766 on 18-Nov-26.',
        'Your bill of Rs 499 has been paid successfully via UPI. Receipt 5566.',
        'E-bill for your payment of Rs 799 made on 05-Nov-2026 is generated. Invoice no 9911.',
      ]) {
        final d = _solve(body);
        expect(d.read, SolverRead.billReceipt, reason: body);
        expect(d.countsInTotals, isFalse, reason: body);
        final m = _facts(d).facts.first as MovementFact;
        expect(m.evidenceOnly, isTrue, reason: body);
        expect(m.direction, Direction.debit);
      }
    });

    test(
      'a bank debit alert for the same premium is the real, counted debit',
      () {
        final d = _solve(
          'Premium Rs 18,000 for policy 998877 has been auto-debited from A/c XX2209 on 07-Nov-2026.',
        );
        expect(d.read, SolverRead.debit);
        expect(d.countsInTotals, isTrue);
        final m = _facts(d).facts.first as MovementFact;
        expect(m.evidenceOnly, isNull);
        expect(m.purpose, MovementPurpose.billPayment);
      },
    );

    test('"processed payment of X for <consumer no>" is a bill payment receipt', () {
      final d = _solve(
        'Processed payment of INR 927.00 for XX60008413407 with ref no. HGAMP00AA10663603336. Click https://ccm.example/x and get instant cashback - Newbnk',
      );
      expect(d.read, SolverRead.billReceipt);
      expect(d.minor, 92700);
      expect(d.consumerRef, '60008413407');
      final m = _facts(d).facts.single as MovementFact;
      expect(m.purpose, MovementPurpose.billPayment);
      expect(m.evidenceOnly, isTrue);
      expect(m.counterparty?.name, contains('60008413407'));
    });

    test('a card bill payment received is a card payment, not income', () {
      final d = _solve(
        'Payment of Rs 23,540.00 has been received towards your card ending 4410. Thank you.',
      );
      expect(d.read, SolverRead.cardPayment);
      final m = _facts(d).facts.single as MovementFact;
      expect(m.purpose, MovementPurpose.cardPayment);
      expect(m.direction, Direction.credit);
      expect(m.instrument?.kind, InstrumentKind.creditCard);
    });
  });

  group('subscriptions and mandates', () {
    test('a renewal notice is evidence only and records the subscription', () {
      final d = _solve(
        'Your annual subscription of Rs 1,499 has been renewed for 12 months. Card ending 7766 charged.',
      );
      expect(d.read, SolverRead.billReceipt);
      final facts = _facts(d).facts;
      expect((facts.first as MovementFact).evidenceOnly, isTrue);
      final mandate = facts.whereType<MandateFact>().single;
      expect(mandate.mandatePurpose, MandatePurpose.subscription);
      expect(mandate.phase, MandatePhase.created);
    });

    test(
      'an AutoPay debit alert carries its mandate reference and is counted',
      () {
        final d = _solve(
          'UPI AutoPay: Rs 149 debited from A/c XX1111 for EXAMPLE VIDEO on 08-Nov. Mandate ID 5566.',
        );
        expect(d.countsInTotals, isTrue);
        final facts = _facts(d).facts;
        final m = facts.first as MovementFact;
        expect(m.mandateRef, '5566');
        expect(m.references['umrn'], '5566');
        expect(m.rail, Rail.upi);
        expect(facts.whereType<MandateFact>(), hasLength(1));
      },
    );

    test(
      'an upcoming auto-debit is a scheduled attempt with its date, never money moved',
      () {
        final d = _solve(
          'Rs 99.00 will be auto-debited on 12-Nov-2026 for your MUSIC PREMIUM subscription.',
        );
        expect(d.read, SolverRead.scheduled);
        final a = _facts(d).facts.single as AttemptFact;
        expect(a.status, AttemptStatus.scheduled);
        expect(a.amount(AmountRole.scheduled)!.minor, 9900);
        expect(a.dueAt, DateTime.utc(2026, 11, 11, 18, 30)); // 12 Nov 00:00 IST
      },
    );

    test('a mandate set-up, with its frequency', () {
      final d = _solve(
        'Mandate created for Rs 649 for NETSTREAM. Auto debit will happen on the 5th of every month. Approve in your banking app.',
      );
      final m = _facts(d).facts.single as MandateFact;
      expect(m.phase, MandatePhase.created);
      expect(m.frequency, 'monthly');
      expect(m.merchantName, contains('NETSTREAM'));
      expect(m.amount(AmountRole.ceiling)!.minor, 64900);
    });

    test('a mandate ended: cancelled, expired, paused', () {
      for (final (body, phase) in [
        (
          'Your autopay for EXAMPLE VIDEO has been cancelled. No further charges will be made.',
          MandatePhase.revoked,
        ),
        (
          'Your subscription to EXAMPLE VIDEO has expired.',
          MandatePhase.expired,
        ),
        ('Autopay for MUSIC PREMIUM has been paused.', MandatePhase.paused),
      ]) {
        final d = _solve(body);
        expect(d.read, SolverRead.mandate, reason: body);
        expect(
          (_facts(d).facts.single as MandateFact).phase,
          phase,
          reason: body,
        );
      }
    });

    test('a person\'s payment request is not a mandate', () {
      final d = _solve(
        'Mr. Rao has requested Rs 1,000 from you. Approve the request in your app.',
      );
      expect(d.read, isNot(SolverRead.mandate));
      expect(d.countsInTotals, isFalse);
    });

    test(
      'a failed renewal is a failed attempt; with no amount it stays in review',
      () {
        expect(
          _facts(
            _solve(
              'Your EXAMPLE VIDEO renewal payment of Rs 499 failed. Update your payment method.',
            ),
          ).facts.single,
          isA<AttemptFact>(),
        );
        expect(
          _solve(
            'AutoPay payment for NETFLIX failed due to insufficient balance. No money was debited.',
          ).accepted,
          isFalse,
        );
      },
    );
  });

  // Found by replaying a real inbox (counts only). The wording here is invented;
  // only the structure is the real one.
  group('generalisation: other banks and slightly different wording', () {
    test('a "ready / generated" bill with no printed date was generated the day it arrived', () {
      for (final body in [
        'Your Sample Bank credit card bill of Rs 4,200 is ready. Pay by 25-Nov-2026 to avoid late charges.',
        'Statement for your card XX1234 has been generated. Total due Rs 4,200. Pay by 25 Nov.',
        'Your e-statement is available. Amount due Rs 4,200, due date 25/11/2026.',
      ]) {
        final d = _solve(body);
        expect(d.read, SolverRead.billDue, reason: body);
        expect(d.statementDate?.iso, '2026-11-09', reason: body);
        expect(d.dueDate?.iso, '2026-11-25', reason: body);
      }
    });

    test('a reminder is not a statement: no generated date is invented', () {
      expect(_solve('Reminder: your bill of Rs 800 is due on 20-Nov-2026. Pay now.').statementDate, isNull);
    });

    test('a printed statement date wins over the arrival day', () {
      expect(_solve('Your bill dated 01-Nov-2026 is generated. Total due Rs 800. Due date 20-Nov-2026.').statementDate?.iso, '2026-11-01');
    });

    test('"due in N days" and variants are counted from the day the message arrived', () {
      expect(_solve('Your bill of Rs 800 is due in 3 days. Pay now to avoid late charges.').dueDate?.iso, '2026-11-12');
      expect(_solve('Your bill of Rs 800 is due in 1 day. Pay now to avoid late charges.').dueDate?.iso, '2026-11-10');
      expect(_solve('Your plan payment of Rs 800 is payable in 10 days. Please pay.').dueDate?.iso, '2026-11-19');
    });

    test('a subscription debit names its merchant, so charges are not merged into one "Unknown service"', () {
      for (final body in [
        'UPI AutoPay: Rs 149 debited from A/c XX1111 for SAMPLE VIDEO on 08-Nov. Mandate ID 5566.',
        'Rs 149 debited from your account XX1111 towards SAMPLE VIDEO under UPI mandate 5566.',
      ]) {
        final d = _solve(body);
        expect(d.countsInTotals, isTrue, reason: body);
        expect(d.party?.toUpperCase(), contains('SAMPLE VIDEO'), reason: body);
        final m = _facts(d).facts.first as MovementFact;
        expect(m.counterparty?.name?.toUpperCase(), contains('SAMPLE VIDEO'), reason: body);
      }
    });

    test('a mandate carries its own reference so a later charge quoting it joins it', () {
      final d = _solve('Mandate created for Rs 649 for SAMPLE STREAM. Mandate ID 5566. Auto debit will happen on the 5th of every month.');
      final m = _facts(d).facts.single as MandateFact;
      expect(m.references['umrn'], '5566');
    });

    test('a sender the registry does not know still gets a stable issuer identity; a numeric short code does not', () {
      final engine = RuleEngine();
      const body = 'Your credit card statement for card ending 4410 is generated. Total amount due Rs 23,540.00, minimum amount due Rs 1,177.00, payment due date 20-Nov-2026.';
      final a = engine.interpretDetailed(_msg('VM-NEWBNK-S', body), _bundle(), appVersion: '2.0.0');
      final bill = a.result.facts.whereType<BillDueFact>().single;
      expect(bill.instrument?.issuerSlug, 'newbnk');
      final b = engine.interpretDetailed(_msg('VM-NEWBNK-T', body), _bundle(), appVersion: '2.0.0');
      expect(b.result.facts.whereType<BillDueFact>().single.instrument?.issuerSlug, 'newbnk');
      final c = engine.interpretDetailed(_msg('56767', body), _bundle(), appVersion: '2.0.0');
      expect(c.result.facts.whereType<BillDueFact>().single.instrument?.issuerSlug, isNull);
    });

    test('a bill with no biller name falls back to its sender header, so reminders and statements share an identity', () {
      final engine = RuleEngine();
      final out = engine.interpretDetailed(
        _msg('BZ-POWERC', 'Your bill of Rs 1,420.00 is ready. Pay by 12-Nov-2026 to avoid disconnection.'),
        _bundle(),
        appVersion: '2.0.0',
      );
      expect(out.result.facts.whereType<BillDueFact>().single.billerName, isNotNull);
    });

    test('plain money-in wording in other phrasings is read as a credit', () {
      for (final body in [
        'Received Rs 500 on 08-Nov-26 in your A/C XX9988 via IMPS from a linked mobile. Ref 1234.',
        'Amount of Rs 300 has been received by your wallet A/c.',
        'Your refund of Rs 799 for the order is successfully processed to your Sample Pay balance.',
      ]) {
        final d = _solve(body);
        expect(d.read, SolverRead.credit, reason: body);
        expect(d.debitDirection, isFalse, reason: body);
      }
    });

    test('a currency written after the number is still an amount', () {
      final d = _solve('Dear Customer, your A/C XX9988 has been successfully Credited with 12345INR on 09-Nov-26 10:15:00. Check now - https://x.example');
      expect(d.read, SolverRead.credit);
      expect(d.minor, 1234500);
      expect(_solve('Rs 500 debited from A/c XX1111 on 08-Nov').minor, 50000);
      expect(SolverText.parse('on 05-11-2026 at 12345 hours').toks.where((t) => t.kind == TokKind.amt), isEmpty);
    });

    test('reward coins redeemed are shown in activity but never counted as spending or income', () {
      final d = _solve('Sample coins redemption transaction of Rs 120.00 having transaction id 99887766 is successful. Regards, Sample Pay Team');
      expect(d.read, SolverRead.redemption);
      expect(d.countsInTotals, isFalse);
      final m = _facts(d).facts.single as MovementFact;
      expect(m.purpose, MovementPurpose.transfer);
      expect(m.direction, Direction.debit);
    });

    test('a dividend announcement with only per-share amounts is not money; one with a total still is', () {
      final announce = _solve('3rd Interim Dividend of Rs 2.50 per share for 2026-27 by Sample Ltd has been credited into your bank account on 08-Nov-2026. Team Sample');
      expect(announce.read, SolverRead.info);
      expect(announce.accepted, isTrue);
      final paise = _solve('4th Dividend of 50 paise per share for 2026-27 by Sample Ltd has been credited into your bank account on 08-Nov-2026.');
      expect(paise.countsInTotals, isFalse);
      final alert = _solve('Dividend of Rs 1,240.00 (Rs 2.50 per share) credited to your bank A/c XX2209 on 08-Nov-2026.');
      expect(alert.read, SolverRead.credit);
      expect(alert.minor, 124000);
    });

    test('an IPO that was not allotted releases its blocked amount: a hold released, not a failure', () {
      final d = _solve('Dear Customer, we are sorry to inform you that no shares have been allotted to your ASBA application no. 123456 for Sample Limited dated 05-Nov-2026. The blocked amount of Rs 14,250.00 is now available for use.');
      expect(d.read, SolverRead.holdRelease);
      final h = _facts(d).facts.single as HoldFact;
      expect(h.phase, HoldPhase.released);
      expect(h.purpose, HoldPurpose.ipoAsba);
      expect(h.amount(AmountRole.released)!.minor, 1425000);
    });

    test('"we have received your request" is a pending attempt, not a transaction', () {
      final d = _solve('We confirm receipt of your request for Purchase of Rs 5,000.00 in Folio 998877 under Sample Tax Fund on 08-Nov-2026. We shall confirm your transaction details shortly.');
      expect(d.read, SolverRead.requestPending);
      final a = _facts(d).facts.single as AttemptFact;
      expect(a.status, AttemptStatus.pending);
      expect(a.purpose, MovementPurpose.investment);
      expect(d.countsInTotals, isFalse);
    });

    test('a successful request to cancel, pause or change a mandate is a mandate update', () {
      for (final (body, phase) in [
        ('Your request to cancel the UPI AutoPay Mandate of Rs 299 towards SAMPLE MUSIC is successful. Ref no. 1234', MandatePhase.revoked),
        ('Your request to pause the UPI AutoPay Mandate of Rs 299 towards SAMPLE MUSIC is successful. Ref no. 1234', MandatePhase.paused),
        ('Your request to modify the UPI AutoPay Mandate of Rs 299 towards SAMPLE MUSIC was successful.', MandatePhase.modified),
      ]) {
        final d = _solve(body);
        expect(d.read, SolverRead.mandate, reason: body);
        expect((_facts(d).facts.single as MandateFact).phase, phase, reason: body);
      }
    });

    test('a request that is only acknowledged ("has been received") does not change a mandate', () {
      final d = _solve('Your request to cancel the UPI AutoPay Mandate of Rs 299 towards SAMPLE MUSIC has been received and will be processed shortly.');
      expect(d.read, isNot(SolverRead.mandate));
    });

    test('a wallet top-up with long wording is a top-up', () {
      final d = _solve('Your Wallet Recharge through UPI via Online Bank Payment bearing Order ID 5566, initiated on 08-Nov-2026 at 10:15 AM was successful and your Wallet Account has been recharged with Rs 500.00. Your current balance is Rs 640.00');
      expect(d.read, SolverRead.walletTopup);
      expect(d.accepted, isTrue);
    });

    test('a refund from a registered wallet sender is linked to that wallet; from an unknown sender it stays in review', () {
      final engine = RuleEngine();
      const body = 'Refund of Rs 799.00 for your order is successfully processed to your balance.';
      final known = engine.interpretDetailed(_msg('VM-SAMPLEWAL-S', body), _bundle(), appVersion: '2.0.0');
      expect(known.result.outcome, InterpretOutcome.matched);
      final m = known.result.facts.single as MovementFact;
      expect(m.direction, Direction.credit);
      expect(m.purpose, MovementPurpose.refund);
      expect(m.instrument?.kind, InstrumentKind.wallet);
      expect(m.instrument?.issuerSlug, 'samplewal');
      final unknown = engine.interpretDetailed(_msg('VM-OTHERXX-S', body), _bundle(), appVersion: '2.0.0');
      expect(unknown.result.outcome, InterpretOutcome.unknown);
    });

    test('a failure that is not about a payment is not financial; one that is stays in review', () {
      expect(_solve("Sorry, we couldn't deliver your package today. Please click the link for the next step.").accepted, isTrue);
      expect(_solve("Sorry, we couldn't deliver your package today. Please click the link for the next step.").read, SolverRead.info);
      final payment = _solve('Your card payment could not be completed. Please try again.');
      expect(payment.accepted, isFalse);
    });

    test('"receipt of your application" is not money wording', () {
      final d = _solve('Dear Sam, we acknowledge the receipt of your Example Bank Credit Card application No 1234. Track the status after 3 days.');
      expect(d.read, SolverRead.info);
      expect(d.accepted, isTrue);
    });

    test('a renewal or due reminder with no amount holds no money and is not left in review', () {
      final d = _solve('Dear customer, renew your insurance before it expires on 20-Nov-2026. Visit https://x.example');
      expect(d.read, SolverRead.info);
      expect(d.accepted, isTrue);
    });

    test('"wallet recharged with Rs X" is a top-up', () {
      final d = _solve('Your Wallet Account has been recharged with Rs 500. Current balance Rs 640.');
      expect(d.read, SolverRead.walletTopup);
    });

    test('a loan paid out to the wallet is money in; a loan EMI debit still counts', () {
      final credit = _solve('Dear Customer, Amount of Rs 20,000 has been received by your wallet A/c. Check it https://x.example Sample Loans');
      expect(credit.countsInTotals, isTrue);
      expect(credit.debitDirection, isFalse);
      final emi = _solve('Your EMI of Rs 4,500.00 for loan A/c LN8812 has been debited from your account XX3345 on 05-11-2026.');
      expect(emi.countsInTotals, isTrue);
    });

    test('a broker "traded value" summary is a notice, not money', () {
      final d = _solve('Dear Client, your traded value for 07-Nov-2026 is Rs 12,500. Check your registered email.');
      expect(d.countsInTotals, isFalse);
    });
  });

  group('structures found on a real inbox', () {
    test('a payout "transferred Rs X to your bank account" is money coming back from investments, not a debit', () {
      final d = _solve('Dear Client, We have transferred Rs 9,000.00 to your bank account No 123456789 as a part of running account settlement vide Ref No CMS123456.');
      expect(d.read, SolverRead.credit);
      final m = _facts(d).facts.single as MovementFact;
      expect(m.direction, Direction.credit);
      expect(m.purpose, MovementPurpose.investment);
    });

    test('ads are filtered: loan offers, job ads, recharge-plan notices in any language', () {
      for (final body in [
        'Sample Finance: Paison ki zaroorat hai? Aaj hi apply karein aur paayein Rs 50,000 ka instant loan! https://x.example',
        'Congrats! You have passed our review, Salary is 25000Rs/day. Please contact https://x.example',
        'Dear Sample Job Alert: Now hiring, work from home, salary is Rs 30,000 per month. Apply https://x.example',
        'आपला रिचार्ज प्लान 12-11-2026 रोजी समाप्त होत आहे! प्लान नाव: Rs 299 रिचार्ज करा https://x.example',
        'आपल्या जिओ नंबर 9800000000 चा 90 दिवसांपासून कोणताही वापर होत नसल्यामुळे Rs 20.00 आपल्या टॉप-अप बॅलेन्स मधून कमी करण्यात आले आहेत. कृपया वैध प्लॅनने रिचार्ज करा',
      ]) {
        final d = _solve(body);
        expect(d.countsInTotals, isFalse, reason: body);
        expect(d.read, SolverRead.promo, reason: body);
      }
      // A real bank debit keeps counting even when it mentions a loan.
      expect(
        _solve('Your EMI of Rs 4,500.00 for loan A/c LN8812 has been debited from your account XX3345 on 05-11-2026.').countsInTotals,
        isTrue,
      );
    });

    test('an offer that says "when your loan is credited" is a promotion, not income', () {
      final d = _solve('Hi Sam, special Loan offer on your recent Pay Later a/c XX1234 transaction! Get a Rs 250 gift voucher when your loan is credited! The offer is valid only till today!');
      expect(d.countsInTotals, isFalse);
    });

    test('a collect request is not an upcoming debit or a bill', () {
      for (final body in [
        'Fund requested by Sam. On Approval, Rs 500 will be debited. Click to pay https://pay.example/x',
        'Sam has requested money through ExamplePay. On approval, Rs 500 will be debited from your Bank Account-Example Bank.',
      ]) {
        final d = _solve(body);
        expect(d.read, SolverRead.info, reason: body);
        expect(d.countsInTotals, isFalse, reason: body);
      }
    });

    test('a card spend in the "Spent Rs X Card no. XX1234 ... Avl Limit" layout is counted', () {
      final d = _solve('Spent Rs 450.00 Example Bank Card no. XX1234 09-11-26 12:30:11 IST SAMPLE SHOP Avl Limit: Rs 80,000.00 Not you? SMS BLOCK 1234 to 9999');
      expect(d.read, SolverRead.debit);
      expect(d.accepted, isTrue);
      expect(d.minor, 45000);
      expect(d.mask, '1234');
    });
  });

  group('financial messages with no printed amount are never ignored', () {
    test('completed money wording without an amount goes to review', () {
      expect(
        _solve(
          'Your account has been debited. Call us if this was not you.',
        ).accepted,
        isFalse,
      );
    });
    test('points are not money and may be ignored', () {
      expect(
        _solve(
          '450 points credited to your card XX1188. Points balance 12,450.',
        ).accepted,
        isTrue,
      );
    });
  });

  group('engine integration (tier 2 runs only when no rule matched)', () {
    final engine = RuleEngine();

    test('an unmatched message becomes facts with a SOLVER rule id', () {
      final out = engine.interpretDetailed(
        _msg(
          'VK-KNOWNBK-S',
          'Rs 540.00 debited from A/c XX8812 on 05-Nov-26 towards UPI/DR/330098871/CHAI POINT. Avl bal Rs 12,300.45',
        ),
        _bundle(),
        appVersion: '2.0.0',
      );
      expect(out.result.outcome, InterpretOutcome.matched);
      expect(out.winnerId, 'SOLVER-DEBIT');
      final f = out.result.facts.single as MovementFact;
      expect(f.provenance.engine, Engine.rules);
      expect(f.provenance.ruleId, 'SOLVER-DEBIT');
      expect(f.confidence, lessThanOrEqualTo(kSolverMaxConfidence));
      expect(f.instrument?.issuerSlug, 'knownbk'); // from the sender registry
      expect(f.validate().ok, isTrue);
    });

    test('a promotion becomes an ignored message with an info fact', () {
      final out = engine.interpretDetailed(
        _msg(
          'VM-SHOPXX-P',
          'Flat Rs 500 OFF on orders above Rs 2,999. Use code SAVE500. Valid till 15-Nov. T&C apply.',
        ),
        _bundle(),
        appVersion: '2.0.0',
      );
      expect(out.result.outcome, InterpretOutcome.ignored);
      expect(out.result.facts.single, isA<InfoFact>());
    });

    test(
      'a message the solver is not sure of stays unknown (review / AI drafter)',
      () {
        final out = engine.interpretDetailed(
          _msg('VM-XXXXXX', 'Quantum flux of Rs 4,321 noted on A/c XX1111'),
          _bundle(),
          appVersion: '2.0.0',
        );
        expect(out.result.outcome, InterpretOutcome.unknown);
        expect(out.reason, 'no_rule_matched');
        expect(engine.stats.solverCandidates, greaterThan(0));
      },
    );

    test(
      'a bundle with no pack, or with the pack switched off, behaves exactly as before',
      () {
        const body =
            'Rs 540.00 debited from A/c XX8812 on 05-Nov-26 towards UPI/DR/330098871/CHAI POINT.';
        final off = _packJson()
          ..['params'] = {...(_packJson()['params'] as Map), 'enabled': false};
        for (final b in [
          _bundle(withPack: false),
          _bundle(pack: off.cast<String, Object?>()),
        ]) {
          final out = engine.interpretDetailed(
            _msg('VK-KNOWNBK-S', body),
            b,
            appVersion: '2.0.0',
          );
          expect(out.result.outcome, InterpretOutcome.unknown);
        }
      },
    );

    test(
      'a pack that does not load switches the solver off without refusing the bundle',
      () {
        final broken = _packJson();
        (broken['lexicons'] as Map).remove('debit');
        final bundle = _bundle(pack: broken.cast<String, Object?>());
        final compiled = engine.compiled(bundle);
        expect(compiled.solver, isNull);
        expect(compiled.solverError, contains('debit'));
        final out = engine.interpretDetailed(
          _msg('VK-KNOWNBK-S', 'Rs 540.00 debited from A/c XX8812'),
          bundle,
          appVersion: '2.0.0',
        );
        expect(out.result.outcome, InterpretOutcome.unknown);
      },
    );

    test(
      'a bundle with a pack signs exactly as one without when the pack is absent',
      () {
        final bare = _bundle(withPack: false);
        expect(bare.toJson().containsKey('solverPack'), isFalse);
        expect(bare.signedPayload.contains('solverPack'), isFalse);
        expect(_bundle().signedPayload.contains('solverPack'), isTrue);
      },
    );
  });

  group('every accepted reading is a valid contract fact', () {
    final solver = _solver();
    for (final path in const [
      '../../tools/sms_golden/solver/held_out.jsonl',
      '../../tools/sms_golden/solver/blind_1.jsonl',
      '../../tools/sms_golden/solver/blind_2.jsonl',
      '../../tools/sms_golden/solver/bills_subs_dev.jsonl',
      '../../tools/sms_golden/solver/non_financial.jsonl',
    ]) {
      test(path, () {
        final bad = <String>[];
        for (final line in File(
          path,
        ).readAsLinesSync().where((l) => l.trim().isNotEmpty)) {
          final row = jsonDecode(line) as Map<String, dynamic>;
          final d = solver.solve(row['body'] as String, observedAt: _observed);
          if (!d.accepted || d.read == SolverRead.unclear) continue;
          final r = SolverFacts.build(
            d,
            sourceKey: '${row['id']}',
            observedAt: _observed,
            issuerSlug: null,
            packVersion: 2,
            bundleVersion: 0,
            engineVersion: smsEngineVersion,
            appVersion: '2.0.0',
          );
          if (r == null) bad.add('${row['id']}: ${row['body']} -> $d');
        }
        expect(bad, isEmpty, reason: bad.join('\n'));
      });
    }
  });
}
