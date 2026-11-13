import 'package:pandapay_domain/sms_v2.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_intake_repository.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import 'ai_withdrawal.dart';

/// Which earlier salary credits should be read again because they were read
/// without saying who paid.
///
/// Money already read is frozen: a better rule (one that now finds the employer
/// in the narration) does not touch the events an older rule made. The salary
/// was counted, but the row shows "Unknown sender" for ever. When the rules
/// change, those messages are withdrawn and read again, so the payer appears
/// wherever the current rules can find one.
///
/// Careful on purpose, because a withdrawal deletes whole events (the same
/// guards as [OwnerRecheck]):
///
/// * every message joined to a candidate is included, so no leg is left
///   without its event;
/// * a group is skipped when the person edited or confirmed any part of it;
/// * a group is skipped when any of its original messages is no longer on the
///   phone, since it could not be read again.
///
/// Cost is bounded for a big inbox: one filtered query finds the candidates
/// (a handful of rows), and event lookups are batched, because the event table
/// has no index on its legs and every lookup scans it.
class SalaryRecheck {
  SalaryRecheck({
    required this.financial,
    required this.namespace,
    required this.bundle,
    this.categoryIdBySlug = const {},
  });

  final FinancialStore financial;
  final String namespace;
  final RuleBundle bundle;
  final Map<String, String> categoryIdBySlug;

  /// The messages to read again: salary credits whose reading names no payer.
  List<String> sourcesToRecheck() {
    final db = financial.database.db;
    final facts = FactStore(db, namespace: namespace);
    final events = EventStore(db, namespace: namespace);

    // One scan, filtered in SQL. Only salary credits that name nobody come back.
    final candidates = db.select(
      "SELECT fact_id, source_key FROM v2_facts "
      "WHERE namespace = ? AND fact_type = 'movement' "
      "AND json_extract(payload, '\$.attrs.purpose') = 'salary' "
      "AND json_extract(payload, '\$.attrs.direction') = 'credit' "
      "AND json_extract(payload, '\$.counterparty.name') IS NULL "
      "AND json_extract(payload, '\$.counterparty.vpa') IS NULL",
      [namespace],
    );
    if (candidates.isEmpty) return const [];

    final factsById = <String, Fact>{};
    final eventsByFact = <String, List<Event>>{};
    final queried = <String>{};
    final sourcesLoaded = <String>{};

    void loadSources(Iterable<String> sources) {
      final fresh = [
        for (final s in sources)
          if (sourcesLoaded.add(s)) s,
      ];
      for (final s in fresh) {
        for (final f in facts.forSource(s)) {
          factsById[f.factId] = f;
        }
      }
      // One event scan for every fact not asked about yet.
      final ids = [
        for (final id in factsById.keys)
          if (queried.add(id)) id,
      ];
      if (ids.isEmpty) return;
      for (final e in events.findByFactIds(ids)) {
        for (final l in e.legs) {
          final list = eventsByFact.putIfAbsent(l.factId, () => []);
          if (!list.any((x) => x.eventId == e.eventId)) list.add(e);
        }
      }
    }

    loadSources([for (final r in candidates) r['source_key'] as String]);

    final seeds = <Event>[];
    for (final r in candidates) {
      final id = r['fact_id'] as String;
      for (final e in eventsByFact[id] ?? const <Event>[]) {
        // Salary counted as income. Anything else (a transfer between own
        // accounts, say) is left to its own rules.
        if (e.type == EventType.income) seeds.add(e);
      }
    }
    if (seeds.isEmpty) return const [];

    final intake = SmsIntakeRepository(financial.database);
    final withdrawal = AiWithdrawal(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      categoryIdBySlug: categoryIdBySlug,
    );
    final out = <String>{};
    final done = <String>{};
    for (final seed in seeds) {
      if (done.contains(seed.eventId)) continue;
      // Everything joined to this event, however far the joins reach.
      final groupEvents = <String>{};
      final groupSources = <String>{};
      var ok = true;
      final queue = [seed];
      while (queue.isNotEmpty && ok) {
        final e = queue.removeLast();
        if (!groupEvents.add(e.eventId)) continue;
        for (final l in e.legs) {
          final f = factsById[l.factId] ?? facts.get(l.factId);
          if (f == null) {
            ok = false;
            break;
          }
          factsById[f.factId] = f;
          if (groupSources.add(f.sourceKey)) {
            loadSources([f.sourceKey]);
            for (final sf in facts.forSource(f.sourceKey)) {
              queue.addAll(eventsByFact[sf.factId] ?? const []);
            }
          }
        }
      }
      done.addAll(groupEvents);
      if (!ok) continue;
      final usable = groupSources.every(
        (source) =>
            intake.capturedById(namespace, source) != null &&
            !withdrawal.touchedByPerson(source),
      );
      if (usable) out.addAll(groupSources);
    }
    return out.toList()..sort();
  }
}
