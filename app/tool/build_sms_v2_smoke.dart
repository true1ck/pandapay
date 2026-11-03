// Synthetic-only emulator input. This is never an application bundle signer.
import 'dart:convert';
import 'dart:io';
import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:pandapay_domain/sms_v2.dart';
import '../test/features/sms_v2/support/rules.dart';

void main(List<String> args) {
  const body =
      'Sent Rs.250.00\nFrom HDFC Bank A/C *1797\nTo VPA 9876543210@ybl\nOn 11/05/25\nRef 412345678901 Avl Bal Rs.12,345.67';
  final bundle = testRuleBundle().toJson();
  final rules = bundle['rules'] as List;
  final rule = rules.cast<Map>().singleWhere(
    (r) => r['id'] == 'HDFC-UPI-SENT-VPA-NUM-B',
  );
  bundle['rules'] = [rule];
  bundle['senders'] = (bundle['senders'] as List)
      .where((sender) => (sender as Map)['brand'] == 'HDFCBK')
      .toList();
  for (final field in [
    'ignoreRules',
    'counterpartyPurposes',
    'linkRules',
    'categoryRules',
    'merchantAliases',
  ]) {
    bundle[field] = <Object?>[];
  }
  rule['status'] = 'provisional';
  rule['createdBy'] = 'ai:synthetic-smoke';
  (rule['match'] as Map)['templateHash'] = smsTemplateHash(
    'HDFC',
    smsSkeleton(body),
  );
  final check = RuleEngine().interpretDetailed(
    SmsMessage(
      sender: 'VM-HDFCBK-S',
      body: body,
      sourceKey: 'a' * 64,
      observedAt: DateTime.utc(2026, 11, 1),
    ),
    RuleBundle.fromJson(bundle),
    appVersion: '2.0.0',
  );
  if (check.result.facts.isEmpty)
    throw StateError(
      'Synthetic bundle cannot read its fixture: ${check.reason}',
    );
  final file = File(
    args.isEmpty ? 'build/sms_v2_smoke_defines.json' : args.single,
  );
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(jsonEncode({'SMS_SMOKE_BUNDLE': jsonEncode(bundle)}));
  stdout.writeln(file.absolute.path);
}
