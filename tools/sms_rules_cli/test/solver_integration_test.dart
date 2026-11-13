// The promise of the two tiers. A rule that is sure of what it read is never
// second-guessed: every such message comes out byte-identical with or without
// the solver pack in the bundle. The evidence reader (tier 2) may change a
// rule-matched message in exactly two ways, both checked here on every rule
// example and every golden-case message so neither can widen unnoticed:
//
// 0. refined: a generic catch-all rule's reading enriched with purpose and
//    merchant by the solver (the rule's own account and date are kept).
// 1. corroborated: the rule's one movement was unsure (confidence below
//    kConfidentRead, or no stated purpose). The evidence reader read the same
//    direction, amount and account, so the same rule's facts are kept and only
//    the purpose, the rail and the confidence change.
// 2. overruled: a rule for any sender (`*`) called the message information
//    only (info or balance), and the evidence reader accepts a completed money
//    movement in it. A wide information rule must not swallow a real debit.
// 3. named: a rule read a single credit as salary but printed no payer. The
//    evidence reader finds the employer next to the salary word (or sees that
//    the money was reversed). Only the payer, or a salary typed reversal, may
//    differ; amount, account, date and every other fact stay byte-identical.
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

bool _countable(Fact f) => f is MovementFact && f.evidenceOnly != true;

Map<String, Object?> _withoutTyping(Fact f) {
  final j = Map<String, Object?>.of(f.toJson())..remove('confidence');
  if (f is MovementFact) {
    j['attrs'] = Map<String, Object?>.of(j['attrs'] as Map<String, Object?>)
      ..remove('purpose')
      ..remove('rail');
  }
  return j;
}

/// True when [before] and [after] differ only in the payer of one salary credit
/// (nobody named before, a name after), or in that credit's purpose going from
/// salary to reversal. Everything else must be byte-identical.
bool _salaryNamed(List<Fact> before, List<Fact> after) {
  final bm = before.whereType<MovementFact>().toList();
  final am = after.whereType<MovementFact>().toList();
  if (bm.length != 1 || am.length != 1) return false;
  final b = bm.single, a = am.single;
  if (b.direction != Direction.credit || b.purpose != MovementPurpose.salary) {
    return false;
  }
  final named = (b.counterparty?.name ?? '').isEmpty &&
      (a.counterparty?.name ?? '').isNotEmpty;
  final reversed = a.purpose == MovementPurpose.reversal;
  if (!named && !reversed) return false;
  Map<String, Object?> strip(Fact f) {
    final j = Map<String, Object?>.of(f.toJson())..remove('counterparty');
    j['attrs'] = Map<String, Object?>.of(j['attrs'] as Map<String, Object?>)
      ..remove('purpose');
    return j;
  }
  for (var i = 0; i < before.length; i++) {
    final x = before[i], y = after[i];
    if (identical(x, b)) {
      if (jsonEncode(strip(x)) != jsonEncode(strip(y))) return false;
    } else if (jsonEncode(x.toJson()) != jsonEncode(y.toJson())) {
      return false;
    }
  }
  return true;
}

/// 'refined', 'corroborated' or 'overruled' when the difference between the
/// reading without the pack ([bare]) and with it ([full]) is one the promise
/// allows; null when it is not.
String? _allowedDifference(EngineOutcome bare, EngineOutcome full, RuleBundle bundle) {
  // A generic catch-all rule's plain reading enriched by the solver (same
  // amount and direction, purpose and merchant added).
  if ((bare.winnerId ?? '').startsWith('GEN-') && full.winnerId == 'SOLVER-REFINED') {
    return 'refined';
  }
  final before = bare.result.facts, after = full.result.facts;
  final mine = before.where(_countable).toList();
  if (full.winnerId == bare.winnerId &&
      mine.length == 1 &&
      before.length == after.length &&
      _salaryNamed(before, after)) {
    return 'named';
  }
  final unsure = mine.length == 1 &&
      (mine.single.confidence < kConfidentRead ||
          (mine.single as MovementFact).purpose == MovementPurpose.unknown);
  if (unsure &&
      full.winnerId == bare.winnerId &&
      before.length == after.length &&
      after.every((f) => f.confidence >= kConfidentRead)) {
    var same = true;
    for (var i = 0; i < before.length; i++) {
      if (jsonEncode(_withoutTyping(before[i])) != jsonEncode(_withoutTyping(after[i]))) same = false;
    }
    if (same) return 'corroborated';
  }
  final rule = bundle.rules.where((r) => r.id == bare.winnerId).firstOrNull;
  final informationOnly = rule != null &&
      rule.senders.contains('*') &&
      before.every((f) => f is InfoFact || f is BalanceSnapshotFact);
  if (informationOnly &&
      (full.winnerId ?? '').startsWith('SOLVER-') &&
      after.where(_countable).length == 1) {
    return 'overruled';
  }
  return null;
}

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
    'a rule example changes with the solver pack only by corroboration',
    () {
      var checked = 0;
      final differences = <String>[];
      final allowed = <String, int>{};
      final overruled = <String>[];
      final refined = <String>[];
      final named = <String>[];
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
            final why = _allowedDifference(a, b, withPack);
            if (why == null) {
              differences.add('${rule.id}: ${ex.body}');
            } else {
              allowed[why] = (allowed[why] ?? 0) + 1;
              if (why == 'overruled') overruled.add('${a.winnerId} -> ${b.winnerId}: ${ex.body}');
              if (why == 'refined') refined.add('${rule.id}: ${ex.body}');
              if (why == 'named') named.add(rule.id);
            }
          }
        }
      }
      expect(checked, greaterThan(1000));
      expect(
        differences,
        isEmpty,
        reason: 'a rule-matched message changed in a way the promise does not allow:\n${differences.join('\n')}',
      );
      // An information rule losing to a money reading changes what lands in
      // people's totals. Each such example is a rule author's own trap (a message
      // their rule must not read), reviewed by hand; a new one needs the same.
      expect(overruled, isEmpty, reason: overruled.join('\n'));
      // The weak last-resort rules and the rules that could not name a purpose
      // are the ones corroborated. Zero would mean the second opinion is off.
      expect(allowed['corroborated'] ?? 0, greaterThan(20));
      // Reviewed: these are salary examples whose rule printed no payer; the
      // evidence reader names the employer next to the salary word and changes
      // nothing else. A new rule id here needs the same hand review.
      // GEN-ACCT-SALARY-NARRATION-C1-B is retired: its own example is now read
      // by the generic salary rule and named the same way (checked identical on
      // a 6,023-message real inbox, apart from the winning rule's id).
      expect(named.toSet(), {
        'BRK-DIV-NACH-NARR-01',
        'GEN-ACCT-SALARY-NARRATION-C1-B',
        'SBI-ACCT-CREDIT-DIVIDEND-NAMED',
        'SBI-STYLE-CR-SAL',
        'SBI-STYLE-CR-SAL-B',
      });
      // Reviewed: these autopay debits were plain unknown-purpose debits that a
      // generic catch-all rule read and the solver enriched.
      expect(refined.map((e) => e.split(':').first).toSet(), {
        'MND-UPCOMING-01',
        'MND-UPCOMING-01-INV',
        'MND-UPCOMING-90',
      });
    },
  );

  test(
    'a golden-case message a rule reads changes with the solver pack only as the promise allows',
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
          // A golden message no rule reads must not start depending on the
          // evidence reader either: only a rule-matched one may differ.
          if (_signature(a) != _signature(b) &&
              (a.result.outcome == InterpretOutcome.unknown ||
                  _allowedDifference(a, b, withPack) == null)) {
            differences.add('${c['id']}: ${m['body']}');
          }
        }
      }
      expect(checked, greaterThan(250));
      expect(
        differences,
        isEmpty,
        reason:
            'the solver changed a golden message in a way the promise does not allow:\n${differences.join('\n')}',
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
