import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/secure_storage/install_guard.dart';
import 'package:pandapay/features/auth/storage_phone_wipe_hooks.dart';

void main() {
  test('destroyKeys runs both key steps even when the first fails', () async {
    final calls = <String>[];
    final hooks = StoragePhoneWipeHooks(
      destroyOwnedKeys: () async {
        calls.add('owned');
        throw StateError('boom');
      },
      clearSecureStorage: () async => calls.add('all'),
      deleteStorageRoot: () async {},
      clearWidgets: () async {},
    );
    await expectLater(hooks.destroyKeys(), throwsStateError);
    expect(calls, ['owned', 'all']);
  });

  test('each hook calls its own step', () async {
    final calls = <String>[];
    final hooks = StoragePhoneWipeHooks(
      destroyOwnedKeys: () async => calls.add('owned'),
      clearSecureStorage: () async => calls.add('all'),
      deleteStorageRoot: () async => calls.add('root'),
      clearWidgets: () async => calls.add('widgets'),
    );
    await hooks.destroyKeys();
    await hooks.wipeStorageRoot();
    await hooks.clearHomeWidgets();
    expect(calls, ['owned', 'all', 'root', 'widgets']);
  });

  test('only the install marker survives sign-out', () {
    expect(StoragePhoneWipeHooks().preservedPreferenceKeys, {
      InstallGuard.markerKey,
    });
  });
}
