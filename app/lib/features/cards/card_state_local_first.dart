import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/local_first/pending_overlays.dart';
import '../sync/sync_engine.dart';
import 'add_card_local_first.dart';

/// WP-C6 (W-07): the one code path for archive / pause / un-archive / set
/// default / points balance, replacing the copies in `card_actions_screen.dart`
/// and `edit_card_screen.dart`.
///
/// Rule, same as every local-first write here: a reachable server is asked
/// first (an online healthy user sees exactly what they saw before); when the
/// server is not there (offline, dead Wi-Fi, timeout, 5xx) or already known to
/// be unreachable, the change is applied on the phone and queued, and the
/// screen returns at once.
enum CardChange {
  /// The server has it.
  saved,

  /// Applied on this phone; it will reach the server later.
  queued,
}

/// Everything that depends on the wallet reloads after a card change.
Future<void> refreshAfterCardChange(WidgetRef ref) async {
  await clearUserCardsCache(ref);
  ref.invalidate(myCardsProvider);
  ref.invalidate(userCardsProvider);
  ref.invalidate(transactionsProvider);
  ref.invalidate(utilizationTransactionsProvider);
  ref.invalidate(homeSummaryProvider);
  ref.invalidate(spendReportProvider);
  ref.invalidate(budgetsProvider);
  ref.invalidate(recurringReportProvider);
}

/// True while [cardId] exists only on this phone (its `add_card` is queued).
Future<bool> isProvisionalCard(WidgetRef ref, String cardId) async {
  try {
    final commands = await ref.read(commandOutboxProvider.future);
    return commands.pendingOf({CardCommand.addCard}).any((c) => c.target == cardId);
  } catch (_) {
    return false;
  }
}

/// Removes a card that never reached the server (and its queued follow-ups).
Future<void> _discardProvisional(WidgetRef ref, String cardId) async {
  final cache = await ref.read(responseCacheProvider.future);
  final ns = ref.read(cacheNamespaceProvider);
  final db = cache.financialStore.database.db;
  db.execute(
    'DELETE FROM command_outbox WHERE namespace=? AND target=? AND kind IN (?, ?)',
    [ns, cardId, CardCommand.addCard, CardCommand.patchCardFields],
  );
  db.execute(
    "DELETE FROM financial_entities WHERE namespace=? AND entity='cards' AND id=? AND pending=1",
    [ns, cardId],
  );
  cache.financialStore.notifyExternalChanges(ns, const ['cards']);
  ref.read(commandOutboxRevisionProvider.notifier).state++;
}

/// Archives ([archived] true: remove / pause) or restores a card.
Future<CardChange> setCardArchived(
  WidgetRef ref,
  String cardId, {
  required bool archived,
}) async {
  final repo = ref.read(userCardsRepositoryProvider);
  if (repo == null) {
    final local = await ref.read(localUserCardsRepositoryProvider.future);
    archived ? await local.archiveCard(cardId) : await local.unarchiveCard(cardId);
    await applyUserCardArchiveToCache(ref, userCardId: cardId, archived: archived);
    return CardChange.saved;
  }
  if (kCardsLocalFirst && archived && await isProvisionalCard(ref, cardId)) {
    // Never reached the server: just forget it.
    await _discardProvisional(ref, cardId);
    return CardChange.queued;
  }
  if (!(kCardsLocalFirst && serverKnownUnreachable(ref))) {
    try {
      archived ? await repo.archiveCard(cardId) : await repo.unarchiveCard(cardId);
      await applyUserCardArchiveToCache(ref, userCardId: cardId, archived: archived);
      return CardChange.saved;
    } catch (error) {
      if (!kCardsLocalFirst || !offlineLike(ref, error)) rethrow;
    }
  }
  final queue = await ref.read(syncQueueProvider.future);
  queue.enqueueUpdate(
    entity: 'user_cards',
    entityId: cardId,
    fields: {'is_archived': archived},
  );
  await applyUserCardArchiveToCache(ref, userCardId: cardId, archived: archived);
  ref.invalidate(pendingSyncCountProvider);
  unawaited(ref.read(syncEngineProvider).sync());
  return CardChange.queued;
}

/// Makes [cardId] the default card.
Future<CardChange> setCardDefault(WidgetRef ref, String cardId) async {
  final repo = ref.read(userCardsRepositoryProvider);
  if (repo == null) {
    final local = await ref.read(localUserCardsRepositoryProvider.future);
    await local.setDefaultCard(cardId);
    return CardChange.saved;
  }
  if (kCardsLocalFirst && await isProvisionalCard(ref, cardId)) {
    // The server does not know the card yet: ask for it once the card exists.
    await queueCardFieldPatch(ref, cardId, {'makeDefault': true});
    final cache = await ref.read(responseCacheProvider.future);
    final ns = ref.read(cacheNamespaceProvider);
    for (final c in cache.financialStore.entities(ns, 'cards')) {
      if (c['is_default'] == true && c['id'] != cardId) {
        cache.financialStore.patchCard(ns, c['id'] as String, {'is_default': false});
      }
    }
    cache.financialStore.patchCard(ns, cardId, {'is_default': true});
    return CardChange.queued;
  }
  if (!(kCardsLocalFirst && serverKnownUnreachable(ref))) {
    try {
      await repo.setDefaultCard(cardId);
      return CardChange.saved;
    } catch (error) {
      if (!kCardsLocalFirst || !offlineLike(ref, error)) rethrow;
    }
  }
  // Signed in: save on the phone, the sync queue carries it. LocalFirstCards
  // clears the previous default in the same step.
  final localFirst = await ref.read(localFirstCardsProvider.future);
  localFirst.setDefault(cardId);
  ref.invalidate(pendingSyncCountProvider);
  unawaited(ref.read(syncEngineProvider).sync());
  return CardChange.queued;
}

/// Sets the points balance by queueing a points adjustment (replaces the old
/// "needs a live connection" refusal). The command carries a client mutation
/// id, so a lost reply cannot count twice.
Future<void> queuePointsBalance(
  WidgetRef ref,
  String cardId,
  double newBalance,
) async {
  await queueCommand(
    ref,
    kind: OverlayCommand.pointsAdjust,
    target: cardId,
    payload: {
      'userCardId': cardId,
      'newBalance': newBalance,
      'clientMutationId': const Uuid().v4(),
    },
  );
  try {
    final cache = await ref.read(responseCacheProvider.future);
    cache.financialStore.patchCard(
      ref.read(cacheNamespaceProvider),
      cardId,
      {'points_balance': newBalance},
    );
  } catch (_) {}
}
