import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';

/// Reads a rules folder (`rules/sms/v2/**`) into one bundle map, without
/// validating it. Layout:
///
/// - `senders/*.json`        -> `senders`   (array, or `{"senders": [...]}`)
/// - `ignore_rules.json`     -> `ignoreRules`
/// - `counterparty_purposes.json` -> `counterpartyPurposes`
/// - `link_rules.json`       -> `linkRules`
/// - `category_rules.json`   -> `categoryRules`
/// - `merchant_aliases.json` -> `merchantAliases`
/// - `meta.json`             -> top-level fields (bundleVersion, createdAt, ...)
/// - every other `*.json`    -> `rules` (array, or `{"rules": [...]}`)
///
/// Lists are sorted (senders by brand, rules by id then version, the rest by
/// their key) so the same folder always gives the same bundle.
class RulesSource {
  RulesSource({
    required this.bundle,
    required this.files,
    required this.problems,
  });

  final Map<String, Object?> bundle;
  final List<String> files;

  /// Files that could not be read.
  final List<String> problems;
}

const _singleFiles = <String, String>{
  'ignore_rules.json': 'ignoreRules',
  'counterparty_purposes.json': 'counterpartyPurposes',
  'link_rules.json': 'linkRules',
  'category_rules.json': 'categoryRules',
  'merchant_aliases.json': 'merchantAliases',
};

List<Object?>? _listFrom(Object? decoded, String key) {
  if (decoded is List) return decoded;
  if (decoded is Map && decoded[key] is List) return decoded[key] as List;
  return null;
}

RulesSource readRulesFolder(
  String dir, {
  int bundleVersion = 1,
  String createdAt = '2026-01-01T00:00:00Z',
  String? expiresAt,
  String minEngineVersion = '2.0.0',
}) {
  final root = Directory(dir);
  final problems = <String>[];
  final files = <String>[];
  final lists = <String, List<Object?>>{
    'senders': [],
    'ignoreRules': [],
    'rules': [],
    'counterpartyPurposes': [],
    'linkRules': [],
    'categoryRules': [],
    'merchantAliases': [],
  };
  Map<String, Object?> meta = {};

  if (!root.existsSync()) {
    problems.add('rules folder not found: $dir');
  } else {
    final found = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in found) {
      final rel = f.path.substring(root.path.length).replaceFirst(RegExp(r'^[/\\]+'), '').replaceAll('\\', '/');
      files.add(rel);
      Object? decoded;
      try {
        decoded = jsonDecode(f.readAsStringSync());
      } on FormatException catch (e) {
        problems.add('$rel: not valid JSON (${e.message})');
        continue;
      }
      final base = rel.split('/').last;
      if (rel == 'meta.json') {
        if (decoded is Map<String, Object?>) {
          meta = decoded;
        } else {
          problems.add('$rel: expected an object');
        }
        continue;
      }
      final String key;
      if (rel.startsWith('senders/')) {
        key = 'senders';
      } else if (_singleFiles.containsKey(base) && !rel.contains('/')) {
        key = _singleFiles[base]!;
      } else {
        key = 'rules';
      }
      final list = _listFrom(decoded, key);
      if (list == null) {
        problems.add('$rel: expected an array (or an object with "$key")');
        continue;
      }
      lists[key]!.addAll(list);
    }
  }

  String idOf(Object? o) => o is Map ? '${o['id'] ?? ''}' : '';
  int versionOf(Object? o) => o is Map && o['version'] is num ? (o['version'] as num).toInt() : 0;
  lists['senders']!.sort((a, b) => '${(a as Map)['brand']}'.compareTo('${(b as Map)['brand']}'));
  lists['rules']!.sort((a, b) {
    final c = idOf(a).compareTo(idOf(b));
    return c != 0 ? c : versionOf(a).compareTo(versionOf(b));
  });
  for (final k in ['ignoreRules', 'counterpartyPurposes', 'linkRules']) {
    lists[k]!.sort((a, b) => idOf(a).compareTo(idOf(b)));
  }
  lists['categoryRules']!.sort((a, b) {
    final x = a as Map, y = b as Map;
    final p = ((y['priority'] ?? 0) as num).compareTo((x['priority'] ?? 0) as num);
    return p != 0 ? p : '${x['merchantKey']}'.compareTo('${y['merchantKey']}');
  });
  lists['merchantAliases']!.sort((a, b) => '${(a as Map)['alias']}'.compareTo('${(b as Map)['alias']}'));

  // The evidence solver's vocabulary lives beside the rules folder
  // (`rules/sms/solver/pack.json`), not inside it, because every other json in
  // the rules folder is read as a rule. Absent for any folder without one.
  Map<String, Object?>? solverPack;
  final packFile = File('${root.path}/../solver/pack.json');
  if (packFile.existsSync()) {
    try {
      final decoded = jsonDecode(packFile.readAsStringSync());
      if (decoded is Map<String, Object?>) {
        solverPack = decoded;
        files.add('../solver/pack.json');
      } else {
        problems.add('../solver/pack.json: expected an object');
      }
    } on FormatException catch (e) {
      problems.add('../solver/pack.json: not valid JSON (${e.message})');
    }
  }

  final created = (meta['createdAt'] as String?) ?? createdAt;
  final bundle = <String, Object?>{
    'schema': 'pandapay.sms.rules/2',
    'bundleVersion': meta['bundleVersion'] ?? bundleVersion,
    'createdAt': created,
    'expiresAt': (meta['expiresAt'] as String?) ??
        expiresAt ??
        DateTime.parse(created).add(const Duration(days: 7)).toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z'),
    'minEngineVersion': meta['minEngineVersion'] ?? minEngineVersion,
    'taxonomyVersion': meta['taxonomyVersion'] ?? 1,
    ...lists,
    if (solverPack != null) 'solverPack': solverPack,
    'signature': null,
  };
  return RulesSource(bundle: bundle, files: files, problems: problems);
}

/// Parses and validates an unsigned bundle (as `build` and `lint` see it).
/// The contract demands a signature on any bundle above version 0, so a
/// placeholder one is attached for validation and the engine; it never reaches
/// a file (see [unsignedJson]). Throws [ContractException].
RuleBundle parseUnsignedBundle(Map<String, Object?> json) {
  final j = Map<String, Object?>.of(json);
  if (j['signature'] == null && j['bundleVersion'] != 0) {
    j['signature'] = {'alg': 'Ed25519', 'keyId': 'unsigned', 'value': 'AAAA'};
  }
  return RuleBundle.fromJson(j);
}

/// The bundle as JSON with `signature` null.
Map<String, Object?> unsignedJson(RuleBundle b) => {...b.toJson(), 'signature': null};
