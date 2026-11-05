import 'package:flutter/foundation.dart';

/// Local test trust is excluded from every release artifact. An explicitly
/// opted-in Profile build can run on an iPhone without a debugger attached.
abstract final class LocalSmsRigBuild {
  static const rulePublicKey = String.fromEnvironment(
    'SMS_V2_LOCAL_RULE_PUBLIC_KEY',
  );
  static const encodedCa = String.fromEnvironment('SMS_V2_LOCAL_CA_PEM');

  static bool get enabled => permits(
    isRelease: kReleaseMode,
    isDebug: kDebugMode,
    profileOptIn: const bool.fromEnvironment('SMS_V2_LOCAL_TEST_BUILD'),
    environment: const String.fromEnvironment('PANDAPAY_ENV'),
    isWeb: kIsWeb,
    hasCa: encodedCa.isNotEmpty,
    hasRuleKey: rulePublicKey.isNotEmpty,
  );

  static bool get controlsEnabled => kDebugMode || enabled;

  @visibleForTesting
  static bool permits({
    required bool isRelease,
    required bool isDebug,
    required bool profileOptIn,
    required String environment,
    required bool isWeb,
    required bool hasCa,
    required bool hasRuleKey,
  }) =>
      !isRelease &&
      !isWeb &&
      environment == 'dev' &&
      hasCa &&
      hasRuleKey &&
      (isDebug || profileOptIn);
}
