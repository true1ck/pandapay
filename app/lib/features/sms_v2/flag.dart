import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Build flag for the SMS pipeline v2.
///
/// Every new behaviour on an app code path runs only when this is true. With it
/// off, the app behaves exactly as before. Turn it on with
/// `--dart-define=SMS_PIPELINE_V2=true`.
const bool kSmsPipelineV2 = bool.fromEnvironment('SMS_PIPELINE_V2');

/// Whether the v2 pipeline is enabled. Follows [kSmsPipelineV2]; tests override
/// it with `smsPipelineV2EnabledProvider.overrideWithValue(true)`.
final smsPipelineV2EnabledProvider = Provider<bool>((ref) => kSmsPipelineV2);
