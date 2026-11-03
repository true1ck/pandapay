import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../golden/adapters.dart';
import '../golden/gates.dart';
import '../golden/models.dart';
import '../golden/report.dart';
import '../golden/scorer.dart';

/// `golden`: score an implementation against the golden cases and scenarios.
///
/// Exit code 0 when the gates (if any) pass and nothing is below `--baseline`;
/// 1 otherwise. A stage that is not available is skipped, not failed, unless
/// `--require-stages` is given.
class GoldenCommand extends Command<int> {
  GoldenCommand() {
    argParser
      ..addOption('bundle', help: 'Rule bundle the engine runs (app/assets/sms_rules/baseline_bundle.json). Not used until the WP-01 engine is wired in.')
      ..addOption('golden-dir', defaultsTo: '../sms_golden', help: 'Folder holding cases/ and scenarios/.')
      ..addOption('gates', help: 'gates.json. Default: <golden-dir>/gates.json.')
      ..addOption('profile', defaultsTo: 'm1', help: 'Gate profile: m1, release, or none.')
      ..addOption('baseline', help: 'report.json that no metric may fall below.')
      ..addOption('out', help: 'Folder for report.json and report.md. Default: <golden-dir>/reports/run.')
      ..addOption('interpretations', help: 'Score precomputed interpretations (output of the baseline tests) instead of the engine.')
      ..addOption('ignore-fields', help: 'Comma-separated fact paths not compared, e.g. instrument.issuerSlug.')
      ..addFlag('require-stages', negatable: false, help: 'Fail when a stage is not available.');
  }

  @override
  String get name => 'golden';

  @override
  String get description =>
      'Run the golden cases and scenarios; write report.json and report.md; '
      'exit non-zero below the gates or the baseline.';

  @override
  Future<int> run() async {
    final r = argResults!;
    final goldenDir = r['golden-dir'] as String;
    final bundle = loadGoldenBundle(goldenDir);

    GoldenAdapters adapters;
    final interpretations = r['interpretations'] as String?;
    if (interpretations != null) {
      final pre = PrecomputedInterpreter.fromFile(interpretations, bundle);
      adapters = GoldenAdapters(interpreter: pre, label: pre.label);
    } else {
      adapters = loadDefaultAdapters(bundlePath: r['bundle'] as String?);
    }

    final ignore = {
      for (final p in (r['ignore-fields'] as String? ?? '').split(','))
        if (p.trim().isNotEmpty) p.trim(),
    };
    final run = await runGolden(bundle, adapters, ignorePaths: ignore);

    final profile = r['profile'] as String;
    List<CheckResult>? checks;
    if (profile != 'none') {
      final gates = loadGates(r['gates'] as String? ?? '$goldenDir/gates.json', profile);
      checks = checkGates(run.metrics, gates);
    }
    final baselinePath = r['baseline'] as String?;
    List<Regression>? regressions;
    if (baselinePath != null) {
      final base = jsonDecode(File(baselinePath).readAsStringSync()) as Map<String, dynamic>;
      regressions = compareToBaseline(run.metrics, base);
    }

    final report = reportJson(
      run,
      profile: profile == 'none' ? null : profile,
      gateResults: checks,
      baselinePath: baselinePath,
      regressions: regressions,
    );
    final outDir = Directory(r['out'] as String? ?? '$goldenDir/reports/run')..createSync(recursive: true);
    File('${outDir.path}/report.json').writeAsStringSync(reportJsonString(report));
    File('${outDir.path}/report.md').writeAsStringSync(reportMarkdown(report, run));

    stdout.writeln(
      'golden: ${bundle.cases.length} cases, ${bundle.scenarios.length} scenarios, '
      'engine=${run.engine} -> ${outDir.path}',
    );
    var failed = false;
    for (final c in checks ?? const <CheckResult>[]) {
      if (c.status == 'fail') {
        failed = true;
        stdout.writeln('  GATE FAIL ${c.metric}: ${c.value} (need ${c.limit})');
      }
    }
    for (final g in regressions ?? const <Regression>[]) {
      failed = true;
      stdout.writeln('  BELOW BASELINE ${g.metric}: ${g.baseline} -> ${g.current}');
    }
    if (r['require-stages'] as bool) {
      for (final e in run.stages.entries) {
        if (e.value != 'available') {
          failed = true;
          stdout.writeln('  STAGE NOT AVAILABLE ${e.key}');
        }
      }
    } else {
      final na = run.stages.entries.where((e) => e.value != 'available').map((e) => e.key);
      if (na.isNotEmpty) stdout.writeln('  not_available: ${na.join(', ')}');
    }
    stdout.writeln(failed ? 'golden: FAILED' : 'golden: ok');
    return failed ? 1 : 0;
  }
}
