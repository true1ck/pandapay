import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart' as app;
import '../../../data/authenticated_http_client.dart';
import '../../../app/env.dart';
import '../flag.dart';
import '../pipeline/sms_v2_runtime.dart';
import '../sync/bundle_verifier.dart';
import '../sync/rule_keys.dart';
import '../sync/attestation.dart';

final FutureProvider<SmsV2Runtime?> smsV2RuntimeProvider =
    FutureProvider<SmsV2Runtime?>((ref) async {
      if (!ref.watch(smsPipelineV2EnabledProvider)) return null;
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
        refreshAccessToken: () async {
          if (!current()) return null;
          final token = await coordinator.refresh();
          return current() ? token : null;
        },
        currentAccessToken: () =>
            current() ? ref.read(app.accessTokenProvider) : null,
      );
      ref.onDispose(client.close);
      const localKey = String.fromEnvironment('SMS_V2_LOCAL_RULE_PUBLIC_KEY');
      final verifier = BundleVerifier(
        trustedKeys: {
          ...smsV2RuleKeys,
          if (kDebugMode && Env.isDev && localKey.isNotEmpty)
            'local-rig': localKey,
        },
      );
      final attestation = DeviceAttestation(deviceId: deviceId);
      final categories =
          ref.watch(app.categoriesProvider).valueOrNull ?? const [];
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
        hasSharingConsent: () async {
          if (!current()) return false;
          final granted = await ref.read(
            app.smsSharedLearningConsentProvider.future,
          );
          return current() && granted != null;
        },
        categoryIdBySlug: {
          for (final category in categories) category.slug: category.id,
        },
      );
    });

final smsV2LifecycleProvider = Provider<void>((ref) {
  if (!ref.watch(smsPipelineV2EnabledProvider)) return;
  var disposed = false;
  ref.onDispose(() => disposed = true);
  Future<void> run() async {
    if (disposed) return;
    try {
      final runtime = await ref.read(smsV2RuntimeProvider.future);
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
      unawaited(run());
    }
  });
  ref.listen(app.smsFlushTriggerProvider, (_, _) => unawaited(run()));
  ref.listen(app.accessTokenProvider, (_, token) {
    if (token != null) unawaited(run());
  });
  final lifecycle = AppLifecycleListener(onResume: () => unawaited(run()));
  ref.onDispose(lifecycle.dispose);
  final timer = Timer.periodic(const Duration(minutes: 15), (_) {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      unawaited(run());
    }
  });
  ref.onDispose(timer.cancel);
});
