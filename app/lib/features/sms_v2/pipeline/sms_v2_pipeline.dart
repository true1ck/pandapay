import 'dart:convert';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_solver.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:crypto/crypto.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_intake_repository.dart';
import '../ledger/foreign_payment_bridge.dart';
import '../ledger/projection_writer.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import '../storage/outbox_store.dart';
import '../storage/schema.dart';
import '../storage/stats_store.dart';
import '../storage/sync_state_store.dart';
import 'receipt_review.dart';
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
    this.ownerNames = const [],
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

  /// The account owner's names, so a payment to or from the owner under their
  /// own name is a transfer between their accounts, not spending or income.
  final List<String> ownerNames;
  String get processingRevision => revision ?? '${bundle.bundleVersion}';
  final RuleEngine engine;
  final DefaultInstrumentResolver _resolver;

  Database get _db => financial.database.db;

  /// True when a financial rule reads [message]. Used to overrule the intake
  /// gate for a message it rejected by keyword; it changes nothing.
  bool readsAsFinancial(SmsMessage message) =>
      engine.interpret(message, bundle, appVersion: appVersion).outcome ==
      InterpretOutcome.matched;

  late final _facts = FactStore(_db, namespace: namespace);
  late final _instruments = InstrumentStore(_db, namespace: namespace);
  late final _events = EventStore(_db, namespace: namespace);
  late final _ledger = LedgerStore(_db, namespace: namespace);
  late final _outbox = OutboxStore(_db, namespace: namespace);
  late final _intake = SmsIntakeRepository(financial.database);
  late final _writer = ProjectionWriter(financial, _ledger);
  late final _foreign = ForeignPaymentBridge(financial.database, namespace);

  /// Returns false for a replay of a source already processed by v2.
  bool process(SmsMessage message, {bool backfill = false}) =>
      processBatch([message], backfill: backfill) != 0;

  /// A history chunk shares one link pass and one local transaction.
  /// Callers yield to the UI between chunks of at most 500 messages.
  int processBatch(
    List<SmsMessage> messages, {
    bool backfill = false,
    bool retry = false,
  }) {
    if (messages.length > 500) {
      throw ArgumentError('Maximum chunk is 500 messages');
    }
    final unique = <String, SmsMessage>{};
    for (final message in messages) {
      final previous = _intake.decision(namespace, message.sourceKey);
      // A message the rules could not read, or that was dropped as "ignored"
      // under an older rule revision (or by the keyword gate, which records no
      // revision at all), is read again when it arrives again. Without this an
      // old "ignored" call was final: a real card spend with an EMI footer
      // stayed out of the ledger for good, even after the gate was fixed.
      final mayBeRead = previous?.decision == 'unknown' ||
          previous?.decision == 'ignored';
      // [retry] re-reads a message that was left waiting for history.
      if (retry ||
          previous?.policyVersion != 'v2' ||
          mayBeRead && previous?.parserVersion != processingRevision) {
        unique.putIfAbsent(message.sourceKey, () => message);
      }
    }
    if (unique.isEmpty) return 0;
    // Set inside the batch: new statements or spends arrived, so messages that
    // were waiting for history may now be completable.
    var brokeNewHistory = false;
    DateTime? newest;
    financial.batch(() {
      _db.execute('SAVEPOINT sms_v2_process');
      try {
        final interpreted = <(SmsMessage, EngineOutcome)>[];
        final review = <ReviewItem>[];
        final incoming = <Fact>[];
        // Oldest first. The phone hands history over newest first, and a reminder
        // can only borrow from a statement or a spend that was read before it.
        final oldestFirst = unique.values.toList()
          ..sort((a, b) => a.observedAt.compareTo(b.observedAt));
        for (final message in oldestFirst) {
          var outcome = engine.interpretDetailed(
            message,
            bundle,
            appVersion: appVersion,
          );
          // A bill reminder with an amount but no due date borrows it from the one
          // earlier statement it can only be about; otherwise it stays as it was.
          final pendingRefund = outcome.pendingRefund;
          if (pendingRefund != null) {
            final linked = _linkRefundToSpend(message, pendingRefund, incoming);
            if (linked != null) {
              outcome = EngineOutcome(
                InterpretResult(
                  outcome: InterpretOutcome.matched,
                  facts: linked.facts,
                  ruleId: linked.ruleId,
                  ruleVersion: pendingRefund.packVersion,
                  templateHash: outcome.result.templateHash,
                ),
                winnerId: linked.ruleId,
              );
            }
          }
          final pending = outcome.pendingBill;
          if (pending != null) {
            final completed = _completeBillFromHistory(
              message,
              pending,
              incoming,
            );
            if (completed != null) {
              outcome = EngineOutcome(
                InterpretResult(
                  outcome: InterpretOutcome.matched,
                  facts: [completed],
                  ruleId: completed.provenance.ruleId,
                  ruleVersion: pending.packVersion,
                  templateHash: outcome.result.templateHash,
                ),
                winnerId: completed.provenance.ruleId,
              );
            }
          }
          final result = outcome.result;
          final provisional = bundle.rules.any(
            (rule) =>
                rule.id == result.ruleId &&
                rule.status == RuleStatus.provisional,
          );
          // A private AI rule reports under its layout's AI id, so the console
          // can show how the draft fares on phones. Its matches always go to
          // review, so each one is counted as sent to review.
          final reported = result.ruleId == null
              ? null
              : provisional
              ? StatsStore.reportedRuleId(result.ruleId!)
              : result.ruleId;
          if (reported != null && (result.ruleVersion ?? 0) > 0) {
            StatsStore(_db, namespace: namespace).record(
              at: message.observedAt,
              ruleId: reported,
              ruleVersion: result.ruleVersion!,
              toReview:
                  provisional ||
                  result.outcome == InterpretOutcome.unknown ||
                  result.facts.any((fact) => fact.confidence < .7),
            );
          }
          interpreted.add((message, outcome));
          // A reminder or refund that could not be completed yet is remembered, so
          // a later batch that brings its statement or spend can finish it; one
          // that completed (or was read some other way) is forgotten.
          final waitingKey = 'history-pending:${message.sourceKey}';
          if (result.outcome == InterpretOutcome.unknown &&
              (outcome.pendingBill != null || outcome.pendingRefund != null)) {
            SyncStateStore(_db, namespace: namespace).put(
              waitingKey,
              message.observedAt.toUtc().toIso8601String(),
            );
          } else {
            _db.execute(
              'DELETE FROM v2_sync_state WHERE namespace=? AND key=?',
              [namespace, waitingKey],
            );
          }
          if (result.outcome == InterpretOutcome.unknown) {
            // A reminder with no date, or a refund with no account, is waiting for
            // history, not for a rule: an AI-drafted rule could not read it either.
            // On a retry its review item already exists (and may have been
            // dismissed), so it is not raised again.
            if (!retry) {
              review.add(
                _templateReview(
                  message,
                  result,
                  history: outcome.pendingBill != null ||
                      outcome.pendingRefund != null,
                ),
              );
            }
          } else if (result.outcome == InterpretOutcome.ignored) {
            for (final fact in result.facts) {
              _facts.insert(fact);
            }
          } else {
            incoming.addAll(result.facts);
            if (result.facts.any((fact) => fact.confidence < .7) ||
                provisional) {
              review.add(
                _templateReview(
                  message,
                  result,
                  // Already read, by history: the person confirms it, no rule is needed.
                  history: (result.ruleId ?? '').endsWith('-INFERRED'),
                ),
              );
            }
          }
        }
        brokeNewHistory = incoming.any(
          (f) => f is BillDueFact || f is MovementFact,
        );
        newest = oldestFirst.last.observedAt;
        var traces = <String, DecisionTrace>{};
        if (incoming.isNotEmpty) {
          traces = _project(
            unique.values.toList(),
            incoming,
            review,
            backfill: backfill,
          );
        }
        // One read per chunk: a per-message json_extract scan of the review
        // table made a long history import quadratic.
        final openTemplateSources = {
          for (final row in _db.select(
            "SELECT json_extract(payload,'\$.sourceKey') AS source FROM v2_review_items WHERE namespace=? AND kind='template' AND status!='resolved'",
            [namespace],
          ))
            row['source'],
        };
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
          if (result.outcome != InterpretOutcome.unknown &&
              openTemplateSources.contains(message.sourceKey)) {
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
    if (!retry && brokeNewHistory) {
      _retryWaitingForHistory(
        backfill: backfill,
        newest: newest!,
        justRead: unique.keys.toSet(),
      );
    }
    return unique.length;
  }

  /// How many waiting messages one retry pass re-reads.
  static const int _retryLimit = 100;

  /// Re-reads, oldest first and once, the messages that were left waiting for a
  /// statement or a spend, now that a batch has stored more history. Phones hand
  /// history over newest first in chunks, so a reminder can land in a chunk read
  /// before the chunk that holds its statement. A message whose capture is gone,
  /// or that is older than the history window, is forgotten.
  void _retryWaitingForHistory({
    required bool backfill,
    required DateTime newest,
    required Set<String> justRead,
  }) {
    final rows = _db.select(
      "SELECT key, value FROM v2_sync_state WHERE namespace=? AND key LIKE 'history-pending:%' ORDER BY value LIMIT ?",
      [namespace, _retryLimit + justRead.length],
    );
    final messages = <SmsMessage>[];
    for (final row in rows) {
      final key = (row['key'] as String).substring('history-pending:'.length);
      if (justRead.contains(key)) continue;
      final at = DateTime.tryParse(row['value'] as String);
      final captured = _intake.capturedById(namespace, key)?.message;
      if (at == null ||
          captured == null ||
          newest.difference(at) > kRefundHistoryWindow + const Duration(days: 30)) {
        _db.execute('DELETE FROM v2_sync_state WHERE namespace=? AND key=?', [
          namespace,
          row['key'],
        ]);
        continue;
      }
      messages.add(
        SmsMessage(
          sender: captured.sender,
          body: captured.body,
          sourceKey: key,
          observedAt: captured.receivedAt.toUtc(),
          iosFilter: normalizeSenderBrand(captured.sender).iosFilter,
        ),
      );
      if (messages.length >= _retryLimit) break;
    }
    if (messages.isNotEmpty) {
      processBatch(messages, backfill: backfill, retry: true);
    }
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
        'senderBrand': uploadBrandOfSender(message.sender, bundle.senders),
        'observedAt': message.observedAt.toUtc().toIso8601String(),
        'bodyHash': sha256.convert(utf8.encode(message.body)).toString(),
        'facts': upload,
      }, backfill: backfill);
    }
  }

  /// A refund with no account, accepted as an inference when exactly one earlier
  /// spend of that amount can be the original ([matchEarlierSpend]).
  SolverFactResult? _linkRefundToSpend(
    SmsMessage message,
    PendingRefund pending,
    List<Fact> incoming,
  ) {
    final d = pending.decision;
    final minor = d.minor;
    if (minor == null) return null;
    final byId = <String, MovementFact>{
      for (final f in _facts.movementsSince(
        message.observedAt.subtract(kRefundHistoryWindow),
      ))
        f.factId: f,
      for (final f in incoming.whereType<MovementFact>()) f.factId: f,
    };
    final original = matchEarlierSpend(
      minor: minor,
      at: message.observedAt,
      history: byId.values,
      text: message.body,
    );
    if (original == null) return null;
    return SolverFacts.build(
      d,
      sourceKey: message.sourceKey,
      observedAt: message.observedAt,
      issuerSlug: pending.issuerSlug,
      packVersion: pending.packVersion,
      bundleVersion: pending.bundleVersion,
      engineVersion: pending.engineVersion,
      appVersion: pending.appVersion,
      forceAccept: true,
      confidenceCap: kRefundInferredConfidence,
      ruleIdOverride: 'SOLVER-REFUND-INFERRED',
    );
  }

  /// The statement a date-less reminder belongs to, from the facts stored in the
  /// history window and the ones read earlier in this same chunk. Null unless
  /// exactly one statement fits ([matchEarlierBill]).
  Fact? _completeBillFromHistory(
    SmsMessage message,
    PendingBill pending,
    List<Fact> incoming,
  ) {
    final d = pending.decision;
    final minor = d.minor;
    if (minor == null) return null;
    final byId = <String, BillDueFact>{
      for (final f in _facts.billDuesSince(
        message.observedAt.subtract(kBillHistoryWindow),
      ))
        f.factId: f,
      for (final f in incoming.whereType<BillDueFact>()) f.factId: f,
    };
    final match = matchEarlierBill(
      minor: minor,
      at: message.observedAt,
      history: byId.values,
      mask: d.mask,
      issuerSlug: pending.issuerSlug,
      billerName: d.billerName,
    );
    if (match == null) return null;
    return completeBillFromHistory(
      d,
      match,
      sourceKey: message.sourceKey,
      observedAt: message.observedAt,
      packVersion: pending.packVersion,
      bundleVersion: pending.bundleVersion,
      engineVersion: pending.engineVersion,
      appVersion: pending.appVersion,
    );
  }

  ReviewItem _templateReview(
    SmsMessage message,
    InterpretResult result, {
    bool history = false,
  }) => ReviewItem(
    kind: ReviewKind.template,
    payload: {
      'sourceKey': message.sourceKey,
      'templateHash': result.templateHash,
      'senderBrand': normalizeSenderBrand(message.sender).brand,
      'iosFilter': message.iosFilter,
      // Never sent for AI rule drafting: history completes it, not a rule.
      if (history) 'aiHold': 'history',
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
          // Money that moved on a card is proof the card exists, even when the
          // issuer never prints its number. A statement, a balance or a hint is
          // not: those never create a card without a number.
          createWithoutMask: fact is MovementFact && fact.evidenceOnly != true,
          // A card payment receipt may print the card ACCOUNT number, not the
          // card's own: it must not complete a card that has no number yet.
          adoptNumberlessCard: !(fact is MovementFact &&
              fact.direction == Direction.credit &&
              fact.purpose == MovementPurpose.cardPayment),
        );
        switch (outcome) {
          case InstrumentResolved(:final resolution)
              when resolution.created &&
                  !cardPaymentMayCreateCard(fact, instrumentsById.values):
            // A payment receipt does not create a second card for an issuer that
            // already has one (it may name the card's account number). It stays
            // unresolved; a spend alert or a statement creates the card.
            break;
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
          case InstrumentReviewNeeded(
            reason: InstrumentReviewReason.rejected,
            :final candidates,
          ):
            // The user said this account or card is not theirs ("Not mine"). A
            // later message about it is not a question: link the fact to it so
            // its money stays hidden (the ledger drops movements on a rejected
            // instrument) and raise nothing for the person to answer. The
            // instrument itself is not written or uploaded again.
            if (candidates.isNotEmpty) {
              instrumentIds[fact.factId] = candidates.first.instrumentId;
              steps[fact.factId] = 'rejected';
            }
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
            ownerNames: ownerNames,
          ),
          rules: bundle.linkRules,
        );
    review.addAll(result.ambiguous);
    // Foreign amounts (CCR-004) go to the foreign payments records, beside the
    // INR ledger. They run after the ledger write below so an INR posting can
    // find its own transaction.
    void bridgeForeign() {
      if (_foreign.apply(
            incoming,
            instrumentsById: instrumentsById,
            instrumentIdByFactId: instrumentIds,
          ) >
          0) {
        financial.notifyExternalChanges(namespace, const ['foreign_payments']);
      }
    }

    final affected = [
      for (final event in [...result.created, ...result.updated])
        _events.upsert(event),
    ];
    // A funding debit that joined a receipt answers the receipt question.
    ReceiptReviews.resolveJoined(_db, namespace, affected);
    if (affected.isEmpty) {
      bridgeForeign();
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
    bridgeForeign();
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
