import '../contract/enums.dart';
import '../contract/event.dart';
import '../contract/fact.dart';
import '../contract/instrument.dart';
import '../contract/rule_bundle.dart';
import 'link_context.dart';
import 'rule_driven_linker.dart';

/// Runs [RuleDrivenLinker] over plain JSON, the way the golden tool's linker
/// stage needs it.
///
/// [facts] are fact JSON, each optionally carrying the `instrumentId` the
/// instruments stage resolved; [instruments] are instrument JSON. Returns the
/// events as JSON (created first, then updated; none of them existed before).
/// [rules] defaults to the bundle's link rules.
List<Map<String, Object?>> linkForGolden({
  required List<Map<String, dynamic>> facts,
  required List<Map<String, dynamic>> instruments,
  RuleBundle? bundle,
  List<LinkRule>? rules,
  DateTime? now,
}) {
  final idByFact = <String, String>{};
  final parsed = <Fact>[];
  for (final json in facts) {
    final copy = Map<String, Object?>.from(json);
    final instrumentId = copy.remove('instrumentId') as String?;
    if (copy['factType'] == FactType.info.wire) continue;
    final fact = Fact.fromJson(copy);
    if (instrumentId != null) idByFact[fact.factId] = instrumentId;
    parsed.add(fact);
  }
  final byId = <String, Instrument>{
    for (final j in instruments)
      (j['instrumentId'] as String): Instrument.fromJson(Map<String, Object?>.from(j)),
  };
  final linker = bundle == null
      ? RuleDrivenLinker(clock: now == null ? null : () => now)
      : RuleDrivenLinker.fromBundle(bundle, clock: now == null ? null : () => now);
  final result = linker.link(
    incoming: parsed,
    context: RuleLinkContext(
      recentFacts: const [],
      openEvents: const [],
      instrumentsById: byId,
      instrumentIdByFactId: idByFact,
    ),
    rules: rules ?? bundle?.linkRules ?? const [],
  );
  return [
    for (final Event e in [...result.created, ...result.updated]) e.toJson(),
  ];
}
