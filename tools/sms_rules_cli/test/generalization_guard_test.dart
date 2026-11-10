// Generalisation guard. Reads `tools/sms_golden/heldout/`: alerts in layouts no
// rule was written for, with the right answer, and lookalikes that are not a
// completed movement. Each message goes alone through the whole pipeline
// (rules, evidence reader, instruments, linker, ledger).
//
// The two things that must never happen are a wrong reading that lands in the
// totals and a real transaction that vanishes without a question. A message
// that is honestly sent to review is allowed in small numbers; it is visible
// and it feeds the learning loop.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_evaluation.dart';
import 'package:sms_rules_cli/rules_source.dart';
import 'package:test/test.dart';

class _Read {
  _Read(this.outcome, this.rule, this.facts, this.events, this.entries, this.spend, this.income);
  final InterpretOutcome outcome;
  final String? rule;
  final List<Fact> facts;
  final List<Map<String, dynamic>> events;
  final int entries, spend, income;
}

void main() {
  late RuleBundle bundle;
  late GoldenAdapters adapters;
  final engine = RuleEngine();
  var n = 0;

  setUpAll(() {
    final source = readRulesFolder('../../rules/sms/v2');
    expect(source.problems, isEmpty);
    bundle = parseUnsignedBundle(source.bundle);
    adapters = adaptersForBundle(bundle);
  });

  Future<_Read> read(String sender, String body) async {
    final o = engine.interpretDetailed(
      SmsMessage(sender: sender, body: body, observedAt: DateTime.utc(2026, 11, 20, 10), sourceKey: 'g${n++}'),
      bundle,
      appVersion: 'guard',
    );
    final money = [
      for (final f in o.result.facts)
        if (f is! InfoFact) f.toJson().cast<String, dynamic>(),
    ];
    var events = <Map<String, dynamic>>[];
    var entries = 0, spend = 0, income = 0;
    if (money.isNotEmpty) {
      final r = await adapters.instruments!.resolve(facts: money, knownInstruments: const []);
      events = await adapters.linker!.link(facts: r.facts, instruments: r.instruments);
      final e = await adapters.projector!.project(events: events, facts: r.facts, instruments: r.instruments);
      final t = await adapters.projector!.totals(entries: e);
      entries = e.length;
      spend = t.spendMinor;
      income = t.incomeMinor;
    }
    return _Read(o.result.outcome, o.winnerId, o.result.facts, events, entries, spend, income);
  }

  List<Map<String, dynamic>> rows(String name) => [
    for (final l in File('../sms_golden/heldout/$name').readAsLinesSync())
      if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, dynamic>,
  ];

  /// 'ok', 'asked' (visible: review or confirmation), or a description of what is wrong.
  Future<String> verdict(Map<String, dynamic> m) async {
    final t = m['truth'] as Map<String, dynamic>;
    final r = await read(m['sender'] as String, m['body'] as String);
    if (r.outcome == InterpretOutcome.unknown) return 'asked';
    final real = [
      for (final f in r.facts)
        if (f is MovementFact && f.evidenceOnly != true) f,
    ];
    if (real.isEmpty) return 'SILENT: read as not a transaction by ${r.rule}';
    final f = real.first;
    if (f.direction.wire != t['direction']) return 'WRONG direction by ${r.rule}';
    if (f.amount(AmountRole.posted)?.minor != t['minor']) return 'WRONG amount by ${r.rule}';
    final mask = f.instrument?.maskDigits;
    final digits = t['digits'] as String;
    if (mask != null && !(digits.endsWith(mask) || mask.endsWith(digits))) {
      return 'WRONG account digits "$mask" by ${r.rule}';
    }
    if (r.entries == 0) {
      return real.every((x) => x.confidence >= kConfidentRead)
          ? 'SILENT: read right but not counted and not asked, by ${r.rule}'
          : 'asked';
    }
    if (r.events.any((e) => e['type'] == 'own_transfer')) return 'WRONG: counted as an own transfer by ${r.rule}';
    final got = t['direction'] == 'credit' ? r.income : r.spend;
    if (got != t['minor']) return 'WRONG ledger total by ${r.rule}';
    return 'ok';
  }

  for (final (file, floor) in [('variants_a.jsonl', 0.97), ('variants_b.jsonl', 0.97), ('variants_c.jsonl', 0.95)]) {
    test('$file: nothing wrong, nothing silent, at least ${(floor * 100).round()}% counted', () async {
      final all = rows(file);
      final bad = <String>[];
      var ok = 0, asked = 0;
      for (final m in all) {
        final v = await verdict(m);
        if (v == 'ok') {
          ok++;
        } else if (v == 'asked') {
          asked++;
        } else {
          bad.add('$v :: ${m['body']}');
        }
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
      expect(ok / all.length, greaterThanOrEqualTo(floor), reason: '$ok counted, $asked asked, of ${all.length}');
    });
  }

  test('lookalikes.jsonl: none is counted as a transaction', () async {
    final counted = <String>[];
    for (final m in rows('lookalikes.jsonl')) {
      final r = await read(m['sender'] as String, m['body'] as String);
      if (r.entries > 0) counted.add('${r.rule} :: ${m['body']}');
    }
    expect(counted, isEmpty, reason: counted.join('\n'));
  });
}
