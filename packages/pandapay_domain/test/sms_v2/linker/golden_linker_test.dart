// Runs the real rule engine, the instrument registry and the linker over the
// golden scenarios (tools/sms_golden/scenarios), the way the golden tool's
// pairsLinked and scenarioEvents metrics do, and checks that no fact is
// counted twice.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import 'helpers.dart' show doubleCounted;

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
    for (final k in [
      'senders',
      'ignoreRules',
      'rules',
      'counterpartyPurposes',
      'linkRules',
      'categoryRules',
      'merchantAliases',
    ])
      k: [],
  };
  final root = Directory(_rulesDir);
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.json')) continue;
    final rel = f.path.substring(root.path.length + 1).replaceAll('\\', '/');
    if (rel == 'meta.json') continue;
    final decoded = jsonDecode(f.readAsStringSync());
    final base = rel.split('/').last;
    final key = rel.startsWith('senders/')
        ? 'senders'
        : (_singleFiles.containsKey(base) && !rel.contains('/'))
        ? _singleFiles[base]!
        : 'rules';
    lists[key]!.addAll(
      decoded is List ? decoded : (decoded as Map)[key] as List,
    );
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

String _shape(Map<String, Object?> e) {
  final roles = [
    for (final l in e['legs'] as List) (l as Map)['role'] as String,
  ]..sort();
  return '${e['type']}[${roles.join(',')}]';
}

void main() {
  final available =
      Directory(_rulesDir).existsSync() && Directory(_goldenDir).existsSync();

  group(
    'golden scenarios',
    skip: available ? false : 'run from packages/pandapay_domain',
    () {
      late RuleBundle bundle;
      final engine = RuleEngine();
      setUpAll(() => bundle = _bundle());

      test('events, linked pairs and double counts', () {
        final files =
            Directory('$_goldenDir/scenarios')
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.json'))
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        var pairs = 0;
        var pairsLinked = 0;
        var scenarios = 0;
        var exact = 0;
        final failures = <String>[];
        final doubles = <String>[];
        for (final file in files) {
          final s = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
          final id = s['id'] as String;
          final facts = <Map<String, dynamic>>[];
          final messages = s['messages'] as List;
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
            facts.addAll([
              for (final f in r.facts)
                if (f.factType != FactType.info) f.toJson(),
            ]);
          }
          final resolved = resolveInstrumentsForGolden(
            facts: facts,
            knownInstruments: [
              for (final k in (s['knownInstruments'] as List? ?? const []))
                (k as Map).cast<String, dynamic>(),
            ],
            bundle: bundle,
          );
          final events = linkForGolden(
            facts: [for (final f in resolved.facts) f.cast<String, dynamic>()],
            instruments: [
              for (final i in resolved.instruments) i.cast<String, dynamic>(),
            ],
            bundle: bundle,
            now: DateTime.utc(2027, 1, 1),
          );
          final expected = [
            for (final e
                in ((s['expect'] as Map)['events'] as List? ?? const []))
              '${(e as Map)['type']}[${([for (final r in e['legRoles'] as List) r as String]..sort()).join(',')}]',
          ]..sort();
          final actual = [for (final e in events) _shape(e)]..sort();
          final remaining = [...actual];
          for (final e in expected) {
            if (!e.contains(',')) continue;
            pairs++;
            if (remaining.remove(e)) pairsLinked++;
          }
          if (expected.isNotEmpty) {
            scenarios++;
            if (actual.join(' ') == expected.join(' ')) {
              exact++;
            } else {
              failures.add('$id: expected $expected, got $actual');
            }
          }
          final byId = {
            for (final f in resolved.facts)
              f['factId'] as String: Fact.fromJson(
                Map<String, Object?>.from(f)..remove('instrumentId'),
              ),
          };
          final parsed = [for (final e in events) Event.fromJson(e)];
          for (final d in doubleCounted(parsed, byId)) {
            doubles.add('$id: $d');
          }
        }
        // ignore: avoid_print
        print(
          'golden linker: pairsLinked $pairsLinked/$pairs, scenarioEvents $exact/$scenarios, doubleCounts ${doubles.length}',
        );
        expect(failures, isEmpty);
        expect(doubles, isEmpty);
        expect(scenarios, greaterThanOrEqualTo(14));
        expect(exact, scenarios);
        expect(pairsLinked, pairs);
      });
    },
  );
}
