/// SMS pipeline v2 template identity and redaction (WP-00).
///
/// Pure Dart, shared by the rules CLI, the rules engine and the phone:
/// the sender brand, the message skeleton, `templateHash`, and `redactSms`.
library;

export 'src/sms_v2/template/redact.dart';
export 'src/sms_v2/template/skeleton.dart';
export 'src/sms_v2/template/vocabulary.dart' show smsMerchantCatalogue;
