import '../storage/stats_store.dart';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:pandapay_domain/sms_v2_template.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_learning_feedback.dart';
import '../category/category_snapshot.dart';
import '../category/user_category_rules.dart';
import '../ledger/projection_writer.dart';
import '../pipeline/trace.dart';
import '../personal/personal_format_service.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import '../storage/outbox_store.dart';
import '../storage/sync_state_store.dart';
import '../sync/learning_signals.dart';

/// A device-local correction. [corrected] uses contract field names such as
/// amountMinor, occurredAt, merchantName, instrumentId, category, or legs.
class SmsCorrection {
  const SmsCorrection({
    required this.id,
    required this.sourceKey,
    required this.kind,
    required this.corrected,
    required this.trace,
    this.factIds = const [],
    this.eventId,
    this.message,
    this.extractedMaskCorrect = true,
    this.sharedLearningConsent = false,
    this.reportCase = true,
  });

  final String id, sourceKey;
  final CorrectionKind kind;
  final Map<String, Object?> corrected;
  final DecisionTrace trace;
  final List<String> factIds;
  final String? eventId;
  final SmsMessage? message;
  final bool extractedMaskCorrect, sharedLearningConsent;

  /// A confirmation locks the reading without reporting a false defect.
  final bool reportCase;
}

/// Applies the local effect and queues its review case in the same savepoint.
class CorrectionsService {
  CorrectionsService({
    required this.financial,
    required this.namespace,
    required this.bundle,
    this.categoryIdBySlug = const {},
  });

  final FinancialStore financial;
  final String namespace;
  final RuleBundle bundle;
  final Map<String, String> categoryIdBySlug;
  late final _db = financial.database.db;
  late final _facts = FactStore(_db, namespace: namespace);
  late final _events = EventStore(_db, namespace: namespace);
  late final _ledger = LedgerStore(_db, namespace: namespace);
  late final _outbox = OutboxStore(_db, namespace: namespace);

  List<String> teachFormat({
    required PersonalFormatChoice choice,
    required Iterable<String> sourceKeys,
    required String appVersion,
  }) => PersonalFormatService(
    financial: financial,
    namespace: namespace,
    bundle: bundle,
    appVersion: appVersion,
    categoryIdBySlug: categoryIdBySlug,
    replaceReading: _replacePersonalReading,
  ).apply(choice: choice, sourceKeys: sourceKeys);

  void _replacePersonalReading(
    SmsMessage message,
    Fact reading,
    EventType type,
    String instrumentId,
  ) {
    final originals = _facts.forSource(message.sourceKey);
    final original =
        originals.whereType<MovementFact>().firstOrNull ??
        originals.whereType<HoldFact>().firstOrNull;
    final events = _events.findByFactIds(originals.map((f) => f.factId));
    if (original == null || events.length != 1)
      throw ArgumentError('One stored payment is required');
    apply(
      SmsCorrection(
        id: sha256
            .convert(
              utf8.encode(
                'personal|${canonicalJson(reading.toJson())}|${type.wire}',
              ),
            )
            .toString(),
        sourceKey: message.sourceKey,
        message: message,
        factIds: [original.factId],
        eventId: events.single.eventId,
        kind: CorrectionKind.wrongKind,
        reportCase: false,
        corrected: {
          'eventType': type.wire,
          '_personalReading': reading.toJson(),
          '_personalInstrumentId': instrumentId,
        },
        trace: DecisionTrace(
          appVersion: reading.provenance.appVersion,
          engineVersion: reading.provenance.engineVersion,
          bundleVersion: bundle.bundleVersion,
          outcome: 'matched',
          facts: originals,
          event: events.single,
        ),
      ),
    );
  }

  void apply(SmsCorrection correction) {
    if (correction.id.isEmpty) {
      throw ArgumentError('Correction id is required');
    }
    final localId = 'correction:${correction.id}';
    if (_db.select(
      'SELECT 1 FROM v2_review_items WHERE namespace=? AND review_id=?',
      [namespace, localId],
    ).isNotEmpty) {
      return;
    }
    final originalFacts = {
      for (final id in correction.factIds)
        id:
            _facts.get(id) ??
            (throw ArgumentError('Fact is not in this account')),
    };
    if (originalFacts.values.any(
      (fact) => fact.sourceKey != correction.sourceKey,
    )) {
      throw ArgumentError('Fact source mismatch');
    }
    var event = correction.eventId == null
        ? null
        : _events.get(correction.eventId!);
    if (correction.eventId != null && event == null) {
      throw ArgumentError('Event is not in this account');
    }
    final eventFacts = <String, Fact>{
      if (event != null)
        for (final leg in event.legs) leg.factId: ?_facts.get(leg.factId),
    };
    final current = event == null
        ? null
        : moneyFactForEvent(event, eventFacts) ??
              event.legs
                  .where(
                    (leg) =>
                        leg.role != LegRole.original &&
                        leg.role != LegRole.duplicateNotice,
                  )
                  .map((leg) => eventFacts[leg.factId])
                  .nonNulls
                  .firstOrNull;
    final stage = correction.trace.stage(
      correction.kind,
      extractedMaskCorrect: correction.extractedMaskCorrect,
    );
    financial.batch(() {
      _db.execute('SAVEPOINT sms_v2_correction');
      try {
        final corrected = correction.corrected;
        final locked = <String, CategoryDecision>{};
        if (correction.kind == CorrectionKind.wrongCategory ||
            correction.kind == CorrectionKind.preferenceOnly) {
          final slug = corrected['category'] as String;
          final key = corrected['merchantKey'] as String;
          UserCategoryRules(
            financial.database,
            namespace: namespace,
          ).saveChoice(merchantKey: key, slug: slug);
          if (event != null) {
            locked[event!.eventId] = CategoryDecision(
              slug: slug,
              source: CategorySource.user,
              confidence: 1,
            );
          }
        } else if (correction.kind == CorrectionKind.notFinancial) {
          final message = correction.message;
          if (message == null || message.sourceKey != correction.sourceKey) {
            throw ArgumentError(
              'The original message is required for an ignore rule',
            );
          }
          SmsLearningFeedback(
            financial.database,
            namespace: namespace,
          ).recordFalseTransactionRule(
            sender: message.sender,
            body: message.body,
          );
          if (event != null) event = event!.copyWith(type: EventType.unknown);
        } else if (correction.kind == CorrectionKind.duplicate) {
          if (event == null) throw ArgumentError('An event is required');
          event = event!.copyWith(type: EventType.unknown);
        } else if (correction.kind == CorrectionKind.wrongInstrument &&
            !corrected.containsKey('targetInstrumentId')) {
          if (originalFacts.isEmpty) {
            throw ArgumentError('A source fact is required');
          }
          final instrumentId = corrected['instrumentId'] as String;
          final target = InstrumentStore(
            _db,
            namespace: namespace,
          ).get(instrumentId);
          if (target == null || target.status == InstrumentStatus.rejected) {
            throw ArgumentError('Instrument is not in this account');
          }
          final reassigned = {...originalFacts};
          if (current != null) reassigned[current.factId] = current;
          for (final fact in reassigned.values) {
            _db.execute(
              'UPDATE v2_facts SET instrument_id=? WHERE namespace=? AND fact_id=?',
              [instrumentId, namespace, fact.factId],
            );
          }
        } else if (correction.kind == CorrectionKind.wrongLink) {
          if (event == null) throw ArgumentError('An event is required');
          final legs = [
            for (final json in corrected['legs'] as List)
              EventLeg.fromJson((json as Map).cast<String, Object?>()),
          ];
          if (legs.isEmpty ||
              legs.any((leg) => _facts.get(leg.factId) == null)) {
            throw ArgumentError('All linked facts must be in this account');
          }
          event = event!.copyWith(
            legs: legs,
            type: corrected['eventType'] is String
                ? EventType.fromWire(corrected['eventType'] as String)
                : null,
          );
        } else if (correction.kind != CorrectionKind.missing) {
          if (event == null || originalFacts.length != 1) {
            throw ArgumentError('One source fact and event are required');
          }
          final original =
              current ??
              (throw ArgumentError('An active event fact is required'));
          final personalJson = corrected['_personalReading'];
          if (personalJson != null &&
              (correction.reportCase ||
                  correction.kind != CorrectionKind.wrongKind)) {
            throw ArgumentError('Personal format readings stay local');
          }
          final json = personalJson is Map
              ? personalJson.cast<String, Object?>()
              : original.toJson();
          final id = sha256
              .convert(utf8.encode('user|${correction.id}|${original.factId}'))
              .toString();
          final source = 'correction:${correction.id}';
          final patch = <String, Object?>{
            ...json,
            'factId': id,
            'sourceKey': source,
            'provenance': {
              ...original.provenance.toJson(),
              'engine': 'user',
              'ruleId': 'USER-CORRECTION',
              'ruleVersion': 1,
            },
            if (correction.kind == CorrectionKind.wrongDate)
              'occurredAt': corrected['occurredAt'],
            if (correction.kind == CorrectionKind.wrongMerchant)
              'counterparty': <String, Object?>{
                ...(original.counterparty ?? const Counterparty()).toJson(),
                'name': corrected['merchantName'],
              },
          };
          if (correction.kind == CorrectionKind.wrongAmount) {
            final amount = corrected['amountMinor'];
            if (amount is! int || amount <= 0) {
              throw ArgumentError('Positive paise required');
            }
            final role =
                corrected['amountRole'] as String? ??
                original.amounts
                    .where((value) => value.role == AmountRole.posted)
                    .firstOrNull
                    ?.role
                    .wire ??
                original.amounts.firstOrNull?.role.wire;
            if (role == null ||
                !original.amounts.any((value) => value.role.wire == role)) {
              throw ArgumentError('A printed amount role is required');
            }
            patch['amounts'] = [
              for (final value in original.amounts)
                {
                  ...value.toJson(),
                  if (value.role.wire == role) 'minor': amount,
                },
            ];
          }
          if (correction.kind == CorrectionKind.wrongInstrument &&
              corrected['targetInstrumentId'] is String) {
            final target = InstrumentStore(
              _db,
              namespace: namespace,
            ).get(corrected['targetInstrumentId'] as String);
            if (event!.type != EventType.cardBillPayment ||
                target?.kind != InstrumentKind.creditCard ||
                target?.status != InstrumentStatus.confirmed ||
                target?.maskDigits == null)
              throw ArgumentError(
                'Choose a confirmed credit card for this bill',
              );
            patch['counterparty'] = Counterparty(
              name: target!.issuerSlug,
              accountMask: target.maskDigits,
              kind: CounterpartyKind.own,
            ).toJson();
          }
          if (corrected['rail'] is String && original is MovementFact) {
            patch['attrs'] = {
              ...(patch['attrs'] as Map).cast<String, Object?>(),
              'rail': corrected['rail'],
            };
          }
          if (correction.kind == CorrectionKind.wrongDate &&
              DateTime.parse(
                corrected['occurredAt'] as String,
              ).isAfter(original.observedAt))
            throw ArgumentError(
              'A payment date cannot be later than its message',
            );
          final replacement = Fact.fromJson(patch);
          final previousInstrument =
              _db.select(
                    'SELECT instrument_id FROM v2_facts WHERE namespace=? AND fact_id=?',
                    [namespace, original.factId],
                  ).single['instrument_id']
                  as String?;
          final personalInstrument =
              corrected['_personalInstrumentId'] as String?;
          if (personalInstrument != null) {
            final selected = InstrumentStore(
              _db,
              namespace: namespace,
            ).get(personalInstrument);
            if (selected?.status != InstrumentStatus.confirmed ||
                selected?.maskDigits != replacement.instrument?.maskDigits ||
                selected?.issuerSlug != replacement.instrument?.issuerSlug ||
                selected?.kind != replacement.instrument?.kind) {
              throw ArgumentError('Choose a confirmed account for this format');
            }
          }
          _facts.insert(
            replacement,
            instrumentId: personalInstrument ?? previousInstrument,
          );
          _outbox.enqueue('source', source, {
            'sourceKey': source,
            'senderBrand': correction.message == null
                ? 'USER'
                : normalizeSenderBrand(correction.message!.sender).brand,
            'observedAt': replacement.observedAt.toUtc().toIso8601String(),
            'bodyHash': sha256.convert(utf8.encode(source)).toString(),
            'facts': [
              {
                ...replacement.toJson(),
                'evidence': <Object?>[],
                if (replacement.instrument != null)
                  'instrument': {
                    ...replacement.instrument!.toJson(),
                    'raw': null,
                  },
              },
            ],
          });
          event = event!.copyWith(
            legs: [
              for (final leg in event!.legs)
                if (leg.factId == original.factId) ...[
                  if (leg.factId == event!.eventId ||
                      original.provenance.engine != Engine.user)
                    EventLeg(factId: leg.factId, role: LegRole.original),
                  EventLeg(
                    factId: replacement.factId,
                    role: personalJson == null
                        ? leg.role
                        : replacement is HoldFact
                        ? (replacement.phase == HoldPhase.placed
                              ? LegRole.holdPlaced
                              : LegRole.holdReleased)
                        : replacement is MovementFact &&
                              replacement.direction == Direction.credit
                        ? LegRole.creditLeg
                        : LegRole.debitLeg,
                  ),
                ] else
                  leg,
            ],
            amountMinor: personalJson != null
                ? replacement.amounts.first.minor
                : correction.kind == CorrectionKind.wrongAmount
                ? corrected['amountMinor'] as int
                : null,
            occurredAt: personalJson != null
                ? replacement.effectiveAt
                : correction.kind == CorrectionKind.wrongDate
                ? replacement.effectiveAt
                : null,
            type: correction.kind == CorrectionKind.wrongKind
                ? EventType.fromWire(corrected['eventType'] as String)
                : null,
          );
        }
        if (event != null) {
          event = event!.copyWith(status: EventStatus.userConfirmed);
          final check = event!.validate();
          if (!check.ok) throw ContractException(check.errors);
          event = _events.upsert(event!, fromUser: true);
          final affected = <String, Event>{
            event!.eventId: event!,
            for (final related in _events.findByFactIds(correction.factIds))
              if (related.eventId != event!.eventId) related.eventId: related,
          };
          for (final id
              in correction.corrected['_retireEventIds'] as List? ?? const []) {
            if (correction.kind != CorrectionKind.wrongLink ||
                id is! String ||
                id == event!.eventId) {
              throw ArgumentError('Invalid merged event');
            }
            final other = _events.get(id);
            final linked = event!.legs.map((leg) => leg.factId).toSet();
            if (other == null ||
                other.legs.any((leg) => !linked.contains(leg.factId))) {
              throw ArgumentError('Every merged message must remain linked');
            }
            affected[id] = _events.upsert(
              other.copyWith(
                type: EventType.unknown,
                status: EventStatus.userConfirmed,
              ),
              fromUser: true,
            );
          }
          final previousEntries = [
            for (final related in affected.values)
              ..._ledger.forEvent(related.eventId),
          ];
          for (final saved in _ledger.categoryDecisions().entries) {
            if (saved.value.source == CategorySource.user) {
              locked.putIfAbsent(saved.key, () => saved.value);
            }
          }
          final allFacts = {
            for (final fact in _facts.since(DateTime.utc(1900)))
              fact.factId: fact,
          };
          final instruments = {
            for (final value in InstrumentStore(
              _db,
              namespace: namespace,
            ).list())
              value.instrumentId: value,
          };
          final categories = CategorySnapshot.load(
            financial.database,
            namespace: namespace,
            aliases: bundle.merchantAliases,
          );
          final snapshot = LedgerSnapshot.project(
            events: affected.values,
            factsById: allFacts,
            instrumentsById: instruments,
            bundle: bundle,
            lockedCategories: locked,
            instrumentIdByFactId: _facts.instrumentIdsSince(DateTime.utc(1900)),
            userRules: categories.userRules,
            confirmedHistory: categories.confirmedHistory,
          );
          ProjectionWriter(financial, _ledger).write(
            snapshot,
            factsById: allFacts,
            instrumentsById: instruments,
            categoryIdBySlug: categoryIdBySlug,
            instrumentIdByFactId: _facts.instrumentIdsSince(DateTime.utc(1900)),
          );
          final retainedIds = snapshot.entries
              .map((entry) => entry.entryId)
              .toSet();
          for (final previous in previousEntries) {
            if (!retainedIds.contains(previous.entryId)) {
              _db.execute('DELETE FROM v2_outbox WHERE namespace=? AND id=?', [
                namespace,
                'ledger:${previous.entryId}',
              ]);
            }
          }
          for (final changed in affected.values) {
            _outbox.enqueue('event', changed.eventId, changed.toJson());
          }
          for (final entry in snapshot.entries) {
            _outbox.enqueue('ledger', entry.entryId, entry.toJson());
          }
          final instrumentIds = _facts.instrumentIdsSince(DateTime.utc(1900));
          // Primary merged-event traces win over the event retired by a link edit.
          for (final changed in affected.values.toList().reversed) {
            _refreshTrace(
              correction,
              changed,
              allFacts,
              instruments,
              instrumentIds,
              snapshot.categoryByEvent[changed.eventId],
              primary: changed.eventId == event!.eventId,
            );
          }
        }
        _db.execute(
          'INSERT INTO v2_review_items(namespace,review_id,kind,payload,status) VALUES(?,?,?,?,?)',
          [
            namespace,
            localId,
            'correction',
            jsonEncode({
              'kind': correction.kind.wire,
              'trace': correction.trace.toJson(),
              'corrected': correction.corrected,
            }),
            correction.reportCase ? 'pending' : 'resolved',
          ],
        );
        if (correction.reportCase &&
            correction.trace.ruleId != null &&
            correction.trace.ruleVersion != null &&
            originalFacts.isNotEmpty &&
            correction.trace.facts.every(
              (f) => f.provenance.engine != Engine.ai,
            )) {
          StatsStore(_db, namespace: namespace).correction(
            at: originalFacts.values.first.observedAt,
            ruleId: correction.trace.ruleId!,
            ruleVersion: correction.trace.ruleVersion!,
          );
        }
        // A shared fix also teaches which shop it was, as an anonymised signal.
        final signal = correction.sharedLearningConsent
            ? _shopSignal(correction, current, event?.type)
            : null;
        if (signal != null) enqueueLearningSignal(_outbox, signal);
        if (stage != null && correction.reportCase) {
          _queueCase(
            correction,
            stage,
            merchantKey: correction.kind == CorrectionKind.wrongCategory
                ? signal?.merchantKey
                : null,
          );
        }
        _db.execute('RELEASE sms_v2_correction');
        financial.notifyExternalChanges(namespace, const [
          'transactions',
          'observations',
        ]);
      } catch (_) {
        _db.execute('ROLLBACK TO sms_v2_correction');
        _db.execute('RELEASE sms_v2_correction');
        rethrow;
      }
    });
  }

  void _refreshTrace(
    SmsCorrection correction,
    Event event,
    Map<String, Fact> facts,
    Map<String, Instrument> instruments,
    Map<String, String> instrumentIds,
    CategoryDecision? category, {
    required bool primary,
  }) {
    final active = [
      for (final leg in event.legs)
        if (leg.role != LegRole.original && facts[leg.factId] != null)
          facts[leg.factId]!,
    ];
    final money = moneyFactForEvent(event, facts);
    final sources = {
      if (primary) correction.sourceKey,
      if (facts[event.eventId] case final anchor?) anchor.sourceKey,
      for (final fact in active) fact.sourceKey,
    };
    final state = SyncStateStore(_db, namespace: namespace);
    for (final source in sources) {
      final saved = state.get('trace:$source');
      final previous = saved == null
          ? correction.trace.toJson()
          : (jsonDecode(saved) as Map).cast<String, Object?>();
      final choices = <CorrectionKind>{
        for (final wire in previous['userChoices'] as List? ?? const [])
          for (final kind in CorrectionKind.values)
            if (kind.wire == wire) kind,
      };
      if (primary) {
        if ([
          CorrectionKind.wrongKind,
          CorrectionKind.notFinancial,
          CorrectionKind.duplicate,
        ].contains(correction.kind)) {
          choices.removeAll([
            CorrectionKind.wrongKind,
            CorrectionKind.notFinancial,
            CorrectionKind.duplicate,
          ]);
        }
        choices.add(correction.kind);
      }
      final previousSteps = {
        for (final row in previous['instruments'] as List? ?? const [])
          if (row is Map) row['factId']: row['step'],
      };
      final trace = DecisionTrace(
        appVersion:
            previous['appVersion'] as String? ?? correction.trace.appVersion,
        engineVersion:
            previous['engineVersion'] as String? ??
            correction.trace.engineVersion,
        bundleVersion:
            previous['bundleVersion'] as int? ?? correction.trace.bundleVersion,
        outcome: event.status.wire,
        ruleId: previous['ruleId'] as String? ?? correction.trace.ruleId,
        ruleVersion:
            previous['ruleVersion'] as int? ?? correction.trace.ruleVersion,
        facts: active,
        instruments: [
          for (final fact in active)
            if (instrumentForFact(
                  fact,
                  instruments,
                  instrumentIdByFactId: instrumentIds,
                )
                case final instrument?)
              (
                factId: fact.factId,
                instrumentId: instrument.instrumentId,
                step:
                    fact.factId == money?.factId &&
                        choices.contains(CorrectionKind.wrongInstrument)
                    ? 'user_choice'
                    : previousSteps[fact.factId] as String? ?? 'stored',
              ),
        ],
        event: event,
        category: category,
        userChoices: choices.toList(),
      );
      state.put('trace:$source', jsonEncode(trace.toJson()));
    }
  }

  /// The shop signal for a category or shop-name fix, or null when it must stay
  /// on the phone (see [learningSignalFor]).
  LearningSignal? _shopSignal(
    SmsCorrection correction,
    Fact? current,
    EventType? eventType,
  ) {
    final sender = correction.message?.sender;
    if (sender == null || current == null || eventType == null) return null;
    final (kind, value) = switch (correction.kind) {
      CorrectionKind.wrongCategory => (
        'category_choice',
        correction.corrected['category'],
      ),
      CorrectionKind.wrongMerchant => (
        'merchant_name',
        correction.corrected['merchantName'],
      ),
      _ => ('', null),
    };
    if (value is! String) return null;
    return learningSignalFor(
      kind: kind,
      eventType: eventType,
      counterparty: current.counterparty,
      sender: sender,
      value: value,
    );
  }

  void _queueCase(SmsCorrection correction, String stage, {String? merchantKey}) {
    final payload = <String, Object?>{
      'sourceKey': correction.sourceKey,
      'factIds': correction.factIds,
      if (correction.eventId != null) 'eventId': correction.eventId,
      'correctionKind': correction.kind.wire,
      'corrected': <String, Object?>{},
      'trace': correction.trace.compact(stage),
    };
    if (correction.sharedLearningConsent && correction.message != null) {
      final message = correction.message!;
      final redacted = redactSms(
        sender: message.sender,
        body: message.body,
        observedAt: message.observedAt,
        options: SmsRedactionOptions(salt: correction.id),
      );
      final skeleton = smsSkeleton(redacted.body);
      final brand = smsTemplateBrand(redacted.sender);
      payload['redactedTemplate'] = skeleton;
      payload['corrected'] = {
        // Only categorical values enter shared review automatically. Corrected
        // amounts, dates and names stay on-device until an admin makes a
        // reviewed synthetic example for code-fix export.
        if (correction.corrected['category'] case final String category)
          'category': category,
        // The shop, only when it passed the same filters as a shop signal.
        'merchantKey': ?merchantKey,
        '_template': {
          'senderBrand': brand,
          'hash': smsTemplateHash(brand, skeleton),
          'observedAt': redacted.observedAt.toUtc().toIso8601String(),
        },
      };
    }
    _outbox.enqueue('correction', correction.id, payload);
  }
}
