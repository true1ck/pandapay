import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart' show AppNotification;

/// Design 19 "Notifications" — the inbox of things that already happened,
/// newest first, grouped Today / Earlier.
///
/// Everything here is a real row from `GET /notifications` (migration 0024).
/// The mockup's four examples (a due date, nearby offers, a streak, a card
/// added) are exactly the four categories the app actually records, but
/// nothing is synthesised to fill the screen — an account with no deliveries
/// gets the empty state, not a demo list.
///
/// Grouping happens client-side, in the device's own timezone: "Today" is a
/// local-calendar question, and a server bucketing in UTC would move a
/// 1 a.m. IST notification into yesterday.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(notificationsProvider);
    final signedIn = ref.watch(accessTokenProvider) != null;

    return Scaffold(
      backgroundColor: BambooInk.paper,
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_rounded, color: BambooInk.ink900),
                      tooltip: 'Back',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        'Notifications',
                        style: BambooFonts.heading(26, weight: FontWeight.w800, color: BambooInk.ink900),
                      ),
                    ),
                    if ((inbox.valueOrNull?.unreadCount ?? 0) > 0)
                      TextButton(
                        onPressed: () => _markAllRead(context, ref),
                        style: TextButton.styleFrom(foregroundColor: BambooInk.ink300),
                        child: Text(
                          'Mark all read',
                          style: BambooFonts.ui(12.5, weight: FontWeight.w600, color: BambooInk.ink300),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: !signedIn
                    ? const EmptyState(
                        icon: Icons.notifications_none_rounded,
                        title: 'Notifications need an account',
                        message:
                            'Your inbox syncs with your account, so guest mode has nothing to show. '
                            'Everything else in the app keeps working.',
                      )
                    : inbox.when(
                        loading: () => const Center(child: CircularProgressIndicator()),
                        error: (err, _) => ErrorState(
                          message: userFacingErrorMessage(err),
                          onRetry: () => ref.invalidate(notificationsProvider),
                        ),
                        data: (data) => _InboxList(items: data.items),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _markAllRead(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repo.markNotificationsRead();
      ref.invalidate(notificationsProvider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
    }
  }
}

class _InboxList extends ConsumerWidget {
  final List<AppNotification> items;
  const _InboxList({required this.items});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) {
      return const EmptyState(
        icon: Icons.notifications_none_rounded,
        title: 'Nothing yet',
        message: "Due-date nudges, cap warnings and nearby offers land here. "
            "We'll only send what you've left switched on in Notifications settings.",
      );
    }

    final now = ref.watch(clockProvider).now();
    final today = DateTime(now.year, now.month, now.day);
    final todays = items.where((n) => !n.createdAt.toLocal().isBefore(today)).toList();
    final earlier = items.where((n) => n.createdAt.toLocal().isBefore(today)).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
      children: [
        if (todays.isNotEmpty) ...[
          const _SectionLabel('Today'),
          for (final n in todays) _NotificationTile(notification: n, now: now),
        ],
        if (earlier.isNotEmpty) ...[
          if (todays.isNotEmpty) const SizedBox(height: AppSpace.md),
          const _SectionLabel('Earlier'),
          for (final n in earlier) _NotificationTile(notification: n, now: now),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Text(
        text.toUpperCase(),
        style: BambooFonts.ui(
          12,
          weight: FontWeight.w600,
          color: BambooInk.ink500,
        ).copyWith(letterSpacing: 1.4),
      ),
    );
  }
}

class _NotificationTile extends ConsumerWidget {
  final AppNotification notification;
  final DateTime now;
  const _NotificationTile({required this.notification, required this.now});

  /// Design 19 tints the icon tile by severity: clay for something that
  /// costs you money if ignored, bamboo for an opportunity, neutral grey for
  /// a record of something that already happened.
  (Color tile, Color dot) get _severityColors => switch (notification.severity) {
    'urgent' => (BambooInk.warningBg, BambooInk.clay),
    'good' => (BambooInk.rankBadgeBg, BambooInk.rankBadgeInk),
    _ => (BambooInk.paperMuted, BambooInk.ink500),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (tileColor, dotColor) = _severityColors;
    final read = !notification.isUnread;
    final tappable = notification.deepLink != null;

    final content = Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: tileColor, borderRadius: BorderRadius.circular(11)),
            child: read
                ? const Icon(Icons.check_rounded, size: 15, color: BambooInk.ink500)
                : Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                  ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notification.title,
                  style: BambooFonts.ui(14, weight: FontWeight.w600, color: BambooInk.ink900),
                ),
                if (notification.body != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    notification.body!,
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.45),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Text(
            _relativeAge(notification.createdAt, now),
            style: BambooFonts.ui(11.5, color: BambooInk.ink500),
          ),
        ],
      ),
    );

    // Read entries are dimmed exactly as the mockup does, but stay legible
    // and stay tappable — "already seen" isn't "no longer useful".
    final body = read ? Opacity(opacity: 0.7, child: content) : content;
    if (!tappable && read) return body;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _open(context, ref),
        child: body,
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(userCardsRepositoryProvider);
    final link = notification.deepLink;
    // Mark read first, then navigate: navigating away disposes this widget,
    // and an invalidate afterwards would fire against a dead ref.
    if (notification.isUnread && repo != null) {
      try {
        await repo.markNotificationsRead(id: notification.id);
        ref.invalidate(notificationsProvider);
      } catch (_) {
        // A failed read-receipt must not block opening what it points at.
      }
    }
    if (link != null && context.mounted) context.push(link);
  }
}

/// "2h" / "4h" / "3d", the mockup's own shorthand. Deliberately coarse —
/// this is a timestamp column 30pt wide, not a full date.
String _relativeAge(DateTime createdAt, DateTime now) {
  final delta = now.difference(createdAt.toLocal());
  if (delta.inMinutes < 1) return 'now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m';
  if (delta.inHours < 24) return '${delta.inHours}h';
  if (delta.inDays < 7) return '${delta.inDays}d';
  return '${(delta.inDays / 7).floor()}w';
}
