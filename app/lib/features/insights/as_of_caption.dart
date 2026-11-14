import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../sync_status/sync_status_providers.dart';
import 'insights_local_first.dart';

/// WP-C7: "Saved data, as of last sync <time>" on figures that come from the
/// saved copy of a server report (caps, fee waivers, milestones, monthly
/// savings). Shown only while offline or when PandaPay cannot be reached;
/// zero height otherwise, so an online user sees no change.
class AsOfLastSyncCaption extends ConsumerWidget {
  const AsOfLastSyncCaption({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kInsightsLocalFirst) return const SizedBox.shrink();
    final mode = ref.watch(syncStatusSummaryProvider.select((s) => s.mode));
    if (mode != SyncStatusMode.offline && mode != SyncStatusMode.unreachable) {
      return const SizedBox.shrink();
    }
    final at = ref.watch(lastSyncedAtProvider).valueOrNull;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Text(
        at == null
            ? 'Saved data'
            : 'Saved data · as of last sync ${DateFormat('d MMM, h:mm a').format(at.toLocal())}',
        style: BambooFonts.ui(11.5, color: BambooInk.ink500),
      ),
    );
  }
}
