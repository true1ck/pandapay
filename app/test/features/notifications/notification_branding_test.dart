import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android notification aliases map to the approved artwork', () {
    final aliases = File(
      'android/app/src/main/res/values/notification_branding.xml',
    ).readAsStringSync();
    expect(
      aliases,
      contains(
        '<item type="drawable" name="pandapay_notification_small_icon">'
        '@drawable/ic_notification</item>',
      ),
    );
    expect(
      aliases,
      contains(
        '<item type="drawable" name="pandapay_notification_large_icon">'
        '@drawable/ic_notification_large</item>',
      ),
    );
  });

  test('shared Flutter notification details include both aliases', () {
    final branding = File(
      'lib/features/notifications/notification_branding.dart',
    ).readAsStringSync();
    expect(branding, contains('icon: smallIcon'));
    expect(
      branding,
      contains('largeIcon: DrawableResourceAndroidBitmap(largeIcon)'),
    );
  });
}
