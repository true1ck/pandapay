import 'package:pandapay_domain/sms_v2.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/local/sms_intake_repository.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import 'ai_withdrawal.dart';

/// Which earlier transactions change when the account owner's identity does.
///
/// Money already read is frozen: reading the same messages again with a newly
/// known name does not touch the events they made. So when the owner types
/// their name, marks a payee as their own, or says "not me", the messages whose
/// reading would now differ are withdrawn and read again.
///
/// This is deliberately careful, because a withdrawal deletes whole events:
///
/// * every message joined to a candidate is included (both legs of a transfer,
///   anything that shares an event), so no leg is left without its event;
/// * a group is skipped when the person edited or confirmed any part of it;
/// * a group is skipped when any of its original messages is no longer on the
///   phone, since it could not be read again.
///
/// A payment is "the person's" when it is to or from their own account, a family
/// member they marked, or one payment they marked on its own. Family and own
/// transfers are both left out of spending; they differ only in the badge.
class OwnerRecheck {
  OwnerRecheck({
    required this.financial,
    required this.namespace,
    required this.bundle,
    this.categoryIdBySlug = const {},
  });

  final FinancialStore financial;
  final String namespace;
  final RuleBundle bundle;
  final Map<String, String> categoryIdBySlug;

  static const _movesToTransfer = {
    EventType.purchase,
    EventType.p2pOut,
    EventType.p2pIn,
    EventType.income,
  };

  /// The messages to read again so every event agrees with [identity].
  ///
  /// With [revertUnmatched] a single-leg own transfer whose payee no longer
  /// matches (the person removed a name) is read again too.
  List<String> sourcesToRecheck(
    OwnerIdentity identity, {
    bool revertUnmatched = false,
  }) {
    final db = financial.database.db;
    final facts = FactStore(db, namespace: namespace);
    final events = EventStore(db, namespace: namespace);
    final intake = SmsIntakeRepository(financial.database);
    final withdrawal = AiWithdrawal(
      financial: financial,
      namespace: namespace,
      bundle: bundle,
      categoryIdBySlug: categoryIdBySlug,
    );
    final factsById = {
      for (final f in facts.since(DateTime.utc(1900))) f.factId: f,
    };
    final all = events.listSince(DateTime.utc(1900));
    final eventsByFact = <String, List<Event>>{};
    for (final e in all) {
      for (final l in e.legs) {
        eventsByFact.putIfAbsent(l.factId, () => []).add(e);
      }
    }

    bool ownCounterparty(Counterparty? c) =>
        c != null &&
        (c.kind == CounterpartyKind.own ||
            identity.matchesName(c.name) ||
            identity.matchesVpa(c.vpa) ||
            identity.matchesAccountMask(c.accountMask));
    bool rejected(Counterparty? c) =>
        c != null &&
        (identity.rejectsName(c.name) ||
            identity.rejectsVpa(c.vpa) ||
            identity.rejectsAccountMask(c.accountMask));
    // A payment the person made theirs: their own account, a family member, or
    // this single payment ("only this one").
    bool isFamily(MovementFact f) =>
        !identity.isMarkedSelfOnce(f.sourceKey) &&
        identity.isFamilyTransfer(
          name: f.counterparty?.name,
          vpa: f.counterparty?.vpa,
          mask: f.counterparty?.accountMask,
          sourceKey: f.sourceKey,
        );
    bool own(MovementFact f) =>
        ownCounterparty(f.counterparty) ||
        identity.isMarkedSelfOnce(f.sourceKey) ||
        isFamily(f);

    // The badge each transfer shows now, so a payee that was a self transfer and
    // becomes family (or the other way round) is read again.
    final shownType = <String, String?>{
      for (final row in db.select(
        "SELECT json_extract(payload,'\$.event_id') AS e, "
        "json_extract(payload,'\$.transfer_type') AS t "
        "FROM financial_entities WHERE namespace=? AND entity='transactions' "
        "AND json_extract(payload,'\$.entry_kind')='transfer'",
        [namespace],
      ))
        if (row['e'] is String) row['e'] as String: row['t'] as String?,
    };

    bool needsRecheck(Event e) {
      final moves = [
        for (final l in e.legs)
          if (factsById[l.factId] case final MovementFact f) f,
      ];
      if (moves.isEmpty) return false;
      if (_movesToTransfer.contains(e.type)) {
        return moves.any(own) &&
            !moves.any((f) => rejected(f.counterparty) && !isFamily(f));
      }
      if (e.type == EventType.ownTransfer) {
        if (moves.any((f) => rejected(f.counterparty) && !isFamily(f))) {
          return true;
        }
        final wantFamily = moves.any(isFamily);
        final shown = shownType[e.eventId];
        if (shown != null && wantFamily != (shown == 'family')) return true;
        if (!revertUnmatched || e.legs.length != 1) return false;
        final f = moves.single;
        final c = f.counterparty;
        return c != null &&
            (c.name != null || c.vpa != null) &&
            c.kind != CounterpartyKind.own &&
            c.accountMask == null &&
            !own(f);
      }
      return false;
    }

    final out = <String>{};
    final done = <String>{};
    for (final seed in all) {
      if (done.contains(seed.eventId) || !needsRecheck(seed)) continue;
      // Everything joined to this event, however far the joins reach.
      final groupEvents = <String>{};
      final groupSources = <String>{};
      var ok = true;
      final queue = [seed];
      while (queue.isNotEmpty && ok) {
        final e = queue.removeLast();
        if (!groupEvents.add(e.eventId)) continue;
        for (final l in e.legs) {
          final f = factsById[l.factId];
          if (f == null) {
            ok = false;
            break;
          }
          if (groupSources.add(f.sourceKey)) {
            // Every event any fact of this message belongs to.
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
