import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../data/local/sms_intake_repository.dart' show smsCaptureNamespaceKey;

import '../personal/owner_identity_store.dart';
import '../../../app/providers.dart' as app;
import '../../../data/api_request_headers_client.dart';
import '../../../data/authenticated_http_client.dart';
import '../../../app/env.dart';
import '../../../app/local_sms_rig_http_client.dart';
import '../../../app/local_sms_rig_build.dart';
import '../pipeline/sms_v2_runtime.dart';
import '../storage/outbox_store.dart';
import '../storage/schema.dart';
import '../storage/sync_state_store.dart';
import '../sync/ai_status.dart' show hasFormatWaitingForAnswer;
import 'sharing_consent_provider.dart';
import '../sync/bundle_verifier.dart';
import '../sync/rule_keys.dart';
import '../sync/attestation.dart';
import '../sync/sharing_consent_mirror.dart';

final FutureProvider<SmsV2Runtime?>
smsV2RuntimeProvider = FutureProvider<SmsV2Runtime?>((ref) async {
  final namespace = ref.watch(app.cacheNamespaceProvider);
  if (!namespace.startsWith('user:')) return null;
  var disposed = false;
  ref.onDispose(() => disposed = true);
  bool current() =>
      !disposed && ref.read(app.cacheNamespaceProvider) == namespace;
  final cache = await ref.watch(app.responseCacheProvider.future);
  final deviceId = await ref.watch(app.localDeviceIdProvider.future);
  if (!current()) return null;
  final coordinator = ref.read(app.sessionRefreshCoordinatorProvider);
  final client = AuthenticatedHttpClient(
    inner: ApiRequestHeadersClient(
      inner: localSmsRigHttpClient() ?? http.Client(),
      apiBaseUrl: Uri.parse(Env.apiBaseUrl),
    ),
    refreshAccessToken: () async {
      if (!current()) return null;
      final token = await coordinator.refresh();
      return current() ? token : null;
    },
    currentAccessToken: () =>
        current() ? ref.read(app.accessTokenProvider) : null,
  );
  ref.onDispose(client.close);
  final verifier = BundleVerifier(
    trustedKeys: {
      ...smsV2RuleKeys,
      if (LocalSmsRigBuild.enabled) 'local-rig': LocalSmsRigBuild.rulePublicKey,
    },
  );
  final attestation = DeviceAttestation(deviceId: deviceId);
  final categories = ref.watch(app.categoriesProvider).valueOrNull ?? const [];
  // The last answer the consent lookup gave, so the upload code can tell a
  // clear "withdrawn" from a lookup that merely failed.
  var lastConsent = ConsentAnswer.unknown;
  return SmsV2Runtime(
    financial: cache.financialStore,
    catalogue: ref.watch(app.catalogueProvider).valueOrNull ?? const [],
    cardRepository: ref.read(app.userCardsRepositoryProvider),
    namespace: namespace,
    client: client,
    baseUri: Uri.parse(Env.apiBaseUrl),
    deviceId: deviceId,
    appVersion: ref.watch(app.appVersionProvider).valueOrNull ?? '1.0.0',
    headers: () async {
      if (!current()) throw StateError('SMS account changed');
      final token = ref.read(app.accessTokenProvider);
      if (token == null) throw StateError('SMS session unavailable');
      final admission = await attestation.headers();
      if (!current()) throw StateError('SMS account changed');
      return {'Authorization': 'Bearer $token', ...admission};
    },
    verify: verifier.verify,
    loadShippedBundle: () =>
        rootBundle.loadString('assets/sms_rules/baseline_bundle.json'),
    accountIsCurrent: current,
    // Known offline: reading messages carries on, the network steps wait.
    isOffline: () => ref.read(app.isOnlineProvider).valueOrNull == false,
    // Who the account owner is: the profile name when it is a real name (a
    // username is ignored), the names they typed, the payees they marked and
    // the names learned from their greetings.
    ownerNames: () {
      final database = cache.financialStore.database;
      return OwnerIdentityStore(
        database.db,
        namespace: namespace,
      ).entries(profileName: database.profileDisplayName(namespace));
    },
    hasSharingConsent: () async {
      if (!current()) return false;
      // The server's answer, or its local mirror when it cannot be reached.
      lastConsent = await sharingConsentAnswer(
        namespace: namespace,
        read: () => ref.read(app.smsSharedLearningConsentProvider.future),
      );
      return current() && lastConsent == ConsentAnswer.granted;
    },
    // Erase the AI answers only when the server clearly said "withdrawn".
    consentWithdrawn: () async => lastConsent == ConsentAnswer.withdrawn,
    categoryIdBySlug: {
      for (final category in categories) category.slug: category.id,
    },
  );
});

final smsV2LifecycleProvider = Provider<void>((ref) {
  var disposed = false;
  ref.onDispose(() => disposed = true);
  // The Android background receiver has no providers: it learns which account
  // to file a message under from this preference. The v2 refactor dropped the
  // writer, so every message that arrived while the app was closed was
  // silently discarded (namespace read back as 'signed-out').
  ref.listen<String>(app.cacheNamespaceProvider, (_, next) {
    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setString(smsCaptureNamespaceKey, next))
          .catchError((_) => false),
    );
  }, fireImmediately: true);
  Future<void> run({bool reconnected = false}) async {
    if (disposed) return;
    try {
      // Catch up on anything the live receiver missed (app closed, RCS, OEM
      // quirks). Progress is row-id based, so a pass with nothing new is one
      // cheap query. Local only: never waits on the network.
      try {
        await ref.read(app.smsAutoImportProvider).captureExistingInbox();
      } catch (_) {
        // The live receiver and the next trigger still run.
      }
      final runtime = await ref.read(smsV2RuntimeProvider.future);
      // Waits set while the phone had no connection say nothing about the
      // server: when it returns, everything queued is tried at once (Q-08).
      if (!disposed && runtime != null && reconnected) {
        runtime.resetUploadBackoff();
      }
      if (!disposed && runtime != null) await runtime.sync();
    } catch (_) {
      // Local intake and the queue retain failed work for the next trigger.
    }
  }

  ref.listen(smsV2RuntimeProvider, (_, next) {
    if (next.hasValue && next.valueOrNull != null) unawaited(run());
  }, fireImmediately: true);
  ref.listen(app.isOnlineProvider, (previous, next) {
    if (previous?.valueOrNull == false && next.valueOrNull == true) {
      unawaited(run(reconnected: true));
    }
  });
  ref.listen(app.smsFlushTriggerProvider, (_, _) => unawaited(run()));
  ref.listen(app.accessTokenProvider, (_, token) {
    if (token != null) unawaited(run());
  });
  // Sharing consent just granted: send what is waiting now, not at the next resume or ordinary sync.
  ref.listen(smsSharingGrantedProvider, (previous, next) {
    if (next.valueOrNull == true && previous?.valueOrNull != true) {
      unawaited(run());
    }
  });
  // A draft takes seconds on the server, but the next ordinary sync can be minutes away. While a format this phone
  // sent in the last 10 minutes has no final answer yet, look for it every 30 seconds.
  DateTime? lastDueWake;
  final waiting = Timer.periodic(const Duration(seconds: 30), (_) async {
    if (disposed ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    try {
      final cache = await ref.read(app.responseCacheProvider.future);
      final db = cache.financialStore.database.db;
      SmsV2Schema.ensure(db);
      final state = SyncStateStore(
        db,
        namespace: ref.read(app.cacheNamespaceProvider),
      );
      // Also wake when an upload's back-off has ended. Without this a failed
      // first try (an expired token, a slow server) waited for the next app
      // resume or the 15-minute tick, so layouts reached the AI hours late.
      // At most once every 2 minutes, so a record that stays due cannot make
      // a busy server answer a full sync every 30 seconds.
      final now = DateTime.now();
      final dueWakeAllowed =
          lastDueWake == null ||
          now.difference(lastDueWake!) >= const Duration(minutes: 2);
      final dueWake =
          dueWakeAllowed &&
          OutboxStore(
            db,
            namespace: ref.read(app.cacheNamespaceProvider),
          ).hasDue(now);
      if (dueWake) lastDueWake = now;
      if (hasFormatWaitingForAnswer(state, now: now) || dueWake) {
        unawaited(run());
      }
    } catch (_) {
      // The ordinary triggers still run.
    }
  });
  ref.onDispose(waiting.cancel);
  final lifecycle = AppLifecycleListener(onResume: () => unawaited(run()));
  ref.onDispose(lifecycle.dispose);
  final timer = Timer.periodic(const Duration(minutes: 15), (_) {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      unawaited(run());
    }
  });
  ref.onDispose(timer.cancel);
});
