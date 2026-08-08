import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// H5 Data & Storage — pure, unit-testable helpers kept separate from the
/// widget so they can be exercised without a `Directory`/`SharedPreferences`
/// platform channel in a plain `flutter test` (no widget pump needed).

/// Recursively sums the byte size of every regular file under [dir].
/// Missing directory (nothing cached yet) returns 0 rather than throwing —
/// a freshly-installed app legitimately has no cache directory contents.
Future<int> computeDirectorySize(Directory dir) async {
  if (!await dir.exists()) return 0;
  var total = 0;
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      try {
        total += await entity.length();
      } on FileSystemException {
        // File vanished between listing and stat (e.g. concurrent cache
        // write) — skip rather than fail the whole sum.
      }
    }
  }
  return total;
}

/// Deletes every file/subdirectory *inside* [dir] without deleting [dir]
/// itself (so the app's cache root stays a valid, writable directory for
/// whatever creates it next).
Future<void> clearDirectoryContents(Directory dir) async {
  if (!await dir.exists()) return;
  await for (final entity in dir.list(followLinks: false)) {
    try {
      await entity.delete(recursive: true);
    } on FileSystemException {
      // Best-effort: a file locked by another process shouldn't abort the
      // whole clear operation.
    }
  }
}

/// Human-readable byte formatting — KB below 1 MB, MB above, matching the
/// spec's "Storage used" row (no bytes/GB granularity needed at this scale).
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

/// Removes every `SharedPreferences` key except those starting with any of
/// [preserveKeyPrefixes] — used by "Reset all data" so the token store
/// (session) survives while every other local preference/cache flag is
/// wiped. Returns the keys that were actually removed, for verification.
Future<List<String>> clearPreferencesExceptPrefixes(
  SharedPreferences prefs,
  List<String> preserveKeyPrefixes,
) async {
  final allKeys = prefs.getKeys();
  final toRemove = allKeys.where((key) {
    return !preserveKeyPrefixes.any((prefix) => key.startsWith(prefix));
  }).toList();
  for (final key in toRemove) {
    await prefs.remove(key);
  }
  return toRemove;
}
