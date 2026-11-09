import 'enums.dart';
import 'errors.dart';
import 'json_util.dart';
import 'validate.dart';

List<T> _list<T>(Object? v, T Function(Json) f) =>
    List.unmodifiable([for (final e in v as List) f(e as Json)]);

List<String>? _strings(Object? v) =>
    v == null ? null : List.unmodifiable((v as List).cast<String>());

Json? _frozenMap(Object? v) => v == null ? null : freezeJson(v) as Json;

/// `{alg, keyId, value}`: Ed25519 over the canonical JSON of the bundle without
/// `signature`.
final class BundleSignature extends JsonValue {
  const BundleSignature({this.alg = 'Ed25519', required this.keyId, required this.value});

  factory BundleSignature.fromJson(Json j) => BundleSignature(
        alg: j['alg'] as String,
        keyId: j['keyId'] as String,
        value: j['value'] as String,
      );

  final String alg;
  final String keyId;

  /// Base64.
  final String value;

  @override
  Json toJson() => {'alg': alg, 'keyId': keyId, 'value': value};
}

/// A known sender brand. The brand is upper case with the operator prefix and
/// `-S`/`-T`/`-P`/`-G` suffix removed.
final class SenderEntry extends JsonValue {
  SenderEntry({
    required this.brand,
    this.issuerSlug,
    required this.issuerKind,
    List<String> aliases = const [],
    this.walletSpendVisibility,
  }) : aliases = List.unmodifiable(aliases);

  factory SenderEntry.fromJson(Json j) => SenderEntry(
        brand: j['brand'] as String,
        issuerSlug: j['issuerSlug'] as String?,
        issuerKind: IssuerKind.fromWire(j['issuerKind'] as String),
        aliases: (j['aliases'] as List).cast<String>(),
        walletSpendVisibility: j['walletSpendVisibility'] == null
            ? null
            : WalletSpendVisibility.fromWire(j['walletSpendVisibility'] as String),
      );

  final String brand;

  /// Null for gateway senders, whose rules set the issuer explicitly.
  final String? issuerSlug;
  final IssuerKind issuerKind;
  final List<String> aliases;

  /// Wallet senders only: `sms` (each wallet purchase is the spend) or
  /// `partial` (a top-up counts as a purchase at the wallet's merchant).
  final WalletSpendVisibility? walletSpendVisibility;

  @override
  Json toJson() => {
        'brand': brand,
        'issuerSlug': issuerSlug,
        'issuerKind': issuerKind.wire,
        'aliases': [...aliases],
        if (walletSpendVisibility != null) 'walletSpendVisibility': walletSpendVisibility!.wire,
      };
}

/// A message that produces one `info` fact and stops the engine.
final class IgnoreRule extends JsonValue {
  IgnoreRule({
    required this.id,
    required List<String> senders,
    required this.pattern,
    required this.flags,
    required this.reason,
  }) : senders = List.unmodifiable(senders);

  factory IgnoreRule.fromJson(Json j) => IgnoreRule(
        id: j['id'] as String,
        senders: (j['senders'] as List).cast<String>(),
        pattern: j['pattern'] as String,
        flags: j['flags'] as String,
        reason: InfoCategory.fromWire(j['reason'] as String),
      );

  final String id;
  final List<String> senders;
  final String pattern;
  final String flags;
  final InfoCategory reason;

  @override
  Json toJson() => {
        'id': id,
        'senders': [...senders],
        'pattern': pattern,
        'flags': flags,
        'reason': reason.wire,
      };
}

/// How a rule recognises a message.
final class RuleMatch extends JsonValue {
  RuleMatch({
    required this.pattern,
    required this.flags,
    List<String>? requireAll,
    List<String>? rejectAny,
    this.templateHash,
  })  : requireAll = requireAll == null ? null : List.unmodifiable(requireAll),
        rejectAny = rejectAny == null ? null : List.unmodifiable(rejectAny);

  factory RuleMatch.fromJson(Json j) => RuleMatch(
        pattern: j['pattern'] as String,
        flags: j['flags'] as String,
        requireAll: _strings(j['requireAll']),
        rejectAny: _strings(j['rejectAny']),
        templateHash: j['templateHash'] as String?,
      );

  final String pattern;

  /// Any of `i`, `m`, `s`.
  final String flags;
  final List<String>? requireAll;
  final List<String>? rejectAny;

  /// A rule with a template hash applies only to messages with that hash.
  final String? templateHash;

  @override
  Json toJson() => {
        'pattern': pattern,
        'flags': flags,
        if (requireAll != null) 'requireAll': [...requireAll!],
        if (rejectAny != null) 'rejectAny': [...rejectAny!],
        if (templateHash != null) 'templateHash': templateHash,
      };
}

/// How an emit reads the original foreign amount of an INR posting (CCR-004).
/// [from] is the group holding the printed foreign amount. The currency is the
/// fixed [currency] or the text of the group [currencyFrom].
final class EmitOriginal extends JsonValue {
  const EmitOriginal({required this.from, this.currency, this.currencyFrom});

  factory EmitOriginal.fromJson(Json j) => EmitOriginal(
        from: j['from'] as String,
        currency: j['currency'] as String?,
        currencyFrom: j['currencyFrom'] as String?,
      );

  final String from;

  /// A fixed ISO code, for a rule that is about one currency.
  final String? currency;

  /// Named regex group holding a code or symbol (`USD`, `US$`, `€`).
  final String? currencyFrom;

  @override
  Json toJson() => {
        'from': from,
        if (currency != null) 'currency': currency,
        if (currencyFrom != null) 'currencyFrom': currencyFrom,
      };
}

/// An amount an emit builds from a regex group. The unit is fixed ([unit]) or
/// read from the message ([unitFrom], CCR-004); exactly one is set. With a
/// foreign unit the amount is a foreign-only price: no INR is known.
final class EmitAmount extends JsonValue {
  EmitAmount({
    required this.role,
    required this.from,
    this.unit,
    this.unitFrom,
    this.original,
    List<String>? transforms,
  })  : assert(unit != null || unitFrom != null, 'unit or unitFrom is required'),
        transforms = transforms == null ? null : List.unmodifiable(transforms);

  factory EmitAmount.fromJson(Json j) => EmitAmount(
        role: AmountRole.fromWire(j['role'] as String),
        from: j['from'] as String,
        unit: j['unit'] as String?,
        unitFrom: j['unitFrom'] as String?,
        original: j['original'] == null ? null : EmitOriginal.fromJson(j['original'] as Json),
        transforms: _strings(j['transforms']),
      );

  final AmountRole role;

  /// Named regex group.
  final String from;
  final String? unit;

  /// Named regex group holding the currency of [from].
  final String? unitFrom;

  /// The foreign amount printed beside an INR posting.
  final EmitOriginal? original;
  final List<String>? transforms;

  @override
  Json toJson() => {
        'role': role.wire,
        'from': from,
        if (unit != null) 'unit': unit,
        if (unitFrom != null) 'unitFrom': unitFrom,
        if (original != null) 'original': original!.toJson(),
        if (transforms != null) 'transforms': [...transforms!],
      };
}

/// One fact a rule builds from its match.
final class Emit extends JsonValue {
  Emit({
    required this.factType,
    Json? attrs,
    List<EmitAmount>? amounts,
    Json? occurredAt,
    Json? instrument,
    Json? counterparty,
    Map<String, String>? references,
  })  : attrs = _frozenMap(attrs),
        amounts = amounts == null ? null : List.unmodifiable(amounts),
        occurredAt = _frozenMap(occurredAt),
        instrument = _frozenMap(instrument),
        counterparty = _frozenMap(counterparty),
        references = references == null ? null : Map.unmodifiable(references);

  factory Emit.fromJson(Json j) => Emit(
        factType: FactType.fromWire(j['factType'] as String),
        attrs: j['attrs'] as Json?,
        amounts: j['amounts'] == null ? null : _list(j['amounts'], EmitAmount.fromJson),
        occurredAt: j['occurredAt'] as Json?,
        instrument: j['instrument'] as Json?,
        counterparty: j['counterparty'] as Json?,
        references: j['references'] == null
            ? null
            : {for (final e in (j['references'] as Map).entries) e.key as String: e.value as String},
      );

  final FactType factType;

  /// Literals and `{sameAs, field}` references, as in the rule format.
  final Json? attrs;
  final List<EmitAmount>? amounts;

  /// `{from, formats?}`.
  final Json? occurredAt;

  /// `{kind?, issuerSlug?, maskFrom?, ...}` or `{sameAs}`.
  final Json? instrument;

  /// `{nameFrom?, kind?, transforms?, ...}` or `{sameAs}`.
  final Json? counterparty;
  final Map<String, String>? references;

  @override
  Json toJson() => {
        'factType': factType.wire,
        if (attrs != null) 'attrs': thawJson(attrs) as Json,
        if (amounts != null) 'amounts': [for (final a in amounts!) a.toJson()],
        if (occurredAt != null) 'occurredAt': thawJson(occurredAt) as Json,
        if (instrument != null) 'instrument': thawJson(instrument) as Json,
        if (counterparty != null) 'counterparty': thawJson(counterparty) as Json,
        if (references != null) 'references': {...references!},
      };
}

/// A positive or negative example a rule must reproduce.
final class RuleExample extends JsonValue {
  RuleExample({required this.sender, required this.body, required List<FactType> expectFactTypes})
      : expectFactTypes = List.unmodifiable(expectFactTypes);

  factory RuleExample.fromJson(Json j) => RuleExample(
        sender: j['sender'] as String,
        body: j['body'] as String,
        expectFactTypes: [
          for (final t in j['expectFactTypes'] as List) FactType.fromWire(t as String),
        ],
      );

  final String sender;
  final String body;

  /// Empty for a negative example.
  final List<FactType> expectFactTypes;

  @override
  Json toJson() => {
        'sender': sender,
        'body': body,
        'expectFactTypes': [for (final t in expectFactTypes) t.wire],
      };
}

/// A parsing rule. Rules are immutable: a change is a new `version`.
final class Rule extends JsonValue {
  Rule({
    required this.id,
    required this.version,
    required this.family,
    required List<String> senders,
    required this.priority,
    required this.match,
    required List<Emit> emit,
    required this.confidence,
    required List<RuleExample> examples,
    required this.status,
    required this.createdBy,
    required this.updatedAt,
  })  : senders = List.unmodifiable(senders),
        emit = List.unmodifiable(emit),
        examples = List.unmodifiable(examples);

  /// Parses without validating the whole bundle. Use [validate] to check.
  factory Rule.fromJson(Json j) => Rule(
        id: j['id'] as String,
        version: (j['version'] as num).toInt(),
        family: j['family'] as String,
        senders: (j['senders'] as List).cast<String>(),
        priority: (j['priority'] as num).toInt(),
        match: RuleMatch.fromJson(j['match'] as Json),
        emit: _list(j['emit'], Emit.fromJson),
        confidence: (j['confidence'] as num).toDouble(),
        examples: _list(j['examples'], RuleExample.fromJson),
        status: RuleStatus.fromWire(j['status'] as String),
        createdBy: j['createdBy'] as String,
        updatedAt: parseUtc(j['updatedAt'] as String),
      );

  final String id;
  final int version;
  final String family;

  /// Brands, or `*` for generic rules.
  final List<String> senders;
  final int priority;
  final RuleMatch match;
  final List<Emit> emit;
  final double confidence;
  final List<RuleExample> examples;
  final RuleStatus status;

  /// `baseline`, an admin, or `ai:<model>` for provisional rules.
  final String createdBy;
  final DateTime updatedAt;

  @override
  Json toJson() => {
        'id': id,
        'version': version,
        'family': family,
        'senders': [...senders],
        'priority': priority,
        'match': match.toJson(),
        'emit': [for (final e in emit) e.toJson()],
        'confidence': confidence,
        'examples': [for (final e in examples) e.toJson()],
        'status': status.wire,
        'createdBy': createdBy,
        'updatedAt': formatUtc(updatedAt),
      };
}

/// Names the instrument a counterparty purpose points at.
final class TargetInstrument extends JsonValue {
  const TargetInstrument({required this.kind, this.issuerSlug});

  factory TargetInstrument.fromJson(Json j) => TargetInstrument(
        kind: InstrumentKind.fromWire(j['kind'] as String),
        issuerSlug: j['issuerSlug'] as String?,
      );

  final InstrumentKind kind;
  final String? issuerSlug;

  @override
  Json toJson() => {'kind': kind.wire, if (issuerSlug != null) 'issuerSlug': issuerSlug};
}

/// Runs after `emit`: re-purposes a movement by who it was paid to. May replace
/// a `purpose` only when it is `unknown`, `p2p`, `purchase` or `transfer`; for
/// `wallet_topup` and `card_payment` it also sets the counterparty kind to
/// `own`.
final class CounterpartyPurpose extends JsonValue {
  const CounterpartyPurpose({
    required this.id,
    this.vpaPattern,
    this.namePattern,
    required this.purpose,
    this.targetInstrument,
  });

  factory CounterpartyPurpose.fromJson(Json j) => CounterpartyPurpose(
        id: j['id'] as String,
        vpaPattern: j['vpaPattern'] as String?,
        namePattern: j['namePattern'] as String?,
        purpose: MovementPurpose.fromWire(j['purpose'] as String),
        targetInstrument: j['targetInstrument'] == null
            ? null
            : TargetInstrument.fromJson(j['targetInstrument'] as Json),
      );

  final String id;
  final String? vpaPattern;
  final String? namePattern;
  final MovementPurpose purpose;
  final TargetInstrument? targetInstrument;

  @override
  Json toJson() => {
        'id': id,
        'vpaPattern': vpaPattern,
        'namePattern': namePattern,
        'purpose': purpose.wire,
        'targetInstrument': targetInstrument?.toJson(),
      };
}

/// The facts a link-rule leg accepts.
final class LinkLegMatch extends JsonValue {
  LinkLegMatch({
    this.factType,
    this.direction,
    List<String>? purpose,
    List<InstrumentKind>? instrumentKind,
    List<HoldPhase>? phase,
    this.evidenceOnly,
  })  : purpose = purpose == null ? null : List.unmodifiable(purpose),
        instrumentKind = instrumentKind == null ? null : List.unmodifiable(instrumentKind),
        phase = phase == null ? null : List.unmodifiable(phase);

  factory LinkLegMatch.fromJson(Json j) => LinkLegMatch(
        factType: j['factType'] == null ? null : FactType.fromWire(j['factType'] as String),
        direction: j['direction'] == null ? null : Direction.fromWire(j['direction'] as String),
        purpose: _strings(j['purpose']),
        instrumentKind: j['instrumentKind'] == null
            ? null
            : [for (final k in j['instrumentKind'] as List) InstrumentKind.fromWire(k as String)],
        phase: j['phase'] == null
            ? null
            : [for (final k in j['phase'] as List) HoldPhase.fromWire(k as String)],
        evidenceOnly: j['evidenceOnly'] as bool?,
      );

  final FactType? factType;
  final Direction? direction;

  /// Movement or hold purpose wire names.
  final List<String>? purpose;
  final List<InstrumentKind>? instrumentKind;
  final List<HoldPhase>? phase;
  final bool? evidenceOnly;

  @override
  Json toJson() => {
        if (factType != null) 'factType': factType!.wire,
        if (direction != null) 'direction': direction!.wire,
        if (purpose != null) 'purpose': [...purpose!],
        if (instrumentKind != null) 'instrumentKind': [for (final k in instrumentKind!) k.wire],
        if (phase != null) 'phase': [for (final k in phase!) k.wire],
        if (evidenceOnly != null) 'evidenceOnly': evidenceOnly,
      };
}

/// One leg of a link rule.
final class LinkLeg extends JsonValue {
  const LinkLeg({required this.role, required this.match});

  factory LinkLeg.fromJson(Json j) => LinkLeg(
        role: LegRole.fromWire(j['role'] as String),
        match: LinkLegMatch.fromJson(j['match'] as Json),
      );

  final LegRole role;
  final LinkLegMatch match;

  @override
  Json toJson() => {'role': role.wire, 'match': match.toJson()};
}

/// How legs are joined.
final class LinkJoin extends JsonValue {
  const LinkJoin({this.amountRole, this.amountTolerancePct, required this.windowHours, this.reference});

  factory LinkJoin.fromJson(Json j) => LinkJoin(
        amountRole: j['amountRole'] == null ? null : AmountRole.fromWire(j['amountRole'] as String),
        amountTolerancePct: j['amountTolerancePct'] as num?,
        windowHours: j['windowHours'] as num,
        reference: j['reference'] == null ? null : ReferenceMode.fromWire(j['reference'] as String),
      );

  final AmountRole? amountRole;
  final num? amountTolerancePct;
  final num windowHours;
  final ReferenceMode? reference;

  @override
  Json toJson() => {
        if (amountRole != null) 'amountRole': amountRole!.wire,
        if (amountTolerancePct != null) 'amountTolerancePct': amountTolerancePct,
        'windowHours': windowHours,
        if (reference != null) 'reference': reference!.wire,
      };
}

/// Parameters for the event linker. The matching algorithm is code; link rules
/// only set its parameters.
final class LinkRule extends JsonValue {
  LinkRule({
    required this.id,
    required this.eventType,
    required List<LinkLeg> legs,
    required this.join,
    required this.singleLeg,
    required this.priority,
  }) : legs = List.unmodifiable(legs);

  factory LinkRule.fromJson(Json j) => LinkRule(
        id: j['id'] as String,
        eventType: EventType.fromWire(j['eventType'] as String),
        legs: _list(j['legs'], LinkLeg.fromJson),
        join: LinkJoin.fromJson(j['join'] as Json),
        singleLeg: SingleLeg.fromWire(j['singleLeg'] as String),
        priority: (j['priority'] as num).toInt(),
      );

  final String id;
  final EventType eventType;
  final List<LinkLeg> legs;
  final LinkJoin join;

  /// What a lone leg becomes.
  final SingleLeg singleLeg;
  final int priority;

  @override
  Json toJson() => {
        'id': id,
        'eventType': eventType.wire,
        'legs': [for (final l in legs) l.toJson()],
        'join': join.toJson(),
        'singleLeg': singleLeg.wire,
        'priority': priority,
      };
}

/// Maps a merchant to a category.
final class CategoryRule extends JsonValue {
  CategoryRule({
    required this.merchantKey,
    required this.match,
    required List<String> senders,
    required List<String> context,
    required this.category,
    required this.priority,
    required this.source,
  })  : senders = List.unmodifiable(senders),
        context = List.unmodifiable(context);

  factory CategoryRule.fromJson(Json j) => CategoryRule(
        merchantKey: j['merchantKey'] as String,
        match: CategoryMatch.fromWire(j['match'] as String),
        senders: (j['senders'] as List).cast<String>(),
        context: (j['context'] as List).cast<String>(),
        category: j['category'] as String,
        priority: (j['priority'] as num).toInt(),
        source: CategorySource.fromWire(j['source'] as String),
      );

  final String merchantKey;
  final CategoryMatch match;
  final List<String> senders;
  final List<String> context;
  final String category;
  final int priority;
  final CategorySource source;

  @override
  Json toJson() => {
        'merchantKey': merchantKey,
        'match': match.wire,
        'senders': [...senders],
        'context': [...context],
        'category': category,
        'priority': priority,
        'source': source.wire,
      };
}

/// Maps a raw merchant string to a canonical merchant key.
final class MerchantAlias extends JsonValue {
  const MerchantAlias({required this.alias, required this.merchantKey, required this.kind});

  factory MerchantAlias.fromJson(Json j) => MerchantAlias(
        alias: j['alias'] as String,
        merchantKey: j['merchantKey'] as String,
        kind: j['kind'] as String,
      );

  final String alias;
  final String merchantKey;

  /// For example `marketplace`.
  final String kind;

  @override
  Json toJson() => {'alias': alias, 'merchantKey': merchantKey, 'kind': kind};
}

/// A signed set of rules. A bundle is data, never code.
final class RuleBundle extends JsonValue {
  RuleBundle({
    this.schema = schemaId,
    required this.bundleVersion,
    required this.createdAt,
    required this.expiresAt,
    required this.minEngineVersion,
    required this.taxonomyVersion,
    List<SenderEntry> senders = const [],
    List<IgnoreRule> ignoreRules = const [],
    List<Rule> rules = const [],
    List<CounterpartyPurpose> counterpartyPurposes = const [],
    List<LinkRule> linkRules = const [],
    List<CategoryRule> categoryRules = const [],
    List<MerchantAlias> merchantAliases = const [],
    this.solverPack,
    this.signature,
  })  : senders = List.unmodifiable(senders),
        ignoreRules = List.unmodifiable(ignoreRules),
        rules = List.unmodifiable(rules),
        counterpartyPurposes = List.unmodifiable(counterpartyPurposes),
        linkRules = List.unmodifiable(linkRules),
        categoryRules = List.unmodifiable(categoryRules),
        merchantAliases = List.unmodifiable(merchantAliases);

  static const String schemaId = 'pandapay.sms.rules/2';

  /// Parses and validates [json]; throws a [ContractException] on violations.
  factory RuleBundle.fromJson(Map<String, Object?> json) {
    final r = validateBundleJson(json);
    if (!r.ok) throw ContractException(r.errors);
    return RuleBundle(
      schema: json['schema'] as String,
      bundleVersion: (json['bundleVersion'] as num).toInt(),
      createdAt: parseUtc(json['createdAt'] as String),
      expiresAt: parseUtc(json['expiresAt'] as String),
      minEngineVersion: json['minEngineVersion'] as String,
      taxonomyVersion: (json['taxonomyVersion'] as num).toInt(),
      senders: _list(json['senders'], SenderEntry.fromJson),
      ignoreRules: _list(json['ignoreRules'], IgnoreRule.fromJson),
      rules: _list(json['rules'], Rule.fromJson),
      counterpartyPurposes: _list(json['counterpartyPurposes'], CounterpartyPurpose.fromJson),
      linkRules: _list(json['linkRules'], LinkRule.fromJson),
      categoryRules: _list(json['categoryRules'], CategoryRule.fromJson),
      merchantAliases: _list(json['merchantAliases'], MerchantAlias.fromJson),
      solverPack: json['solverPack'] == null
          ? null
          : Map<String, Object?>.of((json['solverPack'] as Map).cast<String, Object?>()),
      signature: json['signature'] == null
          ? null
          : BundleSignature.fromJson(json['signature'] as Json),
    );
  }

  final String schema;

  /// 0 is the placeholder baseline: no rules, no signature.
  final int bundleVersion;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String minEngineVersion;
  final int taxonomyVersion;
  final List<SenderEntry> senders;
  final List<IgnoreRule> ignoreRules;
  final List<Rule> rules;
  final List<CounterpartyPurpose> counterpartyPurposes;
  final List<LinkRule> linkRules;
  final List<CategoryRule> categoryRules;
  final List<MerchantAlias> merchantAliases;

  /// The vocabulary of the evidence solver (tier 2, `pandapay.sms.solver/1`), or
  /// null. Kept as plain JSON here; the solver library parses and checks it.
  /// Left out of `toJson` when null, so a bundle without one signs exactly as before.
  final Map<String, Object?>? solverPack;

  /// Null only for `bundleVersion` 0.
  final BundleSignature? signature;

  /// The engine treats version 0 as "no rules".
  bool get isPlaceholder => bundleVersion == 0;

  /// The bytes the signature covers: canonical JSON of the bundle without
  /// `signature`, UTF-8.
  String get signedPayload => canonicalJson(toJson()..remove('signature'));

  @override
  Json toJson() => {
        'schema': schema,
        'bundleVersion': bundleVersion,
        'createdAt': formatUtc(createdAt),
        'expiresAt': formatUtc(expiresAt),
        'minEngineVersion': minEngineVersion,
        'taxonomyVersion': taxonomyVersion,
        'senders': [for (final s in senders) s.toJson()],
        'ignoreRules': [for (final r in ignoreRules) r.toJson()],
        'rules': [for (final r in rules) r.toJson()],
        'counterpartyPurposes': [for (final c in counterpartyPurposes) c.toJson()],
        'linkRules': [for (final l in linkRules) l.toJson()],
        'categoryRules': [for (final c in categoryRules) c.toJson()],
        'merchantAliases': [for (final m in merchantAliases) m.toJson()],
        if (solverPack != null) 'solverPack': solverPack,
        'signature': signature?.toJson(),
      };

  /// Checks this bundle against the contract.
  ValidationResult validate() => validateBundleJson(toJson());
}
