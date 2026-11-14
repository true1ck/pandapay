import 'sync_status_providers.dart';

/// All words the strip says, in one place. Plain language, no jargon.
/// Deliberately not the legacy Home banner phrase (that one stays removed).

String _changes(int n) => n == 1 ? '1 change' : '$n changes';

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
