import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/local_sms_rig_build.dart';

void main() {
  bool allowed({
    bool release = false,
    bool debug = false,
    bool optIn = true,
    String environment = 'dev',
    bool web = false,
    bool ca = true,
    bool key = true,
  }) => LocalSmsRigBuild.permits(
    isRelease: release,
    isDebug: debug,
    profileOptIn: optIn,
    environment: environment,
    isWeb: web,
    hasCa: ca,
    hasRuleKey: key,
  );

  test('standalone profile needs an explicit local test opt-in', () {
    expect(allowed(), isTrue);
    expect(allowed(optIn: false), isFalse);
  });
  test('release never accepts local trust even with an opt-in', () {
    expect(allowed(release: true), isFalse);
    expect(allowed(release: true, debug: true), isFalse);
  });
  test('debug retains the existing explicit development rig support', () {
    expect(allowed(debug: true, optIn: false), isTrue);
  });
  for (final environment in ['prod', 'staging', 'dev_hosted', '']) {
    test('$environment cannot enable local profile trust', () {
      expect(allowed(environment: environment), isFalse);
    });
  }
  test('both local trust anchors are required', () {
    expect(allowed(ca: false), isFalse);
    expect(allowed(key: false), isFalse);
  });
  test('the local native transport is unavailable on the web', () {
    expect(allowed(web: true), isFalse);
  });
}
