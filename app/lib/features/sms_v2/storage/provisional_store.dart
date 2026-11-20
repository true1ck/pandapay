import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';

import 'draft_verdict_store.dart';
import 'sync_state_store.dart';
import 'template_origin_store.dart';

/// Private rules delivered to this account by authenticated sync. They remain
/// separate from the signed shared cache and match only their template hash.
class ProvisionalStore {
  const ProvisionalStore(this.state);
  final SyncStateStore state;

  /// How many times a whole bundle was compiled for an overlay in this isolate (tests and measurements read it).
  static int overlayBuilds = 0;

  /// The overlays built for each database, newest last: the answer for one account, over one shared bundle, made
  /// from one state of its drafts. Building an overlay re-validates and compiles the whole shared bundle (about
  /// 1,150 rules), which the sync pass, every re-read marker and the review screens each used to do again at every
  /// call. A few entries per database, so a second reader holding another copy of the bundle does not evict the
  /// first; held weakly through the database object, so nothing outlives it.
  static final Expando<List<_Built>> _cache = Expando<List<_Built>>('ProvisionalStore');
  static const _cacheEntries = 4;

  static void resetBuildCountForTesting() {
    overlayBuilds = 0;
  }

  /// The shared bundle with this account's usable private rules added, and the revision that names that exact
  /// combination. The same object comes back until a draft, its original wordings, a verdict of this phone or the
  /// shared bundle itself changes: the key is made from the stored draft results, the origin records and the
  /// verdicts, read as they are (cheap) before anything is parsed or compiled (not cheap).
  ({RuleBundle bundle, String revision}) overlay(RuleBundle shared) {
    final drafts = <_Draft>[];
    final key = StringBuffer();
    for (final row in state.db.select(
      "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%' ORDER BY key",
      [state.namespace],
    )) {
      try {
        final result = jsonDecode(row['value'] as String) as Map;
        if (result['status'] != 'ready' || result['rule'] is! Map) continue;
        final remoteHash = result['templateHash'];
        if (remoteHash is! String || row['key'] != 'ai:$remoteHash') continue;
        // This phone checked the draft against its own message and refused it.
        if (DraftVerdictStore(
          state,
        ).isRejected(remoteHash, DraftVerdictStore.draftIdOf(result))) {
          continue;
        }
        final rawOrigin = state.get('template:origins:$remoteHash');
        if (rawOrigin == null) continue;
        drafts.add(_Draft(remoteHash, result, rawOrigin));
        key
          ..write(row['value'])
          ..write('\u0000')
          ..write(rawOrigin)
          ..write('\u0001');
      } catch (_) {
        /* An invalid draft never reaches the engine. */
      }
    }
    if (drafts.isEmpty) {
      return (bundle: shared, revision: '${shared.bundleVersion}');
    }
    final fingerprint = sha256.convert(utf8.encode(key.toString())).toString();
    final entries = _cache[state.db] ??= <_Built>[];
    for (final entry in entries) {
      if (entry.namespace == state.namespace &&
          entry.fingerprint == fingerprint &&
          identical(entry.shared, shared)) {
        return entry.answer;
      }
    }
    final answer = _build(shared, drafts);
    entries.removeWhere(
      (entry) => entry.namespace == state.namespace && identical(entry.shared, shared),
    );
    entries.add(_Built(state.namespace, shared, fingerprint, answer));
    if (entries.length > _cacheEntries) entries.removeAt(0);
    return answer;
  }

  ({RuleBundle bundle, String revision}) _build(RuleBundle shared, List<_Draft> drafts) {
    final rules = <Rule>[];
    for (final draft in drafts) {
      try {
        final remoteHash = draft.remoteHash;
        final origin = TemplateOriginStore(state).parse(draft.rawOrigin);
        if (origin == null) continue;
        final rule = Rule.fromJson(
          (draft.result['rule'] as Map).cast<String, Object?>(),
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
        // The header this phone read the messages under, not only the cleaned brand the server filed the layout
        // under (SBI-UPI, not SBIUPI): the engine matches a rule's senders against the first.
        final senders = {
          for (final brand in origin.localBrands)
            normalizeSenderBrand(brand, shared.senders).brand,
        }.toList();
        final ruleJson = rule.toJson();
        for (final localHash in origin.localHashes) {
          rules.add(
            Rule.fromJson({
              ...ruleJson,
              'id': '${rule.id}:local:$localHash',
              'senders': senders,
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
    overlayBuilds++;
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

class _Draft {
  const _Draft(this.remoteHash, this.result, this.rawOrigin);
  final String remoteHash;
  final Map result;
  final String rawOrigin;
}

class _Built {
  const _Built(this.namespace, this.shared, this.fingerprint, this.answer);
  final String namespace;
  final RuleBundle shared;
  final String fingerprint;
  final ({RuleBundle bundle, String revision}) answer;
}
