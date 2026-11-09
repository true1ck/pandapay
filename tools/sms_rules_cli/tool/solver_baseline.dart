/// Phase 0 gap baseline: runs a labelled synthetic corpus through the CURRENT
/// rule engine (tier 1) and reports, per expected reading, what the rules did.
///
///   dart run tool/solver_baseline.dart BUNDLE CORPUS.jsonl [--verbose]
///
/// Reads only. Changes nothing. Corpus rows: `{id, sender, body, expect}` as in
/// `tools/sms_golden/solver/held_out.jsonl` (synthetic, no real messages).
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';

/// Outcome buckets for tier 1, the thing the solver has to improve on.
String bucketOf(EngineOutcome o) {
  switch (o.result.outcome) {
    case InterpretOutcome.ignored:
      return 'ignored';
    case InterpretOutcome.matched:
      return 'matched';
    case InterpretOutcome.unknown:
      return 'unknown:${o.reason ?? '?'}';
  }
}

String summarise(EngineOutcome o) {
  if (o.result.facts.isEmpty) return '-';
  final f = o.result.facts.first;
  final money = f.amounts.isEmpty ? '' : ' ${f.amounts.first.minor}';
  final dir = f is MovementFact ? ' ${f.direction.wire}' : '';
  return '${f.factType.wire}$dir$money';
}

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: solver_baseline BUNDLE CORPUS.jsonl [--verbose]');
    exit(64);
  }
  final verbose = args.contains('--verbose');
  final bundle = RuleBundle.fromJson(
    jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>,
  );
  final engine = RuleEngine();
  final rows = File(args[1])
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .map((l) => jsonDecode(l) as Map<String, dynamic>)
      .toList();

  final table = <String, Map<String, int>>{};
  final misses = <String>[];
  final wrongKind = <String>[];
  var n = 0;
  for (final row in rows) {
    n++;
    final expect = row['expect'] as Map<String, dynamic>;
    final read = expect['read'] as String;
    final msg = SmsMessage(
      sender: row['sender'] as String,
      body: row['body'] as String,
      observedAt: DateTime.utc(2026, 11, 9),
      sourceKey: row['id'] as String,
    );
    final out = engine.interpretDetailed(msg, bundle, appVersion: '2.0.0');
    final bucket = bucketOf(out);
    table
        .putIfAbsent(read, () => {})
        .update(bucket, (v) => v + 1, ifAbsent: () => 1);
    final line =
        '${row['id']}  ${read.padRight(12)} ${bucket.padRight(24)} ${out.winnerId ?? ''} ${summarise(out)}';
    final financial = !{
      'promo',
      'info',
      'balance',
      'failed',
      'pending',
      'scheduled',
      'bill_due',
    }.contains(read);
    if (financial && bucket.startsWith('unknown')) misses.add(line);
    if (!financial && bucket == 'matched') wrongKind.add(line);
    if (verbose) stdout.writeln(line);
  }

  stdout.writeln('\n== tier 1 outcome by expected reading (n=$n) ==');
  for (final e
      in (table.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))) {
    final total = e.value.values.fold<int>(0, (a, b) => a + b);
    final parts =
        (e.value.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .map((x) => '${x.key}=${x.value}')
            .join('  ');
    stdout.writeln('${e.key.padRight(14)} $total  $parts');
  }
  stdout.writeln(
    '\n== money messages tier 1 left unknown (${misses.length}) ==',
  );
  misses.forEach(stdout.writeln);
  stdout.writeln(
    '\n== non-money messages tier 1 turned into a fact (${wrongKind.length}) ==',
  );
  wrongKind.forEach(stdout.writeln);
}
