import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

/// Only an explicitly created app-private workspace can be recursively removed.
/// Gallery originals and arbitrary picker paths are never cleanup targets.
class PrivateTemporaryWorkspace {
  static const prefix = 'pandapay-private-v1-';
  static const markerName = '.pandapay-private-workspace-v1';
  static final Set<String> _active = {};
  final Directory directory;
  final String _root;
  final String _token;

  PrivateTemporaryWorkspace._(this.directory, this._root, this._token);

  static Future<PrivateTemporaryWorkspace> create(Directory privateRoot) async {
    await privateRoot.create(recursive: true);
    final root = await privateRoot.resolveSymbolicLinks();
    if (path.dirname(root) == root) {
      throw const FileSystemException('Private temporary root is invalid');
    }
    final random = Random.secure();
    final token = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final directory = Directory(path.join(root, '$prefix$token'));
    await directory.create();
    await File(path.join(directory.path, markerName)).writeAsString(
      jsonEncode({
        'version': 1,
        'token': token,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    _active.add(directory.path);
    return PrivateTemporaryWorkspace._(directory, root, token);
  }

  File file(String name) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$').hasMatch(name)) {
      throw const FormatException('Invalid private staging filename');
    }
    return File(path.join(directory.path, name));
  }

  Future<bool> cleanup() async {
    _active.remove(directory.path);
    try {
      if (!await directory.exists()) return true;
      if (!await _owned(directory, _root, expectedToken: _token)) return false;
      // Delete links themselves, never their gallery/external targets.
      await directory.delete(recursive: true);
      return true;
    } on Object {
      // Cleanup must not replace a successful OCR result with a marker/read
      // failure. Leave uncertain ownership untouched for operator review.
      return false;
    }
  }

  static Future<bool> _owned(
    Directory directory,
    String root, {
    String? expectedToken,
  }) async {
    if (path.dirname(directory.path) != root ||
        await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      return false;
    }
    final token = path.basename(directory.path).replaceFirst(prefix, '');
    if (!path.basename(directory.path).startsWith(prefix) ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(token) ||
        (expectedToken != null && token != expectedToken)) {
      return false;
    }
    final marker = File(path.join(directory.path, markerName));
    if (await FileSystemEntity.type(marker.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await marker.length() > 1024) {
      return false;
    }
    try {
      final value = jsonDecode(await marker.readAsString());
      return value is Map &&
          value['version'] == 1 &&
          value['token'] == token &&
          DateTime.tryParse('${value['created_at']}') != null;
    } on Object {
      return false;
    }
  }

  /// Does not scan outside [privateRoot], follow links, or delete unmarked data.
  /// At most 50 stale workspaces are removed per startup invocation.
  static Future<int> reapStale(
    Directory privateRoot, {
    DateTime? now,
    Duration maxAge = const Duration(hours: 24),
  }) async {
    if (maxAge < const Duration(hours: 1)) {
      throw const FormatException('Temporary cleanup age is too short');
    }
    if (!await privateRoot.exists()) return 0;
    final root = await privateRoot.resolveSymbolicLinks();
    var removed = 0, inspected = 0;
    await for (final entry in Directory(root).list(followLinks: false)) {
      if (removed >= 50 || inspected++ >= 200) break;
      if (entry is! Directory ||
          _active.contains(entry.path) ||
          !await _owned(entry, root)) {
        continue;
      }
      try {
        final marker =
            jsonDecode(
                  await File(path.join(entry.path, markerName)).readAsString(),
                )
                as Map;
        final created = DateTime.parse(marker['created_at'] as String).toUtc();
        if ((now ?? DateTime.now()).toUtc().difference(created) < maxAge) {
          continue;
        }
        await entry.delete(recursive: true);
        removed += 1;
      } on Object {
        // An unreadable/active directory is left for a later startup attempt.
      }
    }
    return removed;
  }
}
