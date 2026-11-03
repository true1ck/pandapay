import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';
import '../storage/sync_state_store.dart';

/// A device-local frozen-DSL rule bound to one confirmed owned instrument.
class PersonalRule {
  const PersonalRule({required this.rule, required this.instrumentId});
  final Rule rule;
  final String instrumentId;
  Map<String, Object?> toJson() => {
    'rule': rule.toJson(),
    'instrumentId': instrumentId,
  };
  factory PersonalRule.fromJson(Map<String, Object?> json) => PersonalRule(
    rule: Rule.fromJson((json['rule'] as Map).cast<String, Object?>()),
    instrumentId: json['instrumentId'] as String,
  );
}

/// Kept outside the signed bundle cache and all shared learning outboxes.
class PersonalRuleStore {
  const PersonalRuleStore(this.state);
  final SyncStateStore state;
  static const _key = 'personal:rules';
  List<PersonalRule> list() {
    final saved = state.get(_key);
    if (saved == null) return const [];
    try {
      return [
        for (final item in jsonDecode(saved) as List)
          PersonalRule.fromJson((item as Map).cast<String, Object?>()),
      ];
    } catch (_) {
      // Corrupt local configuration never becomes executable interpretation.
      return const [];
    }
  }

  String get revision =>
      sha256.convert(utf8.encode(state.get(_key) ?? '[]')).toString();
  void save(PersonalRule rule) {
    final all = {
      for (final saved in list()) saved.rule.id: saved,
      rule.rule.id: rule,
    };
    state.put(
      _key,
      jsonEncode(all.values.map((value) => value.toJson()).toList()),
    );
  }
}
