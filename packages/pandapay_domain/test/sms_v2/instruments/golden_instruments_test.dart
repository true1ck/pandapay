// Runs the real rule engine and the instrument resolver over the golden set
// (tools/sms_golden) and scores the instruments it ends up with. This mirrors
// the golden tool's `scenarioInstruments` metric and its `probe:` cases, so
// the done criteria are checked inside the domain package.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

const _rulesDir = '../../rules/sms/v2';
const _goldenDir = '../../tools/sms_golden';

const _singleFiles = <String, String>{
  'ignore_rules.json': 'ignoreRules',
  'counterparty_purposes.json': 'counterpartyPurposes',
  'link_rules.json': 'linkRules',
  'category_rules.json': 'categoryRules',
  'merchant_aliases.json': 'merchantAliases',
};

/// Merges `rules/sms/v2` the way `sms_rules build` does (version 0, unsigned).
RuleBundle _bundle() {
  final lists = <String, List<Object?>>{
    'senders': [],
    'ignoreRules': [],
    'rules': [],
    'counterpartyPurposes': [],
    'linkRules': [],
    'categoryRules': [],
    'merchantAliases': [],
  };
  final root = Directory(_rulesDir);
  final files = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList();
  for (final f in files) {
    final rel = f.path.substring(root.path.length + 1);
    if (rel == 'meta.json') continue;
    final decoded = jsonDecode(f.readAsStringSync());
    final base = rel.split('/').last;
    final key = rel.startsWith('senders/')
        ? 'senders'
        : (_singleFiles.containsKey(base) && !rel.contains('/'))
        ? _singleFiles[base]!
        : 'rules';
    lists[key]!.addAll(decoded is List ? decoded : (decoded as Map)[key] as List);
  }
  return RuleBundle.fromJson({
    'schema': 'pandapay.sms.rules/2',
    'bundleVersion': 0,
    'createdAt': '2026-11-20T00:00:00Z',
    'expiresAt': '2026-11-27T00:00:00Z',
    'minEngineVersion': '2.0.0',
    'taxonomyVersion': 1,
    ...lists,
    'signature': null,
  });
}

List<Map<String, dynamic>> _json(String dir) => [
  for (final f in Directory('$_goldenDir/$dir').listSync(recursive: true).whereType<File>())
    if (f.path.endsWith('.json')) jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
];

/// Every key in [expected] equals the same key in [actual].
bool _partial(Map<String, dynamic> expected, Map<String, Object?> actual) =>
    expected.entries.every((e) => actual[e.key] == e.value);

List<Fact> _facts(RuleEngine engine, RuleBundle bundle, List<dynamic> messages, String id) {
  final out = <Fact>[];
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i] as Map<String, dynamic>;
    final r = engine.interpret(
      SmsMessage(
        sender: m['sender'] as String,
        body: m['body'] as String,
        observedAt: DateTime.parse(m['observedAt'] as String).toUtc(),
        sourceKey: 'golden:$id:$i',
      ),
      bundle,
      appVersion: 'test',
    );
    out.addAll(r.facts.where((f) => f.factType != FactType.info));
  }
  return out;
}

void main() {
  final available = Directory(_rulesDir).existsSync() && Directory(_goldenDir).existsSync();

  group('golden instruments', skip: available ? false : 'run from packages/pandapay_domain', () {
    late RuleBundle bundle;
    late RuleEngine engine;
    setUpAll(() {
      bundle = _bundle();
      engine = RuleEngine();
    });

    test(
      'scenario instruments: at least 99% of scenarios end with exactly the expected instruments',
      () {
        final scenarios = _json('scenarios');
        var checked = 0;
        var passed = 0;
        final failures = <String>[];
        for (final s in scenarios) {
          final expected = [
            for (final e in ((s['expect'] as Map)['instruments'] as List? ?? const []))
              (e as Map).cast<String, dynamic>(),
          ];
          if (expected.isEmpty) continue;
          checked++;
          final facts = _facts(engine, bundle, s['messages'] as List, s['id'] as String);
          final result = resolveInstrumentsForGolden(
            facts: [for (final f in facts) f.toJson()],
            knownInstruments: [
              for (final k in (s['knownInstruments'] as List? ?? const []))
                (k as Map).cast<String, dynamic>(),
            ],
            bundle: bundle,
          );
          final actual = result.instruments;
          // Each expected instrument is matched by a distinct actual one, and there are no extras.
          final used = <int>{};
          var ok = actual.length == expected.length;
          for (final e in expected) {
            final at = [
              for (var i = 0; i < actual.length; i++)
                if (!used.contains(i) && _partial(e, actual[i])) i,
            ];
            if (at.isEmpty) {
              ok = false;
            } else {
              used.add(at.first);
            }
          }
          if (ok) {
            passed++;
          } else {
            failures.add(
              '${s['id']}: expected $expected, got ${[
                for (final a in actual) {'kind': a['kind'], 'issuerSlug': a['issuerSlug'], 'maskDigits': a['maskDigits'], 'creditLimitMinor': a['creditLimitMinor']},
              ]}',
            );
          }
        }
        final rate = passed / checked;
        // ignore: avoid_print
        print('scenario instruments: $passed/$checked = ${(rate * 100).toStringAsFixed(1)}%');
        expect(checked, greaterThanOrEqualTo(15));
        expect(failures, isEmpty);
        expect(rate, greaterThanOrEqualTo(0.99));
      },
    );

    test('probe and case instruments: every expected account or card resolves to the right one', () {
      final cases = _json('cases');
      var checked = 0;
      var passed = 0;
      final failures = <String>[];
      var probes = 0;
      for (final c in cases) {
        final expectedFacts = ((c['expect'] as Map)['facts'] as List? ?? const []);
        final expected = <Map<String, dynamic>>[
          for (final f in expectedFacts)
            if ((f as Map)['instrument'] is Map) (f['instrument'] as Map).cast<String, dynamic>(),
        ];
        if (expected.isEmpty) continue;
        final id = c['id'] as String;
        if (id.startsWith('probe:')) probes++;
        final facts = _facts(engine, bundle, c['messages'] as List, id);
        // A mask-less mention (for example "your Axis credit card") can only
        // name an instrument the user already has: seed the single one.
        final seeded = <Map<String, dynamic>>[];
        for (final e in expected) {
          if (e['maskDigits'] == null &&
              e['kind'] != null &&
              e['issuerSlug'] != null &&
              !seeded.any((k) => k['kind'] == e['kind'] && k['issuerSlug'] == e['issuerSlug'])) {
            seeded.add({
              'kind': e['kind'],
              'issuerSlug': e['issuerSlug'],
              'instrumentId':
                  '00000000-0000-4000-8000-${seeded.length.toRadixString(16).padLeft(12, '0')}',
            });
          }
        }
        final result = resolveInstrumentsForGolden(
          facts: [for (final f in facts) f.toJson()],
          knownInstruments: seeded,
          bundle: bundle,
        );
        for (final e in expected) {
          checked++;
          final seededOnly =
              e['maskDigits'] == null && e['kind'] != null && e['issuerSlug'] != null;
          final ok = seededOnly
              ? result.facts.any(
                  (f) => seeded.any(
                    (k) =>
                        k['instrumentId'] == f['instrumentId'] &&
                        k['kind'] == e['kind'] &&
                        k['issuerSlug'] == e['issuerSlug'],
                  ),
                )
              : e['maskDigits'] == null
              ? result.facts.any(
                  (f) =>
                      f['instrument'] is Map &&
                      _partial(e, (f['instrument'] as Map).cast<String, Object?>()),
                )
              : result.instruments.any((a) => _partial(e, a));
          if (ok) {
            passed++;
          } else {
            failures.add(
              '$id: expected $e, got ${[for (final a in result.instruments) '${a['kind']}/${a['issuerSlug']}/${a['maskDigits']}']}',
            );
          }
        }
      }
      // ignore: avoid_print
      print(
        'case instruments: $passed/$checked = ${(passed / checked * 100).toStringAsFixed(1)}% (probe cases: $probes)',
      );
      // ignore: avoid_print
      if (failures.isNotEmpty) print(failures.join('\n'));
      expect(probes, greaterThan(0));
      expect(passed / checked, greaterThanOrEqualTo(0.99));
    });
  });
}
