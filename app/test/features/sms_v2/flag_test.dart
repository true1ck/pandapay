import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/flag.dart';

void main() {
  test('the build flag defaults to off', () {
    // Run with --dart-define=SMS_PIPELINE_V2=true to exercise the flag-on path.
    const defined = bool.fromEnvironment('SMS_PIPELINE_V2');
    expect(kSmsPipelineV2, defined);
  });

  test('the provider follows the build flag and can be overridden in tests', () {
    final plain = ProviderContainer();
    addTearDown(plain.dispose);
    expect(plain.read(smsPipelineV2EnabledProvider), kSmsPipelineV2);

    final forcedOn = ProviderContainer(overrides: [
      smsPipelineV2EnabledProvider.overrideWithValue(true),
    ]);
    addTearDown(forcedOn.dispose);
    expect(forcedOn.read(smsPipelineV2EnabledProvider), isTrue);
  });
}
