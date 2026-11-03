import 'package:pandapay_domain/sms_v2_template.dart';

import 'family.dart';

/// One message of a case or scenario.
class GoldenMessage {
  const GoldenMessage({
    required this.sender,
    required this.body,
    required this.observedAt,
  });

  factory GoldenMessage.fromJson(Map<String, dynamic> j) => GoldenMessage(
    sender: j['sender'] as String,
    body: j['body'] as String,
    observedAt: DateTime.parse(j['observedAt'] as String).toUtc(),
  );

  final String sender;
  final String body;
  final DateTime observedAt;

  Map<String, Object?> toJson() => {
    'sender': sender,
    'body': body,
    'observedAt': observedAt.toUtc().toIso8601String(),
  };
}

/// A labeled single-template case: `tools/sms_golden/cases/<brand>/<hash>.json`.
///
/// `expect.facts` is a list of partial Facts (listed fields must match,
/// unlisted ones are ignored). With several messages the facts of all messages
/// are pooled before matching. `expect.ignore` means the message is not
/// financial; `expect.unknown` means no rule should claim it (a review item).
class GoldenCase {
  GoldenCase({
    required this.id,
    required this.templateHash,
    required this.weight,
    required this.source,
    required this.messages,
    required this.expectFacts,
    required this.ignore,
    required this.unknown,
    String? family,
    this.path,
  }) : brand = smsTemplateBrand(messages.first.sender),
       family = family ?? guessFamily(messages.first.body);

  factory GoldenCase.fromJson(Map<String, dynamic> j, {String? path}) {
    final expect = (j['expect'] as Map?)?.cast<String, dynamic>() ?? const {};
    final messages = [
      for (final m in (j['messages'] as List))
        GoldenMessage.fromJson((m as Map).cast<String, dynamic>()),
    ];
    if (messages.isEmpty) {
      throw FormatException('case ${j['id']} has no messages');
    }
    return GoldenCase(
      id: j['id'] as String,
      templateHash: j['templateHash'] as String? ?? '',
      weight: (j['weight'] as num?)?.toDouble() ?? 1,
      source: j['source'] as String? ?? 'synthetic',
      messages: messages,
      expectFacts: [
        for (final f in (expect['facts'] as List? ?? const []))
          (f as Map).cast<String, dynamic>(),
      ],
      ignore: expect['ignore'] == true,
      unknown: expect['unknown'] == true,
      family: j['family'] as String?,
      path: path,
    );
  }

  final String id;
  final String templateHash;
  final double weight;
  final String source;
  final List<GoldenMessage> messages;
  final List<Map<String, dynamic>> expectFacts;
  final bool ignore;
  final bool unknown;
  final String brand;
  final String family;
  final String? path;

  /// A financial case is one that is not expected to be ignored.
  bool get financial => !ignore;
}

/// A multi-message scenario: `tools/sms_golden/scenarios/*.json`.
class GoldenScenario {
  GoldenScenario({
    required this.id,
    required this.description,
    required this.knownInstruments,
    required this.messages,
    required this.events,
    required this.instruments,
    required this.totals,
    required this.categories,
    this.path,
  });

  factory GoldenScenario.fromJson(Map<String, dynamic> j, {String? path}) {
    final expect = (j['expect'] as Map?)?.cast<String, dynamic>() ?? const {};
    List<Map<String, dynamic>> maps(Object? v) => [
      for (final e in (v as List? ?? const []))
        (e as Map).cast<String, dynamic>(),
    ];
    return GoldenScenario(
      id: j['id'] as String,
      description: j['description'] as String? ?? '',
      knownInstruments: maps(j['knownInstruments']),
      messages: [
        for (final m in (j['messages'] as List))
          GoldenMessage.fromJson((m as Map).cast<String, dynamic>()),
      ],
      events: maps(expect['events']),
      instruments: maps(expect['instruments']),
      totals: (expect['totals'] as Map?)?.cast<String, dynamic>(),
      categories: maps(expect['categories']),
      path: path,
    );
  }

  final String id;
  final String description;
  final List<Map<String, dynamic>> knownInstruments;
  final List<GoldenMessage> messages;
  final List<Map<String, dynamic>> events;
  final List<Map<String, dynamic>> instruments;
  final Map<String, dynamic>? totals;
  final List<Map<String, dynamic>> categories;
  final String? path;
}

/// All cases and scenarios under a golden directory.
class GoldenBundle {
  GoldenBundle(this.cases, this.scenarios);

  final List<GoldenCase> cases;
  final List<GoldenScenario> scenarios;
}
