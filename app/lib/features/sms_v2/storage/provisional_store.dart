import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';

import 'sync_state_store.dart';
import 'template_origin_store.dart';

/// Private rules delivered to this account by authenticated sync. They remain
/// separate from the signed shared cache and match only their template hash.
class ProvisionalStore {
  const ProvisionalStore(this.state);
  final SyncStateStore state;

  ({RuleBundle bundle, String revision}) overlay(RuleBundle shared) {
    final rules = <Rule>[];
    for (final row in state.db.select(
      "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%' ORDER BY key",
      [state.namespace],
    )) {
      try {
        final result = jsonDecode(row['value'] as String) as Map;
        if (result['status'] != 'ready' || result['rule'] is! Map) continue;
        final remoteHash = result['templateHash'];
        if (remoteHash is! String || row['key'] != 'ai:$remoteHash') continue;
        final origin = TemplateOriginStore(state).get(remoteHash);
        if (origin == null) continue;
        final rule = Rule.fromJson(
          (result['rule'] as Map).cast<String, Object?>(),
        );
        if (rule.status != RuleStatus.provisional ||
            rule.match.templateHash != remoteHash ||
            rule.senders.length != 1 ||
            rule.senders.single != origin.senderBrand) {
          continue;
        }
        // These rules are not covered by the bundle signature, so the engine's
        // regex dialect (no backtracking blow-up, 2,000 characters) is checked
        // here before the pattern can reach the matcher.
        if (lintRegexDialect(rule.match.pattern, rule.match.flags).isNotEmpty) {
          continue;
        }
        if (shared.rules.any((installed) => installed.id == rule.id)) continue;
        final sender = normalizeSenderBrand(
          origin.senderBrand,
          shared.senders,
        ).brand;
        for (final localHash in origin.localHashes) {
          rules.add(
            Rule.fromJson({
              ...rule.toJson(),
              'id': '${rule.id}:local:$localHash',
              'senders': [sender],
              'match': {...rule.match.toJson(), 'templateHash': localHash},
            }),
          );
        }
      } catch (_) {
        /* An invalid draft never reaches the engine. */
      }
    }
    if (rules.isEmpty) {
      return (bundle: shared, revision: '${shared.bundleVersion}');
    }
    var chosen = rules;
    var overlay = _overlayOf(shared, chosen);
    if (overlay == null) {
      // One rule the engine will not take must not hide the others: keep the rules that are fine on their own.
      chosen = [
        for (final rule in rules)
          if (_overlayOf(shared, [rule]) != null) rule,
      ];
      overlay = chosen.isEmpty ? null : _overlayOf(shared, chosen);
    }
    if (overlay == null) {
      return (bundle: shared, revision: '${shared.bundleVersion}');
    }
    final ruleJson = [for (final rule in chosen) rule.toJson()];
    return (
      bundle: overlay,
      revision:
          '${shared.bundleVersion}:${sha256.convert(utf8.encode(canonicalJson(ruleJson)))}',
    );
  }

  /// [shared] with [extra] added, or null when the engine refuses the result.
  static RuleBundle? _overlayOf(RuleBundle shared, List<Rule> extra) {
    try {
      final bundle = RuleBundle.fromJson({
        ...shared.toJson(),
        'rules': [
          ...shared.rules.map((rule) => rule.toJson()),
          ...extra.map((rule) => rule.toJson()),
        ],
      });
      RuleEngine().compiled(bundle);
      return bundle;
    } on ContractException {
      return null;
    } on BundleRefusedException {
      return null;
    }
  }
}
