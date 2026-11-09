/// Steady-state cost of the evidence solver per message (after warm-up).
///   dart run tool/solver_bench.dart PACK CORPUS.jsonl
/// JIT numbers; a release (AOT) build is typically several times faster.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2_solver.dart';

void main(List<String> args) {
  final pack = SolverPack.fromJson(
    jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>,
  );
  final solver = EvidenceSolver(pack);
  final bodies = File(args[1])
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .map((l) => (jsonDecode(l) as Map<String, dynamic>)['body'] as String)
      .toList();
  for (var i = 0; i < 20; i++) {
    for (final b in bodies) {
      solver.solve(b);
    }
  }
  const passes = 100;
  final sw = Stopwatch()..start();
  for (var i = 0; i < passes; i++) {
    for (final b in bodies) {
      solver.solve(b);
    }
  }
  sw.stop();
  final per = sw.elapsedMicroseconds / (passes * bodies.length);
  stdout.writeln(
    '${per.toStringAsFixed(0)} us per message (${bodies.length} messages x $passes passes)',
  );
  stdout.writeln(
    '=> 20,000 messages in ${(per * 20000 / 1e6).toStringAsFixed(1)} s on this machine (JIT)',
  );
}
