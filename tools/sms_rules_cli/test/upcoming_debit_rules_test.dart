// What the Bills page shows for an EMI, an insurance premium or a SIP instalment
// comes from rules, not from the app: a rule says "this is a scheduled debit,
// for this purpose, to this name, on this date". These cases run synthetic
// messages through the REAL rule folder and check exactly those typed facts, so
// a reworded alert is a rule change and the app needs none.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sms_rules_cli/rules_source.dart';
import 'package:test/test.dart';

/// A date the rules read is midnight in India, kept as UTC.
DateTime _istMidnight(int y, int m, int d) =>
    DateTime.utc(y, m, d).subtract(const Duration(hours: 5, minutes: 30));

void main() {
  final source = readRulesFolder('../../rules/sms/v2');
  final bundle = parseUnsignedBundle(source.bundle);
  final engine = RuleEngine();

  AttemptFact? attemptOf(String sender, String body) {
    final o = engine.interpretDetailed(
      SmsMessage(
        sender: sender,
        body: body,
        observedAt: DateTime.utc(2026, 10, 25, 4),
        sourceKey: 'k',
      ),
      bundle,
      appVersion: 'test',
    );
    return o.result.facts.whereType<AttemptFact>().firstOrNull;
  }

  test('the rule folder is clean', () {
    expect(source.problems, isEmpty);
  });

  group('SIP instalment announced', () {
    for (final (label, body) in [
      (
        'monthly SIP wording',
        'Your monthly SIP of Rs 5,000 in Sunrise Equity Fund will be debited from your bank account on 05-Nov-26.',
      ),
      (
        'other wording and date style',
        'Your SIP of INR 5000.00 in Sunrise Equity Fund will be auto-debited on 05/11/2026. Keep funds ready.',
      ),
    ]) {
      test(label, () {
        final f = attemptOf('VM-FUNDCO-S', body)!;
        expect(f.status, AttemptStatus.scheduled);
        expect(f.purpose, MovementPurpose.investment);
        expect(f.counterparty?.name, 'SUNRISE EQUITY FUND');
        expect(f.amounts.single.minor, 500000);
        expect(f.dueAt, _istMidnight(2026, 11, 5));
      });
    }

    test('wording an existing rule already reads is left to that rule', () {
      // "SIP instalment of ... will be debited" has been read by the fund-house
      // receipt rule all along. The new rule ranks below it and changes nothing.
      const body =
          'Your SIP instalment of Rs 5,000 in Sunrise Equity Fund will be debited from your bank account on 05-Nov-26.';
      expect(attemptOf('VM-FUNDCO-S', body), isNull);
      final o = engine.interpretDetailed(
        SmsMessage(sender: 'VM-FUNDCO-S', body: body, observedAt: DateTime.utc(2026, 10, 25, 4), sourceKey: 'k'),
        bundle,
        appVersion: 'test',
      );
      expect(o.winnerId, 'BRK-MF-SIP-INSTALMENT-01');
    });

    test('past tense is a receipt, never a scheduled debit', () {
      expect(
        attemptOf(
          'VM-FUNDCO-S',
          'Your SIP instalment of Rs 5,000 in Sunrise Equity Fund was debited from your bank account on 05-Nov-26.',
        ),
        isNull,
      );
    });
  });

  group('EMI announced', () {
    test('typed as an EMI debit on its date', () {
      final f = attemptOf(
        'VM-GENBNK-S',
        'Dear Customer, your loan EMI of Rs.12,345.00 will be debited from A/c XX1234 on 07-Nov-26. Please maintain sufficient balance.',
      )!;
      expect(f.purpose, MovementPurpose.emi);
      expect(f.status, AttemptStatus.scheduled);
      expect(f.amounts.single.minor, 1234500);
      expect(f.instrument?.maskDigits, '1234');
      expect(f.dueAt, _istMidnight(2026, 11, 7));
    });
  });

  group('insurance premium announced', () {
    test('the existing keep-funds rule keeps reading its wording, unchanged', () {
      const body =
          'Please keep sufficient funds in your account for Sunrise policy no 123456789 premium Rs. 2500 which will be debited on 25-11-2026.';
      final f = attemptOf('VM-INSCOX-S', body)!;
      expect(f.provenance.ruleId, 'BIL-INS-PREMIUM-DEBIT-01');
      expect(f.purpose, MovementPurpose.billPayment);
      expect(f.counterparty, isNull);
    });

    test('a premium notice no existing rule read is typed insurance', () {
      final f = attemptOf(
        'VM-INSCOX-S',
        'Dear Customer, your Sunrise Life Insurance premium of Rs 2,500 for policy no 123456789 will be auto-debited from your account on 25-11-2026.',
      )!;
      expect(f.status, AttemptStatus.scheduled);
      expect(f.purpose, MovementPurpose.insurance);
      expect(f.counterparty?.name, 'SUNRISE LIFE INSURANCE');
      expect(f.amounts.single.minor, 250000);
      expect(f.dueAt, _istMidnight(2026, 11, 25));
    });

    test('a premium already debited is not a scheduled debit', () {
      expect(
        attemptOf(
          'VM-INSCOX-S',
          'Dear Customer, your Sunrise Life Insurance premium of Rs 2,500 for policy no 123456789 was debited from your account on 25-11-2026.',
        ),
        isNull,
      );
    });
  });

  group('insurance notice that names only a month', () {
    BillDueFact? billOf(String body) {
      final o = engine.interpretDetailed(
        SmsMessage(
          sender: 'VM-INSCOX-S',
          body: body,
          observedAt: DateTime.utc(2026, 8, 20, 4),
          sourceKey: 'k',
        ),
        bundle,
        appVersion: 'test',
      );
      return o.result.facts.whereType<BillDueFact>().firstOrNull;
    }

    for (final (label, body, policy) in [
      (
        'numeric month and a policy number',
        'Dear Policyholder, policy no. 123456789 Next Premium falls due on 09/2026. Please pay on time.',
        '6789',
      ),
      (
        'month name, no policy number',
        'Dear Policyholder, your Next Premium is due in September 2026. Pay online to avoid lapse.',
        null,
      ),
      (
        'single-digit month',
        'Your Next Premium falls due on 9/2026.',
        null,
      ),
    ]) {
      test(label, () {
        final f = billOf(body)!;
        // The day was never stated: the fact says so, and carries the month's
        // last day, never a guessed day or amount.
        expect(f.dueMonthOnly, isTrue);
        expect(f.dueDate, '2026-09-30');
        expect(f.billKind, 'insurance');
        expect(f.amounts, isEmpty);
        final mask = f.counterparty?.accountMask;
        expect(mask == null ? null : mask.substring(mask.length - 4), policy);
        expect(f.validate().ok, isTrue);
      });
    }

    test('a notice that prints an amount is left to the bill and receipt rules',
        () {
      expect(
        billOf(
          'Premium of Rs 2,500 received for policy no 123456789. Next Premium falls due on 09/2026.',
        ),
        isNull,
      );
    });

    for (final (label, body) in [
      ('colon after due', 'Your Next Premium due: 09/2026.'),
      ('month name with a full stop after it', 'Your next premium falls due on Sep 2026.'),
      ('by, with a dash', 'Next premium is due by 09-2026.'),
      ('capitals', 'NEXT PREMIUM DUE IN SEPTEMBER 2026'),
      ('masked policy number', 'Dear Customer, Policy No: XXXXX6789, Next Premium due on 09/2026.'),
    ]) {
      test('also read: $label', () {
        final f = billOf(body)!;
        expect(f.dueDate, '2026-09-30', reason: body);
        expect(f.dueMonthOnly, isTrue);
      });
    }

    for (final (label, body) in [
      ('a full date is a dated bill, left to the dated rules',
          'Next premium due on 15/09/2026.'),
      ('no date at all', 'Next premium will be intimated shortly.'),
      ('not a premium', 'Your next installment is due on 09/2026.'),
      ('a payment already made', 'Thank you. Next Premium falls due on 09/2026.'),
      ('something else entirely', 'Your OTP for login is 123456. Do not share.'),
    ]) {
      test('not read: $label', () {
        expect(billOf(body)?.dueMonthOnly, isNot(true), reason: body);
      });
    }

    test('February ends on its last day', () {
      expect(billOf('Your Next Premium is due in February 2028.')!.dueDate,
          '2028-02-29');
    });
  });

  // What these rules must NOT change: the neighbours they sit next to.
  group('existing readings stay as they were', () {
    String? winner(String sender, String body) => engine
        .interpretDetailed(
          SmsMessage(
            sender: sender,
            body: body,
            observedAt: DateTime.utc(2026, 11, 3, 6),
            sourceKey: 'k',
          ),
          bundle,
          appVersion: 'test',
        )
        .winnerId;

    for (final body in [
      'Your SIP instalment of Rs 2,500.00 in Acme Large Cap Fund has been debited. Units will be allotted within 2 working days.',
      'Your SIP instalment of Rs 2,500.00 for Acme Large Cap Fund - Direct Growth has been debited. Folio 123456/78. Units will be allotted at NAV of the next business day.',
      'Your SIP instalment of Rs 2,500.00 in Acme Large Cap Fund was successful. Your statement will be sent by email.',
    ]) {
      test('a SIP receipt that says "will be" later is still a receipt', () {
        expect(winner('VM-FUNDCO-S', body), 'BRK-MF-SIP-INSTALMENT-01');
        final o = engine.interpretDetailed(
          SmsMessage(sender: 'VM-FUNDCO-S', body: body, observedAt: DateTime.utc(2026, 11, 3), sourceKey: 'k'),
          bundle,
          appVersion: 'test',
        );
        final m = o.result.facts.whereType<MovementFact>().single;
        expect(m.evidenceOnly, isTrue); // never counted twice
        expect(m.counterparty?.name, startsWith('ACME LARGE CAP FUND'));
      });
    }

    test('a card or streaming "premium" is not an insurance premium', () {
      // The general reader may still see a scheduled bill payment here, as it
      // always did; what must not happen is typing it as insurance.
      final f = attemptOf(
        'VM-BANKXX-S',
        'Your Example Bank Credit Card XX1234 premium of Rs 499 will be debited on 05-11-2026 towards your Netflix subscription.',
      );
      expect(f?.purpose, isNot(MovementPurpose.insurance));
      expect(f?.provenance.ruleId, isNot('GENZ-INS-PREMIUM-UPCOMING-DEBIT'));
    });

    test('a word before "premium" is not the insurer', () {
      final f = attemptOf(
        'VM-BANKXX-S',
        'Dear Customer, your monthly premium of Rs 1,000 for Health Insurance will be deducted on 10-11-2026 from A/c XX1234.',
      )!;
      expect(f.purpose, MovementPurpose.insurance);
      expect(f.counterparty?.name, isNull);
    });

    test('a future-tense debit without a SIP or insurance word is untouched', () {
      expect(
        winner(
          'VM-HDFCBK-S',
          'Your A/c XX1234 will be debited by Rs.5000.00 on 14/08/2026 towards EMI. Maintain sufficient balance.',
        ),
        isNot(anyOf('GENZ-SIP-UPCOMING-DEBIT', 'GENZ-INS-PREMIUM-UPCOMING-DEBIT')),
      );
    });
  });

  test('the new rules rank below every existing rule, so they only add', () {
    const added = {
      'GENZ-INS-PREMIUM-UPCOMING-DEBIT',
      'GENZ-SIP-UPCOMING-DEBIT',
      'GENZ-INS-PREMIUM-NEXT-MONTH',
    };
    final rules = bundle.rules;
    final mine = rules.where((r) => added.contains(r.id)).toList();
    expect(mine.map((r) => r.id).toSet(), added);
    final lowestOther = rules
        .where((r) => !added.contains(r.id))
        .map((r) => r.priority)
        .reduce((a, b) => a < b ? a : b);
    for (final r in mine) {
      expect(r.priority, lessThan(lowestOther), reason: r.id);
    }
  });
}
