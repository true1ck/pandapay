import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/card_overrides_repository.dart';
import '../../data/local_first/command_outcomes.dart';
import '../../data/user_cards_repository.dart' show UserCard;
import '../cards/add_card_local_first.dart';
import '../cards/card_state_local_first.dart' show isProvisionalCard;

/// WP-C6 (W-08): card overrides that work without a network.
///
/// Same rule as the card helpers: a reachable server is asked first (an online
/// user sees what they saw before); when it is not there the change is saved
/// on the phone and queued, and `cardOverridesProvider` shows it at once
/// (provisional row, hidden row, toggled row) through the queued-work overlay.

/// Drops the saved override list and rebuilds, so the next read is the
/// server's answer (used after a write the server accepted).
Future<void> refreshCardOverrides(WidgetRef ref) async {
  try {
    final cache = await ref.read(responseCacheProvider.future);
    await cache.clear('${ref.read(cacheNamespaceProvider)}:card_overrides');
  } catch (_) {}
  ref.invalidate(cardOverridesProvider);
  ref.invalidate(rankedRecommendationsProvider);
}

/// Rebuilds after something was only queued (the overlay shows it).
void _showQueued(WidgetRef ref) {
  ref.invalidate(cardOverridesProvider);
  ref.invalidate(rankedRecommendationsProvider);
}

/// Creates a "always use [card] here" rule. Returns true when the server has
/// it, false when it is queued. A real refusal (4xx) is rethrown.
Future<bool> createOverrideLocalFirst(
  WidgetRef ref, {
  required UserCard card,
  required OverrideScope scope,
  String? vpa,
  String? merchantName,
  String? categoryId,
  String? categoryName,
  String? reasonNote,
  Duration attempt = const Duration(seconds: 8),
}) async {
  final repo = ref.read(cardOverridesRepositoryProvider)!;
  final id = const Uuid().v4();
  if (!kCardsLocalFirst) {
    await repo.createOverride(
      userCardId: card.id,
      scope: scope,
      vpa: vpa,
      merchantName: merchantName,
      categoryId: categoryId,
      reasonNote: reasonNote,
    );
    await refreshCardOverrides(ref);
    return true;
  }
  if (!serverKnownUnreachable(ref) && !await isProvisionalCard(ref, card.id)) {
    try {
      await repo
          .createOverride(
            id: id,
            userCardId: card.id,
            scope: scope,
            vpa: vpa,
            merchantName: merchantName,
            categoryId: categoryId,
            reasonNote: reasonNote,
          )
          .timeout(attempt);
      await refreshCardOverrides(ref);
      return true;
    } catch (error) {
      if (!offlineLike(ref, error)) rethrow;
    }
  }
  await queueCommand(
    ref,
    kind: CardCommand.createOverride,
    target: id,
    payload: {
      'id': id,
      'userCardId': card.id,
      'scope': scope.name,
      'vpa': ?vpa,
      'merchantName': ?merchantName,
      'categoryId': ?categoryId,
      'categoryName': ?categoryName,
      'reasonNote': ?reasonNote,
      'cardName': card.cardName,
      'cardNickname': ?card.nickname,
      'createdAt': DateTime.now().toIso8601String(),
    },
  );
  _showQueued(ref);
  return false;
}

/// Deletes a rule. A rule that is still only queued is simply cancelled; a
/// delete the server answers 404 to counts as done.
Future<bool> deleteOverrideLocalFirst(WidgetRef ref, String id) async {
  final repo = ref.read(cardOverridesRepositoryProvider)!;
  if (!kCardsLocalFirst) {
    await repo.delete(id);
    await refreshCardOverrides(ref);
    return true;
  }
  if (await _hasQueuedCreate(ref, id)) {
    await queueCommand(
      ref,
      kind: CardCommand.deleteOverride,
      target: id,
      payload: {'id': id},
      cancels: const [CardCommand.createOverride],
    );
    _showQueued(ref);
    return false;
  }
  if (!serverKnownUnreachable(ref)) {
    try {
      await goneIsDone(() => repo.delete(id));
      await refreshCardOverrides(ref);
      return true;
    } catch (error) {
      if (!offlineLike(ref, error)) rethrow;
    }
  }
  await queueCommand(
    ref,
    kind: CardCommand.deleteOverride,
    target: id,
    payload: {'id': id},
  );
  // An edit still waiting for the server would only fail against a row that
  // is about to be deleted.
  try {
    final cache = await ref.read(responseCacheProvider.future);
    cache.financialStore.database.db.execute(
      "DELETE FROM sync_pending_changes WHERE namespace=? AND entity='card_overrides' AND entity_id=? AND in_flight=0",
      [ref.read(cacheNamespaceProvider), id],
    );
  } catch (_) {}
  _showQueued(ref);
  return false;
}

/// Toggle / reassign / edit-note. Returns true when the server has it, false
/// when it was queued.
Future<bool> updateOverrideLocalFirst(
  WidgetRef ref,
  CardOverride rule, {
  bool? isEnabled,
  String? userCardId,
  String? reasonNote,
}) async {
  final repo = ref.read(cardOverridesRepositoryProvider)!;
  final fields = <String, Object?>{
    'is_enabled': ?isEnabled,
    'user_card_id': ?userCardId,
    'reason_note': ?reasonNote,
  };
  if (kCardsLocalFirst) {
    final create = await _queuedCreate(ref, rule.id);
    if (create != null) {
      // Not on the server yet: fold the edit into the queued create.
      await queueCommand(
        ref,
        kind: CardCommand.createOverride,
        target: rule.id,
        payload: {
          ...create.payload,
          'isEnabled': ?isEnabled,
          'userCardId': ?userCardId,
          if (reasonNote != null)
            'reasonNote': reasonNote.isEmpty ? null : reasonNote,
        },
      );
      _showQueued(ref);
      return false;
    }
  }
  if (!(kCardsLocalFirst && serverKnownUnreachable(ref))) {
    try {
      await repo.updateOverride(
        rule.id,
        isEnabled: isEnabled,
        reasonNote: reasonNote,
        userCardId: userCardId,
      );
      await refreshCardOverrides(ref);
      return true;
    } catch (error) {
      if (!kCardsLocalFirst || !offlineLike(ref, error)) rethrow;
    }
  }
  final queue = await ref.read(syncQueueProvider.future);
  queue.enqueueUpdate(
    entity: 'card_overrides',
    entityId: rule.id,
    fields: fields,
  );
  ref.invalidate(pendingSyncCountProvider);
  _showQueued(ref);
  return false;
}

Future<dynamic> _queuedCreate(WidgetRef ref, String id) async {
  try {
    final commands = await ref.read(commandOutboxProvider.future);
    return commands
        .pendingOf({CardCommand.createOverride})
        .where((c) => c.target == id)
        .firstOrNull;
  } catch (_) {
    return null;
  }
}

Future<bool> _hasQueuedCreate(WidgetRef ref, String id) async =>
    await _queuedCreate(ref, id) != null;
