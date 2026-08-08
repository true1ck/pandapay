import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/app_status_repository.dart';

void main() {
  group('isVersionOlderThan', () {
    test('equal versions are not older', () {
      expect(isVersionOlderThan('1.0.0', '1.0.0'), false);
    });

    test('a lower patch version is older', () {
      expect(isVersionOlderThan('1.0.0', '1.0.1'), true);
    });

    test('a higher major version is not older', () {
      expect(isVersionOlderThan('2.0.0', '1.9.9'), false);
    });

    test('a shorter version string is padded with zeros', () {
      expect(isVersionOlderThan('1.0', '1.0.1'), true);
      expect(isVersionOlderThan('1.1', '1.0.9'), false);
    });

    test('a non-numeric segment does not throw — falls back to 0, not full semver', () {
      // "0-beta" isn't parseable as an int, so int.tryParse returns null and
      // this falls back to 0, same as "1.0.0" — a known, documented
      // simplification (not full semver pre-release ordering).
      expect(isVersionOlderThan('1.0.0-beta', '1.0.0'), false);
    });
  });

  group('AppStatus.fromJson', () {
    test('parses a live-shaped maintenance response', () {
      final status = AppStatus.fromJson({
        'minSupportedVersion': '1.2.0',
        'maintenanceMode': true,
        'maintenanceMessage': 'Down for scheduled maintenance until 5pm IST.',
      });
      expect(status.minSupportedVersion, '1.2.0');
      expect(status.maintenanceMode, true);
      expect(status.maintenanceMessage, 'Down for scheduled maintenance until 5pm IST.');
    });

    test('defaults maintenanceMode to false and version to 1.0.0 when absent', () {
      final status = AppStatus.fromJson({});
      expect(status.minSupportedVersion, '1.0.0');
      expect(status.maintenanceMode, false);
      expect(status.maintenanceMessage, isNull);
    });
  });
}
