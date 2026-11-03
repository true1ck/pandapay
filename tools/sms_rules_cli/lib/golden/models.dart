import 'dart:convert';
import 'dart:io';
import 'package:pandapay_domain/src/sms_v2/evaluation/models.dart';
export 'package:pandapay_domain/src/sms_v2/evaluation/models.dart';

/// Loads `cases/**/*.json` and `scenarios/*.json` below [goldenDir].
/// A case file holds one case object or a list of them.
GoldenBundle loadGoldenBundle(String goldenDir) {
  final cases = <GoldenCase>[];
  final casesDir = Directory('$goldenDir/cases');
  if (casesDir.existsSync()) {
    final files =
        casesDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final j = jsonDecode(f.readAsStringSync());
      for (final o in (j is List ? j : [j])) {
        cases.add(
          GoldenCase.fromJson((o as Map).cast<String, dynamic>(), path: f.path),
        );
      }
    }
  }
  final scenarios = <GoldenScenario>[];
  final scenDir = Directory('$goldenDir/scenarios');
  if (scenDir.existsSync()) {
    final files =
        scenDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final j = jsonDecode(f.readAsStringSync());
      for (final o in (j is List ? j : [j])) {
        scenarios.add(
          GoldenScenario.fromJson(
            (o as Map).cast<String, dynamic>(),
            path: f.path,
          ),
        );
      }
    }
  }
  final seen = <String>{};
  for (final c in cases) {
    if (!seen.add(c.id)) throw FormatException('duplicate case id ${c.id}');
  }
  return GoldenBundle(cases, scenarios);
}
