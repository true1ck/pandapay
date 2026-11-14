import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/consent_policy.dart';
import '../../data/consents_api.dart';

/// Consent purpose recorded with `POST /consents` when someone agrees to
/// PandaPay reading their bank SMS. One row per account, so a second account
/// on the same phone sees the disclosure before its own history import.
const smsReadingConsentPurpose = 'sms_reading';

/// Local mirror of "this account has agreed", per cache namespace.
///
/// The server row (`user_consents`) is the record. The mirror lets the
/// pipeline decide without a network round trip, and lets the Android
/// background isolate (which has no providers) skip a message when the account
/// has not agreed. It is written only after the server accepted the grant, and
/// cleared when the consent is withdrawn.
class SmsReadingConsentMirror {
  const SmsReadingConsentMirror._();

  static String keyFor(String namespace) =>
      'pandapay_app.sms_reading_consent_v1.$namespace';

  static bool _usable(String namespace) =>
      namespace.isNotEmpty && namespace != 'signed-out';

  static Future<bool> isGranted(String namespace) async {
    if (!_usable(namespace)) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getString(keyFor(namespace)) == consentPolicyVersion;
    } catch (_) {
      return false;
    }
  }

  /// The policy version the mirror was written for, or null when there is no
  /// mirror (never agreed, withdrawn, cleared).
  static Future<String?> storedVersion(String namespace) async {
    if (!_usable(namespace)) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final v = prefs.getString(keyFor(namespace));
      return v == null || v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// WP-C11 (decision D8): a mirror written for an OLDER policy version still
  /// counts as agreed until the person can be asked again online, so a policy
  /// bump while offline does not stop SMS reading. Withdrawing clears the
  /// mirror, so this is never true after a revoke. The foreground check
  /// ([hasSmsReadingConsent]) clears a carried-over mirror once the server
  /// answers and has no current grant, which is what triggers the re-prompt.
  static Future<bool> isGrantedOrCarriedOver(String namespace) async =>
      await storedVersion(namespace) != null;

  static Future<void> set(String namespace, bool granted) async {
    if (!_usable(namespace)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (granted) {
        await prefs.setString(keyFor(namespace), consentPolicyVersion);
      } else {
        await prefs.remove(keyFor(namespace));
      }
    } catch (_) {
      // The server row stays the record; the next check reads it again.
    }
  }
}

/// True when the latest `sms_reading` row for this account is a grant against
/// the current policy version. The local mirror answers first; otherwise the
/// server is asked, and a grant found there refreshes the mirror. A failed
/// lookup is "not granted": nothing reads SMS on a guess.
Future<bool> hasSmsReadingConsent({
  required String namespace,
  required ConsentsApi? api,
}) async {
  final stored = await SmsReadingConsentMirror.storedVersion(namespace);
  if (stored == consentPolicyVersion) return true;
  if (api == null) return false;
  final List<ConsentRecord> latest;
  try {
    latest = await api.fetchLatest().timeout(const Duration(seconds: 8));
  } catch (error) {
    // D8: agreed to an earlier policy and the server cannot be asked right
    // now: keep reading rather than pause on a version bump.
    if (stored != null && isOfflineLike(error, knownOffline: false)) {
      return true;
    }
    rethrow;
  }
  final granted = latest.any(
    (c) =>
        c.purpose == smsReadingConsentPurpose &&
        c.granted &&
        c.revokedAt == null &&
        c.policyVersion == consentPolicyVersion,
  );
  if (granted) {
    await SmsReadingConsentMirror.set(namespace, true);
  } else if (stored != null) {
    // The server has no current grant (a newer policy, or withdrawn on
    // another device): stop carrying the old agreement and ask again.
    await SmsReadingConsentMirror.set(namespace, false);
  }
  return granted;
}

/// Whether the signed-in account has agreed to SMS reading. Everything that
/// reads SMS or starts a history import asks this first; widgets override it
/// in tests. Invalidate it after the consent changes.
final smsReadingConsentProvider = FutureProvider<bool>((ref) {
  final namespace = ref.watch(cacheNamespaceProvider);
  final api = ref.watch(consentsApiProvider);
  return hasSmsReadingConsent(namespace: namespace, api: api);
});

/// Reads [smsReadingConsentProvider]. A lookup that failed (offline) is not
/// remembered as a refusal: it is asked again the next time. Granting or
/// withdrawing consent invalidates the provider, so "no" is current.
Future<bool> currentAccountHasSmsReadingConsent(Ref ref) async {
  try {
    return await ref.read(smsReadingConsentProvider.future);
  } catch (_) {
    ref.invalidate(smsReadingConsentProvider);
    return false;
  }
}
