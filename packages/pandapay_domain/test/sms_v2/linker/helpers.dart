import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';

/// The baseline link rules (03d), read from the repo.
List<LinkRule> baselineLinkRules() => [
  for (final j
      in jsonDecode(
            File('../../rules/sms/v2/link_rules.json').readAsStringSync(),
          )
          as List)
    LinkRule.fromJson((j as Map).cast<String, Object?>()),
];

/// Amazon Pay is a partial-visibility wallet; Paytm is a normal one.
final testSenders = [
  SenderEntry(
    brand: 'AMAZON',
    issuerSlug: 'amazonpay',
    issuerKind: IssuerKind.wallet,
    walletSpendVisibility: WalletSpendVisibility.partial,
  ),
  SenderEntry(
    brand: 'PAYTM',
    issuerSlug: 'paytm',
    issuerKind: IssuerKind.wallet,
    walletSpendVisibility: WalletSpendVisibility.sms,
  ),
];

const testTopups = [
  CounterpartyPurpose(
    id: 'CPP-PAYTM-TOPUP',
    vpaPattern: r'^add-?money@',
    purpose: MovementPurpose.walletTopup,
    targetInstrument: TargetInstrument(
      kind: InstrumentKind.wallet,
      issuerSlug: 'paytm',
    ),
  ),
  CounterpartyPurpose(
    id: 'CPP-AMAZONPAY-TOPUP',
    vpaPattern: r'^amazonpay@',
    purpose: MovementPurpose.walletTopup,
    targetInstrument: TargetInstrument(
      kind: InstrumentKind.wallet,
      issuerSlug: 'amazonpay',
    ),
  ),
];

/// A clock far after every synthetic fact, so receipt windows have passed.
final testNow = DateTime.utc(2027, 6, 1);

RuleDrivenLinker testLinker({DateTime? now}) => RuleDrivenLinker(
  senders: testSenders,
  counterpartyPurposes: testTopups,
  clock: () => now ?? testNow,
);

int _seq = 0;

String hex64(String seed) => sha256.convert(utf8.encode(seed)).toString();

// ------------------------------------------------------------ instruments

Instrument instrument(
  String id,
  InstrumentKind kind,
  String issuer,
  String? mask, {
  InstrumentStatus status = InstrumentStatus.confirmed,
}) {
  final t = DateTime.utc(2026, 1, 1);
  return Instrument(
    instrumentId: id,
    kind: kind,
    issuerSlug: issuer,
    maskDigits: mask,
    displayName: '$issuer $mask',
    status: status,
    firstSeenAt: t,
    lastSeenAt: t,
    evidenceCount: 1,
  );
}

final hdfcAcct = instrument(
  '00000000-0000-4000-8000-000000000001',
  InstrumentKind.bankAccount,
  'hdfc',
  '1234',
);
final hdfcSaving = instrument(
  '00000000-0000-4000-8000-000000000002',
  InstrumentKind.bankAccount,
  'hdfc',
  '9999',
);
final hdfcCard = instrument(
  '00000000-0000-4000-8000-000000000003',
  InstrumentKind.creditCard,
  'hdfc',
  '5678',
);
final iciciCard = instrument(
  '00000000-0000-4000-8000-000000000004',
  InstrumentKind.creditCard,
  'icici',
  '9012',
);
final paytmWallet = instrument(
  '00000000-0000-4000-8000-000000000005',
  InstrumentKind.wallet,
  'paytm',
  null,
);

final allInstruments = {
  for (final i in [hdfcAcct, hdfcSaving, hdfcCard, iciciCard, paytmWallet])
    i.instrumentId: i,
};

InstrumentMention on(Instrument i) => InstrumentMention(
  kind: i.kind,
  issuerSlug: i.issuerSlug,
  maskDigits: i.maskDigits,
  maskLength: i.maskDigits?.length,
);

// ------------------------------------------------------------------ facts

Map<String, Object?> _envelope(
  String type, {
  required String at,
  String? occurredAt,
  InstrumentMention? instrument,
  Map<String, Object?>? counterparty,
  List<Map<String, Object?>> amounts = const [],
  Map<String, String> references = const {},
  required Map<String, Object?> attrs,
  String? sourceKey,
  String ruleId = 'SYN',
  double confidence = 0.97,
}) {
  final n = _seq++;
  final key = sourceKey ?? 'sms:linker:$n';
  return {
    'contractVersion': '2.0',
    'factId': hex64('$key|$ruleId|$n'),
    'sourceKey': key,
    'factType': type,
    'observedAt': at,
    'occurredAt': occurredAt,
    'instrument': instrument?.toJson(),
    'counterparty': counterparty,
    'amounts': amounts,
    'references': references,
    'attrs': attrs,
    'provenance': {
      'engine': 'rules',
      'ruleId': ruleId,
      'ruleVersion': 1,
      'bundleVersion': 1,
      'engineVersion': '2.0.0',
      'appVersion': '1.0.0+1',
    },
    'evidence': <Object?>[],
    'confidence': confidence,
  };
}

Map<String, Object?> party({
  String? name,
  String? vpa,
  String? kind,
  String? mask,
}) => {'name': name, 'vpa': vpa, 'kind': kind, 'accountMask': mask};

MovementFact move(
  String direction,
  String purpose,
  int minor, {
  required String at,
  String? occurredAt,
  Instrument? inst,
  InstrumentMention? mention,
  Map<String, Object?>? counterparty,
  Map<String, String> references = const {},
  String rail = 'unknown',
  String? mandateRef,
  bool? evidenceOnly,
  String? sourceKey,
  String ruleId = 'SYN',
}) =>
    Fact.fromJson(
          _envelope(
            'movement',
            at: at,
            occurredAt: occurredAt,
            instrument: mention ?? (inst == null ? null : on(inst)),
            counterparty: counterparty,
            amounts: [
              {'role': 'posted', 'minor': minor, 'unit': 'INR'},
            ],
            references: references,
            attrs: {
              'direction': direction,
              'purpose': purpose,
              'rail': rail,
              'mandateRef': ?mandateRef,
              'evidenceOnly': ?evidenceOnly,
            },
            sourceKey: sourceKey,
            ruleId: ruleId,
          ),
        )
        as MovementFact;

MovementFact debit(
  String purpose,
  int minor, {
  required String at,
  Instrument? inst,
  Map<String, Object?>? counterparty,
  Map<String, String> references = const {},
  String? mandateRef,
  bool? evidenceOnly,
  InstrumentMention? mention,
  String? sourceKey,
  String ruleId = 'SYN',
  String? occurredAt,
}) => move(
  'debit',
  purpose,
  minor,
  at: at,
  inst: inst,
  counterparty: counterparty,
  references: references,
  mandateRef: mandateRef,
  evidenceOnly: evidenceOnly,
  mention: mention,
  sourceKey: sourceKey,
  ruleId: ruleId,
  occurredAt: occurredAt,
);

MovementFact credit(
  String purpose,
  int minor, {
  required String at,
  Instrument? inst,
  Map<String, Object?>? counterparty,
  Map<String, String> references = const {},
  bool? evidenceOnly,
  InstrumentMention? mention,
  String? occurredAt,
}) => move(
  'credit',
  purpose,
  minor,
  at: at,
  inst: inst,
  counterparty: counterparty,
  references: references,
  evidenceOnly: evidenceOnly,
  mention: mention,
  occurredAt: occurredAt,
);

HoldFact hold(
  String phase,
  int minor, {
  required String at,
  Instrument? inst,
  String purpose = 'ipo_asba',
  String? issue,
  String? sourceKey,
}) =>
    Fact.fromJson(
          _envelope(
            'hold',
            at: at,
            instrument: inst == null ? null : on(inst),
            amounts: [
              {
                'role': phase == 'released' ? 'released' : 'held',
                'minor': minor,
                'unit': 'INR',
              },
            ],
            attrs: {'phase': phase, 'purpose': purpose, 'issueName': ?issue},
            sourceKey: sourceKey,
          ),
        )
        as HoldFact;

MandateFact mandate(
  String phase, {
  required String at,
  String? merchant,
  int? ceiling,
  bool? oneTime,
  String? purpose,
  Map<String, String> references = const {},
  Instrument? inst,
  String? sourceKey,
}) =>
    Fact.fromJson(
          _envelope(
            'mandate',
            at: at,
            instrument: inst == null ? null : on(inst),
            amounts: [
              if (ceiling != null)
                {'role': 'ceiling', 'minor': ceiling, 'unit': 'INR'},
            ],
            references: references,
            attrs: {
              'phase': phase,
              'merchantName': ?merchant,
              'oneTime': ?oneTime,
              'mandatePurpose': ?purpose,
            },
            sourceKey: sourceKey,
          ),
        )
        as MandateFact;

Fact reward(int points, {required String at, Instrument? inst}) =>
    Fact.fromJson(
      _envelope(
        'reward',
        at: at,
        instrument: inst == null ? null : on(inst),
        amounts: [
          {'role': 'points_earned', 'minor': points, 'unit': 'POINTS'},
        ],
        attrs: const {},
      ),
    );

// ------------------------------------------------------------------ running

/// Links [facts] in one call with an empty history.
LinkResult linkAll(
  List<Fact> facts, {
  List<LinkRule>? rules,
  RuleDrivenLinker? linker,
  Map<String, Instrument>? instruments,
}) => (linker ?? testLinker()).link(
  incoming: facts,
  context: RuleLinkContext(
    recentFacts: const [],
    openEvents: const [],
    instrumentsById: instruments ?? allInstruments,
  ),
  rules: rules ?? baselineLinkRules(),
);

/// Every event a result holds (created and updated).
List<Event> eventsOf(LinkResult r) => [...r.created, ...r.updated];

/// Type and sorted leg roles, the way the golden tool compares events.
String shape(Event e) {
  final roles = [for (final l in e.legs) l.role.wire]..sort();
  return '${e.type.wire}[${roles.join(',')}]';
}

List<String> shapes(LinkResult r) =>
    [for (final e in eventsOf(r)) shape(e)]..sort();

/// Simulates the store: an event upserted by id, newest wins.
class MemoryEvents {
  final byId = <String, Event>{};
  void apply(LinkResult r) {
    for (final e in eventsOf(r)) {
      byId[e.eventId] = e;
    }
  }

  List<Event> get all => [...byId.values];
  List<Event> get open => [
    for (final e in all)
      if (e.status == EventStatus.awaitingLeg) e,
  ];
}

/// A fact counted as money in more than one event, or a receipt counted at all.
List<String> doubleCounted(
  Iterable<Event> events,
  Map<String, Fact> factsById,
) {
  const money = {
    LegRole.debitLeg,
    LegRole.creditLeg,
    LegRole.charge,
    LegRole.reversal,
  };
  final seen = <String, int>{};
  final out = <String>[];
  for (final e in events) {
    for (final l in e.legs) {
      if (!money.contains(l.role)) continue;
      final f = factsById[l.factId];
      if (f is MovementFact && f.evidenceOnly == true)
        out.add('receipt ${l.factId} counted');
      seen.update(l.factId, (v) => v + 1, ifAbsent: () => 1);
    }
  }
  for (final e in seen.entries) {
    if (e.value > 1) out.add('fact ${e.key} is money in ${e.value} events');
  }
  return out;
}
