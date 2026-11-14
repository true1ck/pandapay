import 'sync_status_providers.dart';

/// All words the strip says, in one place. Plain language, no jargon.
/// Deliberately not the legacy Home banner phrase (that one stays removed).

/// The single line shown in the strip.
String syncStatusLabel(SyncStatusSummary summary) {
  switch (summary.mode) {
    case SyncStatusMode.hidden:
      return '';
    case SyncStatusMode.offline:
      return 'Offline mode · changes saved on this phone';
    case SyncStatusMode.unreachable:
      return "Can't reach PandaPay · changes saved on this phone";
    case SyncStatusMode.syncing:
      return 'Syncing…';
    case SyncStatusMode.needsAttention:
      return 'Some changes are saved on this phone';
  }
}

/// What a screen reader announces for the strip: the visible text, no counts.
String syncStatusSemanticsLabel(SyncStatusSummary summary) {
  final label = syncStatusLabel(summary);
  return label.isEmpty ? '' : '$label. Tap for details';
}
