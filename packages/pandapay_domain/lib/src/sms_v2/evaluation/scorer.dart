import 'adapters.dart';
import 'matcher.dart';
import 'models.dart';

/// Metric names, as used in `report.json` and `gates.json`.
class Metric {
  static const captureRecall = 'captureRecall';
  static const ignorePrecision = 'ignorePrecision';
  static const eventKind = 'eventKind';
  static const amountRole = 'amountRole';
  static const instrument = 'instrument';
  static const doubleCounts = 'doubleCounts';
  static const pairsLinked = 'pairsLinked';
  static const category = 'category';
  static const askRate = 'askRate';
  static const scenarioTotals = 'scenarioTotals';

  // Reported, not gated.
  static const eventKindByAmount = 'eventKindByAmount';
  static const amountRoleByAmount = 'amountRoleByAmount';
  static const instrumentByAmount = 'instrumentByAmount';
  static const scenarioEvents = 'scenarioEvents';
  static const scenarioInstruments = 'scenarioInstruments';

  static const all = [
    captureRecall,
    ignorePrecision,
    eventKind,
    amountRole,
    instrument,
    doubleCounts,
    pairsLinked,
    category,
    askRate,
    scenarioTotals,
    eventKindByAmount,
    amountRoleByAmount,
    instrumentByAmount,
    scenarioEvents,
    scenarioInstruments,
  ];

  /// Metrics where a smaller value is better.
  static const lowerIsBetter = {askRate, doubleCounts};

  /// Metrics reported as a count rather than a ratio.
  static const counts = {doubleCounts};
}

class MetricResult {
  const MetricResult({
    required this.status,
    this.value,
    this.numerator = 0,
    this.denominator = 0,
  });

  /// `ok`, `no_data` (nothing to measure) or `not_available` (a stage is
  /// missing).
  final String status;
  final double? value;
  final double numerator;
  final double denominator;

  bool get ok => status == 'ok';

  Map<String, Object?> toJson() => {
    'status': status,
    'value': value,
    'numerator': numerator,
    'denominator': denominator,
  };

  static MetricResult fromJson(Map<String, dynamic> j) => MetricResult(
    status: j['status'] as String,
    value: (j['value'] as num?)?.toDouble(),
    numerator: (j['numerator'] as num?)?.toDouble() ?? 0,
    denominator: (j['denominator'] as num?)?.toDouble() ?? 0,
  );
}

class Acc {
  double num = 0;
  double den = 0;
}

class FailureNote {
  FailureNote(this.kind, this.id, this.reasons);
  final String kind; // case | scenario
  final String id;
  final List<String> reasons;
  Map<String, Object?> toJson() => {'kind': kind, 'id': id, 'reasons': reasons};
}

class ScopeSummary {
  ScopeSummary(this.cases, this.weight, this.metrics);
  final int cases;
  final double weight;
  final Map<String, MetricResult> metrics;
  Map<String, Object?> toJson() => {
    'cases': cases,
    'weight': weight,
    'metrics': {for (final e in metrics.entries) e.key: e.value.toJson()},
  };
}

class GoldenRun {
  GoldenRun({
    required this.engine,
    required this.stages,
    required this.cases,
    required this.scenarios,
    required this.messages,
    required this.weight,
    required this.metrics,
    required this.byFamily,
    required this.byBrand,
    required this.failures,
    required this.casesPassed,
    required this.scenariosPassed,
    required this.scenariosEvaluated,
  });

  final String engine;
  final Map<String, String> stages;
  final int cases;
  final int scenarios;
  final int messages;
  final double weight;
  final Map<String, MetricResult> metrics;
  final Map<String, ScopeSummary> byFamily;
  final Map<String, ScopeSummary> byBrand;
  final List<FailureNote> failures;
  final int casesPassed;
  final int scenariosPassed;

  /// True only when every stage was available, so a scenario "pass" means
  /// all of its expectations were really checked.
  final bool scenariosEvaluated;
}

const _caseMetrics = [
  Metric.captureRecall,
  Metric.ignorePrecision,
  Metric.eventKind,
  Metric.amountRole,
  Metric.instrument,
  Metric.askRate,
  Metric.eventKindByAmount,
  Metric.amountRoleByAmount,
  Metric.instrumentByAmount,
];

/// Runs every case and scenario of [bundle] through [adapters] and scores them.
///
/// Case metrics are weighted by `weight` (the template's real message count);
/// kind, amount and instrument are also reported weighted by rupee amount.
/// [ignorePaths] lists fact paths that are not compared (for example
/// `instrument.issuerSlug` for a baseline that cannot produce it).
Future<GoldenRun> runGolden(
  GoldenBundle bundle,
  GoldenAdapters adapters, {
  Set<String> ignorePaths = const {},
}) async {
  final scopes = <String, Map<String, Acc>>{'overall': {}};
  final scopeCases = <String, int>{};
  final scopeWeight = <String, double>{};
  final failures = <FailureNote>[];
  var casesPassed = 0;
  var scenariosPassed = 0;
  var messageCount = 0;
  var totalWeight = 0.0;

  void add(List<String> keys, String metric, double num, double den) {
    for (final k in keys) {
      final a = scopes.putIfAbsent(k, () => {}).putIfAbsent(metric, Acc.new);
      a.num += num;
      a.den += den;
    }
  }

  // ---------------------------------------------------------------- cases
  final interp = adapters.interpreter;
  if (interp != null) {
    for (final c in bundle.cases) {
      final keys = ['overall', 'family:${c.family}', 'brand:${c.brand}'];
      final w = c.weight;
      scopeCases.update('overall', (v) => v + 1, ifAbsent: () => 1);
      scopeCases.update(keys[1], (v) => v + 1, ifAbsent: () => 1);
      scopeCases.update(keys[2], (v) => v + 1, ifAbsent: () => 1);
      for (final k in keys) {
        scopeWeight.update(k, (v) => v + w, ifAbsent: () => w);
      }
      messageCount += c.messages.length;
      totalWeight += w;
      final reasons = <String>[];

      final facts = <Map<String, dynamic>>[];
      var unknown = false;
      for (final m in c.messages) {
        try {
          final r = await interp.interpret(m);
          unknown = unknown || r.unknown;
          facts.addAll(r.facts);
        } catch (e) {
          unknown = true;
          reasons.add('interpreter threw: $e');
        }
      }
      final ignored = !unknown && facts.every((f) => f['factType'] == 'info');

      if (c.financial) {
        add(keys, Metric.captureRecall, ignored ? 0 : w, w);
        add(keys, Metric.askRate, unknown ? w : 0, w);
      }
      if (ignored) {
        add(keys, Metric.ignorePrecision, c.ignore ? w : 0, w);
      }
      if (c.ignore && !ignored) reasons.add('expected ignored');
      if (c.unknown && !unknown) reasons.add('expected unknown (review)');
      if (!c.ignore && !c.unknown && ignored) {
        reasons.add('financial message was ignored');
      }
      if (!c.unknown && unknown) reasons.add('message became a review item');

      // Facts: score kind, amount and instrument separately.
      final real = [
        for (final f in facts)
          if (f['factType'] != 'info') f,
      ];
      final used = <int>{};
      final dimPass = <String, int>{};
      final dimTotal = <String, int>{};
      for (final exp in c.expectFacts) {
        final dims = splitDimensions(exp);
        int? best;
        var bestScore = -1;
        for (var i = 0; i < real.length; i++) {
          if (used.contains(i)) continue;
          if (exp['factType'] != null && real[i]['factType'] != exp['factType']) {
            continue;
          }
          var score = 0;
          for (final d in dims.values) {
            if (partialMatch(d, real[i], ignorePaths: ignorePaths)) score++;
          }
          if (score > bestScore) {
            bestScore = score;
            best = i;
          }
        }
        if (best != null) used.add(best);
        for (final e in dims.entries) {
          final ok =
              best != null &&
              partialMatch(e.value, real[best], ignorePaths: ignorePaths);
          if (e.key != 'other') {
            dimTotal.update(e.key, (v) => v + 1, ifAbsent: () => 1);
            if (ok) dimPass.update(e.key, (v) => v + 1, ifAbsent: () => 1);
          }
          if (!ok) {
            final why = best == null
                ? 'no ${exp['factType'] ?? ''} fact produced'
                : explainMismatch(
                    e.value,
                    real[best],
                    ignorePaths: ignorePaths,
                    path: '',
                  );
            reasons.add('${e.key}: $why');
          }
        }
      }
      final rupees = _rupees(c.expectFacts);
      for (final (dim, name, byAmount) in [
        ('kind', Metric.eventKind, Metric.eventKindByAmount),
        ('amount', Metric.amountRole, Metric.amountRoleByAmount),
        ('instrument', Metric.instrument, Metric.instrumentByAmount),
      ]) {
        final total = dimTotal[dim] ?? 0;
        if (total == 0) continue;
        final frac = (dimPass[dim] ?? 0) / total;
        add(keys, name, w * frac, w);
        if (rupees > 0) add(keys, byAmount, w * rupees * frac, w * rupees);
      }
      if (reasons.isEmpty) {
        casesPassed++;
      } else {
        failures.add(FailureNote('case', c.id, reasons));
      }
    }
  }

  // ------------------------------------------------------------ scenarios
  for (final s in bundle.scenarios) {
    final reasons = await _scoreScenario(
      s,
      adapters,
      ignorePaths,
      (m, n, d) => add(['overall'], m, n, d),
    );
    if (reasons != null) {
      if (reasons.isEmpty) {
        if (adapters.status.values.every((v) => v == 'available')) {
          scenariosPassed++;
        }
      } else {
        failures.add(FailureNote('scenario', s.id, reasons));
      }
    }
  }

  // ------------------------------------------------------------- results
  final unavailable = _unavailableMetrics(adapters);
  Map<String, MetricResult> build(Map<String, Acc> accs) {
    final out = <String, MetricResult>{};
    for (final name in Metric.all) {
      if (unavailable.contains(name)) {
        out[name] = const MetricResult(status: 'not_available');
        continue;
      }
      final a = accs[name];
      if (a == null || a.den == 0) {
        out[name] = const MetricResult(status: 'no_data');
        continue;
      }
      out[name] = MetricResult(
        status: 'ok',
        value: Metric.counts.contains(name) ? a.num : a.num / a.den,
        numerator: a.num,
        denominator: a.den,
      );
    }
    return out;
  }

  Map<String, ScopeSummary> scopeSet(String prefix) => {
    for (final k
        in (scopes.keys.where((k) => k.startsWith(prefix)).toList()..sort()))
      k.substring(
        prefix.length,
      ): ScopeSummary(scopeCases[k] ?? 0, scopeWeight[k] ?? 0, {
        for (final e in build(scopes[k]!).entries)
          if (_caseMetrics.contains(e.key)) e.key: e.value,
      }),
  };

  return GoldenRun(
    engine: adapters.label,
    stages: adapters.status,
    cases: interp == null ? 0 : bundle.cases.length,
    scenarios: bundle.scenarios.length,
    messages: messageCount,
    weight: totalWeight,
    metrics: build(scopes['overall'] ?? {}),
    byFamily: scopeSet('family:'),
    byBrand: scopeSet('brand:'),
    failures: failures,
    casesPassed: casesPassed,
    scenariosPassed: scenariosPassed,
    scenariosEvaluated: adapters.status.values.every((v) => v == 'available'),
  );
}

Set<String> _unavailableMetrics(GoldenAdapters a) {
  final out = <String>{};
  if (a.interpreter == null) out.addAll(_caseMetrics);
  final chain2 = a.interpreter != null && a.instruments != null;
  final chain3 = chain2 && a.linker != null;
  final chain4 = chain3 && a.projector != null;
  final chain5 = chain4 && a.categories != null;
  if (!chain2) out.add(Metric.scenarioInstruments);
  if (!chain3) out.addAll([Metric.pairsLinked, Metric.scenarioEvents]);
  if (!chain4) out.addAll([Metric.doubleCounts, Metric.scenarioTotals]);
  if (!chain5) out.add(Metric.category);
  return out;
}

double _rupees(List<Map<String, dynamic>> expectFacts) {
  var best = 0.0;
  for (final f in expectFacts) {
    for (final a in (f['amounts'] as List? ?? const [])) {
      final m = (a as Map)['minor'];
      final role = a['role'];
      if (m is num &&
          (role == 'posted' ||
              role == 'held' ||
              role == 'released' ||
              role == 'scheduled')) {
        if (m / 100 > best) best = m / 100;
      }
    }
  }
  return best;
}

/// Returns null when the scenario could not run at all (no interpreter),
/// otherwise the list of failure reasons (empty when it passed everything that
/// could be checked).
Future<List<String>?> _scoreScenario(
  GoldenScenario s,
  GoldenAdapters a,
  Set<String> ignorePaths,
  void Function(String metric, double num, double den) add,
) async {
  final interp = a.interpreter;
  if (interp == null) return null;
  final reasons = <String>[];
  var facts = <Map<String, dynamic>>[];
  for (final m in s.messages) {
    try {
      facts.addAll(
        (await interp.interpret(m)).facts.where((f) => f['factType'] != 'info'),
      );
    } catch (e) {
      reasons.add('interpreter threw: $e');
    }
  }
  final inst = a.instruments;
  if (inst == null) return reasons;

  late List<Map<String, dynamic>> instruments;
  try {
    final r = await inst.resolve(
      facts: facts,
      knownInstruments: s.knownInstruments,
    );
    instruments = r.instruments;
    facts = r.facts;
  } catch (e) {
    reasons.add('instrument stage threw: $e');
    add(Metric.scenarioInstruments, 0, 1);
    return reasons;
  }
  if (s.instruments.isNotEmpty) {
    final why = explainMismatch(
      s.instruments,
      instruments,
      ignorePaths: ignorePaths,
    );
    final countOk = instruments.length == s.instruments.length;
    final ok = why == null && countOk;
    add(Metric.scenarioInstruments, ok ? 1 : 0, 1);
    if (!ok) {
      reasons.add(
        'instruments: ${why ?? 'expected ${s.instruments.length}, got ${instruments.length}'}',
      );
    }
  }

  final linker = a.linker;
  if (linker == null) return reasons;
  late List<Map<String, dynamic>> events;
  try {
    events = await linker.link(facts: facts, instruments: instruments);
  } catch (e) {
    reasons.add('linker threw: $e');
    return reasons;
  }
  // Match expected events to actual ones by type and the multiset of leg roles.
  final matched = <int, int>{}; // expected index -> actual index
  final usedActual = <int>{};
  for (var i = 0; i < s.events.length; i++) {
    final exp = s.events[i];
    final expRoles = [
      for (final r in (exp['legRoles'] as List? ?? const [])) r.toString(),
    ]..sort();
    for (var j = 0; j < events.length; j++) {
      if (usedActual.contains(j)) continue;
      if (events[j]['type'] != exp['type']) continue;
      final roles = [
        for (final l in (events[j]['legs'] as List? ?? const []))
          (l as Map)['role'].toString(),
      ]..sort();
      if (roles.length == expRoles.length && _listEq(roles, expRoles)) {
        matched[i] = j;
        usedActual.add(j);
        break;
      }
    }
    if (expRoles.length >= 2) {
      add(Metric.pairsLinked, matched.containsKey(i) ? 1 : 0, 1);
    }
    if (!matched.containsKey(i)) {
      reasons.add('event $i (${exp['type']} ${exp['legRoles']}) not produced');
    }
  }
  if (s.events.isNotEmpty) {
    final exact =
        matched.length == s.events.length && events.length == s.events.length;
    add(Metric.scenarioEvents, exact ? 1 : 0, 1);
    if (events.length != s.events.length) {
      reasons.add('expected ${s.events.length} events, got ${events.length}');
    }
  }

  final projector = a.projector;
  if (projector == null) return reasons;
  late List<Map<String, dynamic>> entries;
  try {
    entries = await projector.project(
      events: events,
      facts: facts,
      instruments: instruments,
    );
    final cat = a.categories;
    if (cat != null && s.categories.isNotEmpty) {
      entries = await cat.categorize(entries: entries);
    }
  } catch (e) {
    reasons.add('projector threw: $e');
    return reasons;
  }
  final totalsExp = s.totals;
  if (totalsExp != null) {
    DateTime? when(Object? v) =>
        v == null ? null : DateTime.parse(v.toString()).toUtc();
    final t = await projector.totals(
      entries: entries,
      from: when(totalsExp['from']),
      to: when(totalsExp['to']),
    );
    final actual = <String, num>{
      'spendMinor': t.spendMinor,
      'incomeMinor': t.incomeMinor,
      'investmentMinor': t.investmentMinor,
      'transactionCount': t.transactionCount,
    };
    var ok = true;
    var doubleCount = false;
    for (final k in actual.keys) {
      if (!totalsExp.containsKey(k)) continue;
      final want = totalsExp[k] as num;
      if (actual[k] != want) {
        ok = false;
        reasons.add('totals.$k: expected $want, got ${actual[k]}');
        if (actual[k]! > want) doubleCount = true;
      }
    }
    final byCat = totalsExp['byCategory'];
    if (byCat is Map && a.categories != null) {
      for (final e in byCat.entries) {
        final got = t.byCategory[e.key] ?? 0;
        if (got != e.value) {
          ok = false;
          reasons.add(
            'totals.byCategory.${e.key}: expected ${e.value}, got $got',
          );
        }
      }
    }
    add(Metric.scenarioTotals, ok ? 1 : 0, 1);
    add(Metric.doubleCounts, doubleCount ? 1 : 0, 1);
  }

  if (a.categories != null) {
    for (final c in s.categories) {
      final idx = (c['eventIndex'] as num).toInt();
      final actualEvent = matched[idx];
      var ok = false;
      if (actualEvent != null) {
        final id = events[actualEvent]['eventId'];
        ok = entries.any(
          (e) => e['eventId'] == id && e['category'] == c['category'],
        );
      }
      add(Metric.category, ok ? 1 : 0, 1);
      if (!ok) reasons.add('category of event $idx: expected ${c['category']}');
    }
  }
  return reasons;
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
