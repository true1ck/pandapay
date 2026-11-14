import 'dart:convert';

import '../../app/providers.dart'
    show
        cacheNamespaceProvider,
        commandOutboxProvider,
        notificationsProvider,
        responseCacheProvider,
        userCardsRepositoryProvider;
import '../../data/local_first/command_outbox.dart';
import '../../data/user_cards_repository.dart';
import '../account/account_local_first.dart';

typedef InboxSnapshot = ({List<AppNotification> items, int unreadCount});

InboxSnapshot _markRead(InboxSnapshot inbox, {String? id}) {
  final now = DateTime.now();
  var unread = 0;
  final items = [
    for (final n in inbox.items)
      if (n.isUnread && (id == null || n.id == id))
        AppNotification.fromJson({
          ...n.toJson(),
          'read_at': now.toIso8601String(),
        })
      else
        n,
  ];
  for (final n in items) {
    if (n.isUnread) unread++;
  }
  // Keep the server's count when it is higher than what the list shows (the
  // list is a window); never below the visible unread items.
  final dropped = inbox.items.where((n) => n.isUnread).length - unread;
  final count = (inbox.unreadCount - dropped).clamp(unread, 1 << 30);
  return (items: items, unreadCount: id == null ? unread : count);
}

/// Lays read marks that are still queued over a loaded inbox, so a refresh
/// that raced the queue never shows them unread again.
Future<InboxSnapshot> applyPendingReadMarks(dynamic ref, InboxSnapshot inbox) async {
  try {
    final commands = await ref.read(commandOutboxProvider.future) as CommandOutbox;
    var out = inbox;
    for (final c in commands.pendingOf({
      AccountCommand.notificationRead,
      AccountCommand.notificationReadAll,
    })) {
      out = _markRead(
        out,
        id: c.kind == AccountCommand.notificationReadAll
            ? null
            : c.payload['id'] as String?,
      );
    }
    return out;
  } catch (_) {
    return inbox;
  }
}

/// Marks one notification ([id]) or all of them read: the saved inbox changes
/// at once, the server write is sent now or queued. Never loses the mark.
Future<void> markNotificationsReadLocalFirst(dynamic ref, {String? id}) async {
  final repo = ref.read(userCardsRepositoryProvider) as UserCardsRepository?;
  if (repo == null) return;
  try {
    final cache = await ref.read(responseCacheProvider.future);
    final key = '${ref.read(cacheNamespaceProvider)}:notifications';
    final raw = await cache.get(key) as String?;
    if (raw != null) {
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final inbox = (
        items: [
          for (final m in (body['notifications'] as List? ?? const []))
            AppNotification.fromJson(Map<String, dynamic>.from(m as Map)),
        ],
        unreadCount: (body['unreadCount'] as num?)?.toInt() ?? 0,
      );
      final next = _markRead(inbox, id: id);
      await cache.put(
        key,
        jsonEncode({
          'notifications': [for (final n in next.items) n.toJson()],
          'unreadCount': next.unreadCount,
        }),
      );
    }
  } catch (_) {}
  await sendOrQueue(
    ref,
    kind: id == null
        ? AccountCommand.notificationReadAll
        : AccountCommand.notificationRead,
    target: id ?? 'all',
    payload: {if (id != null) 'id': id},
    live: () => repo.markNotificationsRead(id: id),
  );
  ref.invalidate(notificationsProvider);
}
