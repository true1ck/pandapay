import 'dart:convert';
import 'dart:io';

import 'package:sms_rules_cli/golden/adapters.dart';
import 'package:sms_rules_cli/golden/gates.dart';
import 'package:sms_rules_cli/golden/matcher.dart';
import 'package:sms_rules_cli/golden/models.dart';
import 'package:sms_rules_cli/golden/scorer.dart';
import 'package:test/test.dart';

GoldenMessage msg(String body, {String sender = 'VM-HDFCBK-S'}) =>
    GoldenMessage(sender: sender, body: body, observedAt: DateTime.utc(2026, 11, 1));

GoldenCase mkCase(
  String id,
  String body, {
  double weight = 1,
  List<Map<String, dynamic>> facts = const [],
  bool ignore = false,
  bool unknown = false,
  String family = 'f',
}) => GoldenCase(
  id: id,
  templateHash: id,
  weight: weight,
  source: 'synthetic',
  messages: [msg(body)],
  expectFacts: facts,
  ignore: ignore,
  unknown: unknown,
  family: family,
);

Map<String, dynamic> debit(int minor, {String? mask, String purpose = 'purchase'}) => {
  'factType': 'movement',
  'attrs': {'direction': 'debit', 'purpose': purpose},
  'amounts': [
    {'role': 'posted', 'minor': minor},
  ],
  if (mask != null) 'instrument': {'kind': 'bank_account', 'maskDigits': mask},
};

class FakeInterpreter implements InterpreterStage {
  FakeInterpreter(this.byBody);
  final Map<String, InterpretedMessage> byBody;
  @override
  Future<InterpretedMessage> interpret(GoldenMessage m) async =>
      byBody[m.body] ?? const InterpretedMessage();
}

const info = {'factType': 'info', 'attrs': {'category': 'otp'}};

void main() {
  group('partial matcher', () {
    test('listed fields must match, unlisted are ignored', () {
      final actual = {'a': 1, 'b': 'x', 'c': {'d': 2, 'e': 3}};
      expect(partialMatch({'a': 1}, actual), isTrue);
      expect(partialMatch({'a': 1, 'c': {'d': 2}}, actual), isTrue);
      expect(partialMatch({'a': 2}, actual), isFalse);
      expect(partialMatch({'c': {'d': 9}}, actual), isFalse);
      expect(partialMatch({'z': 1}, actual), isFalse);
    });

    test('numbers compare by value, null means absent', () {
      expect(partialMatch({'a': 1}, {'a': 1.0}), isTrue);
      expect(partialMatch({'a': null}, {'b': 1}), isTrue);
      expect(partialMatch({'a': null}, {'a': 1}), isFalse);
    });

    test('lists: every expected element needs its own matching element', () {
      final actual = {
        'amounts': [
          {'role': 'posted', 'minor': 100},
          {'role': 'available_balance', 'minor': 900},
        ],
      };
      expect(partialMatch({'amounts': [{'role': 'posted', 'minor': 100}]}, actual), isTrue);
      expect(
        partialMatch({'amounts': [{'role': 'available_balance', 'minor': 900}, {'role': 'posted'}]}, actual),
        isTrue,
      );
      expect(partialMatch({'amounts': [{'role': 'posted'}, {'role': 'posted'}]}, actual), isFalse);
      expect(partialMatch({'amounts': [{'role': 'held'}]}, actual), isFalse);
    });

    test('ignorePaths skips a field', () {
      final actual = {'instrument': {'kind': 'bank_account', 'issuerSlug': null}};
      final expected = {'instrument': {'kind': 'bank_account', 'issuerSlug': 'hdfc'}};
      expect(partialMatch(expected, actual), isFalse);
      expect(partialMatch(expected, actual, ignorePaths: {'instrument.issuerSlug'}), isTrue);
      expect(explainMismatch(expected, actual), contains('instrument.issuerSlug'));
    });

    test('splitDimensions groups kind, amount, instrument and other', () {
      final d = splitDimensions({
        'factType': 'movement',
        'attrs': {'direction': 'debit'},
        'amounts': [],
        'instrument': {'kind': 'wallet'},
        'counterparty': {'kind': 'own'},
      });
      expect(d.keys.toSet(), {'kind', 'amount', 'instrument', 'other'});
      expect(d['kind']!.keys.toSet(), {'factType', 'attrs'});
    });
  });

  group('metric maths (weights and rupee weights)', () {
    late GoldenBundle bundle;
    late GoldenAdapters adapters;

    setUp(() {
      bundle = GoldenBundle([
        // A: perfect
        mkCase('A', 'a', weight: 3, facts: [debit(10000, mask: '1234')]),
        // B: right kind and instrument, wrong amount
        mkCase('B', 'b', weight: 1, facts: [debit(50000, mask: '1234')]),
        // C: not financial, correctly ignored
        mkCase('C', 'c', ignore: true),
        // D: financial but ignored (a miss)
        mkCase('D', 'd', weight: 2, facts: [debit(20000, mask: '1234')]),
        // E: financial, became a review item
        mkCase('E', 'e'),
      ], []);
      adapters = GoldenAdapters(
        label: 'fake',
        interpreter: FakeInterpreter({
          'a': InterpretedMessage(facts: [debit(10000, mask: '1234')]),
          'b': InterpretedMessage(facts: [debit(60000, mask: '1234')]),
          'c': const InterpretedMessage(facts: [info]),
          'd': const InterpretedMessage(facts: [info]),
          'e': const InterpretedMessage(unknown: true),
        }),
      );
    });

    test('capture recall, ignore precision and ask rate are weighted', () async {
      final run = await runGolden(bundle, adapters);
      // financial: A3 B1 D2 E1 = 7; captured (not ignored): A B E = 5
      expect(run.metrics[Metric.captureRecall]!.value, closeTo(5 / 7, 1e-12));
      // ignored: C (correct, 1) and D (wrong, 2)
      expect(run.metrics[Metric.ignorePrecision]!.value, closeTo(1 / 3, 1e-12));
      // unknown: E (1) over financial weight 7
      expect(run.metrics[Metric.askRate]!.value, closeTo(1 / 7, 1e-12));
    });

    test('kind, amount and instrument are scored per dimension', () async {
      final run = await runGolden(bundle, adapters);
      // A(3) and B(1) pass kind, D(2) fails: 4/6
      expect(run.metrics[Metric.eventKind]!.value, closeTo(4 / 6, 1e-12));
      // only A passes amount: 3/6
      expect(run.metrics[Metric.amountRole]!.value, closeTo(3 / 6, 1e-12));
      expect(run.metrics[Metric.instrument]!.value, closeTo(4 / 6, 1e-12));
    });

    test('rupee weighting counts a wrong 500 more than a wrong 100', () async {
      final run = await runGolden(bundle, adapters);
      // rupees: A 100 x w3 = 300 (pass), B 500 x 1 = 500 (fail), D 200 x 2 = 400 (fail)
      expect(run.metrics[Metric.amountRoleByAmount]!.value, closeTo(300 / 1200, 1e-12));
      expect(run.metrics[Metric.eventKindByAmount]!.value, closeTo(800 / 1200, 1e-12));
    });

    test('per family and per brand slices exist', () async {
      final run = await runGolden(bundle, adapters);
      expect(run.byFamily.keys, ['f']);
      expect(run.byBrand.keys, ['HDFCBK']);
      expect(run.byFamily['f']!.cases, 5);
      expect(run.byFamily['f']!.weight, 8);
    });

    test('failures name the reason', () async {
      final run = await runGolden(bundle, adapters);
      final ids = run.failures.map((f) => f.id).toSet();
      expect(ids, {'B', 'D', 'E'});
      expect(run.casesPassed, 2);
    });

    test('a thrown interpreter counts as a review item, not a crash', () async {
      final run = await runGolden(
        GoldenBundle([mkCase('X', 'x', facts: [debit(100)])], []),
        GoldenAdapters(interpreter: _Throwing()),
      );
      expect(run.metrics[Metric.askRate]!.value, 1);
    });
  });

  group('stages that are not available', () {
    test('no interpreter: every case metric is not_available, nothing fails', () async {
      final run = await runGolden(
        GoldenBundle([mkCase('A', 'a', facts: [debit(100)])], []),
        const GoldenAdapters(),
      );
      for (final m in run.metrics.values) {
        expect(m.status, 'not_available');
      }
      expect(run.failures, isEmpty);
      final gates = {'captureRecall': const Gate(min: 0.99), 'doubleCounts': const Gate(max: 0)};
      final checks = checkGates(run.metrics, gates);
      expect(checks.every((c) => c.status == 'skipped'), isTrue);
    });

    test('scenario metrics stay not_available until their stage exists', () async {
      final bundle = GoldenBundle([mkCase('A', 'a')], []);
      final run = await runGolden(bundle, GoldenAdapters(interpreter: FakeInterpreter({})));
      expect(run.metrics[Metric.captureRecall]!.status, 'ok');
      expect(run.metrics[Metric.pairsLinked]!.status, 'not_available');
      expect(run.metrics[Metric.doubleCounts]!.status, 'not_available');
      expect(run.metrics[Metric.category]!.status, 'not_available');
    });
  });

  group('scenarios through fake stages', () {
    GoldenScenario scenario({int expectedCount = 1, int expectedSpend = 25000}) => GoldenScenario(
      id: 's1',
      description: '',
      knownInstruments: const [],
      messages: [msg('bank'), msg('app')],
      events: const [
        {'type': 'purchase', 'legRoles': ['debit_leg', 'duplicate_notice']},
      ],
      instruments: const [
        {'kind': 'bank_account', 'maskDigits': '1234'},
      ],
      totals: {
        'spendMinor': expectedSpend,
        'incomeMinor': 0,
        'investmentMinor': 0,
        'transactionCount': expectedCount,
      },
      categories: const [
        {'eventIndex': 0, 'category': 'food_dining'},
      ],
    );

    GoldenAdapters adapters({required bool linkDuplicates}) => GoldenAdapters(
      interpreter: FakeInterpreter({
        'bank': InterpretedMessage(facts: [
          {...debit(25000, mask: '1234'), 'factId': 'f1'},
        ]),
        'app': InterpretedMessage(facts: [
          {...debit(25000, mask: '1234'), 'factId': 'f2'},
        ]),
      }),
      instruments: _FakeInstruments(),
      linker: _FakeLinker(linkDuplicates),
      projector: _FakeProjector(),
      categories: _FakeCategories(),
    );

    test('a correct run scores 100% on every scenario metric', () async {
      final run = await runGolden(GoldenBundle([], [scenario()]), adapters(linkDuplicates: true));
      expect(run.metrics[Metric.pairsLinked]!.value, 1);
      expect(run.metrics[Metric.scenarioEvents]!.value, 1);
      expect(run.metrics[Metric.scenarioInstruments]!.value, 1);
      expect(run.metrics[Metric.scenarioTotals]!.value, 1);
      expect(run.metrics[Metric.doubleCounts]!.value, 0);
      expect(run.metrics[Metric.category]!.value, 1);
      expect(run.failures, isEmpty);
    });

    test('not linking the duplicate notice is a double count', () async {
      final run = await runGolden(GoldenBundle([], [scenario()]), adapters(linkDuplicates: false));
      expect(run.metrics[Metric.pairsLinked]!.value, 0);
      expect(run.metrics[Metric.doubleCounts]!.value, 1);
      expect(run.metrics[Metric.scenarioTotals]!.value, 0);
      expect(run.failures.single.reasons.join(' '), contains('transactionCount'));
    });
  });

  group('gates and baseline', () {
    test('gates.json has the m1 and release profiles from Test and release', () {
      final m1 = loadGates('../sms_golden/gates.json', 'm1');
      final rel = loadGates('../sms_golden/gates.json', 'release');
      expect(m1[Metric.captureRecall]!.min, 0.99);
      expect(rel[Metric.captureRecall]!.min, 0.995);
      expect(m1[Metric.ignorePrecision]!.min, 0.995);
      expect(rel[Metric.ignorePrecision]!.min, 0.999);
      expect(m1[Metric.eventKind]!.min, 0.97);
      expect(rel[Metric.eventKind]!.min, 0.99);
      expect(m1[Metric.amountRole]!.min, 0.99);
      expect(rel[Metric.amountRole]!.min, 0.995);
      expect(m1[Metric.instrument]!.min, 0.98);
      expect(rel[Metric.instrument]!.min, 0.99);
      expect(m1[Metric.doubleCounts]!.max, 0);
      expect(rel[Metric.doubleCounts]!.max, 0);
      expect(m1[Metric.pairsLinked]!.min, 0.95);
      expect(rel[Metric.pairsLinked]!.min, 0.98);
      expect(m1[Metric.category]!.min, 0.90);
      expect(rel[Metric.category]!.min, 0.95);
      expect(m1[Metric.askRate]!.max, 0.05);
      expect(rel[Metric.askRate]!.max, 0.02);
      expect(m1[Metric.scenarioTotals]!.min, 1.0);
      expect(rel[Metric.scenarioTotals]!.min, 1.0);
      expect(m1.length, 10);
      expect(rel.length, 10);
    });

    test('a metric below its gate fails, above passes', () {
      const ok = MetricResult(status: 'ok', value: 0.98, numerator: 98, denominator: 100);
      final checks = checkGates(
        {Metric.captureRecall: ok, Metric.askRate: ok},
        {Metric.captureRecall: const Gate(min: 0.99), Metric.askRate: const Gate(max: 0.05)},
      );
      expect(checks.firstWhere((c) => c.metric == Metric.captureRecall).status, 'fail');
      expect(checks.firstWhere((c) => c.metric == Metric.askRate).status, 'fail');
      expect(const Gate(min: 0.98).passes(0.98), isTrue);
    });

    test('baseline: lower value fails, lower-is-better metrics flip, n/a is skipped', () {
      MetricResult r(double v) => MetricResult(status: 'ok', value: v, denominator: 1);
      final current = {
        Metric.captureRecall: r(0.90),
        Metric.eventKind: r(0.95),
        Metric.askRate: r(0.10),
        Metric.doubleCounts: r(0),
        Metric.category: const MetricResult(status: 'not_available'),
      };
      final baseline = {
        'metrics': {
          Metric.captureRecall: r(0.95).toJson(),
          Metric.eventKind: r(0.95).toJson(),
          Metric.askRate: r(0.05).toJson(),
          Metric.doubleCounts: r(1).toJson(),
          Metric.category: r(0.5).toJson(),
        },
      };
      final regs = compareToBaseline(current, baseline);
      expect(regs.map((g) => g.metric).toSet(), {Metric.captureRecall, Metric.askRate});
    });
  });

  group('seed data', () {
    final bundle = loadGoldenBundle('../sms_golden');

    test('the 35 probes, the family corpus and the local cases are converted', () {
      int count(String prefix) => bundle.cases.where((c) => c.id.startsWith(prefix)).length;
      expect(count('probe:'), 35);
      expect(count('corpus:'), 23);
      expect(count('local:'), 24);
    });

    test('there are at least 12 scenarios, including the required ones', () {
      expect(bundle.scenarios.length, greaterThanOrEqualTo(12));
      final ids = bundle.scenarios.map((s) => s.id).toSet();
      for (final id in [
        'card_bill_pair',
        'card_bill_via_cheq_no_receipt',
        'amazon_pay_topup_counts_as_spend',
        'ipo_block_then_release',
        'ipo_block_then_allotment',
        'wallet_topup_then_wallet_spend',
        'refund_after_purchase',
        'mandate_then_charge',
        'self_transfer',
        'duplicate_notice_bank_and_upi_app',
        'salary_credit',
        'dividend_credit',
        'limit_enhancement',
        'points_earned_on_card_spend',
        'cheque_debit',
      ]) {
        expect(ids, contains(id));
      }
    });

    test('every case file is named after its template hash and brand folder', () {
      for (final c in bundle.cases) {
        final p = c.path!;
        expect(p, contains('/cases/${c.brand}/'));
        expect(File(p).uri.pathSegments.last, startsWith(c.templateHash));
        expect(c.source, 'synthetic');
        expect(c.expectFacts.isNotEmpty || c.ignore || c.unknown, isTrue, reason: c.id);
      }
    });

    test('an oracle that returns the expectations scores 100% on every case metric', () async {
      final oracle = _Oracle(bundle);
      final run = await runGolden(bundle, GoldenAdapters(interpreter: oracle, label: 'oracle'));
      for (final name in [
        Metric.captureRecall,
        Metric.ignorePrecision,
        Metric.eventKind,
        Metric.amountRole,
        Metric.instrument,
        Metric.eventKindByAmount,
        Metric.amountRoleByAmount,
        Metric.instrumentByAmount,
      ]) {
        expect(run.metrics[name]!.value, 1, reason: name);
      }
      expect(run.metrics[Metric.askRate]!.value, 0);
      expect(run.failures.map((f) => '${f.id}: ${f.reasons}').toList(), isEmpty);
    });

    test('golden writes a report and exits non-zero below the baseline', () async {
      final dir = Directory.systemTemp.createTempSync('golden_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      // Interpretations that capture nothing.
      final emptyInterp = File('${dir.path}/empty.json')
        ..writeAsStringSync(jsonEncode({'engine': 'empty', 'results': <String, Object?>{}}));
      final oracleInterp = File('${dir.path}/oracle.json')
        ..writeAsStringSync(jsonEncode({
          'engine': 'oracle',
          'results': {
            for (final c in bundle.cases)
              '${c.id}#0': {
                'facts': c.ignore ? [info] : c.expectFacts,
                'unknown': false,
              },
          },
        }));
      Future<(int, Map<String, dynamic>)> go(String interp, String out, {String? baseline}) async {
        final code = await _runGoldenCli([
          'golden',
          '--golden-dir', '../sms_golden',
          '--interpretations', interp,
          '--profile', 'none',
          '--out', '${dir.path}/$out',
          if (baseline != null) ...['--baseline', baseline],
        ]);
        final j = jsonDecode(File('${dir.path}/$out/report.json').readAsStringSync()) as Map<String, dynamic>;
        return (code, j);
      }

      final (c1, good) = await go(oracleInterp.path, 'good');
      expect(c1, 0);
      expect(File('${dir.path}/good/report.md').existsSync(), isTrue);
      expect(good['metrics']['captureRecall']['value'], 1);
      expect(good['stages']['linker'], 'not_available');

      final (c2, _) = await go(emptyInterp.path, 'bad', baseline: '${dir.path}/good/report.json');
      expect(c2, 1);
    });
  });
}

Future<int> _runGoldenCli(List<String> args) async {
  final r = await Process.run('dart', ['run', 'bin/sms_rules.dart', ...args]);
  return r.exitCode;
}

class _Throwing implements InterpreterStage {
  @override
  Future<InterpretedMessage> interpret(GoldenMessage message) => throw StateError('boom');
}

class _Oracle implements InterpreterStage {
  _Oracle(GoldenBundle b) {
    for (final c in b.cases) {
      _byMessage[c.messages.first] = c;
    }
  }
  final Map<GoldenMessage, GoldenCase> _byMessage = {};
  @override
  Future<InterpretedMessage> interpret(GoldenMessage m) async {
    final c = _byMessage[m];
    if (c == null) return const InterpretedMessage();
    return InterpretedMessage(facts: c.ignore ? [info] : c.expectFacts);
  }
}

class _FakeInstruments implements InstrumentStage {
  @override
  Future<InstrumentResolution> resolve({
    required List<Map<String, dynamic>> facts,
    required List<Map<String, dynamic>> knownInstruments,
  }) async => InstrumentResolution(
    instruments: [
      {'instrumentId': 'i1', 'kind': 'bank_account', 'maskDigits': '1234'},
    ],
    facts: facts,
  );
}

class _FakeLinker implements LinkerStage {
  _FakeLinker(this.linkDuplicates);
  final bool linkDuplicates;
  @override
  Future<List<Map<String, dynamic>>> link({
    required List<Map<String, dynamic>> facts,
    required List<Map<String, dynamic>> instruments,
  }) async {
    if (linkDuplicates) {
      return [
        {
          'eventId': 'e1',
          'type': 'purchase',
          'legs': [
            {'factId': 'f1', 'role': 'debit_leg'},
            {'factId': 'f2', 'role': 'duplicate_notice'},
          ],
        },
      ];
    }
    return [
      for (final f in facts)
        {
          'eventId': 'e-${f['factId']}',
          'type': 'purchase',
          'legs': [
            {'factId': f['factId'], 'role': 'debit_leg'},
          ],
        },
    ];
  }
}

class _FakeProjector implements ProjectorStage {
  @override
  Future<List<Map<String, dynamic>>> project({
    required List<Map<String, dynamic>> events,
    required List<Map<String, dynamic>> facts,
    required List<Map<String, dynamic>> instruments,
  }) async => [
    for (final e in events) {'eventId': e['eventId'], 'amountMinor': 25000},
  ];

  @override
  Future<LedgerTotals> totals({
    required List<Map<String, dynamic>> entries,
    DateTime? from,
    DateTime? to,
  }) async => LedgerTotals(
    spendMinor: entries.length * 25000,
    incomeMinor: 0,
    investmentMinor: 0,
    transactionCount: entries.length,
  );
}

class _FakeCategories implements CategoryStage {
  @override
  Future<List<Map<String, dynamic>>> categorize({
    required List<Map<String, dynamic>> entries,
  }) async => [
    for (final e in entries) {...e, 'category': 'food_dining'},
  ];
}
