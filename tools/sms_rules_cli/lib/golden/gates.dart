import 'dart:convert';
import 'dart:io';

import 'scorer.dart';

/// One limit from `gates.json`: `{"min": 0.99}`, `{"max": 0.05}` or `{"exact": 0}`.
class Gate {
  const Gate({this.min, this.max, this.exact});

  factory Gate.fromJson(Map<String, dynamic> j) => Gate(
    min: (j['min'] as num?)?.toDouble(),
    max: (j['max'] as num?)?.toDouble(),
    exact: (j['exact'] as num?)?.toDouble(),
  );

  final double? min;
  final double? max;
  final double? exact;

  bool passes(double v) {
    const eps = 1e-9;
    if (min != null && v < min! - eps) return false;
    if (max != null && v > max! + eps) return false;
    if (exact != null && (v - exact!).abs() > eps) return false;
    return true;
  }

  String describe() => min != null
      ? '>= $min'
      : max != null
      ? '<= $max'
      : '== $exact';
}

class CheckResult {
  CheckResult(this.metric, this.status, this.value, this.limit);

  final String metric;

  /// `pass`, `fail` or `skipped` (metric not available, so not judged).
  final String status;
  final double? value;
  final String limit;

  Map<String, Object?> toJson() => {
    'metric': metric,
    'status': status,
    'value': value,
    'limit': limit,
  };
}

/// The gates of one profile (`m1` or `release`) in `gates.json`.
Map<String, Gate> loadGates(String path, String profile) {
  final j = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final p = j[profile];
  if (p is! Map) {
    throw FormatException('gates.json has no profile "$profile" (has ${j.keys.where((k) => !k.startsWith('_')).toList()})');
  }
  return {
    for (final e in p.entries)
      e.key as String: Gate.fromJson((e.value as Map).cast<String, dynamic>()),
  };
}

/// Judges overall metrics against [gates]. A metric that is `not_available` or
/// `no_data` is `skipped`, not failed.
List<CheckResult> checkGates(
  Map<String, MetricResult> metrics,
  Map<String, Gate> gates,
) {
  return [
    for (final e in gates.entries)
      () {
        final m = metrics[e.key];
        if (m == null || !m.ok) {
          return CheckResult(e.key, 'skipped', null, e.value.describe());
        }
        return CheckResult(
          e.key,
          e.value.passes(m.value!) ? 'pass' : 'fail',
          m.value,
          e.value.describe(),
        );
      }(),
  ];
}

class Regression {
  Regression(this.metric, this.baseline, this.current);
  final String metric;
  final double baseline;
  final double current;
  Map<String, Object?> toJson() => {
    'metric': metric,
    'baseline': baseline,
    'current': current,
  };
}

/// Metrics in [current] that are worse than in the baseline report. Metrics
/// that are not `ok` on either side are not compared, so a stage that was not
/// available yet never counts as a regression.
List<Regression> compareToBaseline(
  Map<String, MetricResult> current,
  Map<String, dynamic> baselineReport,
) {
  const eps = 1e-9;
  final base = (baselineReport['metrics'] as Map?)?.cast<String, dynamic>() ?? const {};
  final out = <Regression>[];
  for (final e in current.entries) {
    final b = base[e.key];
    if (b == null || !e.value.ok) continue;
    final bm = MetricResult.fromJson((b as Map).cast<String, dynamic>());
    if (!bm.ok) continue;
    final worse = Metric.lowerIsBetter.contains(e.key)
        ? e.value.value! > bm.value! + eps
        : e.value.value! < bm.value! - eps;
    if (worse) out.add(Regression(e.key, bm.value!, e.value.value!));
  }
  return out;
}
