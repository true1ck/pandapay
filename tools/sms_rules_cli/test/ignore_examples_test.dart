import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:sms_rules_cli/rules_source.dart';
import 'package:test/test.dart';

/// Ignore rules have no example slot in the bundle contract, so their
/// synthetic positive and negative examples live in
/// `tools/sms_golden/ignore_examples/*.json` and are checked here.
///
/// Positive: the rule's own pattern and sender scope match, and the engine
/// ignores the message. Negative: the rule must not match (the message may
/// still be ignored by another rule or be financial).
void main() {
  final source = readRulesFolder(
    '../../rules/sms/v2',
    bundleVersion: 0,
    createdAt: '2026-11-01T00:00:00Z',
  );
  final bundle = parseUnsignedBundle(source.bundle);
  final engine = RuleEngine();
  final files = Directory('../sms_golden/ignore_examples')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  bool ruleMatches(IgnoreRule rule, String sender, String body) {
    final brand = normalizeSenderBrand(sender, bundle.senders).brand;
    if (!(rule.senders.contains('*') || rule.senders.contains(brand))) {
      return false;
    }
    return RegExp(rule.pattern, caseSensitive: !rule.flags.contains('i'))
        .hasMatch(body);
  }

  for (final file in files) {
    final entries = (jsonDecode(file.readAsStringSync()) as List).cast<Map>();
    group(file.uri.pathSegments.last, () {
      for (final entry in entries) {
        final id = entry['rule'] as String;
        final rule = bundle.ignoreRules.firstWhere((r) => r.id == id);
        final positives = (entry['positive'] as List).cast<Map>();
        final negatives = (entry['negative'] as List).cast<Map>();
        test('$id has at least one positive and one negative example', () {
          expect(positives, isNotEmpty);
          expect(negatives, isNotEmpty);
        });
        for (var i = 0; i < positives.length; i++) {
          final p = positives[i];
          test('$id positive #$i is ignored by the rule', () {
            expect(ruleMatches(rule, p['sender'] as String, p['body'] as String), isTrue);
            final out = engine.interpretDetailed(
              SmsMessage(
                sender: p['sender'] as String,
                body: p['body'] as String,
                observedAt: DateTime.utc(2026, 12, 1),
                sourceKey: 'example:$id:$i',
              ),
              bundle,
              appVersion: '2.0.0',
            );
            expect(out.result.outcome, InterpretOutcome.ignored);
          });
        }
        for (var i = 0; i < negatives.length; i++) {
          final n = negatives[i];
          test('$id negative #$i is not matched by the rule', () {
            expect(ruleMatches(rule, n['sender'] as String, n['body'] as String), isFalse);
          });
        }
      }
    });
  }

  test('every ignore rule added by lane L has examples', () {
    final covered = {
      for (final file in files)
        for (final e in (jsonDecode(file.readAsStringSync()) as List).cast<Map>()) e['rule'] as String,
    };
    final lane = bundle.ignoreRules.where((r) => !const {
          'IGN-OTP-CODE', 'IGN-SECURITY-ALERT', 'IGN-SECURITY-SCAM', 'IGN-PROMO-CASHBACK-OFFER',
          'IGN-LIMIT-OFFER', 'IGN-EMI-AND-CARD-OFFER', 'IGN-LIMIT-NOTICE-NO-AMOUNT',
          'IGN-LOAN-OFFER-CONSENT', 'IGN-BROKER-PAYABLE-TRADES', 'IGN-RECHARGE-PROMO',
          'IGN-TELECOM-SERVICE', 'IGN-TELECOM-PREPAID-DEDUCTION', 'IGN-DELIVERY-STATUS',
          'IGN-SERVICE-SURVEY', 'IGN-SERVICE-KYC-CONTROLS', 'IGN-SERVICE-CARD-CONTROLS',
          'IGN-SERVICE-ADVICE', 'IGN-SERVICE-PF-NOTICE', 'IGN-SERVICE-OPS-NOTICE',
          'IGN-SERVICE-DEMAT-NOTICE', 'IGN-SERVICE-BILLER-ONBOARDING', 'IGN-REWARD-EXPIRY-NOTICE',
          'IGN-SERVICE-WALLET-NAG', 'IGN-PROMO-GAMBLING', 'IGN-PROMO-INSURANCE-RENEWAL',
          'IGN-PROMO-GENERIC', 'IGN-ICICI-TRANSACTION-PASSWORD', 'IGN-JIO-FRAUD-EDUCATION',
        }.contains(r.id));
    expect([for (final r in lane) if (!covered.contains(r.id)) r.id], isEmpty);
  });
}
