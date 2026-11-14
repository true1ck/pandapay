import 'sync_status_providers.dart';

/// All words the strip says, in one place. Plain language, no jargon.
/// Deliberately not the legacy Home banner phrase (that one stays removed).

String _changes(int n) => n == 1 ? '1 change' : '$n changes';

/// The single line shown in the strip.
String syncStatusLabel(SyncStatusSummary summary) {
  final waiting = summary.pendingCount > 0
      ? ' · ${summary.pendingCount} waiting to sync'
      : '';
  switch (summary.mode) {
    case SyncStatusMode.hidden:
      return '';
    case SyncStatusMode.offline:
      return 'Offline · showing saved data$waiting';
    case SyncStatusMode.unreachable:
      return "Can't reach PandaPay · showing saved data$waiting";
    case SyncStatusMode.syncing:
      return 'Syncing ${_changes(summary.pendingCount)}…';
    case SyncStatusMode.needsAttention:
      return summary.attentionCount == 1
          ? '1 change needs attention'
          : '${summary.attentionCount} changes need attention';
  }
}

/// What a screen reader announces for the strip.
String syncStatusSemanticsLabel(SyncStatusSummary summary) {
  final waiting = summary.pendingCount > 0
      ? '${_changes(summary.pendingCount)} waiting'
      : 'showing saved data';
  const tap = 'Tap for details';
  switch (summary.mode) {
    case SyncStatusMode.hidden:
      return '';
    case SyncStatusMode.offline:
      return 'Offline, $waiting. $tap';
    case SyncStatusMode.unreachable:
      return "Can't reach PandaPay, $waiting. $tap";
    case SyncStatusMode.syncing:
      return 'Syncing ${_changes(summary.pendingCount)}. $tap';
    case SyncStatusMode.needsAttention:
      return '${syncStatusLabel(summary)}. $tap';
  }
}
