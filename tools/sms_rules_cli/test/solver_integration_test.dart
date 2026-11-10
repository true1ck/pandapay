// The promise of tier 2: it only ever runs when NO rule matched, so every
// message a rule already reads must come out byte-identical with or without
// the solver pack in the bundle. This test proves it on every rule example in
// the repo bundle and on every golden-case message, so it cannot regress.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:sms_rules_cli/rules_source.dart';
import 'package:test/test.dart';

String _signature(EngineOutcome o) => jsonEncode({
  'outcome': o.result.outcome.name,
  'rule': o.winnerId,
  'facts': [for (final f in o.result.facts) f.toJson()],
});

void main() {
  late RuleBundle withPack;
  late RuleBundle bare;
  final engine = RuleEngine();

  setUpAll(() {
    final source = readRulesFolder('../../rules/sms/v2');
    expect(source.problems, isEmpty);
    expect(
      source.bundle.containsKey('solverPack'),
      isTrue,
      reason: 'rules/sms/solver/pack.json is read into the bundle',
    );
    withPack = parseUnsignedBundle(source.bundle);
    bare = parseUnsignedBundle(
      Map<String, Object?>.of(source.bundle)..remove('solverPack'),
    );
  });

  test(
    'the repo bundle carries a solver pack, passes the contract, and needs engine 2.4.0',
    () {
      expect(withPack.solverPack, isNotNull);
      expect(withPack.validate().ok, isTrue, reason: '${withPack.validate()}');
      expect(
        compareSemver(withPack.minEngineVersion, smsEngineVersion),
        lessThanOrEqualTo(0),
      );
      expect(
        compareSemver(withPack.minEngineVersion, '2.4.0'),
        greaterThanOrEqualTo(0),
      );
      expect(engine.compiled(withPack).solver, isNotNull);
      expect(engine.compiled(withPack).solverError, isNull);
      expect(bare.toJson().containsKey('solverPack'), isFalse);
    },
  );

  test(
    'every rule example reads identically with and without the solver pack',
    () {
      var checked = 0;
      final differences = <String>[];
      final refined = <String>[];
      for (final rule in withPack.rules) {
        for (final ex in rule.examples) {
          final msg = SmsMessage(
            sender: ex.sender,
            body: ex.body,
            observedAt: DateTime.utc(2026, 11, 20, 9),
            sourceKey: 'example:${rule.id}',
          );
          final a = engine.interpretDetailed(msg, bare, appVersion: '2.0.0');
          final b = engine.interpretDetailed(
            msg,
            withPack,
            appVersion: '2.0.0',
          );
          checked++;
          if (a.result.outcome != InterpretOutcome.unknown &&
              _signature(a) != _signature(b)) {
            // The only permitted change: a generic catch-all rule's plain reading
            // enriched by the solver (same amount and direction, purpose and
            // merchant added). A specific rule's result must never change.
            final enriched =
                (a.winnerId ?? '').startsWith('GEN-') &&
                b.winnerId == 'SOLVER-REFINED';
            if (enriched) {
              refined.add('${rule.id}: ${ex.body}');
            } else {
              differences.add('${rule.id}: ${ex.body}');
            }
          }
        }
      }
      expect(checked, greaterThan(1000));
      expect(
        differences,
        isEmpty,
        reason: 'a rule-matched message changed:\n${differences.join('\n')}',
      );
      // Reviewed: these autopay debits were plain unknown-purpose debits.
      expect(refined.map((e) => e.split(':').first).toSet(), {
        'MND-UPCOMING-01',
        'MND-UPCOMING-01-INV',
        'MND-UPCOMING-90',
      });
    },
  );

  test(
    'every golden-case message reads identically with and without the solver pack',
    () {
      final dir = Directory('../sms_golden/cases');
      var checked = 0;
      final differences = <String>[];
      for (final f
          in dir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))) {
        final c = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        for (final m in (c['messages'] as List? ?? const [])) {
          final msg = SmsMessage(
            sender: (m as Map)['sender'] as String,
            body: m['body'] as String,
            observedAt: DateTime.parse(m['observedAt'] as String).toUtc(),
            sourceKey: '${c['id']}',
          );
          final a = engine.interpretDetailed(msg, bare, appVersion: '2.0.0');
          final b = engine.interpretDetailed(
            msg,
            withPack,
            appVersion: '2.0.0',
          );
          checked++;
          if (_signature(a) != _signature(b))
            differences.add('${c['id']}: ${m['body']}');
        }
      }
      expect(checked, greaterThan(250));
      expect(
        differences,
        isEmpty,
        reason:
            'the solver changed a golden message:\n${differences.join('\n')}',
      );
    },
  );

  // The rule examples include the traps rule authors wrote on purpose (messages
  // a rule must NOT read). Where no rule matches, the solver may read them, so
  // every message it would COUNT as money is reviewed by hand and pinned here.
  // A change to this list is a change to what lands in people's totals: review it.
  test(
    'the messages the solver counts as money among the rule examples are the reviewed set',
    () {
      String key(Fact f, String body) {
        final m = f as MovementFact;
        final head = body.replaceAll('\n', ' ');
        return '${m.direction.wire} ${m.amounts.first.minor} ${m.purpose.wire}: ${head.length > 150 - 0 ? head.substring(0, 150) : head}';
      }

      final seen = <String>{};
      final counted = <String>[];
      for (final rule in withPack.rules) {
        for (final ex in rule.examples) {
          if (!seen.add(ex.body)) continue;
          final msg = SmsMessage(
            sender: ex.sender,
            body: ex.body,
            observedAt: DateTime.utc(2026, 11, 20, 9),
            sourceKey: 'x',
          );
          if (engine
                  .interpretDetailed(msg, bare, appVersion: '2.0.0')
                  .result
                  .outcome !=
              InterpretOutcome.unknown)
            continue;
          final b = engine.interpretDetailed(
            msg,
            withPack,
            appVersion: '2.0.0',
          );
          if (!(b.winnerId ?? '').startsWith('SOLVER-')) continue;
          for (final fact in b.result.facts) {
            if (fact is MovementFact && fact.evidenceOnly != true) {
              counted.add(key(fact, ex.body));
              break;
            }
          }
        }
      }
      final expected = File(
        '../sms_golden/solver/rule_example_counts.expected.txt',
      ).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      String shortKey(String s) => s.length > 150 ? s.substring(0, 150) : s;
      expect(
        counted.map(shortKey).toList()..sort(),
        expected..sort(),
        reason:
            'The set of rule-example messages the solver counts as money changed. '
            'Review each change by hand, then update tools/sms_golden/solver/rule_example_counts.expected.txt.',
      );
    },
  );
}
