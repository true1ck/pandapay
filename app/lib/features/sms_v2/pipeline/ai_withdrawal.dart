import 'dart:convert';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';

import '../../../data/local/financial_store.dart';
import '../category/category_snapshot.dart';
import '../ledger/projection_writer.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/subscription_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';

/// Takes back what a private AI rule read, once the server says that rule was
/// rejected (or could not be made). The spend it added leaves the ledger and
/// the display list through the same projection path a correction uses; the
/// facts, events and decision for the message are dropped and the message goes
/// back to a plain Needs review item (the caller reads it again, now without
/// the rule). Nothing the person set is touched: a message they corrected has
/// user facts and a trace that no longer names the AI rule.
class AiWithdrawal {
  AiWithdrawal({
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

  /// Remote template hashes whose AI answer is a rejection or failure.
  List<String> rejectedTemplates() => [
    for (final row in _db.select(
      "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%'",
      [namespace],
    ))
      if (_isRejection(row['value'] as String))
        (row['key'] as String).substring('ai:'.length),
  ];

  static bool _isRejection(String raw) {
    try {
      final status = (jsonDecode(raw) as Map)['status'];
      return status == 'rejected' || status == 'failed';
    } catch (_) {
      return false;
    }
  }

  bool _touchedByPerson(String source, FactStore facts, EventStore events) {
    final sourceFacts = facts.forSource(source);
    if (sourceFacts.any((fact) => fact.provenance.engine == Engine.user)) {
      return true;
    }
    return events
        .findByFactIds(sourceFacts.map((fact) => fact.factId))
        .any((event) => event.status == EventStatus.userConfirmed);
  }

  /// Source keys whose reading still comes from this template's private rule.
  List<String> sourcesRead(String remoteHash) => [
    for (final row in _db.select(
      "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'trace:%'",
      [namespace],
    ))
      if (_readBy(row['value'] as String, remoteHash))
        (row['key'] as String).substring('trace:'.length),
  ];

  static bool _readBy(String raw, String remoteHash) {
    try {
      final id = (jsonDecode(raw) as Map)['ruleId'];
      return id is String && id.startsWith('AI-$remoteHash:local:');
    } catch (_) {
      return false;
    }
  }

  /// Withdraws the readings of [sources] and returns the sources to read again.
  /// A source the person has acted on (a user fact, or an event they confirmed)
  /// is left exactly as it is.
  List<String> withdraw(List<String> candidates) {
    final facts = FactStore(_db, namespace: namespace);
    final events = EventStore(_db, namespace: namespace);
    final ledger = LedgerStore(_db, namespace: namespace);
    final sources = [
      for (final source in candidates)
        if (!_touchedByPerson(source, facts, events)) source,
    ];
    if (sources.isEmpty) return const [];
    financial.batch(() {
      _db.execute('SAVEPOINT sms_ai_withdraw');
      try {
        final affected = <String, Event>{};
        final factIds = <String>{};
        for (final source in sources) {
          final sourceFacts = facts.forSource(source);
          factIds.addAll(sourceFacts.map((fact) => fact.factId));
          for (final event in events.findByFactIds(
            sourceFacts.map((fact) => fact.factId),
          )) {
            affected[event.eventId] = event.type == EventType.unknown
                ? event
                : events.upsert(
                    event.copyWith(type: EventType.unknown),
                    fromUser: false,
                  );
          }
        }
        if (affected.isNotEmpty) {
          final allFacts = {
            for (final fact in facts.since(DateTime.utc(1900)))
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
            lockedCategories: const {},
            instrumentIdByFactId: facts.instrumentIdsSince(DateTime.utc(1900)),
            userRules: categories.userRules,
            confirmedHistory: categories.confirmedHistory,
          );
          ProjectionWriter(financial, ledger).write(
            snapshot,
            factsById: allFacts,
            instrumentsById: instruments,
            categoryIdBySlug: categoryIdBySlug,
            instrumentIdByFactId: facts.instrumentIdsSince(DateTime.utc(1900)),
          );
        }
        for (final source in sources) {
          _db.execute(
            'DELETE FROM sms_source_decisions WHERE namespace=? AND source_key=?',
            [namespace, source],
          );
          _db.execute(
            "UPDATE v2_review_items SET status='resolved' WHERE namespace=? AND kind='template' AND json_extract(payload,'\$.sourceKey')=?",
            [namespace, source],
          );
          _db.execute(
            'DELETE FROM v2_facts WHERE namespace=? AND source_key=?',
            [namespace, source],
          );
          _db.execute("DELETE FROM v2_sync_state WHERE namespace=? AND key=?", [
            namespace,
            'trace:$source',
          ]);
        }
        for (final eventId in affected.keys) {
          _db.execute(
            'DELETE FROM v2_events WHERE namespace=? AND event_id=?',
            [namespace, eventId],
          );
          _db.execute(
            "DELETE FROM v2_outbox WHERE namespace=? AND id IN (?,?)",
            [namespace, 'event:$eventId', 'ledger:$eventId'],
          );
        }
        // Withdrawn facts and events can have been part of a subscription.
        SubscriptionStore(_db, namespace: namespace).markDirty();
        financial.notifyExternalChanges(namespace, const ['subscriptions']);
        _db.execute('RELEASE sms_ai_withdraw');
      } catch (_) {
        _db.execute('ROLLBACK TO sms_ai_withdraw');
        _db.execute('RELEASE sms_ai_withdraw');
        rethrow;
      }
    });
    return sources;
  }
}
