import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/sms_v2.dart' as v2;
import 'package:pandapay_domain/sms_v2_ledger.dart';

import '../../../data/local/financial_store.dart';
import '../../../data/user_cards_repository.dart' show TransactionEntry;
import '../category/category_snapshot.dart';
import '../personal/owner_identity_store.dart';
import '../personal/personal_merchant_aliases.dart';
import '../storage/fact_store.dart';
import '../storage/instrument_store.dart';
import '../storage/ledger_store.dart';
import '../storage/outbox_store.dart';
import '../storage/subscription_store.dart';
import '../storage/sync_state_store.dart';
import 'projection_writer.dart';

/// Bump when the code that turns facts into ledger entries or display rows
/// changes what it writes (`transactionForEvent`, `DefaultLedgerProjector`,
/// `LedgerSnapshot.project`). Every phone then rebuilds its saved rows once, in
/// the background, instead of keeping rows an older build wrote.
///
/// 1: 15 Nov 2026 (b90e1257): a card SMS keeps its card type even when no card
///    record could be named; rows saved before said "Payment method not matched".
/// 2: 16 Nov 2026: a server copy no longer overwrites the phone's own reading
///    of how an SMS payment was made; rebuild the rows it had overwritten.
/// 3: 18 Nov 2026 (iPhone build 183 only): a narrower repair, replaced by 4.
/// 4: 18 Nov 2026: a message is always on the card or account it printed. A
///    stored link the message contradicts (another bank, another number) is
///    pointed back at the one it names (see [ProjectionRefresh]).
const int projectionCodeVersion = 4;

/// One slice of a refresh: how many events were read, how many of them were
/// rewritten, and whether the pass has more to do.
typedef ProjectionRefreshStep = ({int events, int changed, bool more});

/// Keeps the saved ledger entries and Activity rows equal to what the stored
/// facts and events say now.
///
/// A saved row is a copy, made when its message was read. What it is built
/// from can change later without the message being read again: a card is
/// linked to a wallet card, merged, renamed or marked "Not mine"; the person
/// renames a shop or marks a payee as their own; a new app version projects
/// differently. Each of those used to need its own partial repair, and rows the
/// repairs did not reach kept the old answer for good (in Nov 2026, 97% of one
/// phone's rows said "Payment method not matched" while their facts named the
/// card).
///
/// [revision] is a fingerprint of every such input. When it differs from the
/// one the last finished pass recorded, the next [step]s walk every event in
/// primary-key order, [defaultChunk] at a time, project each one again and
/// write only what differs. Nothing is read again from the messages and no
/// category moves: the stored decision of every event is kept (a re-sort stays
/// the person's own choice). Bounded (R1, R4, R5): one slice is one primary-key
/// range of events, their facts by id and their stored rows by the event-id
/// index; it runs in the capture worker, and the cursor survives the app being
/// closed.
///
/// One input is fixed on the way: a message whose stored card or account is
/// one the message itself rules out ([printedCardRulesOut]: another bank or
/// another number). In Nov 2026 a "wrong card" edit applied to similar
/// messages put 101 "SBI card ending 2837" spends on a PNB card ending 1260.
/// The projection already ignores such a link; the stored link is pointed
/// back at the card the message names (or cleared when that card is not
/// known), so every other reader of the link agrees.
class ProjectionRefresh {
  ProjectionRefresh({
    required this.financial,
    required this.namespace,
    required this.bundle,
    this.categoryIdBySlug = const {},
  });

  final FinancialStore financial;
  final String namespace;
  final v2.RuleBundle bundle;
  final Map<String, String> categoryIdBySlug;

  static const doneKey = 'derived:projection:done';
  static const targetKey = 'derived:projection:target';
  static const cursorKey = 'derived:projection:cursor';
  static const failuresKey = 'derived:projection:failures';
  static const defaultChunk = 250;

  late final _db = financial.database.db;
  late final _state = SyncStateStore(_db, namespace: namespace);

  /// Fingerprint of everything a saved row is built from, apart from the facts
  /// and events themselves (a capture or a correction re-projects the events it
  /// touches). Reads three small tables: the account's instruments (identity
  /// and link only, never balances, so an SMS that only moves a balance does
  /// not start a pass), the person's shop names and their owner marks.
  String revision() {
    final instruments = [
      for (final i in InstrumentStore(
        _db,
        namespace: namespace,
      ).list()..sort((a, b) => a.instrumentId.compareTo(b.instrumentId)))
        [
          i.instrumentId,
          i.kind.wire,
          i.issuerSlug,
          i.maskDigits,
          i.status.wire,
          i.userCardId,
          i.displayName,
        ],
    ];
    final aliases = [
      for (final row in _db.select(
        'SELECT printed_key, display_name, since FROM v2_personal_merchant_alias '
        'WHERE namespace = ? ORDER BY printed_key',
        [namespace],
      ))
        [row['printed_key'], row['display_name'], row['since']],
    ];
    final owner = [
      for (final row in _db.select(
        'SELECT entry, source FROM v2_owner_identity WHERE namespace = ? ORDER BY entry',
        [namespace],
      ))
        [row['entry'], row['source']],
    ];
    final categories =
        (categoryIdBySlug.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key)))
            .map((e) => [e.key, e.value])
            .toList();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              projectionCodeVersion,
              instruments,
              aliases,
              owner,
              categories,
            ]),
          ),
        )
        .toString();
  }

  /// Points each stored link in [factsById] that the message itself rules out
  /// ([printedCardRulesOut]) at the instrument the message names, found the
  /// way a new message is (no stored link), or clears it when none fits. Keeps
  /// [instrumentIdByFactId] in step; returns how many links changed. Only the
  /// slice's own facts are looked at.
  int _repairContradictedLinks(
    Map<String, v2.Fact> factsById,
    Map<String, String> instrumentIdByFactId,
    Map<String, v2.Instrument> instruments,
  ) {
    var repaired = 0;
    for (final fact in factsById.values) {
      final current = instrumentIdByFactId[fact.factId];
      final linked = current == null ? null : instruments[current];
      if (linked == null || !printedCardRulesOut(fact.instrument, linked)) {
        continue;
      }
      final named = instrumentForFact(fact, instruments);
      _db.execute(
        'UPDATE v2_facts SET instrument_id = ? '
        'WHERE namespace = ? AND fact_id = ? AND instrument_id = ?',
        [named?.instrumentId, namespace, fact.factId, current],
      );
      if (named == null) {
        instrumentIdByFactId.remove(fact.factId);
      } else {
        instrumentIdByFactId[fact.factId] = named.instrumentId;
      }
      repaired++;
    }
    return repaired;
  }

  /// True when the saved rows may not match their inputs yet: a pass is due
  /// or unfinished.
  bool get pending => _state.get(doneKey) != revision();

  /// One bounded slice of the pass. Safe to call when nothing is due (it
  /// returns at once).
  ///
  /// [evaluate] false only moves the cursor over the slice (nothing is
  /// projected): used to pass over a slice that keeps failing.
  ProjectionRefreshStep step({int limit = defaultChunk, bool evaluate = true}) {
    // Rows written without category ids would lose their category on screen.
    if (categoryIdBySlug.isEmpty) return (events: 0, changed: 0, more: false);
    final rev = revision();
    if (_state.get(doneKey) == rev) return (events: 0, changed: 0, more: false);
    var cursor = _state.get(cursorKey) ?? '';
    if (_state.get(targetKey) != rev) {
      // An input changed (again): start over, from the first event.
      cursor = '';
      _state.put(targetKey, rev);
      _state.put(cursorKey, '');
    }
    final rows = _db.select(
      'SELECT event_id, payload FROM v2_events '
      'WHERE namespace = ? AND event_id > ? ORDER BY event_id LIMIT ?',
      [namespace, cursor, limit],
    );
    // Passing over a slice reads no payload: the one that fails may be the
    // reason the slice is passed over.
    final events = evaluate
        ? [
            for (final row in rows)
              v2.Event.fromJson(
                (jsonDecode(row['payload'] as String) as Map)
                    .cast<String, Object?>(),
              ),
          ]
        : const <v2.Event>[];
    final changed = events.isEmpty ? 0 : _reproject(events);
    final more = rows.length == limit;
    if (more) {
      _state.put(cursorKey, rows.last['event_id'] as String);
    } else {
      _state.put(doneKey, rev);
      _state.put(cursorKey, '');
    }
    return (events: rows.length, changed: changed, more: more);
  }

  /// Every remaining slice in one go, for callers that are not on the UI
  /// thread (tests, the replay tool). The app runs one slice per worker call.
  int runAll({int limit = defaultChunk}) {
    var changed = 0;
    ProjectionRefreshStep step;
    do {
      step = this.step(limit: limit);
      changed += step.changed;
    } while (step.more);
    return changed;
  }

  int _reproject(List<v2.Event> events) {
    final facts = FactStore(_db, namespace: namespace);
    final ledger = LedgerStore(_db, namespace: namespace);
    final ids = {for (final e in events) e.eventId};
    final factIds = {
      for (final e in events)
        for (final leg in e.legs) leg.factId,
    };
    final factsById = facts.byIds(factIds);
    final instrumentIdByFactId = facts.instrumentIdsFor(factIds);
    final instruments = {
      for (final i in InstrumentStore(_db, namespace: namespace).list())
        i.instrumentId: i,
    };
    _repairContradictedLinks(factsById, instrumentIdByFactId, instruments);
    // Every stored decision is kept, automatic ones too: moving categories is
    // the re-sort's job, which the person previews and applies.
    final locked = ledger.categoryDecisions(eventIds: ids);
    final undecided = events.any((e) => !locked.containsKey(e.eventId));
    final categories = undecided
        ? CategorySnapshot.load(
            financial.database,
            namespace: namespace,
            aliases: bundle.merchantAliases,
          )
        : null;
    final snapshot = LedgerSnapshot.project(
      events: events,
      factsById: factsById,
      instrumentsById: instruments,
      bundle: bundle,
      userRules: categories?.userRules ?? const [],
      confirmedHistory: categories?.confirmedHistory ?? const {},
      instrumentIdByFactId: instrumentIdByFactId,
      lockedCategories: locked,
    );
    // As [LedgerStore.replaceForEvent] stores them: a refund row carries its
    // category on the wire fields (CCR-003), so compare it that way too.
    final fresh = <String, List<v2.LedgerEntry>>{};
    for (final entry in snapshot.entries) {
      final decision = snapshot.categoryByEvent[entry.eventId];
      (fresh[entry.eventId] ??= []).add(
        entry.isRefundShaped && decision != null
            ? entry.withCategory(decision.slug, decision.source)
            : entry,
      );
    }
    final previous = ledger.forEvents(ids);
    final stored = _storedRows(ids);
    final merchantAliases = PersonalMerchantAliases(
      _db,
      namespace: namespace,
    ).load();
    final marks = OwnerIdentityStore(_db, namespace: namespace).marksOnly();

    final changed = <v2.Event>[];
    var ledgerChanged = false;
    for (final event in events) {
      final entries = fresh[event.eventId] ?? const <v2.LedgerEntry>[];
      final before = previous[event.eventId] ?? const <v2.LedgerEntry>[];
      final entriesDiffer = !_sameEntries(before, entries);
      final row = transactionForEvent(
        event,
        entries,
        factsById,
        instruments,
        category: snapshot.categoryByEvent[event.eventId],
        categoryIdBySlug: categoryIdBySlug,
        instrumentIdByFactId: instrumentIdByFactId,
        merchantAliases: merchantAliases,
        marks: marks,
      );
      if (entriesDiffer ||
          !ProjectionWriter.displayUnchanged(row, stored[event.eventId])) {
        changed.add(event);
        ledgerChanged |= entriesDiffer;
      }
    }
    if (changed.isEmpty) return 0;

    final changedIds = {for (final e in changed) e.eventId};
    ProjectionWriter(financial, ledger).write(
      LedgerSnapshot(
        events: changed,
        entries: snapshot.entries.where((e) => changedIds.contains(e.eventId)),
        categoryByEvent: {
          for (final id in changedIds) id: ?snapshot.categoryByEvent[id],
        },
      ),
      factsById: factsById,
      instrumentsById: instruments,
      categoryIdBySlug: categoryIdBySlug,
      instrumentIdByFactId: instrumentIdByFactId,
      markSubscriptionsDirty: false,
    );

    // Only entries that really changed go to the server; an entry the event no
    // longer has leaves the queue (same as confirming a card does).
    final outbox = OutboxStore(_db, namespace: namespace);
    for (final event in changed) {
      final before = {
        for (final e in previous[event.eventId] ?? const <v2.LedgerEntry>[])
          e.entryId: jsonEncode(e.toJson()),
      };
      final after = fresh[event.eventId] ?? const <v2.LedgerEntry>[];
      for (final entry in after) {
        if (before[entry.entryId] != jsonEncode(entry.toJson())) {
          outbox.enqueue(
            'ledger',
            entry.entryId,
            entry.toJson(),
            backfill: true,
          );
        }
      }
      final kept = {for (final e in after) e.entryId};
      for (final id in before.keys) {
        if (!kept.contains(id)) {
          _db.execute('DELETE FROM v2_outbox WHERE namespace=? AND id=?', [
            namespace,
            'ledger:$id',
          ]);
        }
      }
    }
    if (ledgerChanged) {
      SubscriptionStore(_db, namespace: namespace).markDirty();
      financial.notifyExternalChanges(namespace, const ['subscriptions']);
    }
    return changed.length;
  }

  /// The stored display rows of [eventIds], by event id, through the same
  /// event-id index [ProjectionWriter] uses, 400 ids per query.
  Map<String, TransactionEntry> _storedRows(Set<String> eventIds) {
    _db.execute(
      "CREATE INDEX IF NOT EXISTS idx_financial_sms_v2_event ON financial_entities(namespace,json_extract(payload,'\$.event_id')) WHERE entity='transactions'",
    );
    final ids = eventIds.toList();
    final out = <String, TransactionEntry>{};
    for (var start = 0; start < ids.length; start += 400) {
      final chunk = ids.skip(start).take(400).toList();
      for (final row in _db.select(
        "SELECT payload FROM financial_entities WHERE namespace=? AND entity='transactions' "
        "AND json_extract(payload,'\$.event_id') IN (${List.filled(chunk.length, '?').join(',')})",
        [namespace, ...chunk],
      )) {
        final entry = TransactionEntry.fromJson(
          jsonDecode(row['payload'] as String) as Map<String, dynamic>,
        );
        final eventId = entry.eventId;
        if (eventId != null) out[eventId] = entry;
      }
    }
    return out;
  }

  static bool _sameEntries(List<v2.LedgerEntry> a, List<v2.LedgerEntry> b) {
    if (a.length != b.length) return false;
    String key(v2.LedgerEntry e) => jsonEncode(e.toJson());
    final left = a.map(key).toList()..sort();
    final right = b.map(key).toList()..sort();
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }
}
