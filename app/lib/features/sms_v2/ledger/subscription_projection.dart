import 'package:pandapay_domain/sms_v2.dart' as v2;
import 'package:sqlite3/sqlite3.dart';

import '../similar/fact_keys.dart';
import '../storage/event_store.dart';
import '../storage/fact_store.dart';
import '../storage/subscription_store.dart';
import 'adapters.dart';

/// Derives the saved subscription rows from the SMS ledger.
///
/// Deriving is O(history), so it is never done by a screen. It runs where the
/// ledger is written (the capture worker's transaction, after the messages of a
/// chunk are stored) and only when something that can change a subscription
/// arrived ([touchesSubscriptions]). Paths that change the ledger without going
/// through capture (a correction, a server pull) only [SubscriptionStore.markDirty];
/// the next reader re-derives once, off the UI isolate.
abstract final class SubscriptionProjection {
  /// Re-derives every row of [namespace] from the ledger in [db] and saves
  /// them, clearing the dirty flag.
  static void rebuild(Database db, String namespace) {
    final facts = FactStore(db, namespace: namespace).all();
    final events = EventStore(db, namespace: namespace).listSince(DateTime.utc(1900));
    SubscriptionStore(db, namespace: namespace).replaceAll(
      subscriptionStatesFromLedger(facts, events),
      subscriptionHistoryFromLedger(facts, events, now: DateTime.now()),
    );
  }

  /// Re-derives the rows only when they are missing, out of date, or marked
  /// dirty. Returns true when it did.
  static bool rebuildIfNeeded(Database db, String namespace) {
    if (SubscriptionStore(db, namespace: namespace).isCurrent) return false;
    rebuild(db, namespace);
    return true;
  }

  /// Whether any of [incoming] (already stored) can change a subscription:
  ///  - a mandate message (set up, paused, resumed, cancelled, expired);
  ///  - an announced or failed debit;
  ///  - a debit that carries a mandate reference (a charge under a mandate);
  ///  - a spend at a shop that already has enough earlier spends to form a
  ///    repeating pattern (one indexed count, not a scan).
  ///
  /// An ordinary one-off purchase is not, so a normal day of SMS costs nothing.
  static bool touchesSubscriptions(
    Database db,
    String namespace,
    Iterable<v2.Fact> incoming,
  ) {
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
          if (f.direction != v2.Direction.debit || f.evidenceOnly == true) continue;
          final shop = FactKeys.of(f).merchantKey;
          if (shop == null) continue;
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
