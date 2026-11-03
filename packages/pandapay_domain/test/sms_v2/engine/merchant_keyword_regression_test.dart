import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';
import '../support/rules.dart';

void main() {
  final bundle = testRuleBundle();
  final engine = RuleEngine();
  InterpretResult run(String body, {String sender = 'VM-HDFCBK-S'}) =>
      engine.interpret(
        SmsMessage(
          sender: sender,
          body: body,
          observedAt: DateTime.utc(2026, 11, 5, 13),
          sourceKey: 'synthetic:$sender:$body',
        ),
        bundle,
        appVersion: 'test',
      );

  test('financial keywords inside a merchant never reject a UPI debit', () {
    for (final merchant in ['chaipoint', 'sipstation', 'asbakery']) {
      final result = run(
        'Rs.250.00 debited from A/c XX1234 on 05-11-26 to VPA $merchant@okaxis (UPI Ref No 432100000001). Avl bal Rs 40,000.00',
      );
      final movement = result.facts.whereType<MovementFact>().single;
      expect(movement.purpose.wire, 'purchase', reason: merchant);
      expect(movement.references['upiRef'], '432100000001', reason: merchant);
    }
  });

  test(
    'Google Pay notice carries a merchant and UPI reference without inventing an account',
    () {
      final result = run(
        'You paid Rs.250.00 to Chai Point using Google Pay. UPI Ref 432100000001.',
        sender: 'VM-GPAY-S',
      );
      expect(result.outcome, InterpretOutcome.matched);
      final fact = result.facts.whereType<MovementFact>().single;
      expect(fact.counterparty?.name?.toUpperCase(), 'CHAI POINT');
      expect(fact.references['upiRef'], '432100000001');
      expect(fact.instrument, isNull);
      expect(fact.purpose.wire, 'purchase');
    },
  );

  test('failed and future Google Pay notices do not become money', () {
    for (final body in [
      'Your payment of Rs.250.00 to Chai Point failed using Google Pay.',
      'You will pay Rs.250.00 to Chai Point using Google Pay.',
    ]) {
      expect(
        run(body, sender: 'VM-GPAY-S').facts.whereType<MovementFact>(),
        isEmpty,
      );
    }
  });
}
