/// Differential check: runs every golden case message through the rule engine
/// WITH and WITHOUT the bundle's solver pack and reports every message whose
/// result differs, against what the golden case expects.
///
///   dart run tool/solver_golden_diff.dart BUNDLE [CASES_DIR]
///
/// By construction the solver runs only when no rule matched, so a message a
/// rule matched must never differ. This tool proves it, and shows what the
/// solver does with the messages no rule read (each case's expectation says
/// whether that is right). Exit code 1 if a rule-matched message differs or
/// the solver turns a case that expects financial facts into an ignored one.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: solver_golden_diff BUNDLE [CASES_DIR]');
    exit(64);
  }
  final json =
      jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final withPack = RuleBundle.fromJson(json);
  final bare = RuleBundle.fromJson(
    Map<String, dynamic>.of(json)..remove('solverPack'),
  );
  final dir = Directory(args.length > 1 ? args[1] : '../sms_golden/cases');
  final engine = RuleEngine();

  var messages = 0,
      same = 0,
      changed = 0,
      ruleMatchedChanged = 0,
      badIgnore = 0;
  final lines = <String>[];
  for (final f
      in dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))) {
    final c = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final expect = c['expect'] as Map<String, dynamic>? ?? const {};
    final expectedFacts = (expect['facts'] as List?) ?? const [];
    final wantsFinancial = expectedFacts.any(
      (x) => (x as Map)['factType'] != 'info',
    );
    for (final m in (c['messages'] as List? ?? const [])) {
      final msg = m as Map<String, dynamic>;
      final sm = SmsMessage(
        sender: msg['sender'] as String,
        body: msg['body'] as String,
        observedAt: DateTime.parse(msg['observedAt'] as String).toUtc(),
        sourceKey: '${c['id']}',
      );
      messages++;
      final a = engine.interpretDetailed(sm, bare, appVersion: '2.0.0');
      final b = engine.interpretDetailed(sm, withPack, appVersion: '2.0.0');
      final sa = _sig(a), sb = _sig(b);
      if (sa == sb) {
        same++;
        continue;
      }
      changed++;
      final solverMade = (b.winnerId ?? '').startsWith('SOLVER-');
      if (a.result.outcome != InterpretOutcome.unknown) ruleMatchedChanged++;
      final ignoredWrongly =
          solverMade &&
          b.result.outcome == InterpretOutcome.ignored &&
          wantsFinancial;
      if (ignoredWrongly) badIgnore++;
      lines.add(
        '${ignoredWrongly ? "BAD IGNORE " : ""}${c['id']}  rules=${a.result.outcome.name}  solver=${b.winnerId}/${b.result.outcome.name}  expects=${wantsFinancial ? "financial" : (expectedFacts.isEmpty ? "nothing" : "info")}',
      );
    }
  }
  stdout.writeln(
    'messages: $messages   identical: $same   changed by the solver: $changed',
  );
  stdout.writeln(
    'rule-matched messages that changed: $ruleMatchedChanged   financial cases ignored by the solver: $badIgnore',
  );
  for (final l in lines) {
    stdout.writeln('  $l');
  }
  if (ruleMatchedChanged > 0 || badIgnore > 0) exit(1);
}

String _sig(EngineOutcome o) => jsonEncode({
  'o': o.result.outcome.name,
  'r': o.winnerId,
  'f': [for (final f in o.result.facts) f.toJson()],
});
