import 'dart:convert';

import 'gates.dart';
import 'scorer.dart';

const reportSchema = 'pandapay.sms.golden-report/1';

/// Builds the `report.json` map. No timestamp, so a rerun on the same inputs
/// gives the same bytes.
Map<String, Object?> reportJson(
  GoldenRun run, {
  String? profile,
  List<CheckResult>? gateResults,
  String? baselinePath,
  List<Regression>? regressions,
}) {
  return {
    'schema': reportSchema,
    'engine': run.engine,
    'stages': run.stages,
    'counts': {
      'cases': run.cases,
      'casesPassed': run.casesPassed,
      'scenarios': run.scenarios,
      'scenariosPassed': run.scenariosEvaluated ? run.scenariosPassed : null,
      'scenariosEvaluated': run.scenariosEvaluated,
      'messages': run.messages,
      'weight': run.weight,
    },
    'metrics': {for (final e in run.metrics.entries) e.key: e.value.toJson()},
    'byFamily': {for (final e in run.byFamily.entries) e.key: e.value.toJson()},
    'byBrand': {for (final e in run.byBrand.entries) e.key: e.value.toJson()},
    'failures': [for (final f in run.failures) f.toJson()],
    if (gateResults != null)
      'gates': {
        'profile': profile,
        'passed': !gateResults.any((r) => r.status == 'fail'),
        'results': [for (final r in gateResults) r.toJson()],
      },
    if (baselinePath != null)
      'baseline': {
        'path': baselinePath,
        'regressions': [for (final r in regressions ?? const <Regression>[]) r.toJson()],
      },
  };
}

String reportJsonString(Map<String, Object?> report) =>
    '${const JsonEncoder.withIndent('  ').convert(report)}\n';

String _fmt(String metricName, MetricResult m) {
  if (m.status != 'ok') return m.status;
  if (Metric.counts.contains(metricName)) return m.value!.toStringAsFixed(0);
  return '${(m.value! * 100).toStringAsFixed(2)}%';
}

String _n(MetricResult m) => m.status == 'ok' ? m.denominator.toStringAsFixed(m.denominator == m.denominator.roundToDouble() ? 0 : 1) : '';

/// Human-readable `report.md`.
String reportMarkdown(Map<String, Object?> report, GoldenRun run) {
  final b = StringBuffer();
  final counts = report['counts'] as Map;
  b.writeln('# SMS golden report');
  b.writeln();
  b.writeln('Engine: `${run.engine}`');
  b.writeln();
  b.writeln('Cases: ${counts['cases']} (${counts['casesPassed']} fully passed), '
      'scenarios: ${counts['scenarios']} (${run.scenariosEvaluated ? '${counts['scenariosPassed']} fully passed' : 'not evaluated, a stage is not available'}), '
      'messages: ${counts['messages']}, weight: ${counts['weight']}');
  b.writeln();
  b.writeln('Stages: ${run.stages.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
  b.writeln();
  final gates = report['gates'] as Map?;
  final byName = {
    if (gates != null)
      for (final r in (gates['results'] as List)) (r as Map)['metric'] as String: r,
  };
  b.writeln('## Metrics');
  b.writeln();
  b.writeln('| Metric | Value | n | Gate | Result |');
  b.writeln('| --- | --- | --- | --- | --- |');
  for (final name in Metric.all) {
    final m = run.metrics[name]!;
    final g = byName[name];
    b.writeln('| $name | ${_fmt(name, m)} | ${_n(m)} | ${g?['limit'] ?? ''} | ${g?['status'] ?? ''} |');
  }
  if (gates != null) {
    b.writeln();
    b.writeln('Gate profile `${gates['profile']}`: ${gates['passed'] == true ? 'PASS' : 'FAIL'}');
  }
  final baseline = report['baseline'] as Map?;
  if (baseline != null) {
    final regs = baseline['regressions'] as List;
    b.writeln();
    b.writeln('Baseline `${baseline['path']}`: ${regs.isEmpty ? 'no regressions' : '${regs.length} regression(s)'}');
    for (final r in regs) {
      b.writeln('- ${(r as Map)['metric']}: ${r['baseline']} -> ${r['current']}');
    }
  }
  void scope(String title, Map<String, ScopeSummary> scopes) {
    if (scopes.isEmpty) return;
    b.writeln();
    b.writeln('## $title');
    b.writeln();
    b.writeln('| Name | Cases | Weight | Capture recall | Event kind | Amount | Instrument | Ask rate |');
    b.writeln('| --- | --- | --- | --- | --- | --- | --- | --- |');
    final rows = scopes.entries.toList()..sort((a, c) => c.value.weight.compareTo(a.value.weight));
    for (final e in rows.take(25)) {
      final m = e.value.metrics;
      String f(String k) => m[k] == null ? '' : _fmt(k, m[k]!);
      b.writeln('| ${e.key} | ${e.value.cases} | ${e.value.weight.toStringAsFixed(0)} | '
          '${f(Metric.captureRecall)} | ${f(Metric.eventKind)} | ${f(Metric.amountRole)} | '
          '${f(Metric.instrument)} | ${f(Metric.askRate)} |');
    }
  }

  scope('By family', run.byFamily);
  scope('By brand', run.byBrand);
  if (run.failures.isNotEmpty) {
    b.writeln();
    b.writeln('## Failures (${run.failures.length})');
    b.writeln();
    for (final f in run.failures.take(80)) {
      b.writeln('- ${f.kind} `${f.id}`: ${f.reasons.take(3).join('; ')}');
    }
    if (run.failures.length > 80) b.writeln('- ... and ${run.failures.length - 80} more (see report.json)');
  }
  return b.toString();
}
