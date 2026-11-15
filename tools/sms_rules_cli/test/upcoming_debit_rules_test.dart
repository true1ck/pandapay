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
        'plain',
        'Your SIP instalment of Rs 5,000 in Sunrise Equity Fund will be debited from your bank account on 05-Nov-26.',
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
    for (final (label, sender, body, insurer) in [
      (
        'keep-funds wording',
        'VM-INSCOX-S',
        'Please keep sufficient funds in your account for Sunrise policy no 123456789 premium Rs. 2500 which will be debited on 25-11-2026.',
        'SUNRISE',
      ),
      (
        'auto-debit wording',
        'VM-INSCOX-S',
        'Dear Customer, your Sunrise Life Insurance premium of Rs 2,500 for policy no 123456789 will be auto-debited from your account on 25-11-2026.',
        'SUNRISE LIFE INSURANCE',
      ),
    ]) {
      test(label, () {
        final f = attemptOf(sender, body)!;
        expect(f.status, AttemptStatus.scheduled);
        expect(f.purpose, MovementPurpose.insurance);
        // The rule names who is paid; the app classifies it from that name.
        expect(f.counterparty?.name, insurer);
        expect(f.amounts.single.minor, 250000);
        expect(f.dueAt, _istMidnight(2026, 11, 25));
      });
    }

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
}
