import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const _localDeviceIdKey = 'local_device_id_v1';

/// This install's own stable identifier, generated once and persisted —
/// the value login_screen.dart/account_recovery_screen.dart now send as
/// `device_id` at OTP-verify (replacing the literal string `'app-mobile'`
/// every install used to send, which made every phone the SAME device as
/// far as `user_devices` — see pubspec.yaml's comment on the `uuid`
/// dependency), and the value linked_devices_screen.dart compares against
/// each fetched device's `deviceIdentifier` to highlight "this device."
///
/// Plain SharedPreferences, not flutter_secure_storage: this is an
/// identifier, not a credential — knowing it grants nothing on its own,
/// same reasoning `biometric_lock_enabled_v1` is stored the same way.
class DeviceIdentity {
  Future<String> localDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_localDeviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = const Uuid().v4();
    await prefs.setString(_localDeviceIdKey, generated);
    return generated;
  }
}
