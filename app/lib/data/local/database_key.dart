import 'dart:ffi';
import 'dart:io';

import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import '../secure_storage/flutter_secure_key_value_store.dart';
import '../secure_storage/local_database_key_custody.dart';

final _hexKey = RegExp(r'^[0-9a-f]{64}$');

/// Call once in every isolate before the first sqlite3 use (main, workers,
/// background SMS entry points). Android must load libsqlcipher instead of the
/// system libsqlite, and iOS must be pinned to SQLCipher.framework (see
/// [openCipherOnIos]). Safe to repeat.
void ensureSqlCipherLoaded() {
  if (Platform.isAndroid) {
    open.overrideFor(OperatingSystem.android, openCipherOnAndroid);
  } else if (Platform.isIOS) {
    open.overrideFor(OperatingSystem.iOS, openCipherOnIos);
  }
}

/// Where the iOS app keeps SQLCipher: a dynamic framework that CocoaPods
/// embeds (`use_frameworks!`). The first path is how the dynamic linker names
/// it, the second the short form it also accepts.
const iosSqlCipherPaths = [
  '@rpath/SQLCipher.framework/SQLCipher',
  'SQLCipher.framework/SQLCipher',
];

/// Opens SQLCipher on iOS by name instead of searching the whole process.
///
/// The iOS app contains two SQLite builds that export the same `sqlite3_*`
/// names: Apple's `libsqlite3.dylib` (Firebase Messaging links it, and it comes
/// first in the app's link order) and `SQLCipher.framework`. `package:sqlite3`
/// otherwise looks the names up in the whole process, so which build a phone
/// gets is not pinned. When it was Apple's, `PRAGMA cipher_version` came back
/// empty and the app refused to open the database ("SQLCipher is not
/// linked"). Opening the framework itself binds every call to SQLCipher.
///
/// [openLibrary], [isSqlCipher] and [fallback] exist for tests. A library that
/// does not load, or does not export `sqlite3_key`, is skipped; if none does,
/// the process-wide lookup is used, as before.
DynamicLibrary openCipherOnIos({
  DynamicLibrary Function(String path)? openLibrary,
  bool Function(DynamicLibrary library)? isSqlCipher,
  DynamicLibrary Function()? fallback,
}) {
  final load = openLibrary ?? DynamicLibrary.open;
  final isCipher =
      isSqlCipher ?? (DynamicLibrary lib) => lib.providesSymbol('sqlite3_key');
  for (final path in iosSqlCipherPaths) {
    try {
      final library = load(path);
      if (isCipher(library)) return library;
      // ignore: avoid_catching_errors
    } on ArgumentError {
      // Not at this path; try the next one.
    }
  }
  return (fallback ?? DynamicLibrary.process)();
}

String keyBytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Must run before any other statement on the connection.
void applyCipherKey(Database db, String keyHex) {
  if (!_hexKey.hasMatch(keyHex)) throw ArgumentError('Invalid database key');
  db.execute("PRAGMA key = \"x'$keyHex'\"");
  final rows = db.select('PRAGMA cipher_version');
  final version = rows.isEmpty ? null : rows.first.values.first as String?;
  if (version == null || version.isEmpty) {
    throw StateError(
      'SQLCipher is not linked; refusing to open an unencrypted database',
    );
  }
  // A wrong key fails here with SQLITE_NOTADB (26).
  db.select('SELECT count(*) FROM sqlite_master');
}

final class DatabaseKeyUnavailable implements Exception {
  const DatabaseKeyUnavailable(this.status);
  final LocalKeyStatus status;

  /// The phone is locked or the secure store is busy; nothing is wrong with
  /// the key, so callers must not reset anything.
  bool get isTemporary =>
      status == LocalKeyStatus.unavailable || status == LocalKeyStatus.busy;

  @override
  String toString() => 'DatabaseKeyUnavailable(${status.name})';
}

/// The single install key. Never derived from the account; destroyed on
/// sign-out by [destroy].
class DatabaseKeyLoader {
  DatabaseKeyLoader({required this.installId, LocalDatabaseKeyCustody? custody})
    : _custody =
          custody ?? LocalDatabaseKeyCustody(FlutterSecureKeyValueStore());

  final String installId;
  final LocalDatabaseKeyCustody _custody;

  Future<String> loadHex({required bool databaseExists}) async {
    final result = await _custody.openKey(
      installId: installId,
      encryptedManifestExists: databaseExists,
    );
    final handle = result.handle;
    if (handle == null) throw DatabaseKeyUnavailable(result.status);
    try {
      return handle.withKeyBytes(keyBytesToHex);
    } finally {
      handle.dispose();
    }
  }

  /// Loads the key for the database at [databasePath]. If the file exists but
  /// its key is lost, bound to another install or damaged, the file can never
  /// be read again: [wipeStorage] deletes it, the dead key is destroyed and a
  /// fresh key is created (server data re-syncs after sign-in). A temporarily
  /// unavailable key store is rethrown untouched, because the phone may just
  /// not have been unlocked since boot.
  Future<String> loadHexOrReset({
    required String databasePath,
    required Future<void> Function() wipeStorage,
  }) async {
    try {
      return await loadHex(databaseExists: File(databasePath).existsSync());
    } on DatabaseKeyUnavailable catch (error) {
      if (error.isTemporary) rethrow;
      await wipeStorage();
      await destroy();
      return loadHex(databaseExists: false);
    }
  }

  /// Destroys the install key. The encrypted database becomes unreadable
  /// noise; delete the files too ([StoragePaths.wipe]). Close every
  /// connection first.
  Future<void> destroy() => _custody.destroy();
}
