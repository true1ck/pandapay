import 'dart:convert';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:crypto/crypto.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_intake_repository.dart';
import '../ledger/projection_writer.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import '../storage/outbox_store.dart';
import '../storage/schema.dart';
import '../storage/stats_store.dart';
import '../storage/sync_state_store.dart';
import 'trace.dart';

/// The local part of WP-14. The caller supplies a verified bundle and a
/// financial candidate that has already passed the existing safety gate.
class SmsV2Pipeline {
  SmsV2Pipeline({
    required this.financial,
    required this.namespace,
    required this.bundle,
    required this.appVersion,
    this.userRules = const [],
    this.confirmedHistory = const {},
    this.categoryIdBySlug = const {},
    this.revision,
    RuleEngine? engine,
  }) : engine = engine ?? RuleEngine(),
       _resolver = DefaultInstrumentResolver.fromBundle(bundle) {
    SmsV2Schema.ensure(_db);
  }

  final FinancialStore financial;
  final String namespace;
  final RuleBundle bundle;
  final String appVersion;
  final List<CategoryRule> userRules;
  final Map<String, String> confirmedHistory;
  final Map<String, String> categoryIdBySlug;
  final String? revision;
  String get processingRevision => revision ?? '${bundle.bundleVersion}';
  final RuleEngine engine;
  final DefaultInstrumentResolver _resolver;

  Database get _db => financial.database.db;
  late final _facts = FactStore(_db, namespace: namespace);
  late final _instruments = InstrumentStore(_db, namespace: namespace);
  late final _events = EventStore(_db, namespace: namespace);
  late final _ledger = LedgerStore(_db, namespace: namespace);
  late final _outbox = OutboxStore(_db, namespace: namespace);
  late final _intake = SmsIntakeRepository(financial.database);
  late final _writer = ProjectionWriter(financial, _ledger);

  /// Returns false for a replay of a source already processed by v2.
  bool process(SmsMessage message, {bool backfill = false}) =>
      processBatch([message], backfill: backfill) != 0;

  /// A history chunk shares one link pass and one local transaction.
  /// Callers yield to the UI between chunks of at most 500 messages.
  int processBatch(List<SmsMessage> messages, {bool backfill = false}) {
    if (messages.length > 500) {
      throw ArgumentError('Maximum chunk is 500 messages');
    }
    final unique = <String, SmsMessage>{};
    for (final message in messages) {
      final previous = _intake.decision(namespace, message.sourceKey);
      if (previous?.policyVersion != 'v2' ||
          previous?.decision == 'unknown' &&
              previous?.parserVersion != processingRevision) {
        unique.putIfAbsent(message.sourceKey, () => message);
      }
    }
    if (unique.isEmpty) return 0;
    financial.batch(() {
      _db.execute('SAVEPOINT sms_v2_process');
      try {
        final interpreted = <(SmsMessage, EngineOutcome)>[];
        final review = <ReviewItem>[];
        final incoming = <Fact>[];
        for (final message in unique.values) {
          final outcome = engine.interpretDetailed(
            message,
            bundle,
            appVersion: appVersion,
          );
          final result = outcome.result;
          final provisional = bundle.rules.any(
            (rule) =>
                rule.id == result.ruleId &&
                rule.status == RuleStatus.provisional,
          );
          if (!provisional &&
              result.ruleId != null &&
              (result.ruleVersion ?? 0) > 0) {
            StatsStore(_db, namespace: namespace).record(
              at: message.observedAt,
              ruleId: result.ruleId!,
              ruleVersion: result.ruleVersion!,
              toReview:
                  result.outcome == InterpretOutcome.unknown ||
                  result.facts.any((fact) => fact.confidence < .7),
            );
          }
          interpreted.add((message, outcome));
          if (result.outcome == InterpretOutcome.unknown) {
            review.add(_templateReview(message, result));
          } else if (result.outcome == InterpretOutcome.ignored) {
            for (final fact in result.facts) {
              _facts.insert(fact);
            }
          } else {
            incoming.addAll(result.facts);
            if (result.facts.any((fact) => fact.confidence < .7) ||
                provisional) {
              review.add(_templateReview(message, result));
            }
          }
        }
        var traces = <String, DecisionTrace>{};
        if (incoming.isNotEmpty) {
          traces = _project(
            unique.values.toList(),
            incoming,
            review,
            backfill: backfill,
          );
        }
        for (final (message, outcome) in interpreted) {
          final result = outcome.result;
          final trace =
              traces[message.sourceKey] ??
              DecisionTrace(
                appVersion: appVersion,
                engineVersion: engine.engineVersion,
                bundleVersion: bundle.bundleVersion,
                outcome: result.outcome.name,
                ruleId: result.ruleId,
                ruleVersion: result.ruleVersion,
                facts: result.facts,
              );
          SyncStateStore(
            _db,
            namespace: namespace,
          ).put('trace:${message.sourceKey}', jsonEncode(trace.toJson()));
          if (result.outcome != InterpretOutcome.unknown) {
            _db.execute(
              "UPDATE v2_review_items SET status='resolved' WHERE namespace=? AND kind='template' AND json_extract(payload,'\$.sourceKey')=?",
              [namespace, message.sourceKey],
            );
          }
          if (result.outcome == InterpretOutcome.matched) {
            _queue(message, result.facts, backfill: backfill);
          }
          _intake.recordDecision(
            namespace,
            sourceKey: message.sourceKey,
            decision: result.outcome.name,
            state: 'final',
            reasonCode: outcome.reason ?? result.outcome.name,
            receivedAt: message.observedAt.millisecondsSinceEpoch,
            bundleVersion: bundle.bundleVersion,
            parserVersion: processingRevision,
            policyVersion: 'v2',
          );
        }
        for (final (index, item) in review.indexed) {
          final source =
              item.payload['sourceKey'] as String? ??
              incoming
                  .where((fact) => fact.factId == item.payload['factId'])
                  .firstOrNull
                  ?.sourceKey ??
              unique.keys.first;
          _db.execute(
            'INSERT INTO v2_review_items '
            '(namespace, review_id, kind, payload, status) VALUES (?, ?, ?, ?, ?) '
            'ON CONFLICT(namespace,review_id) DO UPDATE SET kind=excluded.kind,payload=excluded.payload,status=excluded.status',
            [
              namespace,
              '$source:$index',
              item.kind.name,
              jsonEncode(item.payload),
              'open',
            ],
          );
        }
        _db.execute('RELEASE SAVEPOINT sms_v2_process');
        financial.notifyExternalChanges(namespace, const ['observations']);
      } catch (_) {
        _db.execute('ROLLBACK TO SAVEPOINT sms_v2_process');
        _db.execute('RELEASE SAVEPOINT sms_v2_process');
        rethrow;
      }
    });
    return unique.length;
  }

  void _queue(SmsMessage message, List<Fact> facts, {required bool backfill}) {
    final upload = [
      for (final fact in facts)
        if (fact.factType != FactType.info)
          {
            ...fact.toJson(),
            'evidence': <Object?>[],
            if (fact.instrument != null)
              'instrument': {...fact.instrument!.toJson(), 'raw': null},
          },
    ];
    if (upload.isNotEmpty) {
      _outbox.enqueue('source', message.sourceKey, {
        'sourceKey': message.sourceKey,
        'senderBrand': normalizeSenderBrand(
          message.sender,
          bundle.senders,
        ).brand,
        'observedAt': message.observedAt.toUtc().toIso8601String(),
        'bodyHash': sha256.convert(utf8.encode(message.body)).toString(),
        'facts': upload,
      }, backfill: backfill);
    }
  }

  ReviewItem _templateReview(SmsMessage message, InterpretResult result) =>
      ReviewItem(
        kind: ReviewKind.template,
        payload: {
          'sourceKey': message.sourceKey,
          'templateHash': result.templateHash,
          'senderBrand': normalizeSenderBrand(message.sender).brand,
          'iosFilter': message.iosFilter,
        },
      );

  Map<String, DecisionTrace> _project(
    List<SmsMessage> messages,
    List<Fact> incoming,
    List<ReviewItem> review, {
    required bool backfill,
  }) {
    final ordered = [...messages]
      ..sort((a, b) => a.observedAt.compareTo(b.observedAt));
    final from = ordered.first.observedAt.subtract(const Duration(days: 120));
    final recent = _facts.since(from);
    final knownEvents = _events.contextSince(from);
    final instrumentsById = {
      for (final instrument in _instruments.list())
        instrument.instrumentId: instrument,
    };
    final instrumentIds = _facts.instrumentIdsSince(from);
    final steps = <String, String>{};
    for (final fact in incoming) {
      final mention = fact.instrument;
      if (mention != null) {
        final outcome = _resolver.resolveDetailed(
          mention,
          instrumentsById.values,
          profileId: namespace.startsWith('user:')
              ? namespace.substring(5)
              : namespace,
          observedAt: fact.observedAt,
        );
        switch (outcome) {
          case InstrumentResolved(:final resolution):
            final base = resolution.instrument;
            final update = applyFact(
              base,
              fact,
              limitHistory: _instruments.limitHistory(base.instrumentId),
            );
            _instruments.upsert(
              update.instrument,
              limitHistory: update.limitHistory,
            );
            instrumentsById[base.instrumentId] = update.instrument;
            _outbox.enqueue(
              'instrument',
              base.instrumentId,
              update.instrument.toJson(),
              backfill: backfill,
            );
            instrumentIds[fact.factId] = base.instrumentId;
            steps[fact.factId] =
                fact.provenance.engine == Engine.user &&
                    fact.provenance.ruleId.startsWith('PERSONAL-')
                ? 'user_choice'
                : resolution.created
                ? 'created'
                : mention.maskDigits == null
                ? 'issuer_kind'
                : mention.kind == null
                ? 'issuer_mask'
                : 'exact_key';
          case InstrumentReviewNeeded(:final reason):
            review.add(
              ReviewItem(
                kind: ReviewKind.instrument,
                payload: {'factId': fact.factId, 'reason': reason.name},
              ),
            );
          case InstrumentNotCreated():
            break;
        }
      }
      _facts.insert(fact, instrumentId: instrumentIds[fact.factId]);
    }

    final result =
        RuleDrivenLinker.fromBundle(
          bundle,
          clock: () => ordered.last.observedAt,
        ).link(
          incoming: incoming,
          context: RuleLinkContext(
            recentFacts: recent,
            openEvents: knownEvents
                .where((e) => e.status == EventStatus.awaitingLeg)
                .toList(),
            knownEvents: knownEvents,
            instrumentsById: instrumentsById,
            instrumentIdByFactId: instrumentIds,
          ),
          rules: bundle.linkRules,
        );
    review.addAll(result.ambiguous);
    final affected = [
      for (final event in [...result.created, ...result.updated])
        _events.upsert(event),
    ];
    if (affected.isEmpty) {
      return {
        for (final message in messages)
          message.sourceKey: DecisionTrace(
            appVersion: appVersion,
            engineVersion: engine.engineVersion,
            bundleVersion: bundle.bundleVersion,
            outcome: 'matched',
            facts: incoming
                .where((fact) => fact.sourceKey == message.sourceKey)
                .toList(),
          ),
      };
    }
    for (final event in affected) {
      _outbox.enqueue(
        'event',
        event.eventId,
        event.toJson(),
        backfill: backfill,
      );
      if (event.confidence < .7) {
        review.add(ReviewItem(kind: ReviewKind.event, payload: event.toJson()));
      }
    }
    final factsById = {
      for (final f in [...recent, ...incoming]) f.factId: f,
    };
    for (final event in affected) {
      for (final leg in event.legs) {
        if (factsById.containsKey(leg.factId)) continue;
        final fact = _facts.get(leg.factId);
        if (fact != null) factsById[leg.factId] = fact;
      }
    }
    final originalIds = {
      for (final event in affected)
        for (final leg in event.legs)
          if (leg.role == LegRole.original) leg.factId,
    };
    final projection = LedgerSnapshot.project(
      events: {
        if (originalIds.isNotEmpty)
          for (final event in knownEvents)
            if (event.legs.any((leg) => originalIds.contains(leg.factId)))
              event.eventId: event,
        for (final event in affected) event.eventId: event,
      }.values,
      factsById: factsById,
      instrumentsById: instrumentsById,
      bundle: bundle,
      userRules: userRules,
      confirmedHistory: confirmedHistory,
      senderBySource: {
        for (final message in messages)
          message.sourceKey: normalizeSenderBrand(
            message.sender,
            bundle.senders,
          ).brand,
      },
      instrumentIdByFactId: instrumentIds,
      lockedCategories: _ledger.categoryDecisions().map(
        (key, value) => MapEntry(key, value),
      )..removeWhere((_, value) => value.source != CategorySource.user),
    );
    final affectedIds = affected.map((event) => event.eventId).toSet();
    final changed = LedgerSnapshot(
      events: affected,
      entries: projection.entries.where(
        (entry) => affectedIds.contains(entry.eventId),
      ),
      categoryByEvent: projection.categoryByEvent,
    );
    _writer.write(
      changed,
      factsById: factsById,
      instrumentsById: instrumentsById,
      categoryIdBySlug: categoryIdBySlug,
      instrumentIdByFactId: instrumentIds,
    );
    for (final entry in changed.entries) {
      _outbox.enqueue(
        'ledger',
        entry.entryId,
        entry.toJson(),
        backfill: backfill,
      );
    }
    final eventByFact = {
      for (final event in affected)
        for (final leg in event.legs) leg.factId: event,
    };
    final bySource = <String, List<Fact>>{};
    for (final fact in incoming) {
      bySource.putIfAbsent(fact.sourceKey, () => []).add(fact);
    }
    return {
      for (final message in messages)
        for (final ownFacts in [bySource[message.sourceKey] ?? <Fact>[]])
          for (final event in [
            ownFacts
                .map((fact) => eventByFact[fact.factId])
                .whereType<Event>()
                .firstOrNull,
          ])
            message.sourceKey: DecisionTrace(
              appVersion: appVersion,
              engineVersion: engine.engineVersion,
              bundleVersion: bundle.bundleVersion,
              outcome: 'matched',
              ruleId: ownFacts.firstOrNull?.provenance.ruleId,
              ruleVersion: ownFacts.firstOrNull?.provenance.ruleVersion,
              facts: ownFacts,
              instruments: [
                for (final fact in ownFacts)
                  if (instrumentIds[fact.factId] case final id?)
                    (
                      factId: fact.factId,
                      instrumentId: id,
                      step: steps[fact.factId] ?? 'stored',
                    ),
              ],
              event: event,
              category: event == null
                  ? null
                  : projection.categoryByEvent[event.eventId],
            ),
    };
  }
}
