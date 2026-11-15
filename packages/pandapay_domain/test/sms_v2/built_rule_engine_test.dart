import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:test/test.dart';

Directory _contracts() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final c = Directory('${dir.path}/contracts/sms/v2');
    if (c.existsSync()) return c;
    dir = dir.parent;
  }
  throw StateError('contracts/sms/v2 not found above ${Directory.current.path}');
}

/// The server builds a rule from a layout and the AI's facts (api/src/sms_v2/layout_matcher.js and
/// template_worker.js buildRule). The fixture is what it builds for the worked examples in the prompt; the JS test
/// api/test/sms_v2/layout_matcher.test.js keeps it current. This test is the other half: the phone's real engine
/// reads REAL-shaped messages with those rules and gets the right facts. The rule is bound to the message's own
/// layout hash, as the phone's overlay does (ProvisionalStore). Every value below is invented.
void main() {
  final built = (jsonDecode(File('${_contracts().path}/fixtures/built_rules.json').readAsStringSync()) as List).cast<Map>();
  final base = (jsonDecode(File('${_contracts().path}/fixtures/valid/bundle/full.json').readAsStringSync()) as Map).cast<String, Object?>();

  InterpretResult read(int example, String body) {
    final rule = (built[example]['rule'] as Map).cast<String, Object?>();
    final hash = smsTemplateHash('HDFCBK', smsSkeleton(body));
    final bound = {
      ...rule,
      'id': '${rule['id']}:local:$hash',
      'match': {...(rule['match'] as Map).cast<String, Object?>(), 'templateHash': hash},
    };
    return RuleEngine().interpret(
      SmsMessage(sender: 'HDFCBK', body: body, observedAt: DateTime.utc(2026, 11, 20), sourceKey: 'k'),
      RuleBundle.fromJson({...base, 'rules': [bound]}),
      appVersion: '1',
    );
  }

  test('a debit and its balance are read from messages with other names, dates, amounts and card forms', () {
    for (final (body, posted, balance) in [
      ('Rs.450.00 debited from A/c XX1234 on 20-11-26 to RAHUL SHARMA. UPI Ref 123456789012. Avl Bal Rs.10,500.25.', 45000, 1050025),
      ('INR 1,23,456.78 debited from A/c 4012XXXXXXXX3456 on 2026-11-20 to Amazon Pay. UPI Ref 998877665544. Avl Bal INR 85,000.00.', 12345678, 8500000),
    ]) {
      final result = read(0, body);
      expect(result.outcome, InterpretOutcome.matched, reason: body);
      expect(result.facts.map((f) => f.factType.name), ['movement', 'balanceSnapshot']);
      expect(result.facts[0].amounts.single.minor, posted);
      expect(result.facts[1].amounts.single.minor, balance);
    }
  });

  test('an OTP and a bill reminder are read from their own layouts', () {
    final otp = read(1, 'Dear Customer, your OTP is 482910. Do not share it with anyone.');
    expect(otp.outcome, InterpretOutcome.matched);
    expect(otp.facts.map((f) => f.factType.name), ['info']);
    final bill = read(2, 'Your Airtel bill of Rs.499 is due on 25-11-26.');
    expect(bill.outcome, InterpretOutcome.matched);
    expect(bill.facts.map((f) => f.factType.name), ['billDue']);
    expect(bill.facts.single.amounts.single.minor, 49900);
  });
}
