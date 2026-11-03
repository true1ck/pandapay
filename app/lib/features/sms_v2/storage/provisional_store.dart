import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';

import 'sync_state_store.dart';

/// Private rules delivered to this account by authenticated sync. They remain
/// separate from the signed shared cache and match only their template hash.
class ProvisionalStore {
  const ProvisionalStore(this.state);
  final SyncStateStore state;

  ({RuleBundle bundle, String revision}) overlay(RuleBundle shared) {
    final rules = <Rule>[];
    for (final row in state.db.select(
      "SELECT value FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%' ORDER BY key",
      [state.namespace],
    )) {
      try {
        final result = jsonDecode(row['value'] as String) as Map;
        if (result['status'] != 'ready' || result['rule'] is! Map) continue;
        final rule = Rule.fromJson(
          (result['rule'] as Map).cast<String, Object?>(),
        );
        if (rule.status != RuleStatus.provisional ||
            rule.match.templateHash != result['templateHash']) {
          continue;
        }
        if (!shared.rules.any((installed) => installed.id == rule.id))
          rules.add(rule);
      } catch (_) {
        /* An invalid draft never reaches the engine. */
      }
    }
    if (rules.isEmpty) {
      return (bundle: shared, revision: '${shared.bundleVersion}');
    }
    final ruleJson = [for (final rule in rules) rule.toJson()];
    try {
      final overlay = RuleBundle.fromJson({
        ...shared.toJson(),
        'rules': [...shared.rules.map((rule) => rule.toJson()), ...ruleJson],
      });
      RuleEngine().compiled(overlay);
      return (
        bundle: overlay,
        revision:
            '${shared.bundleVersion}:${sha256.convert(utf8.encode(canonicalJson(ruleJson)))}',
      );
    } on ContractException {
      return (bundle: shared, revision: '${shared.bundleVersion}');
    } on BundleRefusedException {
      return (bundle: shared, revision: '${shared.bundleVersion}');
    }
  }
}
