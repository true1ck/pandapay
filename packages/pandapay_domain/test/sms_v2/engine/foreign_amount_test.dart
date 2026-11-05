import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

// CCR-004: a rule can read the unit of an amount from the message, and can
// attach the original foreign amount to a posted INR amount.

Map<String, Object?> _fixture() =>
    jsonDecode(File('../../contracts/sms/v2/fixtures/valid/bundle/full.json').readAsStringSync())
        as Map<String, Object?>;

const _codes =
    'usd|eur|gbp|aed|sgd|jpy|kwd|\\\$|us\\\$|€|£';

Map<String, Object?> _rule({
  required String id,
  required String pattern,
  required List<Map<String, Object?>> amounts,
  String direction = 'debit',
}) => {
  'id': id,
  'version': 1,
  'family': 'test',
  'senders': ['*'],
  'priority': 500,
  'match': {'pattern': pattern, 'flags': 'i'},
  'emit': [
    {
      'factType': 'movement',
      'attrs': {'direction': direction, 'purpose': 'purchase', 'rail': 'card'},
      'amounts': amounts,
    },
  ],
  'confidence': 0.9,
  'examples': [
    {'sender': 'VM-HDFCBK-S', 'body': 'pos', 'expectFactTypes': ['movement']},
    {'sender': 'VM-HDFCBK-S', 'body': 'neg', 'expectFactTypes': <String>[]},
  ],
  'status': 'active',
  'createdBy': 'baseline',
  'updatedAt': '2026-11-20T00:00:00Z',
};

RuleBundle _bundle(List<Map<String, Object?>> rules) {
  final j = _fixture();
  j['rules'] = rules;
  j['ignoreRules'] = <Object?>[];
  j['counterpartyPurposes'] = <Object?>[];
  j['minEngineVersion'] = smsEngineVersion;
  return RuleBundle.fromJson(j);
}

SmsMessage _msg(String body) => SmsMessage(
  sender: 'VM-HDFCBK-S',
  body: body,
  observedAt: DateTime.utc(2026, 11, 1, 8),
  sourceKey: 'src1',
);

final _foreignOnly = _rule(
  id: 'T-FX-ONLY',
  pattern: 'spent\\s+(?<cur>$_codes)\\s*(?<amt>\\d[\\d,]*(?:\\.\\d+)?)\\s+at',
  amounts: [
    {'role': 'posted', 'from': 'amt', 'unitFrom': 'cur'},
  ],
);

final _inrWithOriginal = _rule(
  id: 'T-FX-INR',
  pattern:
      'rs\\.?\\s*(?<amt>\\d[\\d,]*(?:\\.\\d{1,2})?)\\s+spent\\s+\\((?<cur>$_codes)\\s*(?<fx>\\d[\\d,]*(?:\\.\\d+)?)\\)',
  amounts: [
    {
      'role': 'posted',
      'from': 'amt',
      'unit': 'INR',
      'original': {'from': 'fx', 'currencyFrom': 'cur'},
    },
  ],
);

List<Map<String, Object?>> _amounts(InterpretResult r) => [
  for (final f in r.facts)
    for (final a in (f.toJson()['amounts'] as List)) (a as Map).cast<String, Object?>(),
];

void main() {
  final engine = RuleEngine();

  test('engine version requires the CCR-004 features', () {
    expect(compareSemver(smsEngineVersion, '2.2.0'), greaterThanOrEqualTo(0));
  });

  group('unitFrom', () {
    test('a three letter code becomes the unit, minor uses the currency precision', () {
      final out = engine.interpret(
        _msg('spent USD 20.50 at SAMPLE AI'),
        _bundle([_foreignOnly]),
        appVersion: '1.0.0+1',
      );
      expect(out.outcome, InterpretOutcome.matched);
      expect(_amounts(out), [
        {'role': 'posted', 'minor': 2050, 'unit': 'USD'},
      ]);
    });

    test('zero-decimal and three-decimal currencies scale by their own precision', () {
      final b = _bundle([_foreignOnly]);
      expect(_amounts(engine.interpret(_msg('spent JPY 1,500 at SAMPLE SHOP'), b, appVersion: 'x')), [
        {'role': 'posted', 'minor': 1500, 'unit': 'JPY'},
      ]);
      expect(_amounts(engine.interpret(_msg('spent KWD 3.250 at SAMPLE SHOP'), b, appVersion: 'x')), [
        {'role': 'posted', 'minor': 3250, 'unit': 'KWD'},
      ]);
    });

    test('symbols map to a code; a bare dollar sign is not guessed', () {
      final b = _bundle([_foreignOnly]);
      expect(_amounts(engine.interpret(_msg('spent US\$ 9.99 at SAMPLE'), b, appVersion: 'x')), [
        {'role': 'posted', 'minor': 999, 'unit': 'USD'},
      ]);
      expect(_amounts(engine.interpret(_msg('spent € 10 at SAMPLE'), b, appVersion: 'x')), [
        {'role': 'posted', 'minor': 1000, 'unit': 'EUR'},
      ]);
      expect(_amounts(engine.interpret(_msg('spent \$ 20.00 at SAMPLE'), b, appVersion: 'x')), [
        {'role': 'posted', 'minor': 2000, 'unit': 'XXX'},
      ]);
    });

    test('a zero amount or too many decimals is an invalid emit, never a purchase', () {
      final b = _bundle([_foreignOnly]);
      for (final body in ['spent USD 0.00 at SAMPLE', 'spent USD 1.234 at SAMPLE']) {
        final o = engine.interpretDetailed(_msg(body), b, appVersion: 'x');
        expect(o.result.outcome, InterpretOutcome.unknown, reason: body);
        expect(o.reason, 'rule_emitted_invalid', reason: body);
      }
    });
  });

  group('original', () {
    test('INR posted amount carries the foreign original', () {
      final out = engine.interpret(
        _msg('Rs.1,750.00 spent (USD 20.00)'),
        _bundle([_inrWithOriginal]),
        appVersion: 'x',
      );
      expect(_amounts(out), [
        {
          'role': 'posted',
          'minor': 175000,
          'unit': 'INR',
          'original': {'minor': 2000, 'currency': 'USD'},
        },
      ]);
    });

    test('an original group that did not match is skipped, the INR amount stays', () {
      final r = _rule(
        id: 'T-FX-OPT',
        pattern: 'rs\\.?\\s*(?<amt>\\d[\\d,]*(?:\\.\\d{1,2})?)\\s+spent(?:\\s+\\((?<cur>usd)\\s*(?<fx>\\d+(?:\\.\\d+)?)\\))?',
        amounts: [
          {
            'role': 'posted',
            'from': 'amt',
            'unit': 'INR',
            'original': {'from': 'fx', 'currencyFrom': 'cur'},
          },
        ],
      );
      final out = engine.interpret(_msg('Rs.499.00 spent'), _bundle([r]), appVersion: 'x');
      expect(_amounts(out), [
        {'role': 'posted', 'minor': 49900, 'unit': 'INR'},
      ]);
    });

    test('a fixed original currency is allowed', () {
      final r = _rule(
        id: 'T-FX-FIXED',
        pattern: 'rs\\.?\\s*(?<amt>\\d[\\d,]*(?:\\.\\d{1,2})?)\\s+for\\s+usd\\s*(?<fx>\\d+(?:\\.\\d+)?)',
        amounts: [
          {
            'role': 'posted',
            'from': 'amt',
            'unit': 'INR',
            'original': {'from': 'fx', 'currency': 'USD'},
          },
        ],
      );
      final out = engine.interpret(_msg('Rs.1750 for USD 20'), _bundle([r]), appVersion: 'x');
      expect(_amounts(out).single['original'], {'minor': 2000, 'currency': 'USD'});
    });

    test('an INR original is refused', () {
      final b = _bundle([
        _rule(
          id: 'T-FX-BAD',
          pattern: 'rs\\.?\\s*(?<amt>\\d+)\\s+spent\\s+\\((?<cur>inr)\\s*(?<fx>\\d+)\\)',
          amounts: [
            {
              'role': 'posted',
              'from': 'amt',
              'unit': 'INR',
              'original': {'from': 'fx', 'currencyFrom': 'cur'},
            },
          ],
        ),
      ]);
      final o = engine.interpretDetailed(_msg('Rs.10 spent (INR 10)'), b, appVersion: 'x');
      expect(o.reason, 'rule_emitted_invalid');
    });
  });

  group('bundle validation', () {
    test('unit or unitFrom is required, never neither', () {
      final j = _fixture();
      final rule = _rule(
        id: 'T-FX-NONE',
        pattern: '(?<amt>\\d+)',
        amounts: [
          {'role': 'posted', 'from': 'amt'},
        ],
      );
      j['rules'] = [rule];
      j['ignoreRules'] = <Object?>[];
      j['counterpartyPurposes'] = <Object?>[];
      final r = validateBundleJson(j);
      expect(r.codes, ['bundle.emit.amount_unit_required']);
    });

    test('original needs a source group and a currency', () {
      final j = _fixture();
      j['rules'] = [
        _rule(
          id: 'T-FX-ORIG',
          pattern: '(?<amt>\\d+)',
          amounts: [
            {
              'role': 'posted',
              'from': 'amt',
              'unit': 'INR',
              'original': {'from': 'amt'},
            },
          ],
        ),
      ];
      j['ignoreRules'] = <Object?>[];
      j['counterpartyPurposes'] = <Object?>[];
      expect(validateBundleJson(j).codes, ['bundle.emit.original_invalid']);
    });

    test('lint flags a unitFrom or original group the pattern does not define', () {
      final bundle = _bundle([
        _rule(
          id: 'T-FX-LINT',
          pattern: '(?<amt>\\d+)',
          amounts: [
            {
              'role': 'posted',
              'from': 'amt',
              'unit': 'INR',
              'original': {'from': 'fx', 'currencyFrom': 'cur'},
            },
          ],
        ),
      ]);
      final issues = lintBundle(bundle).where((i) => i.code == 'lint.group.missing').toList();
      expect(issues, hasLength(2));
    });
  });

  group('Amount helpers', () {
    test('foreign amount reads original, or the unit of a foreign-only amount', () {
      const settled = Amount(
        role: AmountRole.posted,
        minor: 175000,
        unit: 'INR',
        original: OriginalAmount(minor: 2000, currency: 'USD'),
      );
      const only = Amount(role: AmountRole.posted, minor: 2000, unit: 'USD');
      const plain = Amount(role: AmountRole.posted, minor: 500, unit: 'INR');
      expect(settled.isInr, isTrue);
      expect(settled.foreign?.currency, 'USD');
      expect(only.isInr, isFalse);
      expect(only.foreign?.minor, 2000);
      expect(only.foreign?.currency, 'USD');
      expect(plain.foreign, isNull);
    });

    test('currency precision table', () {
      expect(smsCurrencyExponent('USD'), 2);
      expect(smsCurrencyExponent('JPY'), 0);
      expect(smsCurrencyExponent('KWD'), 3);
      expect(smsCurrencyExponent('XXX'), 2);
      expect(smsCurrencyExponent('ZZZ'), isNull);
      expect(smsForeignCurrencyCode('us\$'), 'USD');
      expect(smsForeignCurrencyCode('inr'), isNull);
    });
  });
}
