import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';

import '../../../data/local/financial_store.dart';
import '../category/category_snapshot.dart';
import '../ledger/projection_writer.dart';
import '../storage/dismissal_store.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/subscription_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import '../storage/sync_state_store.dart';

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
    // Drafts this phone refused on its own check read nothing from now on.
    for (final row in _db.select(
      "SELECT key FROM v2_sync_state WHERE namespace=? AND key LIKE 'draft:verdict:%' "
      "AND json_extract(value,'\$.verdict')='rejected'",
      [namespace],
    ))
      (row['key'] as String).substring('draft:verdict:'.length),
  ];

  static bool _isRejection(String raw) {
    try {
      final status = (jsonDecode(raw) as Map)['status'];
      return status == 'rejected' || status == 'failed';
    } catch (_) {
      return false;
    }
  }

  /// Events a dismissed-then-recovered transaction was put back as (Recover
  /// confirms the event only to undo the hide). Such an event is not something
  /// the person decided: it is withdrawn like an untouched one.
  late final Map<String, DateTime> _restoredMarks = DismissalStore(
    SyncStateStore(_db, namespace: namespace),
  ).restoredMarks();

  /// Fact ids that are a leg of an event the person confirmed, read once per
  /// instance through the status index. A per-source look-up through
  /// [EventStore.findByFactIds] scanned the whole events table for every source
  /// (R4); the recheck loops ask this once per candidate.
  late final Set<String> _confirmedFactIds = {
    for (final row in _db.select(
      'SELECT payload FROM v2_events WHERE namespace=? AND status=?',
      [namespace, EventStatus.userConfirmed.wire],
    ))
      if (!_restoreOnlyJson(jsonDecode(row['payload'] as String) as Map))
        for (final leg
            in (jsonDecode(row['payload'] as String) as Map)['legs'] as List)
          (leg as Map)['factId'] as String,
  };

  bool _restoreOnlyJson(Map payload) => isRestoreOnly(
    _restoredMarks,
    payload['eventId'] as String,
    DateTime.tryParse(payload['decidedAt'] as String? ?? ''),
  );

  /// True when the person has acted on [source] (edited it, or confirmed an
  /// event it made). Such a source is never withdrawn.
  bool touchedByPerson(String source) {
    final sourceFacts = FactStore(_db, namespace: namespace).forSource(source);
    return sourceFacts.any(
      (fact) =>
          fact.provenance.engine == Engine.user ||
          _confirmedFactIds.contains(fact.factId),
    );
  }

  /// Source keys whose reading still comes from a private rule of one of
  /// [remoteHashes], by hash. One pass over the traces for all of them (a pass
  /// per template was a whole-table read inside a loop, R4); the key range
  /// uses the primary key, and only traces of AI rules are decoded in Dart.
  Map<String, List<String>> sourcesReadBy(Set<String> remoteHashes) {
    final out = <String, List<String>>{};
    if (remoteHashes.isEmpty) return out;
    for (final row in _db.select(
      "SELECT key, rule_id FROM (SELECT key, CASE WHEN json_valid(value) THEN json_extract(value,'\$.ruleId') END AS rule_id "
      "FROM v2_sync_state WHERE namespace=? AND key >= 'trace:' AND key < 'trace;') WHERE rule_id LIKE 'AI-%'",
      [namespace],
    )) {
      final id = row['rule_id'];
      if (id is! String) continue;
      final cut = id.indexOf(':local:');
      if (cut < 0) continue;
      final hash = id.substring('AI-'.length, cut);
      if (remoteHashes.contains(hash)) {
        (out[hash] ??= []).add(
          (row['key'] as String).substring('trace:'.length),
        );
      }
    }
    return out;
  }

  /// Source keys whose reading still comes from this template's private rule.
  List<String> sourcesRead(String remoteHash) =>
      sourcesReadBy({remoteHash})[remoteHash] ?? const [];

  /// Last draft offered per template: the hash of its rule. A different hash
  /// is a new revision of the draft.
  static const ruleMarker = 'aiw:rule:';

  /// A rejection already taken back, so a sync does not look for it again.
  static const doneMarker = 'aiw:done:';

  /// The templates whose AI readings are to be taken back now, and what to
  /// remember once that was done ([commit]).
  ///
  /// Three reasons, all cheap to test (a few `ai:` rows, no trace scan):
  /// * the server rejected the draft (or this phone's own check did), once;
  /// * the draft was taken back and a replacement is queued, so phones see
  ///   "pending" where a draft they read with was: what it read must not keep
  ///   counting until the replacement answers (the replacement reads it again);
  /// * a new revision of the draft replaced the one that read (same rule id
  ///   and version, another body): the old revision's readings are read again
  ///   with the new one. A draft seen for the first time only records itself.
  /// A draft the signed rule set already carries is never taken back.
  ({Set<String> hashes, void Function() commit}) takeBackPlan(
    RuleBundle shared,
  ) {
    final state = SyncStateStore(_db, namespace: namespace);
    final rejected = rejectedTemplates().toSet();
    final hashes = <String>{};
    final writes = <String, String?>{};
    for (final hash in rejected) {
      if (state.get('$doneMarker$hash') == null) {
        hashes.add(hash);
        writes['$doneMarker$hash'] = '1';
      }
      if (state.get('$ruleMarker$hash') != null) {
        writes['$ruleMarker$hash'] = null;
      }
    }
    for (final row in _db.select(
      "SELECT key FROM v2_sync_state WHERE namespace=? AND key LIKE 'aiw:done:%'",
      [namespace],
    )) {
      final hash = (row['key'] as String).substring(doneMarker.length);
      if (!rejected.contains(hash)) writes[row['key'] as String] = null;
    }
    for (final row in _db.select(
      "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'ai:%'",
      [namespace],
    )) {
      final hash = (row['key'] as String).substring('ai:'.length);
      if (rejected.contains(hash) ||
          shared.rules.any((rule) => rule.id == 'AI-$hash')) {
        continue;
      }
      final Map result;
      try {
        result = jsonDecode(row['value'] as String) as Map;
      } catch (_) {
        continue;
      }
      final marker = state.get('$ruleMarker$hash');
      if (result['status'] == 'ready' && result['rule'] is Map) {
        final fingerprint = sha256
            .convert(utf8.encode(canonicalJson(result['rule'])))
            .toString();
        if (marker == fingerprint) continue;
        if (marker != null) hashes.add(hash);
        writes['$ruleMarker$hash'] = fingerprint;
      } else if (result['status'] == 'pending' && marker != null) {
        hashes.add(hash);
        writes['$ruleMarker$hash'] = null;
      }
    }
    return (
      hashes: hashes,
      commit: () {
        writes.forEach((key, value) {
          if (value == null) {
            _db.execute(
              'DELETE FROM v2_sync_state WHERE namespace=? AND key=?',
              [namespace, key],
            );
          } else {
            state.put(key, value);
          }
        });
      },
    );
  }

  /// Withdraws the readings of [sources] and returns the sources to read again.
  /// A source the person has acted on (a user fact, or an event they confirmed)
  /// is left exactly as it is.
  ///
  /// [personChecked]: the caller has already left out every source the person
  /// acted on (with a check at least as strict), so it is not repeated.
  List<String> withdraw(List<String> candidates, {bool personChecked = false}) {
    final facts = FactStore(_db, namespace: namespace);
    final events = EventStore(_db, namespace: namespace);
    final ledger = LedgerStore(_db, namespace: namespace);
    // The events of every candidate in one look-up: the events table has no
    // index on its legs, so one look-up per source was one full scan each.
    final factsBySource = {
      for (final source in candidates) source: facts.forSource(source),
    };
    final eventsByFact = <String, List<Event>>{};
    for (final event in events.findByFactIds({
      for (final list in factsBySource.values)
        for (final fact in list) fact.factId,
    })) {
      for (final leg in event.legs) {
        (eventsByFact[leg.factId] ??= []).add(event);
      }
    }
    List<Event> eventsOf(String source) => {
      for (final fact in factsBySource[source] ?? const <Fact>[])
        for (final event in eventsByFact[fact.factId] ?? const <Event>[])
          event.eventId: event,
    }.values.toList();
    bool touched(String source) =>
        (factsBySource[source] ?? const <Fact>[]).any(
          (fact) => fact.provenance.engine == Engine.user,
        ) ||
        eventsOf(source).any(
          (e) =>
              e.status == EventStatus.userConfirmed &&
              !isRestoreOnly(_restoredMarks, e.eventId, e.decidedAt),
        );
    final sources = [
      for (final source in candidates)
        if (personChecked || !touched(source)) source,
    ];
    if (sources.isEmpty) return const [];
    financial.batch(() {
      _db.execute('SAVEPOINT sms_ai_withdraw');
      try {
        final affected = <String, Event>{};
        final factIds = <String>{};
        // The ledger rows of the withdrawn events: the queue holds them under
        // `ledger:<entryId>` (a hash of the event id), not `ledger:<eventId>`.
        var ledgerIdsOf = <String>{};
        for (final source in sources) {
          final sourceFacts = factsBySource[source] ?? const <Fact>[];
          factIds.addAll(sourceFacts.map((fact) => fact.factId));
          for (final event in eventsOf(source)) {
            affected[event.eventId] = event.type == EventType.unknown
                ? event
                : events.upsert(
                    event.copyWith(type: EventType.unknown),
                    // A recovered transaction is stored as confirmed, which the
                    // store would refuse to change otherwise.
                    fromUser: isRestoreOnly(
                      _restoredMarks,
                      event.eventId,
                      event.decidedAt,
                    ),
                  );
          }
        }
        if (affected.isNotEmpty) {
          // The facts and instrument links of the affected events only: the
          // whole fact history was read here (and again below) for each call.
          final legFactIds = {
            for (final event in affected.values)
              for (final leg in event.legs) leg.factId,
          };
          final allFacts = facts.byIds({...legFactIds, ...affected.keys});
          final instrumentIds = facts.instrumentIdsFor(legFactIds);
          ledgerIdsOf = {
            for (final entries in ledger.forEvents(affected.keys).values)
              for (final row in entries) row.entryId,
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
            instrumentIdByFactId: instrumentIds,
            userRules: categories.userRules,
            confirmedHistory: categories.confirmedHistory,
          );
          ProjectionWriter(financial, ledger).write(
            snapshot,
            factsById: allFacts,
            instrumentsById: instruments,
            categoryIdBySlug: categoryIdBySlug,
            instrumentIdByFactId: instrumentIds,
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
          // Its facts are gone: a queued copy of them must not reach the server.
          _db.execute('DELETE FROM v2_outbox WHERE namespace=? AND id=?', [
            namespace,
            'source:$source',
          ]);
          _db.execute("DELETE FROM v2_sync_state WHERE namespace=? AND key=?", [
            namespace,
            'trace:$source',
          ]);
        }
        for (final eventId in affected.keys) {
          // A review item about an event that is being withdrawn would point at
          // nothing; a fresh one is raised if the new reading is still unsure.
          _db.execute(
            "UPDATE v2_review_items SET status='resolved' WHERE namespace=? AND kind='event' AND json_extract(payload,'\$.eventId')=?",
            [namespace, eventId],
          );
          _db.execute(
            'DELETE FROM v2_events WHERE namespace=? AND event_id=?',
            [namespace, eventId],
          );
          _db.execute("DELETE FROM v2_outbox WHERE namespace=? AND id=?", [
            namespace,
            'event:$eventId',
          ]);
        }
        for (final entryId in ledgerIdsOf) {
          _db.execute("DELETE FROM v2_outbox WHERE namespace=? AND id=?", [
            namespace,
            'ledger:$entryId',
          ]);
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
