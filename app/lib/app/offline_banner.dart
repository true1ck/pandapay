import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'design/app_theme.dart';
import 'providers.dart';

/// Design 21's third state — *"You're offline · Showing your last synced
/// balances from 6:40 PM"* — as one widget every screen can drop in.
///
/// This started as `_OfflineBanner`, private to Home. The deck files
/// offline under *21 Empty & error states* with the note that it is
/// **app-wide**, and the reasoning there is a product one worth repeating:
/// the ranking is useful offline and must not hard-fail at a checkout
/// counter where signal dies. A banner only Home could draw meant Wallet,
/// Activity, Card detail and Compare all silently served cached data with
/// nothing telling the user it was cached.
///
/// Renders nothing at all when online, so it is safe to place
/// unconditionally at the top of any screen body.
class OfflineBanner extends ConsumerWidget {
  /// Horizontal inset, matching whatever gutter the host screen uses.
  final double gutter;

  /// Called when the user taps Retry. Screens that own a refreshable
  /// provider should pass an invalidate; omit it and no action is shown,
  /// since a Retry that does nothing is worse than no Retry at all.
  final VoidCallback? onRetry;

  const OfflineBanner({super.key, this.gutter = 20, this.onRetry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOnline = ref.watch(isOnlineProvider).valueOrNull ?? true;
    if (isOnline) return const SizedBox.shrink();

    final pendingCount = ref.watch(pendingOutboxCountProvider).valueOrNull ?? 0;
    final lastSynced = ref.watch(lastSyncedAtProvider).valueOrNull;
    final now = ref.watch(clockProvider).now();

    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, AppSpace.md, gutter, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.md),
        decoration: BoxDecoration(
          color: BambooInk.paperMuted,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 16, color: BambooInk.ink500),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "You're offline",
                    style: BambooFonts.ui(12.5, weight: FontWeight.w600, color: BambooInk.ink900),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    offlineDetailLine(lastSynced: lastSynced, now: now, pendingCount: pendingCount),
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                ],
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(width: AppSpace.sm),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: BambooInk.ink900,
                  minimumSize: const Size(44, 44),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                  textStyle: BambooFonts.ui(12.5, weight: FontWeight.w700),
                ),
                child: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The banner's second line, extracted so it can be unit-tested without
/// pumping a widget and a connectivity stream.
///
/// Three independent facts, only stated when true: how stale the cached
/// view is, and how many quick-add transactions are still queued. With no
/// cache timestamp at all — a user who has been offline since install —
/// the staleness clause is dropped rather than filled with a guess.
String offlineDetailLine({required DateTime? lastSynced, required DateTime now, required int pendingCount}) {
  final parts = <String>[];

  if (lastSynced == null) {
    parts.add('Showing what little is cached on this phone.');
  } else {
    final sameDay = lastSynced.year == now.year && lastSynced.month == now.month && lastSynced.day == now.day;
    final stamp = sameDay
        ? DateFormat.jm().format(lastSynced)
        : DateFormat.MMMd().add_jm().format(lastSynced);
    parts.add('Showing your last synced data from $stamp.');
  }

  if (pendingCount > 0) {
    parts.add(
      '$pendingCount transaction${pendingCount == 1 ? '' : 's'} '
      "will sync when you're back.",
    );
  }

  return parts.join(' ');
}
