import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/sms_v2.dart';
import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_intake_repository.dart';
import '../category/category_snapshot.dart';
import '../pipeline/sms_v2_pipeline.dart';
import '../storage/instrument_store.dart';
import '../storage/fact_store.dart';
import '../storage/event_store.dart';
import '../storage/sync_state_store.dart';
import 'personal_rule_engine.dart';
import 'personal_rule_store.dart';

/// UTF-16 offsets in the representative captured SMS, not replacement values.
class PersonalFieldSpan {
  const PersonalFieldSpan(this.start, this.end);
  final int start, end;
  String text(String body) {
    if (start < 0 || end <= start || end > body.length) {
      throw ArgumentError('Select a field from the message');
    }
    return body.substring(start, end);
  }
}

class PersonalFormatChoice {
  const PersonalFormatChoice({
    required this.sourceKey,
    required this.instrumentId,
    required this.amount,
    this.merchant,
    this.date,
    this.dateFormat,
    this.type = EventType.purchase,
    this.amountRole = AmountRole.posted,
    this.rail = Rail.unknown,
  });
  final String sourceKey, instrumentId;
  final PersonalFieldSpan amount;
  final PersonalFieldSpan? merchant, date;
  final String? dateFormat;
  final EventType type;
  final AmountRole amountRole;
  final Rail rail;
}

const personalFormatTypes = [
  EventType.purchase,
  EventType.income,
  EventType.refund,
  EventType.ownTransfer,
  EventType.investment,
  EventType.ipoApplication,
];
const personalDateFormats = [
  'yyyy-MM-dd',
  'dd-MM-yyyy',
  'dd/MM/yyyy',
  'dd-MM-yy',
  'dd/MM/yy',
  'dd-MMM-yyyy',
  'dd-MMM-yy',
  'dd MMM yyyy',
  'yyyy-MM-dd:HH:mm:ss',
];

/// Builds exact literal wording with only the user's selected fields varying.
PersonalRule buildPersonalRule({
  required SmsMessage message,
  required PersonalFormatChoice choice,
  required Instrument instrument,
}) {
  if (message.sourceKey != choice.sourceKey ||
      instrument.instrumentId != choice.instrumentId ||
      instrument.status != InstrumentStatus.confirmed ||
      instrument.maskDigits == null) {
    throw ArgumentError(
      'Choose a confirmed account or card with masked digits',
    );
  }
  if (message.body.length > 1800 ||
      !personalFormatTypes.contains(choice.type)) {
    throw ArgumentError('This format cannot be taught here');
  }
  final amountText = choice.amount.text(message.body);
  if (!RegExp(r'^[0-9][0-9,]*(?:\.[0-9]{1,2})?$').hasMatch(amountText) ||
      (parseAmountIndian(amountText) ?? 0) <= 0) {
    throw ArgumentError(
      'Select the positive printed amount, without the currency sign',
    );
  }
  if (choice.type == EventType.ipoApplication
      ? ![AmountRole.held, AmountRole.released].contains(choice.amountRole)
      : choice.amountRole != AmountRole.posted) {
    throw ArgumentError('Choose posted money, or an IPO held/released amount');
  }
  if (choice.date != null &&
      (!personalDateFormats.contains(choice.dateFormat) ||
          parseDate(choice.date!.text(message.body), [choice.dateFormat!]) ==
              null)) {
    throw ArgumentError('Choose the printed date and its matching format');
  }
  if (choice.merchant != null &&
      (choice.merchant!.text(message.body).trim().isEmpty ||
          choice.merchant!.end - choice.merchant!.start > 120)) {
    throw ArgumentError('Select a merchant name of up to 120 characters');
  }
  final fields = <({String name, PersonalFieldSpan span, String pattern})>[
    (
      name: 'amount',
      span: choice.amount,
      pattern: r'[0-9][0-9,]{0,17}(?:\.[0-9]{1,2})?',
    ),
    if (choice.merchant != null)
      (name: 'merchant', span: choice.merchant!, pattern: r'[^\r\n]{1,120}?'),
    if (choice.date != null)
      (name: 'date', span: choice.date!, pattern: r'[0-9A-Za-z:/ .-]{6,30}'),
  ];
  final mask = instrument.maskDigits!;
  final masks = RegExp('(?<![0-9])${RegExp.escape(mask)}(?![0-9])')
      .allMatches(message.body)
      .where(
        (m) =>
            !fields.any((f) => m.start < f.span.end && m.end > f.span.start) &&
            RegExp(
              r'(?:card|a/?c|acct|account|ending|xx|\*)[^\r\n]{0,16}$',
              caseSensitive: false,
            ).hasMatch(message.body.substring(0, m.start)),
      )
      .toList();
  if (masks.length != 1) {
    throw ArgumentError(
      'The selected account mask must appear once beside an account or card label',
    );
  }
  fields.add((
    name: 'mask',
    span: PersonalFieldSpan(masks.single.start, masks.single.end),
    pattern: RegExp.escape(mask),
  ));
  fields.sort((a, b) => a.span.start.compareTo(b.span.start));
  String literal(String value) {
    // References vary per payment; account masks remain exact literals. Only
    // explicitly labelled reference digits can vary outside selected fields.
    final out = StringBuffer();
    var cursor = 0;
    for (final reference in RegExp(
      r'\b(?:ref(?:erence)?|utr|rrn|txn\s+id)\s*(?:no\.?\s*)?[:#-]?\s*([0-9]{6,24})',
      caseSensitive: false,
    ).allMatches(value)) {
      final digits = reference.group(1)!;
      final start = reference.end - digits.length;
      out.write(RegExp.escape(value.substring(cursor, start)));
      out.write(r'[0-9]{6,24}');
      cursor = reference.end;
    }
    out.write(RegExp.escape(value.substring(cursor)));
    return out.toString();
  }

  final pattern = StringBuffer('^');
  final example = StringBuffer();
  var offset = 0;
  for (final field in fields) {
    field.span.text(message.body);
    if (field.span.start < offset) {
      throw ArgumentError('Selected fields must not overlap');
    }
    pattern.write(literal(message.body.substring(offset, field.span.start)));
    example.write(message.body.substring(offset, field.span.start));
    example.write(switch (field.name) {
      'amount' => '1.00',
      'merchant' => 'SYNTHETIC PARTY',
      'date' => DateFormat(choice.dateFormat!).format(DateTime(2000, 1, 2)),
      _ => mask,
    });
    pattern.write('(?<${field.name}>${field.pattern})');
    offset = field.span.end;
  }
  pattern.write(literal(message.body.substring(offset)));
  example.write(message.body.substring(offset));
  pattern.write(r'$');
  if (lintRegexDialect(pattern.toString(), '').isNotEmpty) {
    throw ArgumentError('This format is too complex to save');
  }
  final brand = normalizeSenderBrand(message.sender).brand;
  final purpose = switch (choice.type) {
    EventType.purchase => 'purchase',
    EventType.income => 'salary',
    EventType.refund => 'refund',
    EventType.ownTransfer => 'transfer',
    EventType.investment => 'investment',
    _ => null,
  };
  final config = {
    'sender': brand,
    'pattern': pattern.toString(),
    'instrument': instrument.instrumentId,
    'type': choice.type.wire,
    'role': choice.amountRole.wire,
    'dateFormat': choice.dateFormat,
    'rail': choice.rail.wire,
  };
  final id =
      'PERSONAL-${sha256.convert(utf8.encode(canonicalJson(config))).toString()}';
  final hold = choice.type == EventType.ipoApplication;
  final rule = Rule(
    id: id,
    version: 1,
    family: 'personal',
    senders: [brand],
    priority: 1000,
    match: RuleMatch(pattern: pattern.toString(), flags: ''),
    emit: [
      Emit(
        factType: hold ? FactType.hold : FactType.movement,
        attrs: hold
            ? {
                'phase': choice.amountRole == AmountRole.held
                    ? 'placed'
                    : 'released',
                'purpose': 'ipo_asba',
              }
            : {
                'direction':
                    [EventType.income, EventType.refund].contains(choice.type)
                    ? 'credit'
                    : 'debit',
                'purpose': purpose,
                'rail': choice.rail.wire,
              },
        amounts: [
          EmitAmount(role: choice.amountRole, from: 'amount', unit: 'INR'),
        ],
        occurredAt: choice.date == null
            ? null
            : {
                'from': 'date',
                'formats': [choice.dateFormat],
              },
        instrument: {
          'kind': instrument.kind.wire,
          'issuerSlug': instrument.issuerSlug,
          'maskFrom': 'mask',
        },
        counterparty:
            choice.merchant == null && choice.type != EventType.ownTransfer
            ? null
            : {
                if (choice.merchant != null) 'nameFrom': 'merchant',
                'kind': choice.type == EventType.ownTransfer
                    ? 'own'
                    : 'merchant',
              },
      ),
    ],
    confidence: 1,
    examples: [
      RuleExample(
        sender: brand,
        body: example.toString(),
        expectFactTypes: [hold ? FactType.hold : FactType.movement],
      ),
      RuleExample(
        sender: brand,
        body: 'Not this format: ${example.toString()}',
        expectFactTypes: const [],
      ),
    ],
    status: RuleStatus.active,
    createdBy: 'user',
    updatedAt: message.observedAt,
  );
  return PersonalRule(rule: rule, instrumentId: instrument.instrumentId);
}

class PersonalFormatService {
  const PersonalFormatService({
    required this.financial,
    required this.namespace,
    required this.bundle,
    required this.appVersion,
    this.categoryIdBySlug = const {},
    this.replaceReading,
  });
  final void Function(SmsMessage, Fact, EventType, String)? replaceReading;
  final FinancialStore financial;
  final String namespace, appVersion;
  final RuleBundle bundle;
  final Map<String, String> categoryIdBySlug;
  List<String> apply({
    required PersonalFormatChoice choice,
    required Iterable<String> sourceKeys,
  }) {
    final sources = sourceKeys.toSet();
    if (sources.isEmpty ||
        sources.length > 20000 ||
        !sources.contains(choice.sourceKey)) {
      throw ArgumentError('Choose up to 20,000 messages including the example');
    }
    final db = financial.database.db;
    final intake = SmsIntakeRepository(financial.database);
    SmsMessage captured(String source) {
      final raw = intake.capturedById(namespace, source);
      if (raw == null) {
        throw ArgumentError(
          'The original message is unavailable in this account',
        );
      }
      final decision = intake.decision(namespace, source);
      if (decision?.policyVersion != 'v2' ||
          (decision?.decision != 'unknown' &&
              !(sources.length > 1 && decision?.decision == 'matched'))) {
        throw ArgumentError('Only unread financial formats can be taught');
      }
      return SmsMessage(
        sender: raw.message.sender,
        body: raw.message.body,
        observedAt: raw.message.receivedAt.toUtc(),
        sourceKey: source,
      );
    }

    final messages = [for (final source in sources) captured(source)];
    final instruments = InstrumentStore(db, namespace: namespace);
    final instrument = instruments.get(choice.instrumentId);
    if (instrument == null) {
      throw ArgumentError('The account or card is unavailable');
    }
    final built = buildPersonalRule(
      message: messages.firstWhere((m) => m.sourceKey == choice.sourceKey),
      choice: choice,
      instrument: instrument,
    );
    final rule = PersonalRule(
      instrumentId: built.instrumentId,
      rule: Rule.fromJson({
        ...built.rule.toJson(),
        'senders': [
          normalizeSenderBrand(
            messages.firstWhere((m) => m.sourceKey == choice.sourceKey).sender,
            bundle.senders,
          ).brand,
        ],
      }),
    );
    final state = SyncStateStore(db, namespace: namespace);
    // Stage only in memory until every captured source passes the exact rule.
    final staged = PersonalRuleStore(state);
    final validation = RuleEngine();
    final local = RuleBundle(
      bundleVersion: 0,
      createdAt: bundle.createdAt,
      expiresAt: bundle.expiresAt,
      minEngineVersion: bundle.minEngineVersion,
      taxonomyVersion: bundle.taxonomyVersion,
      senders: bundle.senders,
      rules: [rule.rule],
    );
    final readings = <String, Fact>{};
    for (final message in messages) {
      final safety = validation.interpretDetailed(
        message,
        bundle,
        appVersion: appVersion,
      );
      final parsed = validation.interpretDetailed(
        message,
        local,
        appVersion: appVersion,
      );
      if (safety.result.outcome == InterpretOutcome.ignored ||
          parsed.result.outcome != InterpretOutcome.matched ||
          (choice.date != null &&
              parsed.result.facts.any((fact) => fact.occurredAt == null)) ||
          parsed.result.facts.any(
            (f) => f.instrument?.maskDigits != instrument.maskDigits,
          )) {
        throw ArgumentError(
          'Every selected message must match the chosen sender, account and printed fields',
        );
      }
      readings[message.sourceKey] = parsed.result.facts.single;
    }
    financial.batch(() {
      db.execute('SAVEPOINT personal_format');
      try {
        staged.save(rule);
        final categories = CategorySnapshot.load(
          financial.database,
          namespace: namespace,
          aliases: bundle.merchantAliases,
        );
        final pipeline = SmsV2Pipeline(
          financial: financial,
          namespace: namespace,
          bundle: bundle,
          appVersion: appVersion,
          engine: PersonalRuleEngine(store: staged, instruments: instruments),
          revision: '${bundle.bundleVersion}:personal:${staged.revision}',
          userRules: categories.userRules,
          confirmedHistory: categories.confirmedHistory,
          categoryIdBySlug: categoryIdBySlug,
        );
        final pending = <SmsMessage>[];
        for (final message in messages) {
          final oldFacts = FactStore(
            db,
            namespace: namespace,
          ).forSource(message.sourceKey);
          final events = EventStore(
            db,
            namespace: namespace,
          ).findByFactIds(oldFacts.map((f) => f.factId));
          if (events.isNotEmpty) {
            if (replaceReading == null || events.length != 1) {
              throw ArgumentError(
                'Resolve the matching payment before fixing its format',
              );
            }
            replaceReading!(
              message,
              readings[message.sourceKey]!,
              choice.type,
              instrument.instrumentId,
            );
          } else {
            db.execute(
              'DELETE FROM sms_source_decisions WHERE namespace=? AND source_key=?',
              [namespace, message.sourceKey],
            );
            pending.add(message);
          }
        }
        var processed = messages.length - pending.length;
        for (var start = 0; start < pending.length; start += 500) {
          processed += pipeline.processBatch(
            pending.sublist(start, (start + 500).clamp(0, pending.length)),
            backfill: true,
          );
        }
        if (processed != messages.length)
          throw StateError(
            'A selected message changed before it could be saved',
          );
        for (final message in messages) {
          final saved = state.get('trace:${message.sourceKey}');
          if (saved != null) {
            final trace = (jsonDecode(saved) as Map).cast<String, Object?>();
            trace['userChoices'] = ['missing'];
            trace['instruments'] = [
              for (final row in trace['instruments'] as List? ?? const [])
                {
                  ...(row as Map).cast<String, Object?>(),
                  'step': 'user_choice',
                },
            ];
            state.put('trace:${message.sourceKey}', jsonEncode(trace));
          }
        }
        db.execute('RELEASE personal_format');
        financial.notifyExternalChanges(namespace, const [
          'needs_review',
          'transactions',
          'observations',
        ]);
      } catch (_) {
        db.execute('ROLLBACK TO personal_format');
        db.execute('RELEASE personal_format');
        rethrow;
      }
    });
    return sources.toList();
  }
}
