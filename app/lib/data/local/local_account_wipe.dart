import 'dart:async';

import '../../features/home_widget/home_widget_service.dart';
import '../secure_storage/flutter_secure_key_value_store.dart';
import 'storage_paths.dart';

/// Some steps of the local wipe failed. The other steps still ran.
final class LocalWipeIncomplete implements Exception {
  const LocalWipeIncomplete(this.failedSteps);
  final List<String> failedSteps;
  @override
  String toString() => 'LocalWipeIncomplete(${failedSteps.join(', ')})';
}

/// Removes every piece of account data this phone holds, in the order sign-out
/// needs: files first, then the keys that could read them, then the widgets.
///
/// Before calling [run]: revoke the session on the server, close every
/// [AppDatabase] connection and stop the `FinancialReadWorker`; afterwards
/// invalidate the Riverpod providers that held them. The iOS SMS spool key is
/// destroyed natively when the spool is emptied (`IosSmsIntakeService.revoke`,
/// which `TokenStore.clear` already calls).
///
/// Every step runs even when an earlier one fails, so a half-failed sign-out
/// still destroys the keys. Failures are reported together afterwards.
class LocalAccountWipe {
  LocalAccountWipe({
    Future<void> Function()? deleteFiles,
    Future<void> Function()? destroyKeys,
    Future<void> Function()? clearWidgets,
  }) : _deleteFiles =
           deleteFiles ?? (() async => (await StoragePaths.resolve()).wipe()),
       _destroyKeys =
           destroyKeys ?? (() => FlutterSecureKeyValueStore().deleteAllOwned()),
       _clearWidgets = clearWidgets ?? (() => HomeWidgetService().clearAll());

  final Future<void> Function() _deleteFiles;
  final Future<void> Function() _destroyKeys;
  final Future<void> Function() _clearWidgets;

  /// Deletes `Application Support/PandaPay` (database, receipts), destroys the
  /// database key and every receipt key, and clears the home widgets.
  /// Throws [LocalWipeIncomplete] if any step failed.
  Future<void> run() async {
    final failed = <String>[];
    for (final (name, step) in [
      ('files', _deleteFiles),
      ('keys', _destroyKeys),
      ('widgets', _clearWidgets),
    ]) {
      try {
        await step();
      } catch (_) {
        failed.add(name);
      }
    }
    if (failed.isNotEmpty) throw LocalWipeIncomplete(failed);
  }
}
