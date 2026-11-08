import 'dart:convert';
import 'dart:io';
import 'package:pandapay_domain/sms_v2.dart';

const _rulesDir = '../rules/sms/v2';

const _singleFiles = <String, String>{
  'ignore_rules.json': 'ignoreRules',
  'counterparty_purposes.json': 'counterpartyPurposes',
  'link_rules.json': 'linkRules',
  'category_rules.json': 'categoryRules',
  'merchant_aliases.json': 'merchantAliases',
};

/// Merges `rules/sms/v2` the way `sms_rules build` does (version 0, unsigned).
RuleBundle testRuleBundle() {
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
  // Sorted: the synthetic corpus draws rule examples by index, so the rule order
  // must not depend on the file system (macOS and Linux list folders differently).
  final files = root.listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
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
