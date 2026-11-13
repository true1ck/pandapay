import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../data/api_exception.dart';
import '../../../data/consents_api.dart';

/// Local mirror of "this account has agreed to share SMS fixes with the
/// community" (`sms_shared_learning`), per cache namespace.
///
/// The server row (`user_consents`, latest row per purpose) is the record.
/// The mirror only reflects what the server last said, so a correction made
/// offline keeps its "share" part for the person who agreed. Privacy rules,
/// the same as for the SMS-reading mirror, tightened:
///
/// * written only from a server answer (grant found, or no grant found);
/// * cleared by any server answer that is not a current grant, and at once by
///   [set] with false, which a withdrawal must call before anything else;
/// * valid for the exact policy version only: a new policy version is "not
///   agreed" until the person answers again (no carry-over, unlike reading).
class SmsSharedLearningConsentMirror {
  const SmsSharedLearningConsentMirror._();

  static String keyFor(String namespace) =>
      'pandapay_app.sms_shared_learning_consent_v1.$namespace';

  static bool _usable(String namespace) =>
      namespace.isNotEmpty && namespace != 'signed-out';

  static Future<bool> isGranted(String namespace) async {
    if (!_usable(namespace)) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getString(keyFor(namespace)) ==
          smsSharedLearningPolicyVersion;
    } catch (_) {
      return false;
    }
  }

  static Future<void> set(String namespace, bool granted) async {
    if (!_usable(namespace)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (granted) {
        await prefs.setString(
          keyFor(namespace),
          smsSharedLearningPolicyVersion,
        );
      } else {
        await prefs.remove(keyFor(namespace));
      }
    } catch (_) {
      // The server row stays the record; the next answer refreshes it.
    }
  }
}

/// True for a failure that only says the server could not be reached.
bool consentLookupWasOffline(Object error) =>
    error is SocketException ||
    error is TimeoutException ||
    isTransientNetworkFailure(error);

/// Whether sharing is agreed: the server's answer when there is one (which
/// also refreshes the mirror, so a withdrawal is seen as soon as the server
/// is asked), the mirror when the server could not be reached. Any other
/// failure is "not agreed": nothing is shared on a guess. [read] returns the
/// current grant record, or null when there is none.
Future<bool> sharingConsentWithMirror({
  required String namespace,
  required Future<ConsentRecord?> Function() read,
}) async {
  final ConsentRecord? record;
  try {
    record = await read();
  } catch (error) {
    if (consentLookupWasOffline(error)) {
      return SmsSharedLearningConsentMirror.isGranted(namespace);
    }
    return false;
  }
  await SmsSharedLearningConsentMirror.set(namespace, record != null);
  return record != null;
}
