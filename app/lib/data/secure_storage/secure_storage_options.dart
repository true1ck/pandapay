import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The one set of Keychain/Keystore options every PandaPay secret uses.
/// iOS: readable after the first unlock (background SMS work runs while the
/// phone is locked) and never synced to iCloud or moved to another device.
/// Android: never reset the store on a cipher error.
const pandaPayAndroidStorageOptions = AndroidOptions(resetOnError: false);
const pandaPayIosStorageOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
  synchronizable: false,
);

/// A secure storage handle with those options.
const pandaPaySecureStorage = FlutterSecureStorage(
  aOptions: pandaPayAndroidStorageOptions,
  iOptions: pandaPayIosStorageOptions,
);
