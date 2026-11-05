import '../../data/local/storage_paths.dart';
import '../../data/secure_storage/flutter_secure_key_value_store.dart';
import '../../data/secure_storage/install_guard.dart';
import '../home_widget/home_widget_service.dart';
import 'account_sign_out.dart';

/// The real sign-out hooks: they remove everything the phone stores for the
/// account. Each step is independent, so a failure in one never stops the next.
class StoragePhoneWipeHooks extends PhoneWipeHooks {
  StoragePhoneWipeHooks({
    Future<void> Function()? destroyOwnedKeys,
    Future<void> Function()? clearSecureStorage,
    Future<void> Function()? deleteStorageRoot,
    Future<void> Function()? clearWidgets,
  }) : _destroyOwnedKeys =
           destroyOwnedKeys ??
           (() => FlutterSecureKeyValueStore().deleteAllOwned()),
       _clearSecureStorage =
           clearSecureStorage ?? InstallGuard.clearAllSecureStorage,
       _deleteStorageRoot =
           deleteStorageRoot ??
           (() async => (await StoragePaths.resolve()).wipe()),
       _clearWidgets = clearWidgets ?? (() => HomeWidgetService().clearAll());

  final Future<void> Function() _destroyOwnedKeys;
  final Future<void> Function() _clearSecureStorage;
  final Future<void> Function() _deleteStorageRoot;
  final Future<void> Function() _clearWidgets;

  @override
  Future<void> destroyKeys() async {
    Object? failure;
    for (final step in [_destroyOwnedKeys, _clearSecureStorage]) {
      try {
        await step();
      } catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) throw failure;
  }

  @override
  Future<void> wipeStorageRoot() => _deleteStorageRoot();

  @override
  Future<void> clearHomeWidgets() => _clearWidgets();

  @override
  Set<String> get preservedPreferenceKeys => const {InstallGuard.markerKey};
}
