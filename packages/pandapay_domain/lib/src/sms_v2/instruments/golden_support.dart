import '../contract/enums.dart';
import '../contract/fact.dart';
import '../contract/instrument.dart';
import '../contract/rule_bundle.dart';
import 'apply_fact.dart';
import 'instrument_resolver.dart';

/// Result of [resolveInstrumentsForGolden].
class GoldenInstrumentResult {
  const GoldenInstrumentResult({
    required this.instruments,
    required this.facts,
    required this.review,
  });

  /// Every instrument after resolution, known ones first, as `Instrument` JSON.
  final List<Map<String, Object?>> instruments;

  /// The input facts, each with `instrumentId` set when it resolved.
  final List<Map<String, Object?>> facts;

  /// Facts that went to review: `{factId, reason}`.
  final List<Map<String, Object?>> review;
}

/// Runs the resolver and [applyFact] over fact JSON, the way the golden tool's
/// instruments stage needs it: plain maps in, plain maps out.
///
/// [knownInstruments] may be partial (`kind`, `issuerSlug`, `maskDigits`);
/// missing fields get defaults. Facts are processed in the order given. Pass
/// [bundle] so wallets with partial visibility are not turned into instruments.
GoldenInstrumentResult resolveInstrumentsForGolden({
  required List<Map<String, dynamic>> facts,
  required List<Map<String, dynamic>> knownInstruments,
  DateTime? now,
  RuleBundle? bundle,
  DefaultInstrumentResolver? resolver,
}) {
  final res =
      resolver ??
      (bundle != null ? DefaultInstrumentResolver.fromBundle(bundle) : DefaultInstrumentResolver());
  final epoch = (now ?? DateTime.utc(2000)).toUtc();
  final instruments = <Instrument>[
    for (var n = 0; n < knownInstruments.length; n++)
      _knownFromPartial(knownInstruments[n], n, epoch),
  ];
  final history = <String, List<LimitChangeRecord>>{};
  final outFacts = <Map<String, Object?>>[];
  final review = <Map<String, Object?>>[];

  for (final json in facts) {
    final fact = Fact.fromJson(Map<String, Object?>.from(json));
    final out = Map<String, Object?>.from(json);
    final mention = fact.instrument;
    if (mention != null && fact.factType != FactType.info) {
      final outcome = res.resolveDetailed(
        mention,
        instruments,
        profileId: 'golden',
        observedAt: fact.observedAt,
      );
      switch (outcome) {
        case InstrumentResolved(:final resolution):
          final base = resolution.instrument;
          final update = applyFact(
            base,
            fact,
            limitHistory: history[base.instrumentId] ?? const [],
          );
          history[base.instrumentId] = [...update.limitHistory];
          if (resolution.created) {
            instruments.add(update.instrument);
          } else {
            final at = instruments.indexWhere((i) => i.instrumentId == base.instrumentId);
            instruments[at] = update.instrument;
          }
          out['instrumentId'] = base.instrumentId;
        case InstrumentReviewNeeded(:final reason):
          review.add({'factId': fact.factId, 'reason': reason.name});
        case InstrumentNotCreated():
          break;
      }
    }
    outFacts.add(out);
  }
  return GoldenInstrumentResult(
    instruments: [for (final i in instruments) i.toJson()],
    facts: outFacts,
    review: review,
  );
}

Instrument _knownFromPartial(Map<String, dynamic> j, int n, DateTime epoch) {
  final kind = InstrumentKind.fromWire(j['kind'] as String);
  final issuer = j['issuerSlug'] as String;
  final mask = j['maskDigits'] as String?;
  final id =
      (j['instrumentId'] as String?) ??
      '00000000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';
  return Instrument(
    instrumentId: id,
    kind: kind,
    issuerSlug: issuer,
    maskDigits: mask,
    displayName: defaultDisplayName(defaultIssuerLabel(issuer), kind, mask),
    status: InstrumentStatus.confirmed,
    firstSeenAt: epoch,
    lastSeenAt: epoch,
    evidenceCount: 0,
  );
}
