import 'package:pandapay_domain/sms_v2.dart';
import '../storage/instrument_store.dart';
import 'personal_rule_store.dart';

/// Shared ignore rules retain safety precedence. A confirmed personal reading
/// otherwise wins over shared extraction; the engine still runs the same DSL.
class PersonalRuleEngine extends RuleEngine {
  PersonalRuleEngine({required this.store, required this.instruments});
  final PersonalRuleStore store;
  final InstrumentStore instruments;
  final RuleEngine _personal = RuleEngine();
  final Map<String, RuleBundle> _bundles = {};

  @override
  EngineOutcome interpretDetailed(
    SmsMessage message,
    RuleBundle bundle, {
    required String appVersion,
  }) {
    final shared = super.interpretDetailed(
      message,
      bundle,
      appVersion: appVersion,
    );
    if (shared.result.outcome == InterpretOutcome.ignored ||
        shared.reason == 'bundle_refused') {
      return shared;
    }
    for (final entry in store.list().reversed) {
      final instrument = instruments.get(entry.instrumentId);
      final emit = entry.rule.emit.singleOrNull;
      if (instrument?.status != InstrumentStatus.confirmed ||
          emit == null ||
          emit.instrument?['kind'] != instrument!.kind.wire ||
          emit.instrument?['issuerSlug'] != instrument.issuerSlug) {
        continue;
      }
      final key = '${store.revision}:${bundle.bundleVersion}:${entry.rule.id}';
      final local = _bundles.putIfAbsent(
        key,
        () => RuleBundle(
          bundleVersion: 0,
          createdAt: bundle.createdAt,
          expiresAt: bundle.expiresAt,
          minEngineVersion: bundle.minEngineVersion,
          taxonomyVersion: bundle.taxonomyVersion,
          senders: bundle.senders,
          rules: [entry.rule],
        ),
      );
      final parsed = _personal.interpretDetailed(
        message,
        local,
        appVersion: appVersion,
      );
      if (parsed.result.outcome != InterpretOutcome.matched ||
          (emit.occurredAt != null &&
              parsed.result.facts.any((fact) => fact.occurredAt == null))) {
        continue;
      }
      // The literal mask in the rule is never widened to a new account.
      if (parsed.result.facts.any(
        (fact) => fact.instrument?.maskDigits != instrument.maskDigits,
      )) {
        continue;
      }
      final facts = [
        for (final fact in parsed.result.facts)
          Fact.fromJson({
            ...fact.toJson(),
            'provenance': {
              ...fact.provenance.toJson(),
              'engine': 'user',
              'bundleVersion': bundle.bundleVersion,
            },
          }),
      ];
      return EngineOutcome(
        InterpretResult(
          outcome: InterpretOutcome.matched,
          facts: facts,
          ruleId: entry.rule.id,
          ruleVersion: 0,
          templateHash: parsed.result.templateHash,
        ),
        winnerId: entry.rule.id,
      );
    }
    return shared;
  }
}
