import '../../app/providers.dart' show cacheNamespaceProvider, consentsApiProvider;
import '../../data/consent_policy.dart';
import '../../data/consents_api.dart';
import '../account/account_local_first.dart';
import '../sms_v2/sync/sharing_consent_mirror.dart';
import 'sms_reading_consent.dart';

/// WP-C11: consent writes that work without the network. [ref] is a
/// `WidgetRef` or `Ref`.
///
/// Rules:
/// * a WITHDRAWAL clears the local mirrors first, then sends or queues the
///   audit row. It never waits for the network and is never dropped; a refusal
///   (4xx) is the only thing that surfaces as an error.
/// * a GRANT may be made offline only because the caller has already shown the
///   policy text (the disclosure's own Agree button, or a toggle whose
///   explanation is on screen). The mirror is set at once and the row queued.
/// * the same purpose queued twice keeps the latest intent (grant then revoke
///   offline sends the revoke).
Future<AccountWrite> submitConsentLocalFirst(
  dynamic ref, {
  required String purpose,
  required bool granted,
  String? policyVersion,
  String? sourceScreen,
}) async {
  final api = ref.read(consentsApiProvider) as ConsentsApi?;
  if (api == null) {
    throw StateError('Sign in to change this choice.');
  }
  final namespace = ref.read(cacheNamespaceProvider) as String;
  final version =
      policyVersion ??
      (purpose == smsSharedLearningPurpose
          ? smsSharedLearningPolicyVersion
          : consentPolicyVersion);

  if (!granted) {
    // Privacy first: stop using the permission on this phone before anything
    // else can fail.
    if (purpose == smsReadingConsentPurpose) {
      await SmsReadingConsentMirror.set(namespace, false);
    }
    if (purpose == smsSharedLearningPurpose) {
      await SmsSharedLearningConsentMirror.set(namespace, false);
    }
  }

  final id = newClientId();
  final recordedAt = DateTime.now().toUtc();
  final result = await sendOrQueue(
    ref,
    kind: AccountCommand.consentSubmit,
    target: 'consent:$purpose',
    payload: {
      'purpose': purpose,
      'granted': granted,
      'policyVersion': version,
      'sourceScreen': sourceScreen,
      'clientMutationId': id,
      'clientRecordedAt': recordedAt.toIso8601String(),
    },
    live: () => api.submit(
      purpose: purpose,
      granted: granted,
      policyVersion: version,
      sourceScreen: sourceScreen,
      clientMutationId: id,
      clientRecordedAt: recordedAt,
    ),
  );

  if (granted && purpose == smsReadingConsentPurpose) {
    await SmsReadingConsentMirror.set(namespace, true);
  }
  // sms_shared_learning: the mirror is written only from a server answer (see
  // SmsSharedLearningConsentMirror), so a queued grant does not set it. Sharing
  // starts once the server has the grant.
  return result;
}

/// Handler used by the command outbox: sends the audit row exactly as queued.
Future<void> replayConsent(ConsentsApi api, Map<String, Object?> p) =>
    api.submit(
      purpose: p['purpose'] as String,
      granted: p['granted'] as bool,
      policyVersion: p['policyVersion'] as String,
      sourceScreen: p['sourceScreen'] as String?,
      clientMutationId: p['clientMutationId'] as String?,
      clientRecordedAt: DateTime.tryParse(
        p['clientRecordedAt'] as String? ?? '',
      ),
    );
