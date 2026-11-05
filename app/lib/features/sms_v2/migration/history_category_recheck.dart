import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../data/local/app_database.dart';
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
    for (final row in db.select(
      "SELECT payload FROM v2_outbox WHERE namespace=? AND kind='ledger' AND coalesce(json_extract(payload,'\$._categoryOnly'),0)!=1",
      [namespace],
    ))
      (jsonDecode(row['payload'] as String) as Map)['eventId'] as String,
  };
  late final _periodEvents = _events
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
        for (final entry in _ledger.categoryDecisions().entries)
          if (entry.value.source == CategorySource.user)
            entry.key: entry.value.slug,
      },
      'from': from.toUtc().toIso8601String(),
      'to': to.toUtc().toIso8601String(),
      if (onlySources != null)
        'onlySources': (onlySources!.map((source) => source.wire).toList()..sort()),
      'targets': _targets,
    });
    return 'history:categories:${sha256.convert(utf8.encode(revision))}';
  }

  void _check() {
    if (!accountIsCurrent()) throw StateError('History account changed');
  }

  Future<HistoryCategoryReport> preview() async {
    _check();
    final clone = sqlite3.openInMemory();
    FinancialStore? store;
    try {
      await db.backup(clone, nPage: 64).drain<void>();
      _check();
      store = FinancialStore(AppDatabase.forTesting(clone));
      return await HistoryCategoryRecheck(
        financial: store,
        namespace: namespace,
        bundle: bundle,
        from: from,
        to: to,
        categoryIdBySlug: categoryIdBySlug,
        accountIsCurrent: accountIsCurrent,
      ).run();
    } finally {
      store?.dispose();
      clone.dispose();
    }
  }

  Future<HistoryCategoryReport> run({
    int chunkSize = 25,
    bool Function()? shouldContinue,
    void Function(HistoryCategoryReport)? onProgress,
  }) async {
    if (chunkSize < 1 || chunkSize > 50) {
      throw ArgumentError('Use chunks of 1 to 50 events');
    }
    _check();
    final key = _key;
    final saved = _state.get(key);
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
      financial.batch(() {
        db.execute('SAVEPOINT history_categories');
        try {
          final counts = _apply(ids);
          progress['processed'] = (progress['processed'] as int) + ids.length;
          progress['changed'] = (progress['changed'] as int) + counts.$1;
          progress['preservedUser'] =
              (progress['preservedUser'] as int) + counts.$2;
          _state.put(key, jsonEncode(progress));
          db.execute('RELEASE history_categories');
        } catch (_) {
          db.execute('ROLLBACK TO history_categories');
          db.execute('RELEASE history_categories');
          rethrow;
        }
      });
      onProgress?.call(HistoryCategoryReport(Map.of(progress)));
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    _check();
    progress['complete'] = progress['processed'] == targets.length;
    _state.put(key, jsonEncode(progress));
    return HistoryCategoryReport(Map.of(progress));
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
    for (final id in facts.keys) {
      final rows = db.select(
        'SELECT instrument_id FROM v2_facts WHERE namespace=? AND fact_id=?',
        [namespace, id],
      );
      if (rows.firstOrNull?['instrument_id'] case final String instrument) {
        instrumentIds[id] = instrument;
      }
    }
    final before = _ledger.categoryDecisions(eventIds: affected.keys.toSet());
    // Custom user categories have no slug in the frozen ledger contract.
    // Preserve both the display choice and its existing ledger attribution.
    final customCategories = <String>{};
    for (final id in affected.keys) {
      if (db.select(
        "SELECT 1 FROM financial_entities WHERE namespace=? AND entity='transactions' AND json_extract(payload,'\$.event_id')=? AND json_extract(payload,'\$.user_category_id') IS NOT NULL LIMIT 1",
        [namespace, id],
      ).isNotEmpty) {
        customCategories.add(id);
      }
    }
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
    for (final event in snapshot.events) {
      final old = _ledger.forEvent(event.eventId);
      final updated = snapshot.entries
          .where((entry) => entry.eventId == event.eventId)
          .toList();
      Map<String, Object?> money(LedgerEntry row) => Map.of(row.toJson())
        ..remove('category')
        ..remove('categorySource');
      if (canonicalJson(old.map(money).toList()) !=
          canonicalJson(updated.map(money).toList())) {
        throw StateError('History category check changed money');
      }
    }
    if (changed.isNotEmpty) {
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
        for (final row in db.select(
          "SELECT id,payload FROM financial_entities WHERE namespace=? AND entity='transactions' AND json_extract(payload,'\$.event_id')=?",
          [namespace, event.eventId],
        )) {
          final payload = (jsonDecode(row['payload'] as String) as Map)
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
            [jsonEncode(payload), namespace, row['id']],
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
