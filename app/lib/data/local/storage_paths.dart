import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Every file that holds account data lives under one private root,
/// Application Support/PandaPay, never Documents. iOS excludes the root from
/// iCloud and computer backups; Android blocks backup and device transfer in
/// the manifest (`data_extraction_rules.xml`).
class StoragePaths {
  StoragePaths._(this.root, this._excludeFromBackup);

  final Directory root;
  final Future<void> Function(String path) _excludeFromBackup;

  static const _channel = MethodChannel('pandapay/storage');
  static Future<StoragePaths>? _shared;

  /// The process-wide root. Each isolate resolves its own copy; the result is
  /// the same folder.
  static Future<StoragePaths> resolve() => _shared ??= create(
    supportDirectory: getApplicationSupportDirectory,
    excludeFromBackup: (path) async {
      if (Platform.isIOS) {
        await _channel.invokeMethod<void>('excludeFromBackup', {'path': path});
      }
    },
  ).catchError((Object error) {
    _shared = null; // Do not cache a failure; the next call retries.
    throw error;
  });

  static Future<StoragePaths> create({
    required Future<Directory> Function() supportDirectory,
    required Future<void> Function(String path) excludeFromBackup,
  }) async {
    final support = await supportDirectory();
    final root = Directory(p.join(support.path, 'PandaPay'));
    await root.create(recursive: true);
    await excludeFromBackup(root.path);
    return StoragePaths._(root, excludeFromBackup);
  }

  String get databasePath => p.join(root.path, 'pandapay.sqlite');
  Directory get receiptsDir => Directory(p.join(root.path, 'receipts'));

  /// Deletes every account file and leaves an empty, backup-excluded root.
  /// Close database connections and stop the read worker first. Sign-out calls
  /// this after it has revoked the session.
  Future<void> wipe() async {
    if (await root.exists()) await root.delete(recursive: true);
    await root.create(recursive: true);
    await _excludeFromBackup(root.path);
  }
}
