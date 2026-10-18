import 'package:geolocator/geolocator.dart' as geo;
import 'package:permission_handler/permission_handler.dart';

/// Read the operating system each time; saved app settings are not evidence
/// that a permission is still enabled.
Future<PermissionStatus> readDevicePermissionStatus(
  Permission permission,
) async {
  if (permission == Permission.locationWhenInUse ||
      permission == Permission.location) {
    return foregroundLocationPermissionStatus(
      await geo.Geolocator.checkPermission(),
    );
  }
  return permission.status;
}

/// Android's approximate-only grant still enables foreground location.
/// Checking the combined fine/coarse permission with permission_handler can
/// otherwise report that valid grant as denied.
PermissionStatus foregroundLocationPermissionStatus(
  geo.LocationPermission permission,
) => switch (permission) {
  geo.LocationPermission.whileInUse ||
  geo.LocationPermission.always => PermissionStatus.granted,
  geo.LocationPermission.deniedForever => PermissionStatus.permanentlyDenied,
  _ => PermissionStatus.denied,
};
