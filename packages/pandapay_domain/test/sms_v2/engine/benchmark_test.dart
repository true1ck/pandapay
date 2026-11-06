@Tags(['benchmark'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

/// 1,000 rules over 100 brands; 10,000 messages (matching, near-miss and
/// unknown). Gates: compile under 300 ms, interpret under 2 s.
///
/// Shared CI runners are about three times slower than a developer machine
/// (GitHub measured 207 ms and 2,048 ms where an M-series Mac takes 56 ms and
/// 644 ms), so CI gets twice each budget. That still fails a real regression,
/// which is an order of magnitude, not a few percent.
final _ciBudgetFactor = Platform.environment['CI'] == 'true' ? 2 : 1;

void main() {
  final base = jsonDecode(File('../../contracts/sms/v2/fixtures/valid/bundle/full.json').readAsStringSync())
      as Map<String, Object?>;

  Map<String, Object?> rule(int brand, int n) => {
        'id': 'B$brand-R$n',
        'version': 1,
        'family': 'bench',
        'senders': ['BRAND$brand'],
        'priority': 1000 - n,
        'match': {
          'pattern': '^Rs\\.(?<amt>[\\d,]+\\.\\d{2}) spent on card x(?<mask>\\d{4}) at (?<m>[A-Z ]+?) variant$n\\.',
          'flags': 'i',
          'requireAll': ['spent'],
          'rejectAny': ['declined'],
        },
        'emit': [
          {
            'factType': 'movement',
            'attrs': {'direction': 'debit', 'purpose': 'purchase', 'rail': 'card'},
            'amounts': [
              {'role': 'posted', 'from': 'amt', 'unit': 'INR'},
            ],
            'instrument': {'kind': 'credit_card', 'issuerSlug': 'hdfc', 'maskFrom': 'mask'},
            'counterparty': {'nameFrom': 'm', 'kind': 'merchant', 'transforms': ['sanitizeNarration']},
          },
        ],
        'confidence': 0.9,
        'examples': [
          {
            'sender': 'VM-BRAND$brand-S',
            'body': 'Rs.1.00 spent on card x1234 at SHOP variant$n.',
            'expectFactTypes': ['movement'],
          },
          {'sender': 'VM-BRAND$brand-S', 'body': 'declined', 'expectFactTypes': <String>[]},
        ],
        'status': 'active',
        'createdBy': 'baseline',
        'updatedAt': '2026-11-20T00:00:00Z',
      };

  final json = Map<String, Object?>.of(base)
    ..['senders'] = [
      for (var b = 0; b < 100; b++)
        {'brand': 'BRAND$b', 'issuerSlug': 'hdfc', 'issuerKind': 'bank', 'aliases': <String>[]},
    ]
    ..['ignoreRules'] = <Object?>[]
    ..['counterpartyPurposes'] = <Object?>[]
    ..['rules'] = [
      for (var b = 0; b < 100; b++)
        for (var n = 0; n < 10; n++) rule(b, n),
    ];
  final bundle = RuleBundle.fromJson(json);

  test('compile 1,000 rules in under 300 ms', () {
    final sw = Stopwatch()..start();
    CompiledBundle.compile(bundle);
    sw.stop();
    // ignore: avoid_print
    print('compile: ${sw.elapsedMilliseconds} ms');
    expect(sw.elapsedMilliseconds, lessThan(300 * _ciBudgetFactor));
  });

  test('interpret 10,000 messages in under 2 s', () {
    final engine = RuleEngine();
    final observed = DateTime.utc(2026, 11, 1);
    engine.compiled(bundle);
    final msgs = <SmsMessage>[
      for (var i = 0; i < 10000; i++)
        SmsMessage(
          sender: 'VM-BRAND${i % 100}-S',
          body: switch (i % 4) {
            0 || 1 => 'Rs.${i + 1}.00 spent on card x${1000 + i % 9000} at SWIGGY variant${i % 10}.',
            2 => 'Txn of Rs.${i + 1}.00 declined at SWIGGY',
            _ => 'Your OTP is ${100000 + i}. Do not share it with anyone.',
          },
          observedAt: observed,
          sourceKey: 'k$i',
        ),
    ];
    final sw = Stopwatch()..start();
    var matched = 0;
    for (final m in msgs) {
      if (engine.interpret(m, bundle, appVersion: '1').outcome == InterpretOutcome.matched) matched++;
    }
    sw.stop();
    // ignore: avoid_print
    print('interpret: ${sw.elapsedMilliseconds} ms, matched $matched');
    expect(matched, 5000);
    expect(sw.elapsedMilliseconds, lessThan(2000 * _ciBudgetFactor));
  });
}
