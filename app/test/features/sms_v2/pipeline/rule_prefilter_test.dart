// Lane P regression: the engine's literal prefilter must never change which
// rule wins. It runs before the regex, so a wrong literal would silently turn
// a match into "unknown".
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/sms_v2.dart';

import '../support/rules.dart';
import '../support/synthetic_corpus.dart';

void main() {
  final bundle = testRuleBundle();
  final corpus = SyntheticCorpus.generate(bundle, count: 1500, seed: 11);

  test('every required literal is present in every body its regex matches', () {
    final random = Random(5);
    final bodies = <String>{
      for (final m in corpus.messages) m.body,
      for (final rule in bundle.rules)
        for (final example in rule.examples) example.body,
    }.toList();
    var checkedMatches = 0, withLiterals = 0;
    for (final rule in bundle.rules) {
      final compiled = CompiledRule(
        rule,
        RegExp(
          rule.match.pattern,
          caseSensitive: !rule.match.flags.contains('i'),
          multiLine: rule.match.flags.contains('m'),
          dotAll: rule.match.flags.contains('s'),
        ),
      );
      if (compiled.literals.isNotEmpty) withLiterals++;
      final sample = <String>[
        for (final example in rule.examples) example.body,
        for (var i = 0; i < 400; i++) bodies[random.nextInt(bodies.length)],
      ];
      for (final body in sample) {
        if (!compiled.regex.hasMatch(body)) continue;
        checkedMatches++;
        final lower = body.toLowerCase();
        expect(
          compiled.literals.every(lower.contains),
          isTrue,
          reason: '${rule.id} literals ${compiled.literals} vs "$body"',
        );
      }
    }
    expect(checkedMatches, greaterThan(1000));
    expect(withLiterals / bundle.rules.length, greaterThan(.7));
  });

  test('the winning rule equals a brute-force scan without the prefilter', () {
    final engine = RuleEngine();
    final compiled = engine.compiled(bundle);
    var compared = 0;
    for (final m in corpus.messages) {
      final message = SmsMessage(
        sender: m.sender,
        body: m.body,
        observedAt: m.receivedAt.toUtc(),
        sourceKey: 'a' * 64,
      );
      final outcome = engine.interpretDetailed(message, bundle, appVersion: '2');
      if (outcome.result.outcome == InterpretOutcome.ignored) continue;
      final lower = m.body.toLowerCase();
      final brand = compiled.normalize(m.sender).brand;
      String? expected;
      for (final c in compiled.rulesFor(brand)) {
        final th = c.templateHash;
        if (th != null && th != outcome.result.templateHash) continue;
        if (c.regex.firstMatch(m.body) == null) continue;
        if (c.requireAll.any((s) => !lower.contains(s)) ||
            c.rejectAny.any(lower.contains)) {
          continue;
        }
        expected = c.rule.id;
        break;
      }
      expect(outcome.winnerId, expected, reason: m.body);
      compared++;
    }
    expect(compared, greaterThan(1000));
  });
}
