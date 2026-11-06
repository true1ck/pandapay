import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/notifications/push_deep_link.dart';

void main() {
  const id = 'd0d5c8ad-7b46-47f2-8062-384cec32f654';

  test('a split group link from a push is allowed', () {
    expect(pushDeepLink('/insights/splits/$id'), '/insights/splits/$id');
    expect(
      pushDeepLink('  /insights/splits/${id.toUpperCase()}  '),
      '/insights/splits/$id',
    );
  });

  test('anything else in the payload is ignored, never routed', () {
    for (final bad in [
      null,
      42,
      '',
      '/insights/splits/',
      '/insights/splits/not-a-uuid',
      '/insights/splits/$id/extra',
      '/insights/splits/$id?x=1',
      'https://evil.example/insights/splits/$id',
      '//evil.example/insights/splits/$id',
      '/settings/delete-account',
      '/insights/splits/../../x',
    ]) {
      expect(pushDeepLink(bad), isNull, reason: '$bad');
    }
  });
}
