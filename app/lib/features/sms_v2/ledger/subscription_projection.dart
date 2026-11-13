import 'package:pandapay_domain/sms_v2.dart' as v2;
import 'package:sqlite3/sqlite3.dart';

import '../similar/fact_keys.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/subscription_store.dart';
import 'adapters.dart';
import 'subscription_state.dart';

/// Derives the saved subscription rows from the SMS ledger.
///
/// Deriving is O(history), so it is never done by a screen and never inside the
/// capture transaction. Anything that can change a subscription (capture, a
/// correction, a server pull, an AI withdrawal) only calls
/// [SubscriptionStore.markDirty]; the next reader re-derives once, off the UI
/// isolate ([rebuildSubscriptionsOffThread]). [touchesSubscriptions] decides
/// whether a chunk of captured messages is worth marking at all.
abstract final class SubscriptionProjection {
  /// Re-derives every row of [namespace] from the ledger in [db] and saves
  /// them. Returns false, writing nothing, when the ledger changed while this
  /// ran (see [SubscriptionStore.replaceAll]); the dirty flag then stays set.
  static bool rebuild(Database db, String namespace) {
    final store = SubscriptionStore(db, namespace: namespace);
    // Before the ledger is read: anything marked after this makes the write
    // below refuse, instead of overwriting newer facts with these rows.
    final seq = store.seq;
    final facts = FactStore(db, namespace: namespace).all();
    final events = EventStore(db, namespace: namespace).listSince(DateTime.utc(1900));
    return store.replaceAll(
      subscriptionStatesFromLedger(facts, events),
      subscriptionHistoryFromLedger(facts, events, now: DateTime.now()),
      basedOnSeq: seq,
    );
  }

  /// Re-derives the rows only when they are missing, out of date, or marked
  /// dirty, trying again (a few times) when the ledger moved under it. Returns
  /// true when it derived.
  static bool rebuildIfNeeded(Database db, String namespace) {
    if (SubscriptionStore(db, namespace: namespace).isCurrent) return false;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (rebuild(db, namespace)) break;
    }
    return true;
  }

  /// Whether any of [incoming] (already stored) can change a subscription:
  ///  - a mandate message (set up, paused, resumed, cancelled, expired);
  ///  - an announced or failed debit;
  ///  - a debit that carries a mandate reference (a charge under a mandate);
  ///  - a debit that can join a mandate already saved (no reference printed), or
  ///    a service's own receipt (evidence only) that merges with a bank debit;
  ///  - a spend at a shop that already has enough earlier spends to form a
  ///    repeating pattern (one indexed count, not a scan).
  ///
  /// An ordinary one-off purchase is not, so a normal day of SMS costs nothing.
  static bool touchesSubscriptions(
    Database db,
    String namespace,
    Iterable<v2.Fact> incoming,
  ) {
    final store = SubscriptionStore(db, namespace: namespace);
    // Never built: the first reader derives everything anyway.
    if (!store.isBuilt) return true;
    // The services a mandate or a setup message already names. A debit to one
    // of them can join its mandate (by amount and name, with no mandate
    // reference printed), which is how a subscription charge is found.
    List<String>? serviceKeys;
    List<String> keys() => serviceKeys ??= [
      for (final s in store.states())
        if (s.kind == SubscriptionStateKind.mandate) s.key,
    ];
    final countAtShop = db.prepare(
      'SELECT COUNT(*) AS n FROM v2_facts INDEXED BY idx_v2_facts_merchant '
      "WHERE namespace=? AND merchant_key=? AND fact_type='movement'",
    );
    try {
      for (final f in incoming) {
        if (f is v2.MandateFact) return true;
        if (f is v2.AttemptFact &&
            (f.status == v2.AttemptStatus.failed ||
                (f.status == v2.AttemptStatus.scheduled && f.dueAt != null))) {
          return true;
        }
        if (f is v2.MovementFact) {
          if (f.mandateRef != null) return true;
          if (f.direction != v2.Direction.debit) continue;
          // A service's own receipt names it differently from the bank's payee;
          // the two are merged when the linker joins them.
          if (f.evidenceOnly == true) {
            if (f.counterparty?.name != null) return true;
            continue;
          }
          final shop = FactKeys.of(f).merchantKey;
          if (shop == null) continue;
          if (keys().any(
            (k) => k == shop || shop.startsWith('$k ') || k.startsWith('$shop '),
          )) {
            return true;
          }
          final n = countAtShop.select([namespace, shop]).single['n'] as int;
          if (n >= 3) return true;
        }
      }
      return false;
    } finally {
      countAtShop.dispose();
    }
  }
}
