import 'package:pandapay_domain/sms_v2.dart';

enum CorrectionKind {
  notFinancial('not_financial'),
  wrongKind('wrong_kind'),
  wrongAmount('wrong_amount'),
  wrongDate('wrong_date'),
  wrongMerchant('wrong_merchant'),
  wrongInstrument('wrong_instrument'),
  wrongLink('wrong_link'),
  duplicate('duplicate'),
  wrongCategory('wrong_category'),
  missing('missing'),
  preferenceOnly('preference_only');

  const CorrectionKind(this.wire);
  final String wire;
}

/// Stage evidence contains identifiers, role names and matching steps only.
class DecisionTrace {
  const DecisionTrace({
    required this.appVersion,
    required this.engineVersion,
    required this.bundleVersion,
    required this.outcome,
    this.ruleId,
    this.ruleVersion,
    this.facts = const [],
    this.instruments = const [],
    this.event,
    this.category,
  });

  final String appVersion, engineVersion, outcome;
  final int bundleVersion;
  final String? ruleId;
  final int? ruleVersion;
  final List<Fact> facts;
  final List<({String factId, String instrumentId, String step})> instruments;
  final Event? event;
  final CategoryDecision? category;

  String? stage(CorrectionKind kind, {bool extractedMaskCorrect = true}) =>
      switch (kind) {
        CorrectionKind.preferenceOnly => null,
        CorrectionKind.notFinancial =>
          outcome == 'ignored' || outcome == 'gate' ? 'gate' : 'extraction',
        CorrectionKind.wrongInstrument =>
          extractedMaskCorrect ? 'instrument' : 'extraction',
        CorrectionKind.wrongLink || CorrectionKind.duplicate => 'linking',
        CorrectionKind.wrongCategory => 'category',
        CorrectionKind.missing => 'gate',
        _ => 'extraction',
      };

  Map<String, Object?> compact(String stage) => {
    'appVersion': appVersion,
    'engineVersion': engineVersion,
    'bundleVersion': bundleVersion,
    'ruleId': ruleId,
    'ruleVersion': ruleVersion,
    'stage': stage,
  };

  Map<String, Object?> toJson() => {
    ...compact('extraction')..remove('stage'),
    'outcome': outcome,
    'facts': [
      for (final fact in facts)
        {
          'factId': fact.factId,
          'type': fact.factType.wire,
          'amountRoles': [for (final amount in fact.amounts) amount.role.wire],
        },
    ],
    'instruments': [
      for (final instrument in instruments)
        {
          'factId': instrument.factId,
          'instrumentId': instrument.instrumentId,
          'step': instrument.step,
        },
    ],
    if (event != null)
      'event': {
        'eventId': event!.eventId,
        'linkRuleId': event!.linkRuleId,
        'legs': [for (final leg in event!.legs) leg.toJson()],
      },
    if (category != null)
      'category': {'source': category!.source.wire, 'ruleId': category!.ruleId},
  };
}
