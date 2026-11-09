import '../local/financial_store.dart';
import '../local/sync_queue.dart';

/// Local-first writes for the wallet.
///
/// The rule this class exists to enforce: a button that changes a card writes
/// the phone's own database first and returns, and the change reaches the server
/// later through [SyncQueue] (`/sync/push`). The screen never waits on the API.
///
/// How the pieces fit:
/// * [FinancialStore.entities] already overlays every pending
///   `sync_pending_changes` row on top of the stored card, so queueing a change
///   is enough for every reader of the card cache to see it at once.
/// * [SyncQueue.enqueueUpdate] coalesces per field, so dragging a card around
///   ten times pushes one `sort_order` per card, not ten.
/// * The server applies each field with a per-field clock, so a later edit on
///   another device wins instead of being overwritten.
///
/// Only operations the server can apply as plain field updates live here. Adding
/// a card and un-archiving one need server-side checks (catalogue, duplicate
/// identity) and are not routed through this class.
class LocalFirstCards {
  const LocalFirstCards({
    required this.store,
    required this.queue,
    required this.namespace,
  });

  final FinancialStore store;
  final SyncQueue queue;
  final String namespace;

  static const _entity = 'user_cards';

  List<Map<String, dynamic>> _cards() => store.entities(namespace, 'cards');

  /// Makes [cardId] the default card. Only one card may be default, so this
  /// clears any other default in the same step; the server has no constraint
  /// that would do it for us on the generic sync path.
  void setDefault(String cardId) {
    final cards = _cards();
    final target = cards.where((c) => c['id'] == cardId).firstOrNull;
    if (target == null || target['is_archived'] == true) {
      throw StateError('That card is no longer in your wallet.');
    }
    final at = DateTime.now();
    for (final card in cards) {
      final id = card['id'] as String;
      if (id == cardId || card['is_default'] != true) continue;
      queue.enqueueUpdate(
        entity: _entity,
        entityId: id,
        fields: {'is_default': false},
        at: at,
      );
    }
    if (target['is_default'] != true) {
      queue.enqueueUpdate(
        entity: _entity,
        entityId: cardId,
        fields: {'is_default': true},
        at: at,
      );
    }
    store.notifyExternalChanges(namespace, const ['cards']);
  }

  /// Saves a new priority order, most important first. Every card in
  /// [orderedIds] gets its position as `sort_order`, matching what
  /// `POST /user-cards/reorder` does, and the local list order changes at once.
  void reorder(List<String> orderedIds) {
    if (orderedIds.isEmpty) return;
    final known = {for (final c in _cards()) c['id'] as String};
    final at = DateTime.now();
    for (var i = 0; i < orderedIds.length; i++) {
      final id = orderedIds[i];
      if (!known.contains(id)) continue;
      store.patchCard(namespace, id, {'_local_order': i}, at: at);
      queue.enqueueUpdate(
        entity: _entity,
        entityId: id,
        fields: {'sort_order': i},
        at: at,
      );
    }
  }
}
