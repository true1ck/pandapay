import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/card_overrides_repository.dart';
import '../../data/connectivity/known_connectivity.dart';
import '../../data/connectivity/reachability.dart';
import '../../data/local/financial_store.dart';
import '../../data/local_first/command_outbox.dart';
import '../../data/local_first/command_outcomes.dart';
import '../../data/user_cards_repository.dart';

/// WP-C6 master switch. `false` restores the old network-first card flows
/// (the screens still call the helpers, which then go straight to the server).
const bool kCardsLocalFirst = true;

/// Command kinds this package queues in the [CommandOutbox]. The outbox table
/// is already a `QueueRegistry` queue, so sign-out counts, flushes and the top
/// strip shows these without a new table.
abstract final class CardCommand {
  /// Creates a card on the server. Target = the phone's card id; payload
  /// `{id, cardProductId, nickname?, last4?, patch?}`.
  static const addCard = 'add_card';

  /// Sets plain card fields on the server's own PATCH route. Used for fields
  /// an older server's `/sync/push` drops silently (last4, fee override) and
  /// for edits made to a card that is still only on the phone.
  static const patchCardFields = 'card_fields_patch';

  static const createOverride = 'create_override';
  static const deleteOverride = 'delete_override';

  /// Sent before transactions and overrides, which may name a queued card.
  static const addFirst = {addCard};
}

// --- id remap (pure) -------------------------------------------------------

/// Returns [value] with every string equal to [from] replaced by [to], through
/// maps and lists. Keys are never touched. Pure: [value] is not modified.
Object? remapIdInJson(Object? value, String from, String to) {
  if (value is String) return value == from ? to : value;
  if (value is List) return [for (final e in value) remapIdInJson(e, from, to)];
  if (value is Map) {
    return {
      for (final e in value.entries) e.key: remapIdInJson(e.value, from, to),
    };
  }
  return value;
}

/// Same for a JSON text; returns the input unchanged when it does not hold
/// [from] or is not JSON.
String remapIdInJsonText(String text, String from, String to) {
  if (!text.contains(from)) return text;
  try {
    return jsonEncode(remapIdInJson(jsonDecode(text), from, to));
  } catch (_) {
    return text;
  }
}

/// Replaces the phone's id [from] by the server's id [to] everywhere the phone
/// kept it: the stored card (the provisional row is dropped when the server's
/// card is already stored), queued transactions and their local rows, queued
/// sync edits, queued commands (target and payload) and the cached override
/// list. [from] == [to] only settles the provisional card.
///
/// Works on whatever those tables hold now and is safe to repeat. Only
/// `pending=1` transactions are scanned: the server never saw a card that was
/// provisional, so no confirmed transaction can name it.
void remapLocalId(Database db, String ns, String from, String to) {
  db.execute('SAVEPOINT remap_local_id');
  try {
    if (from == to) {
      db.execute(
        "UPDATE financial_entities SET pending=0 WHERE namespace=? AND entity='cards' AND id=?",
        [ns, from],
      );
    } else {
      final serverRowStored = db.select(
        "SELECT 1 FROM financial_entities WHERE namespace=? AND entity='cards' AND id=?",
        [ns, to],
      ).isNotEmpty;
      if (serverRowStored) {
        db.execute(
          "DELETE FROM financial_entities WHERE namespace=? AND entity='cards' AND id=?",
          [ns, from],
        );
      } else {
        db.execute(
          "UPDATE financial_entities SET id=?, pending=0, payload=json_set(payload, '\$.id', ?) "
          "WHERE namespace=? AND entity='cards' AND id=?",
          [to, to, ns, from],
        );
      }
      db.execute(
        "UPDATE financial_entities SET payload=json_set(payload, '\$.user_card_id', ?) "
        "WHERE namespace=? AND entity='transactions' AND pending=1 "
        "AND json_extract(payload, '\$.user_card_id')=?",
        [to, ns, from],
      );
      for (final row in db.select(
        'SELECT client_seq, entity_id, payload_json FROM sync_pending_changes '
        'WHERE namespace=? AND (entity_id=? OR payload_json LIKE ?)',
        [ns, from, '%$from%'],
      )) {
        db.execute(
          'UPDATE sync_pending_changes SET entity_id=?, payload_json=? WHERE client_seq=?',
          [
            row['entity_id'] == from ? to : row['entity_id'],
            remapIdInJsonText(row['payload_json'] as String, from, to),
            row['client_seq'],
          ],
        );
      }
      for (final row in db.select(
        'SELECT id, target, payload_json FROM command_outbox '
        'WHERE namespace=? AND (target=? OR payload_json LIKE ?)',
        [ns, from, '%$from%'],
      )) {
        db.execute('UPDATE command_outbox SET target=?, payload_json=? WHERE id=?', [
          row['target'] == from ? to : row['target'],
          remapIdInJsonText(row['payload_json'] as String, from, to),
          row['id'],
        ]);
      }
      db.execute(
        'UPDATE transaction_outbox_entries SET user_card_id=? WHERE user_card_id=?',
        [to, from],
      );
      final overridesKey = '$ns:card_overrides';
      for (final row in db.select(
        'SELECT raw_json FROM cached_responses WHERE key=?',
        [overridesKey],
      )) {
        db.execute('UPDATE cached_responses SET raw_json=? WHERE key=?', [
          remapIdInJsonText(row['raw_json'] as String, from, to),
          overridesKey,
        ]);
      }
    }
    db.execute('RELEASE SAVEPOINT remap_local_id');
  } catch (_) {
    db.execute('ROLLBACK TO SAVEPOINT remap_local_id');
    db.execute('RELEASE SAVEPOINT remap_local_id');
    rethrow;
  }
}

// --- provisional card ------------------------------------------------------

/// The card the wallet shows while the server does not have it yet, built
/// from the catalogue data the app already holds.
UserCard provisionalCard(
  String id,
  CardProduct? product, {
  required String cardProductId,
  String? nickname,
  String? last4,
  double? creditLimitInr,
}) => UserCard(
  id: id,
  cardProductId: cardProductId,
  nickname: nickname,
  cardName: product?.name ?? 'New card',
  cardType: product?.cardType,
  isDefault: false,
  last4: last4,
  creditLimit: creditLimitInr == null ? null : Money.fromRupees(creditLimitInr),
);

/// Stores [card] as a pending row (`pending=1`) so the wallet and Home show it
/// at once and a wallet refresh keeps it (`FinancialStore.replaceCards`).
void insertProvisionalCard(FinancialStore store, String ns, UserCard card) {
  final db = store.database.db;
  final next =
      (db.select(
                "SELECT MAX(json_extract(payload, '\$._local_order')) AS m "
                "FROM financial_entities WHERE namespace=? AND entity='cards'",
                [ns],
              ).first['m']
              as num?)
          ?.toInt() ??
      -1;
  db.execute(
    'INSERT OR REPLACE INTO financial_entities(namespace, entity, id, payload, observed_at, pending) '
    "VALUES (?, 'cards', ?, ?, ?, 1)",
    [
      ns,
      card.id,
      jsonEncode({...card.toJson(), '_local_order': next + 1}),
      DateTime.now().millisecondsSinceEpoch,
    ],
  );
  store.notifyExternalChanges(ns, const ['cards']);
}

/// Card ids still waiting for their server copy, and ids whose add the server
/// refused for good ("not saved").
class CardSaveStates {
  const CardSaveStates({this.saving = const {}, this.notSaved = const {}});
  final Set<String> saving;
  final Set<String> notSaved;
  static const none = CardSaveStates();
}

CardSaveStates cardSaveStatesFor(CommandOutbox commands) => CardSaveStates(
  saving: {
    for (final c in commands.pendingOf({CardCommand.addCard})) c.target,
  },
  notSaved: {
    for (final p in commands.parked())
      if (p.kind == CardCommand.addCard) p.target,
  },
);

/// Per-card "saving" / "not saved" state for the wallet. Rebuilds when the
/// command outbox changes.
final cardSaveStatesProvider = FutureProvider<CardSaveStates>((ref) async {
  ref.watch(commandOutboxRevisionProvider);
  try {
    return cardSaveStatesFor(await ref.watch(commandOutboxProvider.future));
  } catch (_) {
    return CardSaveStates.none;
  }
});

/// True when the server is known to be unreachable right now (radio down, or a
/// recent probe failed). Unknown counts as reachable: online behaviour stays
/// exactly as before.
bool serverKnownUnreachable(dynamic ref) {
  if (KnownConnectivity.knownOffline) return true;
  try {
    if ((ref.read(isOnlineProvider) as AsyncValue<bool>).valueOrNull == false) {
      return true;
    }
    return (ref.read(serverReachabilityProvider) as ServerReachability)
        .shouldSkipBackgroundReads;
  } catch (_) {
    return false;
  }
}

/// "The server is not there" for [error]: [isOfflineLike], or the app already
/// knows the device is offline.
bool offlineLike(dynamic ref, Object error) =>
    isOfflineLike(error) || serverKnownUnreachable(ref);

// --- add card --------------------------------------------------------------

class AddCardOutcome {
  const AddCardOutcome({required this.id, required this.queued});

  /// The card id the wallet uses now (the server's when [queued] is false).
  final String id;

  /// True when the card is only on this phone for now.
  final bool queued;
}

/// Adds a card to the wallet without waiting for the network.
///
/// Reachable server: one bounded attempt with the phone's own client id (so a
/// lost reply cannot create a second card), exactly what the screens did
/// before. Anything that means "server not there" (offline, dead Wi-Fi,
/// timeout, 5xx): the card is stored as a pending row, shown at once, and an
/// `add_card` command carries it to the server later. A real refusal (4xx) is
/// rethrown for the screen to show.
///
/// Signed out (no repository): the on-device wallet, as before.
Future<AddCardOutcome> addCardLocalFirst(
  WidgetRef ref, {
  required String cardProductId,
  CardProduct? product,
  String? nickname,
  String? last4,
  double? creditLimitInr,
  Duration attempt = const Duration(seconds: 8),
}) async {
  final repo = ref.read(userCardsRepositoryProvider);
  if (repo == null) {
    final local = await ref.read(localUserCardsRepositoryProvider.future);
    final id = await local.addCard(cardProductId, nickname: nickname, last4: last4);
    return AddCardOutcome(id: id, queued: false);
  }
  final id = const Uuid().v4();
  if (!kCardsLocalFirst) {
    final serverId = await repo.addCard(cardProductId, nickname: nickname, last4: last4);
    await _patchLimit(repo, serverId, creditLimitInr);
    return AddCardOutcome(id: serverId, queued: false);
  }
  if (!serverKnownUnreachable(ref)) {
    try {
      final result = await repo
          .addCardWithClientId(
            id,
            cardProductId,
            nickname: nickname,
            last4: last4,
            mergeExisting: false,
          )
          .timeout(attempt);
      if (creditLimitInr != null) {
        try {
          await repo.updateCard(result.id, creditLimitInr: creditLimitInr);
        } catch (error) {
          if (!offlineLike(ref, error)) rethrow;
          await _queueFields(ref, result.id, {'creditLimitInr': creditLimitInr});
        }
      }
      return AddCardOutcome(id: result.id, queued: false);
    } catch (error) {
      if (!offlineLike(ref, error)) rethrow;
    }
  }
  final cache = await ref.read(responseCacheProvider.future);
  final ns = ref.read(cacheNamespaceProvider);
  final existing = _pendingAddFor(cache.financialStore.database.db, ns, cardProductId, last4);
  if (existing != null) return AddCardOutcome(id: existing, queued: true);
  CardProduct? found = product;
  if (found == null) {
    try {
      found = (await ref.read(catalogueProvider.future))
          .where((p) => p.id == cardProductId)
          .firstOrNull;
    } catch (_) {}
  }
  insertProvisionalCard(
    cache.financialStore,
    ns,
    provisionalCard(
      id,
      found,
      cardProductId: cardProductId,
      nickname: nickname,
      last4: last4,
      creditLimitInr: creditLimitInr,
    ),
  );
  await queueCommand(
    ref,
    kind: CardCommand.addCard,
    target: id,
    payload: {
      'id': id,
      'cardProductId': cardProductId,
      'nickname': ?nickname,
      'last4': ?last4,
      if (creditLimitInr != null) 'patch': {'creditLimitInr': creditLimitInr},
    },
  );
  refreshCardProviders(ref);
  return AddCardOutcome(id: id, queued: true);
}

Future<void> _patchLimit(UserCardsRepository repo, String id, double? limit) async {
  if (limit != null) await repo.updateCard(id, creditLimitInr: limit);
}

String? _pendingAddFor(Database db, String ns, String productId, String? last4) {
  for (final row in db.select(
    "SELECT target, payload_json FROM command_outbox WHERE namespace=? AND kind=? AND parked=0",
    [ns, CardCommand.addCard],
  )) {
    final p = jsonDecode(row['payload_json'] as String) as Map;
    if (p['cardProductId'] == productId && p['last4'] == last4) {
      return row['target'] as String;
    }
  }
  return null;
}

/// Tells every wallet reader that cards changed.
void refreshCardProviders(WidgetRef ref) {
  ref.invalidate(myCardsProvider);
  ref.invalidate(userCardsProvider);
}

Future<void> _queueFields(WidgetRef ref, String cardId, Map<String, Object?> fields) =>
    queueCommand(
      ref,
      kind: CardCommand.patchCardFields,
      target: cardId,
      payload: {'cardId': cardId, ...fields},
    );

/// Queues plain field edits for [cardId]. When the card is still only on the
/// phone the edit is folded into its `add_card` command instead (the server
/// does not know the id yet, so a separate edit could not be applied).
/// Returns true when it was folded in.
Future<bool> queueCardFieldPatch(
  WidgetRef ref,
  String cardId,
  Map<String, Object?> fields,
) async {
  final commands = await ref.read(commandOutboxProvider.future);
  final add = commands
      .pendingOf({CardCommand.addCard})
      .where((c) => c.target == cardId)
      .firstOrNull;
  if (add == null) {
    // Replaces an earlier unsent patch for the same card: merge first.
    final earlier = commands
        .pendingOf({CardCommand.patchCardFields})
        .where((c) => c.target == cardId)
        .firstOrNull;
    await _queueFields(ref, cardId, {...?earlier?.payload, ...fields});
    return false;
  }
  final patch = {...?(add.payload['patch'] as Map?)?.cast<String, Object?>(), ...fields};
  await queueCommand(
    ref,
    kind: CardCommand.addCard,
    target: cardId,
    payload: {...add.payload, 'patch': patch},
  );
  return true;
}

// --- handlers --------------------------------------------------------------

/// What the card command handlers need. Built by [cardCommandContext].
class CardCommandContext {
  CardCommandContext({
    required this.userCards,
    required this.overrides,
    required this.commands,
    required this.db,
    required this.namespace,
    this.onChanged,
  });
  final UserCardsRepository userCards;
  final CardOverridesRepository? overrides;
  final CommandOutbox commands;
  final Database db;
  final String namespace;
  final void Function()? onChanged;
}

/// Builds the context from a `Ref`/`WidgetRef`; null when signed out or the
/// database is unavailable (the card kinds then have no handler and simply
/// stay queued... see [CommandOutbox.flush]: callers only build handlers when
/// they hold a repository).
Future<CardCommandContext?> cardCommandContext(dynamic ref) async {
  try {
    final repo = ref.read(userCardsRepositoryProvider) as UserCardsRepository?;
    if (repo == null) return null;
    final cache = await ref.read(responseCacheProvider.future);
    final commands = await ref.read(commandOutboxProvider.future) as CommandOutbox;
    final ns = ref.read(cacheNamespaceProvider) as String;
    return CardCommandContext(
      userCards: repo,
      overrides: ref.read(cardOverridesRepositoryProvider) as CardOverridesRepository?,
      commands: commands,
      db: (cache.financialStore as FinancialStore).database.db,
      namespace: ns,
      onChanged: () {
        try {
          (cache.financialStore as FinancialStore).notifyExternalChanges(ns, const ['cards']);
          ref.invalidate(userCardsProvider);
          ref.invalidate(myCardsProvider);
          ref.invalidate(cardOverridesProvider);
        } catch (_) {}
      },
    );
  } catch (_) {
    return null;
  }
}

Map<String, CommandHandler> cardCommandHandlers(CardCommandContext c) => {
  CardCommand.addCard: (p) async {
    final id = p['id'] as String;
    final result = await c.userCards.addCardWithClientId(
      id,
      p['cardProductId'] as String,
      nickname: p['nickname'] as String?,
      last4: p['last4'] as String?,
    );
    // The phone's id is replaced by the server's (the same id on a current
    // server, another on an older one or when the card already existed).
    remapLocalId(c.db, c.namespace, id, result.id);
    final patch = p['patch'];
    if (patch is Map && patch.isNotEmpty) {
      // A separate command, so a failing patch never re-sends the add.
      c.commands.enqueue(
        kind: CardCommand.patchCardFields,
        target: result.id,
        payload: {'cardId': result.id, ...Map<String, Object?>.from(patch)},
      );
    }
    c.onChanged?.call();
  },
  CardCommand.patchCardFields: (p) => _patchFields(c.userCards, p),
  if (c.overrides != null) ...{
    CardCommand.createOverride: (p) async {
      final cardId = p['userCardId'] as String;
      // The card is still only on the phone: wait (a plain error is retried
      // with backoff, never parked) instead of sending an id the server
      // has not seen.
      if (c.commands.pendingOf({CardCommand.addCard}).any((x) => x.target == cardId) ||
          c.commands.parked().any((x) => x.kind == CardCommand.addCard && x.target == cardId)) {
        throw StateError('Waiting for the card to be saved first');
      }
      final id = p['id'] as String;
      final scope = OverrideScope.values.firstWhere((s) => s.name == p['scope']);
      final created = await c.overrides!.createOverride(
        id: id,
        userCardId: cardId,
        scope: scope,
        vpa: p['vpa'] as String?,
        merchantName: p['merchantName'] as String?,
        categoryId: p['categoryId'] as String?,
        reasonNote: p['reasonNote'] as String?,
      );
      if (created.id != id) remapLocalId(c.db, c.namespace, id, created.id);
      c.onChanged?.call();
    },
    CardCommand.deleteOverride: (p) =>
        goneIsDone(() => c.overrides!.delete(p['id'] as String)),
  },
};

Future<void> _patchFields(UserCardsRepository repo, Map<String, Object?> p) {
  final id = p['cardId'] as String;
  return goneIsDone(() async {
    final feeTouched = p.containsKey('annualFeeOverrideInr') || p['clearAnnualFeeOverride'] == true;
    final other = p.keys.any(
      (k) =>
          !const {'cardId', 'makeDefault', 'annualFeeOverrideInr', 'clearAnnualFeeOverride'}
              .contains(k),
    );
    if (other) {
      await repo.updateCard(
        id,
        nickname: p['nickname'] as String?,
        creditLimitInr: (p['creditLimitInr'] as num?)?.toDouble(),
        statementDay: (p['statementDay'] as num?)?.toInt(),
        dueDay: (p['dueDay'] as num?)?.toInt(),
        autopayMode: p['autopayMode'] == null
            ? null
            : AutopayMode.fromJson(p['autopayMode'] as String?),
        last4: p['last4'] as String?,
      );
    }
    if (p['makeDefault'] == true) await repo.setDefaultCard(id);
    if (feeTouched) {
      await repo.updateAnnualFeeOverride(
        id,
        annualFeeOverrideInr: (p['annualFeeOverrideInr'] as num?)?.toDouble(),
        clear: p['clearAnnualFeeOverride'] == true,
      );
    }
  });
}
