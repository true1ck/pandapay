import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../data/local/financial_store.dart';
import '../category/category_snapshot.dart';
import 'package:pandapay_domain/sms_v2_category.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import '../storage/outbox_store.dart';
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';

class HistoryCategoryReport {
  const HistoryCategoryReport(this.data);
  final Map<String, Object?> data;
  bool get complete => data['complete'] == true;
  int get changed => data['changed'] as int;
  int get preservedUser => data['preservedUser'] as int;
  int get processed => data['processed'] as int;
  int get total => data['total'] as int;
  int get awaitingSync => data['awaitingSync'] as int? ?? 0;

  /// Spends this pass could not look at, and why (reason word -> how many).
  /// One spend that cannot be re-sorted never stops the rest.
  int get failed => data['failed'] as int? ?? 0;
  Map<String, int> get failedWhy => {
    for (final entry in ((data['failedWhy'] as Map?) ?? const {}).entries)
      '${entry.key}': (entry.value as num).toInt(),
  };
  Map<String, Object?> toJson() => Map.of(data);
}

/// Categories the rules chose on their own. A person's own choice (`user`) and
/// one they confirmed through history (`historyConfirmed`) are never in this set.
const automaticCategorySources = <CategorySource>{
  CategorySource.fallback,
  CategorySource.catalogue,
  CategorySource.shared,
  CategorySource.mcc,
  CategorySource.ai,
};

/// An explicitly requested category pass. Ordinary sync never invokes it,
/// except through [HistoryCategoryRecheck.automaticChoices] once per shared
/// rule-set revision. Stored money facts and event identities keep their
/// existing authority.
class HistoryCategoryRecheck {
  HistoryCategoryRecheck({
    required this.financial,
    required this.namespace,
    required this.bundle,
    required this.from,
    required this.to,
    required this.accountIsCurrent,
    this.categoryIdBySlug = const {},
    this.onlySources,
    this.onlyEventIds,
    this.dryRun = false,
  }) {
    if (!from.isBefore(to)) throw ArgumentError('Choose a nonempty period');
    SmsV2Schema.ensure(db);
  }

  /// Every spend in the account's history, re-categorised only where the
  /// current decision came from the rules (see [automaticCategorySources]).
  /// The user's own choices and confirmed history are left exactly as they are.
  factory HistoryCategoryRecheck.automaticChoices({
    required FinancialStore financial,
    required String namespace,
    required RuleBundle bundle,
    required bool Function() accountIsCurrent,
    Map<String, String> categoryIdBySlug = const {},
    DateTime? now,
  }) => HistoryCategoryRecheck(
    financial: financial,
    namespace: namespace,
    bundle: bundle,
    from: DateTime.utc(1970),
    to: (now ?? DateTime.now()).toUtc().add(const Duration(days: 2)),
    accountIsCurrent: accountIsCurrent,
    categoryIdBySlug: categoryIdBySlug,
    onlySources: automaticCategorySources,
  );

  /// When set, only decisions from these sources are recomputed; every other
  /// decision stays locked.
  final Set<CategorySource>? onlySources;

  /// When set, only these events are looked at (a bulk change from the edit
  /// screen); the period then only bounds which of them count.
  final Set<String>? onlyEventIds;

  /// Looks at every spend and counts what would change, but writes nothing:
  /// no category, no queue entry, no saved progress. It reads the live
  /// database. (The first version of the preview worked on an in-memory copy
  /// made with SQLite's backup, which an encrypted SQLCipher database cannot
  /// give to a plain one, so it never worked on a phone.)
  final bool dryRun;

  final FinancialStore financial;
  final String namespace;
  final RuleBundle bundle;
  final DateTime from, to;
  final bool Function() accountIsCurrent;
  final Map<String, String> categoryIdBySlug;
  Database get db => financial.database.db;
  late final _state = SyncStateStore(db, namespace: namespace);
  late final _events = EventStore(db, namespace: namespace);
  late final _facts = FactStore(db, namespace: namespace);
  late final _ledger = LedgerStore(db, namespace: namespace);
  late final _queue = OutboxStore(db, namespace: namespace);

  // A changed bundle or newly imported event set creates a new explicit job.
  // Runtime downloads do not call this operation.
  Set<String> _pendingMoneyEvents() => {
    // json_extract reads the id inside SQLite; decoding every pending payload
    // in Dart for each chunk of 25 events was the larger share of this call.
    for (final row in db.select(
      "SELECT json_extract(payload,'\$.eventId') AS event_id FROM v2_outbox WHERE namespace=? AND kind='ledger' AND coalesce(json_extract(payload,'\$._categoryOnly'),0)!=1",
      [namespace],
    ))
      row['event_id'] as String,
  };
  late final _periodEvents = onlyEventIds != null
      ? {
          for (final id in onlyEventIds!)
            if (_events.get(id) case final event?)
              if (!event.occurredAt.isBefore(from) &&
                  event.occurredAt.isBefore(to))
                event.eventId,
        }
      : _events
            .listSince(from)
            .where((event) => event.occurredAt.isBefore(to))
            .map((event) => event.eventId)
            .toSet();
  late final _awaiting = _periodEvents.intersection(_pendingMoneyEvents());
  late final _targets = _periodEvents.difference(_awaiting).toList()..sort();
  String get _key {
    final personal = CategorySnapshot.load(
      financial.database,
      namespace: namespace,
      aliases: bundle.merchantAliases,
    );
    final revision = canonicalJson({
      'version': 1,
      'categories': bundle.categoryRules.map((rule) => rule.toJson()).toList(),
      'aliases': bundle.merchantAliases.map((alias) => alias.toJson()).toList(),
      'taxonomy': bundle.taxonomyVersion,
      'personalRules': personal.userRules.map((rule) => rule.toJson()).toList(),
      'confirmedHistory': personal.confirmedHistory,
      'userDecisions': {
        for (final entry in _ledger.categoryDecisions().entries) // perf-ok: once per run, not per chunk
          if (entry.value.source == CategorySource.user)
            entry.key: entry.value.slug,
      },
      'from': from.toUtc().toIso8601String(),
      'to': to.toUtc().toIso8601String(),
      if (onlySources != null)
        'onlySources': (onlySources!.map((source) => source.wire).toList()
          ..sort()),
      'targets': _targets,
    });
    return 'history:categories:${sha256.convert(utf8.encode(revision))}';
  }

  void _check() {
    if (!accountIsCurrent()) throw StateError('History account changed');
  }

  /// Works out what a pass would do; nothing on the phone changes. [restart]
  /// looks at every spend again even when this rule set was already applied.
  Future<HistoryCategoryReport> preview({bool restart = false}) {
    _check();
    return HistoryCategoryRecheck(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      from: from,
      to: to,
      categoryIdBySlug: categoryIdBySlug,
      accountIsCurrent: accountIsCurrent,
      onlySources: onlySources,
      onlyEventIds: onlyEventIds,
      dryRun: true,
    ).run(restart: restart);
  }

  /// [restart] ignores a saved "already done" record for the same rules and
  /// looks at every spend again: the person asked for a fresh pass.
  Future<HistoryCategoryReport> run({
    int chunkSize = 25,
    bool Function()? shouldContinue,
    void Function(HistoryCategoryReport)? onProgress,
    bool restart = false,
  }) async {
    if (chunkSize < 1 || chunkSize > 50) {
      throw ArgumentError('Use chunks of 1 to 50 events');
    }
    _check();
    final key = _key;
    final saved = restart ? null : _state.get(key);
    final progress = saved == null
        ? <String, Object?>{
            'complete': false,
            'processed': 0,
            'changed': 0,
            'preservedUser': 0,
            'from': from.toUtc().toIso8601String(),
            'to': to.toUtc().toIso8601String(),
            'bundleVersion': bundle.bundleVersion,
            // The key fingerprints the sorted targets. Reconstruct them on
            // resume rather than rewriting thousands of IDs after each chunk.
            'total': _targets.length,
            'awaitingSync': _awaiting.length,
          }
        : (jsonDecode(saved) as Map).cast<String, Object?>();
    if (progress['complete'] == true) {
      return HistoryCategoryReport({
        ...progress,
        'changed': 0,
        'alreadyApplied': true,
      });
    }
    final targets = _targets;
    while ((progress['processed'] as int) < targets.length) {
      _check();
      if (shouldContinue?.call() == false) break;
      final ids = targets
          .skip(progress['processed'] as int)
          .take(chunkSize)
          .toSet();
      // A spend linked to one that is still waiting to be sent is held back
      // for a later pass; it must not stop the rest of the history.
      final pending = _pendingMoneyEvents();
      final ready = pending.isEmpty
          ? ids
          : ids.where((id) => !_linkedToPending(id, pending)).toSet();
      progress['held'] =
          (progress['held'] as int? ?? 0) + (ids.length - ready.length);
      void step() {
        final counts = _applyIsolating(ready, progress);
        progress['processed'] = (progress['processed'] as int) + ids.length;
        progress['changed'] = (progress['changed'] as int) + counts.$1;
        progress['preservedUser'] =
            (progress['preservedUser'] as int) + counts.$2;
      }

      if (dryRun) {
        step();
      } else {
        financial.batch(() {
          db.execute('SAVEPOINT history_categories');
          try {
            step();
            _state.put(key, jsonEncode(progress));
            db.execute('RELEASE history_categories');
          } catch (_) {
            db.execute('ROLLBACK TO history_categories');
            db.execute('RELEASE history_categories');
            rethrow;
          }
        });
      }
      onProgress?.call(HistoryCategoryReport(Map.of(progress)));
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    _check();
    final held = progress['held'] as int? ?? 0;
    progress['awaitingSync'] = _awaiting.length + held;
    progress['complete'] = progress['processed'] == targets.length;
    if (dryRun) {
      // Nothing is saved: the pass was only a look.
    } else if (held > 0 || (progress['failed'] as int? ?? 0) > 0) {
      // Held spends were skipped: forget this job so the next pass looks at
      // every spend again once what they wait for has been sent.
      db.execute('DELETE FROM v2_sync_state WHERE namespace=? AND key=?', [
        namespace,
        key,
      ]);
    } else {
      _state.put(key, jsonEncode(progress));
    }
    return HistoryCategoryReport(Map.of(progress));
  }

  /// [_apply] for a chunk; if its checks refuse the chunk (a [StateError]),
  /// each spend is tried alone so one that cannot be re-sorted is counted, with
  /// the reason, and the rest still are. `_apply` checks everything before it
  /// writes anything, so a refusal leaves the chunk untouched. A failed write (a
  /// database error) is not a refusal: it propagates and rolls the chunk back.
  (int, int) _applyIsolating(Set<String> ready, Map<String, Object?> progress) {
    try {
      return _apply(ready);
    } catch (error) {
      if (!_skippable(error)) rethrow;
      if (ready.length == 1) {
        _countFailure(progress, error);
        return (0, 0);
      }
    }
    var changed = 0, kept = 0;
    for (final id in ready) {
      try {
        final one = _apply({id});
        changed += one.$1;
        kept += one.$2;
      } catch (error) {
        if (!_skippable(error)) rethrow;
        _countFailure(progress, error);
      }
    }
    return (changed, kept);
  }

  /// A check that refuses a spend ([StateError]) is skippable. A look that
  /// writes nothing may also skip a spend whose data surprised the code (a
  /// type or range error). A database error never is, and while changing
  /// anything only the checks are: a surprise after a write began must roll
  /// the chunk back.
  bool _skippable(Object error) =>
      error is StateError || (dryRun && error is! SqliteException);

  void _countFailure(Map<String, Object?> progress, Object error) {
    progress['failed'] = (progress['failed'] as int? ?? 0) + 1;
    final why = ((progress['failedWhy'] as Map?) ?? const {})
        .cast<String, Object?>();
    final reason = failureReason(error);
    progress['failedWhy'] = {
      ...why,
      reason: ((why[reason] as int?) ?? 0) + 1,
    };
  }

  /// A short word for why a spend could not be looked at: a fixed set of
  /// words, never a message that could carry a value.
  static String failureReason(Object error) {
    final text = '$error';
    if (text.contains('Sync pending money')) return 'waiting_to_send';
    if (text.contains('changed money')) return 'money_would_change';
    // Type names are obfuscated in a release build, so each kind of failure
    // gets its own word here.
    return switch (error) {
      StateError() => 'inconsistent_data',
      RangeError() => 'unexpected_range',
      ArgumentError() => 'unexpected_value',
      SqliteException() => 'database_error',
      TypeError() => 'unexpected_type',
      FormatException() => 'unexpected_format',
      UnsupportedError() => 'unsupported',
      _ => 'error',
    };
  }

  /// True when this event, or one linked to it through a shared fact (a
  /// purchase and its refund), is still waiting to be sent to the account.
  bool _linkedToPending(String id, Set<String> pending) {
    if (pending.contains(id)) return true;
    final event = _events.get(id);
    if (event == null) return false;
    final legIds = event.legs.map((leg) => leg.factId).toSet();
    return _events
        .findByFactIds(legIds)
        .any((e) => pending.contains(e.eventId));
  }

  /// Display transactions of the given events, grouped by event id, read with a
  /// single scan per 400 events.
  Map<String, List<_TransactionRow>> _transactionRowsByEvent(
    Iterable<String> eventIds,
  ) {
    final ids = eventIds.toList();
    final result = <String, List<_TransactionRow>>{};
    for (var start = 0; start < ids.length; start += 400) {
      final group = ids.sublist(start, (start + 400).clamp(0, ids.length));
      for (final row in db.select(
        "SELECT id,payload,json_extract(payload,'\$.event_id') AS event_id,"
        "json_extract(payload,'\$.user_category_id') IS NOT NULL AS custom "
        "FROM financial_entities WHERE namespace=? AND entity='transactions' "
        "AND json_extract(payload,'\$.event_id') IN (${List.filled(group.length, '?').join(',')})",
        [namespace, ...group],
      )) {
        (result[row['event_id'] as String] ??= []).add(
          _TransactionRow(
            row['id'],
            row['payload'] as String,
            (row['custom'] as int) == 1,
          ),
        );
      }
    }
    return result;
  }

  (int, int) _apply(Set<String> targetIds) {
    final affected = <String, Event>{
      for (final id in targetIds) id: ?_events.get(id),
    };
    // Include the purchase for a refund, and refunds linked to a selected
    // purchase. Their category must stay consistent across month boundaries.
    final legIds = affected.values
        .expand((e) => e.legs.map((l) => l.factId))
        .toSet();
    for (final related in _events.findByFactIds(legIds)) {
      affected[related.eventId] = related;
    }
    if (_pendingMoneyEvents().any(affected.containsKey)) {
      throw StateError(
        'Sync pending money changes before refreshing categories',
      );
    }
    final facts = <String, Fact>{
      for (final event in affected.values)
        for (final leg in event.legs) leg.factId: ?_facts.get(leg.factId),
    };
    final instruments = {
      for (final instrument in InstrumentStore(db, namespace: namespace).list())
        instrument.instrumentId: instrument,
    };
    final instrumentIds = <String, String>{};
    final factKeys = facts.keys.toList();
    for (var start = 0; start < factKeys.length; start += 400) {
      final group = factKeys.skip(start).take(400).toList();
      for (final row in db.select(
        'SELECT fact_id,instrument_id FROM v2_facts WHERE namespace=? AND instrument_id IS NOT NULL '
        'AND fact_id IN (${List.filled(group.length, '?').join(',')})',
        [namespace, ...group],
      )) {
        instrumentIds[row['fact_id'] as String] = row['instrument_id'] as String;
      }
    }
    final before = _ledger.categoryDecisions(eventIds: affected.keys.toSet());
    // Custom user categories have no slug in the frozen ledger contract.
    // Preserve both the display choice and its existing ledger attribution.
    // One table scan for the whole chunk (there is no index on the JSON
    // event id): per-event lookups made this pass quadratic on the UI thread.
    final transactionRows = _transactionRowsByEvent(affected.keys);
    final customCategories = <String>{
      for (final entry in transactionRows.entries)
        if (entry.value.any((row) => row.hasCustomCategory)) entry.key,
    };
    final locked = Map<String, CategoryDecision>.of(before)
      ..removeWhere(
        (id, decision) =>
            !customCategories.contains(id) &&
            decision.source != CategorySource.user &&
            (onlySources == null || onlySources!.contains(decision.source)) &&
            (affected[id]!.type == EventType.refund ||
                affected[id]!.occurredAt.isBefore(to) &&
                    !affected[id]!.occurredAt.isBefore(from)),
      );
    final purchaseFacts = {
      for (final event in affected.values)
        if (spendEventTypes.contains(event.type)) ...{
          event.eventId,
          ...event.legs.map((leg) => leg.factId),
        },
    };
    for (final event in affected.values) {
      if (event.type == EventType.refund &&
          !customCategories.contains(event.eventId) &&
          event.legs.any(
            (leg) =>
                leg.role == LegRole.original &&
                purchaseFacts.contains(leg.factId),
          )) {
        locked.remove(event.eventId);
      }
    }
    final categories = CategorySnapshot.load(
      financial.database,
      namespace: namespace,
      aliases: bundle.merchantAliases,
    );
    final snapshot = LedgerSnapshot.project(
      events: affected.values,
      factsById: facts,
      instrumentsById: instruments,
      instrumentIdByFactId: instrumentIds,
      bundle: bundle,
      userRules: categories.userRules,
      confirmedHistory: categories.confirmedHistory,
      lockedCategories: locked,
    );
    final changed = snapshot.categoryByEvent.entries
        .where((entry) {
          if (customCategories.contains(entry.key)) return false;
          final old = before[entry.key];
          final next = entry.value;
          return old?.slug != next.slug ||
              old?.source != next.source ||
              old?.ruleId != next.ruleId ||
              old?.confidence != next.confidence;
        })
        .map((entry) => entry.key)
        .toSet();
    // A category pass may never change money, counts, dates or instrument legs.
    final storedRows = _ledger.forEvents(snapshot.events.map((e) => e.eventId));
    final projectedRows = <String, List<LedgerEntry>>{};
    for (final entry in snapshot.entries) {
      (projectedRows[entry.eventId] ??= []).add(entry);
    }
    for (final event in snapshot.events) {
      // Same order as LedgerStore.forEvent (entry id), which the comparison
      // below has always used.
      final old = [...?storedRows[event.eventId]]
        ..sort((a, b) => a.entryId.compareTo(b.entryId));
      final updated = projectedRows[event.eventId] ?? const <LedgerEntry>[];
      Map<String, Object?> money(LedgerEntry row) => Map.of(row.toJson())
        ..remove('category')
        ..remove('categorySource');
      if (canonicalJson(old.map(money).toList()) !=
          canonicalJson(updated.map(money).toList())) {
        throw StateError('History category check changed money');
      }
    }
    if (changed.isNotEmpty && !dryRun) {
      final update = LedgerSnapshot(
        events: snapshot.events.where((e) => changed.contains(e.eventId)),
        entries: snapshot.entries.where((e) => changed.contains(e.eventId)),
        categoryByEvent: snapshot.categoryByEvent,
      );
      for (final event in update.events) {
        _ledger.replaceForEvent(
          event.eventId,
          update.entries.where((entry) => entry.eventId == event.eventId),
          category: update.categoryByEvent[event.eventId],
        );
        final category = update.categoryByEvent[event.eventId];
        if (category == null) continue;
        // Change only automatic display categorization. Preserve all other
        // fields, including a pending deletion and corrected amounts/merchants.
        for (final row in transactionRows[event.eventId] ?? const []) {
          final payload = (jsonDecode(row.payload) as Map)
              .cast<String, Object?>();
          payload['category_id'] = TaxonomyRegistry.v1.categoryIdForSlug(
            category.slug,
            categoryIdBySlug,
          );
          payload['category_name'] = TaxonomyRegistry.v1
              .categoryFor(category.slug)
              ?.displayName;
          db.execute(
            "UPDATE financial_entities SET payload=? WHERE namespace=? AND entity='transactions' AND id=?",
            [jsonEncode(payload), namespace, row.id],
          );
        }
      }
      for (final entry in update.entries) {
        _queue.enqueue(
          'ledger',
          entry.entryId,
          entry.toJson(),
          backfill: true,
          categoryOnly: true,
        );
      }
      financial.notifyExternalChanges(namespace, const [
        'transactions',
        'observations',
      ]);
    }
    return (
      changed.length,
      targetIds
          .where(
            (id) =>
                customCategories.contains(id) ||
                locked[id]?.source == CategorySource.user,
          )
          .length,
    );
  }
}

class _TransactionRow {
  const _TransactionRow(this.id, this.payload, this.hasCustomCategory);
  final Object? id;
  final String payload;
  final bool hasCustomCategory;
}
