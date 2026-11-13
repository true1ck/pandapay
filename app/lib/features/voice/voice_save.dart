/// Saves each voice entry once. [save] writes one entry locally (outbox or
/// command queue) and may throw; an entry that was written is never written
/// again on a retry, and one failing entry does not stop the others.
/// Returns the indexes that failed (empty = all saved).
Future<List<int>> saveVoiceEntries<T>(
  List<T> entries, {
  required bool Function(T) isSaved,
  required void Function(T) markSaved,
  required Future<void> Function(T) save,
}) async {
  final failed = <int>[];
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    if (isSaved(entry)) continue;
    try {
      await save(entry);
      markSaved(entry);
    } catch (_) {
      failed.add(i);
    }
  }
  return failed;
}
