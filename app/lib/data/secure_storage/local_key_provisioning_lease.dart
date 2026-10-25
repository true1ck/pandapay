import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Cross-isolate and cross-process serialization boundary for key custody.
abstract interface class LocalKeyProvisioningLease {
  Future<T> runExclusive<T>(Future<T> Function() operation);
}

final class LocalKeyProvisioningLeaseUnavailable implements Exception {
  const LocalKeyProvisioningLeaseUnavailable();
}

/// The lease is healthy but remained held until the bounded wait expired.
final class LocalKeyProvisioningLeaseBusy implements Exception {
  const LocalKeyProvisioningLeaseBusy();
}

/// Uses an independent SQLite database so the lease exists before the primary
/// database is opened. SQLite's reserved write lock is process-wide on disk.
final class SqliteLocalKeyProvisioningLease
    implements LocalKeyProvisioningLease {
  final String databasePath;
  final Duration timeout;
  final Duration retryInterval;

  SqliteLocalKeyProvisioningLease(
    this.databasePath, {
    this.timeout = const Duration(seconds: 10),
    this.retryInterval = const Duration(milliseconds: 20),
  }) {
    _validateDurations(timeout, retryInterval);
  }

  static LocalKeyProvisioningLease applicationSupport({
    Duration timeout = const Duration(seconds: 10),
  }) {
    _validateDurations(timeout, const Duration(milliseconds: 20));
    return _ApplicationSupportLease(timeout);
  }

  @override
  Future<T> runExclusive<T>(Future<T> Function() operation) async {
    final timer = Stopwatch()..start();
    Database? database;
    try {
      final target = File(databasePath).absolute;
      await _rejectUnsafePath(target);
      final parent = target.parent;
      await parent.create(recursive: true);
      await _rejectUnsafePath(target);
      database = sqlite3.open(target.path);
      database.execute('PRAGMA busy_timeout = 0');
      while (true) {
        try {
          database.execute('BEGIN IMMEDIATE');
          break;
        } on SqliteException catch (error) {
          if (!_isBusy(error)) {
            throw const LocalKeyProvisioningLeaseUnavailable();
          }
          if (timer.elapsed >= timeout) {
            throw const LocalKeyProvisioningLeaseBusy();
          }
          await Future<void>.delayed(retryInterval);
        }
      }
      try {
        return await operation();
      } finally {
        database.execute('ROLLBACK');
      }
    } on LocalKeyProvisioningLeaseUnavailable {
      rethrow;
    } on LocalKeyProvisioningLeaseBusy {
      rethrow;
    } on Object {
      throw const LocalKeyProvisioningLeaseUnavailable();
    } finally {
      database?.dispose();
    }
  }

  bool _isBusy(SqliteException error) =>
      error.resultCode == 5 || error.resultCode == 6;

  static void _validateDurations(Duration timeout, Duration retryInterval) {
    if (timeout <= Duration.zero ||
        timeout > const Duration(minutes: 1) ||
        retryInterval <= Duration.zero ||
        retryInterval > timeout) {
      throw ArgumentError('Invalid local key lease timeout or retry interval');
    }
  }

  static Future<void> _rejectUnsafePath(File target) async {
    var current = target.parent;
    while (true) {
      final type = await FileSystemEntity.type(
        current.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.link) {
        if (!await _trustedSystemAlias(current)) {
          throw const LocalKeyProvisioningLeaseUnavailable();
        }
      } else if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw const LocalKeyProvisioningLeaseUnavailable();
      }
      if (current.parent.path == current.path) break;
      current = current.parent;
    }
    final targetType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.notFound &&
        targetType != FileSystemEntityType.file) {
      throw const LocalKeyProvisioningLeaseUnavailable();
    }
  }

  static Future<bool> _trustedSystemAlias(Directory directory) async {
    if (!Platform.isMacOS && !Platform.isIOS) return false;
    final expected = switch (directory.path) {
      '/var' => '/private/var',
      '/tmp' => '/private/tmp',
      _ => null,
    };
    if (expected == null) return false;
    try {
      return await directory.resolveSymbolicLinks() == expected;
    } on FileSystemException {
      return false;
    }
  }
}

final class _ApplicationSupportLease implements LocalKeyProvisioningLease {
  final Duration timeout;
  _ApplicationSupportLease(this.timeout);

  @override
  Future<T> runExclusive<T>(Future<T> Function() operation) async {
    try {
      final directory = await getApplicationSupportDirectory();
      // path_provider returns an OS-owned app-private location. Some Android
      // API levels expose that location through compatibility aliases (for
      // example /data/data -> /data/user/0). Resolve that trusted plugin path
      // before passing it to the stricter injectable lease-path validator.
      await directory.create(recursive: true);
      final canonicalDirectory = await directory.resolveSymbolicLinks();
      return await SqliteLocalKeyProvisioningLease(
        '$canonicalDirectory${Platform.pathSeparator}pandapay-key-provisioning-lease.sqlite',
        timeout: timeout,
      ).runExclusive(operation);
    } on LocalKeyProvisioningLeaseUnavailable {
      rethrow;
    } on LocalKeyProvisioningLeaseBusy {
      rethrow;
    } on Object {
      throw const LocalKeyProvisioningLeaseUnavailable();
    }
  }
}
