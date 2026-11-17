import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import '../support/rules.dart';

// Money a broker sends back to the person's bank is an investment coming back,
// never spending and never income, in whichever words it is written, and
// money paid to a broker is money invested.
void main() {
  // The rules plus the evidence solver's vocabulary, as `sms_rules build` ships them.
  final bundle = RuleBundle.fromJson({
    ...testRuleBundle().toJson(),
    'solverPack': jsonDecode(File('../../rules/sms/solver/pack.json').readAsStringSync()),
  });
  final engine = RuleEngine();
  MovementFact read(String sender, String body) {
    final r = engine.interpret(
      SmsMessage(
        sender: sender,
        body: body,
        observedAt: DateTime.utc(2026, 11, 5, 9),
        sourceKey: 'k',
      ),
      bundle,
      appVersion: '2',
    );
    return r.facts.whereType<MovementFact>().single;
  }

  test('a bank credit from a broker is an investment coming back', () {
    final f = read(
      'AD-SBIPSG-S',
      'Dear Customer, INR 143.23 credited to your A/c No XX1234 on 18/04/2026 through NEFT with UTR HDFCH00000000001 by UPSTOX SECURITIES PVT LTD  DSCNB A/C, INFO: BATCHID:0032-SBI',
    );
    expect(f.direction, Direction.credit);
    expect(f.purpose, MovementPurpose.investment);
  });

  test('a bank credit from a person keeps its own reading', () {
    final f = read(
      'AD-SBIPSG-S',
      'Dear Customer, INR 143.23 credited to your A/c No XX1234 on 18/04/2026 through NEFT with UTR HDFCH00000000001 by RAVI KUMAR, INFO: BATCHID:0032-SBI',
    );
    expect(f.direction, Direction.credit);
    expect(f.purpose, isNot(MovementPurpose.investment));
  });

  test('money paid to a broker from the bank is invested, not spent', () {
    final f = read(
      'JD-SBIUPI',
      'Dear SBI User, your A/c X1234-debited by Rs10000.0 on 08Jul23 transfer to Zerodha Ref No 355550000000. If not done by u, fwd this SMS to 9223008333 -SBI',
    );
    expect(f.direction, Direction.debit);
    expect(f.purpose, MovementPurpose.investment);
  });

  test('a broker that sends unused funds back: money in, an investment', () {
    final f = read(
      'LEMNNS-S',
      'Dear A B CUSTOMER, as per SEBI and exchange guidelines, we have transferred unused funds of Rs 1234.56 from your Lemonn trading account back to your registered bank account by NEFT/RTGS ;Transaction ID: TXN0001; Date: 05/11/2026.',
    );
    expect(f.direction, Direction.credit);
    expect(f.purpose, MovementPurpose.investment);
    expect(f.counterparty?.name, 'Lemonn');
  });

  test('a payout notice names the account by its number, not the sender\'s bank', () {
    final f = read(
      'CP-KOTAKS',
      'Dear customer, as per your request, payout of Rs.2500.40 has been made to your SBI Bank Account No. XXXX1234. - Kotak Securities',
    );
    expect(f.direction, Direction.credit);
    expect(f.instrument?.maskDigits, '1234');
    expect(f.instrument?.issuerSlug, isNull);
  });

  test('an unknown sender\'s withdrawal sent to the bank account is money in', () {
    final unknown = RuleBundle.fromJson({
      ...bundle.toJson(),
      'rules': const [],
      'ignoreRules': const [],
    });
    final r = engine.interpret(
      SmsMessage(
        sender: 'VM-ACMEIN-S',
        body: 'Acme: Withdrawal of Rs 4,000.00 has been transferred to your bank a/c XX4321. UTR: ACME00112233.',
        observedAt: DateTime.utc(2026, 11, 5, 9),
        sourceKey: 'k',
      ),
      unknown,
      appVersion: '2',
    );
    final f = r.facts.whereType<MovementFact>().single;
    expect(f.direction, Direction.credit);
  });

  test('a cash withdrawal from the bank stays money out', () {
    final f = read(
      'VM-EXBANK-S',
      'Withdrawal of Rs.3500/- made from your A/C NO.XXXXXX1234 on 14 Aug 2026.',
    );
    expect(f.direction, Direction.debit);
  });
}
