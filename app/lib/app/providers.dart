import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/acceptance_reports_repository.dart';
import '../data/analytics.dart';
import '../data/app_status_repository.dart';
import '../data/api_exception.dart';
import '../data/auth_api.dart';
import '../data/product_access_api.dart';
import '../data/authenticated_http_client.dart';
import '../data/card_bill_ledger.dart';
import '../data/card_feedback_repository.dart';
import '../data/card_overrides_repository.dart';
import '../data/card_requests_api.dart';
import '../data/catalogue_repository.dart';
import '../data/commitments_repository.dart';
import '../data/consents_api.dart';
import '../data/device_identity.dart';
import '../data/device_metadata.dart';
import '../data/devices_api.dart';
import '../data/emergency_contacts_repository.dart';
import '../data/import_repository.dart';
import '../data/local/app_database.dart';
import '../data/local/response_cache.dart';
import '../data/local/financial_store.dart';
import '../data/local/auto_resolved_history_repository.dart';
import '../data/local/sms_auto_resolution_controller.dart';
import '../data/local/sms_rule_bundle.dart';
import '../data/local/sms_rule_bundle_store.dart';
import '../data/local/sms_facts_outbox.dart';
import '../data/local/sms_dismissal_outbox.dart';
import '../data/local/sms_rule_exposure_outbox.dart';
import '../data/local/sms_intake_repository.dart';
import '../data/local/sms_import_store.dart';
import '../data/local_sms_parser.dart';
import '../data/local/sync_queue.dart';
import '../data/local/duplicate_resolution_outbox.dart';
import '../data/local/transaction_outbox_repository.dart';
import '../data/local/transaction_attachments_repository.dart';
import '../data/local_user_cards_repository.dart';
import '../data/merchant_category_rules_repository.dart';
import '../data/merchant_issue_rules_repository.dart';
import '../data/merchant_search_repository.dart';
import '../data/needs_review_repository.dart';
import '../data/notification_preferences_repository.dart';
import '../data/notification_devices_api.dart';
import '../data/override_resolver.dart';
import '../data/partner_apply_repository.dart';
import '../data/pending_bills.dart';
import '../data/past_bill_receipts.dart';
import '../data/premium_reminders.dart';
import '../data/recovery_api.dart';
import '../data/referral_repository.dart';
import '../data/spend_by_category_repository.dart';
import '../data/spend_reports_repository.dart';
import '../data/spending_selection.dart';
import '../data/subscription_credits_repository.dart';
import '../data/sync_api.dart';
import '../data/token_store.dart';
import '../data/upi_payment_service.dart';
import '../data/user_cards_repository.dart';
import '../data/user_categories_repository.dart';
import '../data/transaction_tags_repository.dart';
import '../data/user_settings_api.dart';
import '../features/geofence/geofence_monitor_service.dart';
import '../features/geofence/background_alerts_controller.dart';
import '../features/geofence/nearby_merchants_repository.dart';
import '../features/home_widget/home_widget_service.dart';
import '../features/notifications/notification_gate.dart';
import '../features/notifications/notification_triggers.dart';
import '../features/notifications/push_notification_service.dart';
import '../features/sms_import/sms_listener_service.dart';
import '../features/sms_import/sms_inbox_scanner.dart';
import '../features/sms_import/sms_capture_worker.dart';
import '../features/sms_import/sms_background_queue.dart';
import '../features/sms_import/sms_text_hint.dart';
import '../features/settings/settings_sync.dart';
import '../features/sync/sync_engine.dart';
import 'env.dart';

/// api/'s and auth/'s base URLs, fixed at compile time by `--dart-define`
/// (plan Phase 0.3). These were plain hardcoded `localhost` consts until
/// `env.dart` was added — see that file for the build flags and for why a
/// release build compiled without them throws on startup instead of silently
/// trying to reach the handset itself.
const _apiBaseUrl = Env.apiBaseUrl;
const _authBaseUrl = Env.authBaseUrl;

/// A bank can send several messages that contain transaction-shaped words but
/// do not represent money spent: OTPs, declines, reversals, refunds and
/// credits. Those are expected negative matches, not parser failures, so they
/// must never become a user-facing review item. Successful formats are
/// recorded by the server as transactions; card attribution is optional.
bool _isIgnorableSmsReason(String? reason) {
  final normalized = (reason ?? '').trim().toLowerCase();
  return normalized == 'security_message' ||
      normalized == 'not_a_successful_spend' ||
      normalized == 'non_transaction_message' ||
      normalized == 'not_a_transaction_alert' ||
      normalized == 'non_transaction_alert';
}

/// Determines whether an error during startup review replay is fatal to the pass.
/// Server refusals on specific messages (4xx) should skip that message and continue,
/// while transport/server failures (5xx, network drops) stop the pass for retry later.
bool reviewReplayShouldStop(Object error) {
  if (error is ApiException) {
    final status = error.statusCode;
    if (status != null && status >= 400 && status < 500) {
      return false;
    }
    return true;
  }
  return true;
}

/// Determines whether an error from the AI queue represents an explicit, permanent refusal
/// (such as HTTP 400 or HTTP 503 ai_queue_disabled), as opposed to a transient or network error.
bool _isExplicitAiRefusal(Object error) {
  if (error is ApiException) {
    final status = error.statusCode;
    return status == 400 || status == 409 || status == 429 || status == 503;
  }
  final message = error.toString().toLowerCase();
  if (message.contains('ai_queue_disabled') ||
      message.contains('status: 400') ||
      message.contains('400 bad request')) {
    return true;
  }
  return false;
}

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(authBaseUrl: _authBaseUrl),
);

/// One shared retrying client for all authenticated repositories. Keeping the
/// refresh coordination here prevents a screen with several report requests
/// from firing several refresh-token rotations at once after resume.
final authenticatedHttpClientProvider = Provider<AuthenticatedHttpClient>((
  ref,
) {
  final refreshCoordinator = ref.read(sessionRefreshCoordinatorProvider);
  final client = AuthenticatedHttpClient(
    refreshAccessToken: () async {
      return refreshCoordinator.refresh();
    },
    currentAccessToken: () => ref.read(accessTokenProvider),
    onSuccessfulMutation: (request) {
      if (RegExp(
        r'/(?:transactions|user-cards|budgets|card-overrides|duplicate-candidates|sync/push)(?:/|$)',
      ).hasMatch(request.url.path)) {
        ref
            .read(responseCacheProvider)
            .valueOrNull
            ?.markAccountStale(ref.read(cacheNamespaceProvider));
      }
    },
    refreshAccessTokenForToken: (rejectedAccessToken) =>
        refreshCoordinator.refresh(expectedAccessToken: rejectedAccessToken),
  );
  ref.onDispose(client.close);
  return client;
});

final tokenStoreProvider = FutureProvider<TokenStore>(
  (ref) => TokenStore.load(),
);

/// This install's stable device identifier — see device_identity.dart's
/// own doc-comment for why this exists (every install used to send the
/// same literal `'app-mobile'` string, so there was nothing real to
/// generate/persist/compare here before).
final localDeviceIdProvider = FutureProvider<String>(
  (ref) => DeviceIdentity().localDeviceId(),
);

/// Device description sent alongside the install ID when an OTP is verified.
final deviceMetadataProvider = FutureProvider<Map<String, Object?>>(
  (ref) => loadDeviceMetadata(),
);

/// The signed-in access token, or null when signed out. Seeded on startup
/// by sessionInitProvider from a stored refresh token; login_screen.dart
/// persists both tokens on a fresh OTP sign-in.
final accessTokenProvider = StateProvider<String?>((ref) => null);

/// The signed-in account's server-verified product-access namespace. It is
/// intentionally session-memory only: after a cold start the access API is
/// checked again before incomplete onboarding can proceed.
final activationVerifiedNamespaceProvider = StateProvider<String?>(
  (ref) => null,
);

/// All refresh entry points in the app share this coordinator.  The auth
/// service rotates refresh tokens as one-time credentials; separate locks in
/// the HTTP client and lifecycle keep-alive can otherwise race after resume,
/// make the server see the same token twice, and revoke the whole device
/// family.  A single in-flight future also means a burst of 401s produces one
/// refresh request and all callers reuse its result.
final sessionRefreshCoordinatorProvider = Provider<SessionRefreshCoordinator>(
  (ref) => SessionRefreshCoordinator(
    loadStore: () => ref.read(tokenStoreProvider.future),
    authApi: ref.read(authApiProvider),
    readAccessToken: () => ref.read(accessTokenProvider),
    writeAccessToken: (token) =>
        ref.read(accessTokenProvider.notifier).state = token,
  ),
);

/// Namespaces persisted response snapshots by account. The SQLite file is
/// shared by the install, so a logout followed by another login must never
/// allow the second account to read the first account's cards, transactions,
/// or Insights report while offline.
final cacheNamespaceProvider = Provider<String>((ref) {
  // Token rotation must not look like an account change. `select` compares
  // the derived namespace, so the router and authenticated repositories stay
  // alive while the access token is refreshed underneath them.
  return ref.watch(
    accessTokenProvider.select((token) => _cacheNamespaceForToken(token)),
  );
});

String _cacheNamespaceForToken(String? token) {
  if (token == null) return 'signed-out';
  final subject = _jwtSubject(token);
  if (subject != null && subject.isNotEmpty) return 'user:$subject';
  return 'session:${sha256.convert(utf8.encode(token)).toString()}';
}

/// Reads the current token without making every authenticated repository
/// rebuild when a healthy session rotates its access token. The namespace
/// still changes on login/logout, so account boundaries remain reactive.
String? _stableSessionToken(Ref ref) {
  ref.watch(cacheNamespaceProvider);
  return ref.read(accessTokenProvider);
}

/// Whether this app PROCESS has already passed biometric_lock_screen.dart's
/// challenge. Deliberately plain in-memory state, never persisted — a
/// fresh cold start must always re-lock when the toggle
/// (account_settings_screen.dart's biometricLockProvider) is on, matching
/// its own copy: "Require Face/Touch ID to open the app," not "...once per
/// install."
final biometricUnlockedProvider = StateProvider<bool>((ref) => false);

final profileApiProvider = Provider<ProfileApi?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return ProfileApi(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

final productAccessApiProvider = Provider<ProductAccessRepository?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return ProductAccessApi(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

final pendingInvitationStoreProvider = FutureProvider<PendingInvitationStore>(
  (ref) async => PendingInvitationStore(),
);

final pendingSignupChoicesStoreProvider =
    FutureProvider<PendingSignupChoicesStore>(
      (ref) async => PendingSignupChoicesStore(),
    );

/// A8/C8 Request Unsupported Card. Same null-when-signed-out shape as every
/// other repository provider in this file.
final cardRequestsApiProvider = Provider<CardRequestsApi?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return CardRequestsApi(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

/// A4/H4 consent writes (DPDP §8.2). Same null-when-signed-out shape as
/// every other repository provider in this file.
final consentsApiProvider = Provider<ConsentsApi?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return ConsentsApi(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

/// Plan Phase 2.3 — attributed outbound "Apply" links. Null when signed out:
/// a click has to belong to a profile for the attribution to mean anything.
final partnerApplyRepositoryProvider = Provider<PartnerApplyRepository?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return PartnerApplyRepository(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

/// New-card-acquisition recommender's data input. Null when signed out: a
/// guest has no server-side transaction history to project a spend pattern
/// from, same reasoning as every other repository provider in this file.
final spendByCategoryRepositoryProvider = Provider<SpendByCategoryRepository?>((
  ref,
) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return SpendByCategoryRepository(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

/// Trailing-12-month category totals — empty (not an error) when signed
/// out, same convention as userCardsProvider: a guest simply has no
/// history to project from, so "nothing worth recommending yet" is the
/// correct, unsurprising result rather than a screen-blocking error.
final categorySpendProvider = FutureProvider<List<CategorySpend>>((ref) async {
  final repo = ref.watch(spendByCategoryRepositoryProvider);
  if (repo == null) return const [];
  final cache = await _cacheOrNull(ref);
  final key = _scopedCacheKey(ref, 'category_spend:12');
  final cached = await _readCacheOrNull(ref, cache, key);
  List<CategorySpend> decode(CachedResponse snapshot) =>
      ((jsonDecode(snapshot.rawJson) as Map<String, dynamic>)['categories']
              as List)
          .cast<Map<String, dynamic>>()
          .map(CategorySpend.fromJson)
          .toList();

  if (cached != null) {
    try {
      final saved = decode(cached);
      _warmDisplay(
        ref,
        cache,
        key,
        cached.fetchedAt,
        () => repo.fetchSpendByCategory(months: 12),
        (rows) => {'categories': rows.map((r) => r.toJson()).toList()},
      );
      return saved;
    } catch (_) {
      await cache?.clear(key);
    }
  }

  try {
    final rows = await repo.fetchSpendByCategory(months: 12);
    try {
      await cache?.put(
        key,
        jsonEncode({'categories': rows.map((row) => row.toJson()).toList()}),
      );
    } catch (_) {}
    return rows;
  } catch (error) {
    if (!_canUseReadCache(error) || cached == null) {
      // Recommendations are a read-only display surface. If the session is
      // being recovered and this is the first uncached request, an empty
      // spend profile is still a valid input for the catalogue recommender;
      // surfacing the auth transport error would blank the whole page.
      if (_isAuthenticationFailure(error)) {
        return const [];
      }
      rethrow;
    }
    try {
      return decode(cached);
    } catch (_) {
      await cache?.clear(key);
      rethrow;
    }
  }
});

final acquisitionRecommenderProvider = Provider<CardAcquisitionRecommender>((
  ref,
) {
  return const CardAcquisitionRecommender();
});

/// Which cards NOT already in the wallet would be worth acquiring, given
/// the signed-in user's real trailing-12-month spend —
/// packages/pandapay_domain's CardAcquisitionRecommender applied to live
/// catalogue + spend data, mirroring rankedRecommendationsProvider's own
/// combine-multiple-providers shape below. Candidates are the WHOLE
/// catalogue, not pre-filtered to non-owned here — the recommender itself
/// already excludes owned cards (see its own rank()), so this stays
/// consistent with the one place that filtering logic is meant to live.
final acquisitionCandidatesProvider =
    Provider<AsyncValue<List<AcquisitionCandidate>>>((ref) {
      final catalogue = ref.watch(catalogueProvider);
      final userCards = ref.watch(userCardsProvider);
      final categorySpend = ref.watch(categorySpendProvider);
      final recommender = ref.watch(acquisitionRecommenderProvider);
      final categories = ref.watch(categoriesProvider);

      if (catalogue.isLoading ||
          userCards.isLoading ||
          categorySpend.isLoading ||
          categories.isLoading) {
        return const AsyncValue.loading();
      }
      final combinedError =
          catalogue.error ??
          userCards.error ??
          categorySpend.error ??
          categories.error;
      if (combinedError != null) {
        return AsyncValue.error(
          combinedError,
          catalogue.stackTrace ??
              userCards.stackTrace ??
              categorySpend.stackTrace ??
              categories.stackTrace!,
        );
      }

      final allCards = catalogue.requireValue;
      final wallet = userCards.requireValue;
      final spend = categorySpend.requireValue;
      final categoryList = categories.requireValue;

      final ownedProducts = allCards
          .where((c) => wallet.any((w) => w.cardProductId == c.id))
          .toList();

      final hasRealSpend = spend.any((s) => s.totalSpend > const Money.zero());
      final SpendProfile profile;
      if (hasRealSpend) {
        profile = SpendProfile(
          annualSpendByCategory: {
            for (final s in spend) s.categoryId: s.totalSpend,
          },
        );
      } else {
        final slugToId = {for (final c in categoryList) c.slug: c.id};
        profile = SpendProfile.starter(categorySlugToIdMap: slugToId);
      }

      final results = recommender.rank(
        candidates: allCards,
        ownedCards: ownedProducts,
        spendProfile: profile,
        // Never suggest applying for a card on the strength of a promo rate
        // that has already expired — the user would apply and never see it.
        now: ref.watch(clockProvider).now(),
      );
      return AsyncValue.data(results);
    });

/// Plan Phase 2.1 — acceptance reports ("did this card work here?"). Null
/// when signed out: a guest has no profile for the server-side opt-in check
/// to consult, and `submit_acceptance_report()` refuses without one.
final acceptanceReportsRepositoryProvider =
    Provider<AcceptanceReportsRepository?>((ref) {
      final token = _stableSessionToken(ref);
      if (token == null) return null;
      return AcceptanceReportsRepository(
        apiBaseUrl: _apiBaseUrl,
        accessToken: token,
        client: ref.read(authenticatedHttpClientProvider),
      );
    });

/// Scan-to-pay targeted UPI-app handoff (RuPay-on-UPI plan, Phase 1).
/// Overridden with a fake in widget tests — the real one talks to a
/// MethodChannel that isn't registered in the test harness.
final upiPaymentServiceProvider = Provider<UpiPaymentService>(
  (ref) => MethodChannelUpiPaymentService(),
);

/// Plan Phase 2.2 — product analytics. Deliberately NOT null when signed out:
/// the activation funnel's most important steps (app opened, onboarding
/// started/completed) happen before an account exists, and an analytics client
/// that only works once you're signed in cannot measure activation at all.
/// The token is read lazily at flush time, so events queued while signed out
/// go up unattributed and events after sign-in are attributed.
final analyticsProvider = Provider<Analytics>((ref) {
  final analytics = Analytics(
    apiBaseUrl: _apiBaseUrl,
    tokenReader: () => ref.read(accessTokenProvider),
    appVersion: ref.watch(appVersionProvider).valueOrNull,
  );
  ref.onDispose(analytics.dispose);
  return analytics;
});

/// Fires `app_opened` exactly once per process, and flushes whatever is
/// buffered when the session ends.
///
/// A `Provider` read once from `_AppShell` rather than a call in `main()`:
/// `main()` runs before the ProviderScope exists, and putting it in the
/// shell's `build` would count every tab switch as an app open — which would
/// make the top of the funnel meaningless and every downstream conversion
/// rate wrong in the flattering direction.
final analyticsLifecycleProvider = Provider<void>((ref) {
  final analytics = ref.read(analyticsProvider);
  analytics.track(AnalyticsEvent.appOpened);

  // Flush when the app goes to the background rather than on a repeating
  // timer. This is both cheaper (no wakeups while the user is mid-task) and
  // more reliable: backgrounding is the last moment guaranteed to happen
  // before the OS may kill the process, so it is the point at which buffered
  // events would otherwise be lost. `AppLifecycleListener` schedules nothing,
  // which also keeps widget tests free of pending timers.
  final listener = AppLifecycleListener(
    onPause: analytics.flush,
    onDetach: analytics.flush,
  );
  ref.onDispose(listener.dispose);

  ref.listen<String>(cacheNamespaceProvider, (previous, next) {
    // Flush on sign-out too, so events buffered before it aren't attributed
    // to whoever signs in next on the same device.
    if (previous != 'signed-out' && next == 'signed-out') {
      analytics.flush();
    }
  });
});

/// Plan Phase 4 — multi-device sync transport and local change queue.
final syncApiProvider = Provider<SyncApi?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return SyncApi(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

final syncQueueProvider = FutureProvider<SyncQueue>((ref) async {
  final namespace = ref.watch(cacheNamespaceProvider);
  final cache = await ref.watch(responseCacheProvider.future);
  return SyncQueue(
    cache.financialStore.database,
    namespace: namespace,
    onChanged: () => cache.financialStore.notifyPendingChange(namespace),
  );
});

/// Local edits not yet accepted by the server. Distinct from
/// [pendingOutboxCountProvider], which counts queued server mutations such as
/// B6 quick-adds and duplicate-review resolutions.
final pendingSyncCountProvider = FutureProvider<int>((ref) async {
  ref.watch(financialStoreRevisionProvider('transactions'));
  return (await ref.watch(syncQueueProvider.future)).pendingCount;
});

final pendingRecoveryStatusProvider = FutureProvider<Map<String, int>>((
  ref,
) async {
  ref.watch(financialStoreRevisionProvider('transactions'));
  final namespace = ref.watch(cacheNamespaceProvider);
  final cache = await ref.watch(responseCacheProvider.future);
  final db = cache.financialStore.database;
  int count(String table, String where, List<Object?> args) =>
      db.db
              .select('SELECT COUNT(*) AS n FROM $table WHERE $where', args)
              .single['n']
          as int;
  return {
    'sms': count('sms_intake', 'namespace=?', [namespace]),
    'blocked':
        count('sync_pending_changes', 'namespace=? AND attempts>=5', [
          namespace,
        ]) +
        count('duplicate_resolution_outbox', 'namespace=? AND attempts>=5', [
          namespace,
        ]),
    'legacy':
        count('sync_pending_changes', "namespace='legacy'", []) +
        count('transaction_outbox_entries', "namespace='legacy'", []) +
        count('duplicate_resolution_outbox', "namespace='legacy'", []) +
        count('sms_intake', "namespace='legacy'", []) +
        count('local_needs_review', "namespace='legacy'", []),
  };
});

Future<void> recoverLegacyPendingChanges(WidgetRef ref) async {
  final namespace = ref.read(cacheNamespaceProvider);
  if (namespace == 'signed-out') return;
  final cache = await ref.read(responseCacheProvider.future);
  final db = cache.financialStore.database.db;
  final intake = SmsIntakeRepository(cache.financialStore.database);
  db.execute('SAVEPOINT recover_pending');
  try {
    for (final table in [
      'sync_pending_changes',
      'transaction_outbox_entries',
      'duplicate_resolution_outbox',
      'local_needs_review',
    ]) {
      db.execute("UPDATE $table SET namespace=? WHERE namespace='legacy'", [
        namespace,
      ]);
    }
    for (final entry in intake.pending('legacy', limit: 100000)) {
      final bundle = SmsRuleBundleStore(cache.financialStore.database)
          .loadActiveBundleSync(
            clientVersion: ref.read(appVersionProvider).valueOrNull ?? '1.0.0',
          );
      SmsImportStore(
        cache.financialStore,
        downloadedRules: bundle,
        candidateRules: SmsRuleBundleStore(cache.financialStore.database)
            .loadCandidateBundlesSync(
              clientVersion:
                  ref.read(appVersionProvider).valueOrNull ?? '1.0.0',
              namespace: namespace,
            ),
      ).capture(namespace, entry.message);
      intake.acknowledge('legacy', entry.id);
    }
    db.execute('RELEASE SAVEPOINT recover_pending');
  } catch (_) {
    db.execute('ROLLBACK TO SAVEPOINT recover_pending');
    db.execute('RELEASE SAVEPOINT recover_pending');
    rethrow;
  }
  cache.financialStore.notifyPendingChange(namespace);
  ref.invalidate(pendingRecoveryStatusProvider);
  ref.invalidate(pendingOutboxCountProvider);
  ref.invalidate(pendingSyncCountProvider);
}

/// Plan Phase 1.3 — whether this account has a second way in. Points at
/// `authBaseUrl`: `users.is_email_verified` is the auth service's column.
final recoveryApiProvider = Provider<RecoveryApi?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return RecoveryApi(
    authBaseUrl: _authBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

final recoveryStatusProvider = FutureProvider.autoDispose<RecoveryStatus?>((
  ref,
) async {
  final api = ref.watch(recoveryApiProvider);
  if (api == null) return null;
  try {
    return await api.fetchStatus();
  } catch (error) {
    if (isAuthenticationFailure(error)) return null;
    rethrow;
  }
});

/// Plan Phase 1.4 — linked-device management. Points at `authBaseUrl`, not
/// `apiBaseUrl`: `user_devices` is the auth service's own table.
final devicesApiProvider = Provider<DevicesApi?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return DevicesApi(
    authBaseUrl: _authBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

/// Plan Phase 1.1 — account-level preference sync (migration 0028). Same
/// null-when-signed-out shape as every other repository provider here, which
/// is also what makes `SettingsSync` a no-op for a guest: there is no account
/// for their preferences to follow, so they stay device-local.
final userSettingsApiProvider = Provider<UserSettingsApi?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return UserSettingsApi(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

/// Same pattern as console/lib/app/providers.dart's sessionInitProvider:
/// resolve a stored refresh token through auth/'s real POST /auth/refresh
/// on startup. Refresh failures preserve the cached session. A failed refresh
/// is not the same thing as an explicit sign-out: the auth service can reject
/// a rotated/stale token after a process restart, deployment, database restore,
/// or temporary device/network condition. Clearing secure credentials here
/// would turn that recoverable state into the "Welcome back" screen and make
/// the account-scoped offline cache inaccessible.
String? _jwtSubject(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final payload =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
            as Map<String, dynamic>;
    return payload['sub'] as String?;
  } catch (_) {
    return null;
  }
}

class SessionRefreshCoordinator {
  final Future<TokenStore> Function() loadStore;
  final AuthApi authApi;
  final String? Function() readAccessToken;
  final void Function(String?) writeAccessToken;

  Future<String?>? _refreshInProgress;

  SessionRefreshCoordinator({
    required this.loadStore,
    required this.authApi,
    required this.readAccessToken,
    required this.writeAccessToken,
  });

  Future<String?> refresh({String? expectedAccessToken}) {
    final current = readAccessToken();
    // A different refresh path already won. The request that received a 401
    // can safely retry with the winning token and must not rotate again.
    if (expectedAccessToken != null &&
        current != null &&
        current != expectedAccessToken) {
      return Future<String?>.value(current);
    }

    final active = _refreshInProgress;
    if (active != null) return active;

    final future = _refresh(expectedAccessToken: expectedAccessToken);
    _refreshInProgress = future;
    return future.whenComplete(() {
      if (identical(_refreshInProgress, future)) {
        _refreshInProgress = null;
      }
    });
  }

  Future<String?> _refresh({String? expectedAccessToken}) async {
    final store = await loadStore();
    final refreshToken = store.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      return readAccessToken();
    }
    final accessTokenBeforeRefresh = readAccessToken();

    try {
      // Reuse a durable request identity after a lost response/process death.
      // The server returns the same still-active successor for this request.
      final requestId = await store.refreshRequestId(refreshToken);
      final tokens = await authApi.refresh(refreshToken, requestId: requestId);
      // A fresh login or another coordinator invocation may have won while
      // the network request was in flight. Never overwrite that session.
      if (readAccessToken() != accessTokenBeforeRefresh ||
          store.refreshToken != refreshToken) {
        return readAccessToken();
      }
      await store.save(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      writeAccessToken(tokens.accessToken);
      debugPrint('PandaPay session refresh completed.');
      return tokens.accessToken;
    } catch (error) {
      if (error is ApiException && error.statusCode == 401) {
        // A newer OTP sign-in may have replaced this session while the
        // rejected refresh request was in flight. Never clear that winner.
        final currentAccessToken = readAccessToken();
        if (currentAccessToken != accessTokenBeforeRefresh ||
            store.refreshToken != refreshToken) {
          return currentAccessToken;
        }
        // A 401 from /auth/refresh is a definitive rejection of this
        // credential, not a transient outage. Keeping it made the app appear
        // signed in while every later profile read fell back to "Your
        // account". Clear only the unusable tokens; account-scoped local data
        // stays in SQLite and becomes available again after the same user
        // signs in.
        try {
          await store.clear();
        } catch (_) {
          // Do not keep publishing a credential the server has rejected if
          // secure-storage cleanup itself is temporarily unavailable.
        }
        writeAccessToken(null);
        debugPrint('PandaPay session refresh rejected; sign-in is required.');
        return null;
      }
      // Keep credentials and account-scoped data intact. Record only a coarse
      // reason for device diagnostics; never log either token or response body.
      final reason = error is ApiException
          ? 'http_${error.statusCode ?? 'unknown'}'
          : error.runtimeType.toString();
      debugPrint('PandaPay session refresh unavailable: $reason');
      // Non-authentication failures can be temporary, so preserve the
      // current session and account-scoped cache for a later retry. Never log
      // either token or the response body.
      return null;
    }
  }
}

final sessionInitProvider = FutureProvider<void>((ref) async {
  // Restore the locally persisted access token before doing any network work.
  // The old startup path waited for /auth/refresh here, which made a healthy
  // install sit on the splash for several seconds whenever auth/ was slow.
  // A refresh is still started immediately below, but Home can now render
  // from its local snapshot while it runs.
  late final TokenStore store;
  try {
    store = await ref.watch(tokenStoreProvider.future);
  } catch (_) {
    // Keystore/platform failures are not proof that the account is signed
    // out. The router can show the account gate, while a later explicit login
    // can recreate the secure-store entry.
    return;
  }
  final refreshToken = store.refreshToken;
  final storedAccessToken = store.accessToken;
  if (storedAccessToken != null) {
    ref.read(accessTokenProvider.notifier).state = storedAccessToken;
  }
  if (refreshToken == null) {
    // A legacy/partially-written session may contain only an access token.
    // Keep it available for the normal offline-cache path; there is no
    // refresh request we can make until the user signs in again.
    return;
  }

  // Do not make routing wait on the hosted auth service. The coordinator
  // shares this request with any API call that receives a 401, preserves the
  // stored session for every refresh outcome. This keeps app startup usable
  // from the local cache even when auth/ is unavailable or rejects a stale
  // rotating credential.
  unawaited(
    ref
        .read(sessionRefreshCoordinatorProvider)
        .refresh()
        .then<void>((_) {}, onError: (_, _) {}),
  );
});

/// Keeps a signed-in session alive for as long as the app stays open, not
/// just at startup. sessionInitProvider above only ever calls /auth/refresh
/// once, when the app launches; auth/'s access tokens expire after
/// JWT_ACCESS_TTL (15 minutes by default), so without this, anyone who kept
/// the app open past that window would silently start getting 401s on
/// every API call while accessTokenProvider still held the now-dead token
/// — "signed in" on screen, broken underneath. This re-reads the CURRENT
/// refresh token from storage (not a captured value) every 10 minutes,
/// comfortably inside the 15-minute TTL. Refresh failures leave the current
/// session intact; only explicit user sign-out clears credentials and returns
/// the user to login.
/// Read once from `_AppShell` in main.dart so it runs for the app's whole
/// lifetime regardless of which tab is showing.
/// How often to proactively rotate the access token. Must stay comfortably
/// below auth/'s JWT_ACCESS_TTL (15m by default) — overridable so tests can
/// drive the timer without waiting in real time.
final sessionRefreshIntervalProvider = Provider<Duration>(
  (ref) => const Duration(minutes: 5),
);

final sessionKeepAliveProvider = Provider<void>((ref) {
  Timer? timer;

  Future<void> tick() async {
    final currentToken = ref.read(accessTokenProvider);
    if (currentToken == null) {
      return; // avoid rotating one-time tokens concurrently
    }
    await ref
        .read(sessionRefreshCoordinatorProvider)
        .refresh(expectedAccessToken: currentToken);
  }

  ref.listen<String>(cacheNamespaceProvider, (previous, next) {
    timer?.cancel();
    if (next != 'signed-out') {
      timer = Timer.periodic(
        ref.read(sessionRefreshIntervalProvider),
        (_) => unawaited(tick()),
      );
    }
  }, fireImmediately: true);

  final lifecycle = AppLifecycleListener(
    // Android may pause Dart timers while the process is backgrounded. Refresh
    // immediately on resume instead of waiting for the next five-minute tick.
    onResume: () => unawaited(tick()),
  );
  ref.onDispose(() {
    timer?.cancel();
    lifecycle.dispose();
  });
});

/// Tasks 4-6: whether the first-run onboarding flow (Welcome -> Account
/// Choice -> optional sign-up/sign-in -> Tutorial) has ever been completed
/// on this device. Persisted directly via SharedPreferences (not through
/// TokenStore — this has nothing to do with auth; it must stay `true` even
/// after a sign-out, per ui-spec.md A3's "no nagging later" principle:
/// finishing onboarding once and later signing out must never show the
/// welcome flow again).
const _onboardingCompleteKey = 'pandapay_app.onboarding_complete_v1';

final onboardingCompleteProvider =
    StateNotifierProvider<OnboardingController, AsyncValue<bool>>(
      OnboardingController.new,
    );

class OnboardingController extends StateNotifier<AsyncValue<bool>> {
  final Ref _ref;
  OnboardingController(this._ref) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = AsyncValue.data(prefs.getBool(_onboardingCompleteKey) ?? false);
  }

  Future<void> complete() async {
    final api = _ref.read(productAccessApiProvider);
    if (api == null) {
      throw StateError('Sign in to finish account setup.');
    }
    // The local routing flag must never claim completion until the server has
    // persisted it. A failed request leaves the local flag false and safely
    // permits the user to retry from the final setup screen.
    try {
      await api.completeOnboarding();
    } catch (error) {
      if (error is ApiException &&
          (error.errorCode == 'required_terms_missing' ||
              error.userMessage.contains('required_terms_missing') ||
              error.debugMessage.contains('required_terms_missing'))) {
        final consents = _ref.read(consentsApiProvider);
        if (consents != null) {
          try {
            await consents.submit(
              purpose: 'terms',
              granted: true,
              policyVersion: appProductTermsVersion,
              sourceScreen: 'onboarding_complete',
            );
            await api.completeOnboarding();
          } catch (_) {
            Error.throwWithStackTrace(error, StackTrace.current);
          }
        } else {
          rethrow;
        }
      } else {
        rethrow;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingCompleteKey, true);
    state = const AsyncValue.data(true);
    // Plan Phase 1.1: the highest-value key in the sync registry. Without
    // it, an existing user signing in on a second device is sent back
    // through Welcome and direct auth as though they were brand new.
    _ref.read(settingsSyncProvider).pushKeyQuietly(_onboardingCompleteKey);
    // Plan Phase 2.2: the activation funnel's first measurable completion.
    _ref.read(analyticsProvider).track(AnalyticsEvent.onboardingCompleted);
  }

  /// Settings' "Replay tutorial" (Task 21) hook — lets a user re-see the
  /// coach marks without losing anything else, never a way to re-trigger
  /// account choice or sign-up.
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingCompleteKey, false);
    state = const AsyncValue.data(false);
    _ref.read(settingsSyncProvider).pushKeyQuietly(_onboardingCompleteKey);
  }
}

/// Task 5 (ui-spec.md A11): whether the first-run coach-mark tutorial has
/// been seen. Deliberately a SEPARATE flag from onboardingCompleteProvider
/// above, not a reuse of it — Settings' future "Replay tutorial" (Task 21)
/// must reset only the coach marks, never send a returning user back
/// through Welcome/direct auth.
const _tutorialSeenKey = 'pandapay_app.tutorial_seen_v1';

final tutorialSeenProvider =
    StateNotifierProvider<TutorialController, AsyncValue<bool>>(
      TutorialController.new,
    );

class TutorialController extends StateNotifier<AsyncValue<bool>> {
  final Ref _ref;
  TutorialController(this._ref) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = AsyncValue.data(prefs.getBool(_tutorialSeenKey) ?? false);
  }

  Future<void> complete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_tutorialSeenKey, true);
    state = const AsyncValue.data(true);
    _ref.read(settingsSyncProvider).pushKeyQuietly(_tutorialSeenKey);
  }

  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_tutorialSeenKey, false);
    state = const AsyncValue.data(false);
    _ref.read(settingsSyncProvider).pushKeyQuietly(_tutorialSeenKey);
  }
}

/// Task E8 (Due Date Calendar) reminder toggles. Per the plan's own
/// scoping note: no server-side storage exists for "remind me about card
/// X's due date" (no column, no table), and the spec doesn't require
/// cross-device sync of this preference — scoped to a local-only toggle,
/// same on-device SharedPreferences mechanism onboardingCompleteProvider
/// above already uses, rather than inventing a new `user_card_reminders`
/// table with no ui-spec mandate. Actual notification delivery is H3's
/// territory (out of scope here) — this only owns the on/off state.
const _dueDateRemindersKey = 'pandapay_app.due_date_reminders_v1';

final dueDateRemindersProvider =
    StateNotifierProvider<DueDateRemindersController, Set<String>>(
      DueDateRemindersController.new,
    );

class DueDateRemindersController extends StateNotifier<Set<String>> {
  final Ref _ref;
  DueDateRemindersController(this._ref) : super(const {}) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = (prefs.getStringList(_dueDateRemindersKey) ?? const []).toSet();
  }

  Future<void> toggle(String userCardId) async {
    final prefs = await SharedPreferences.getInstance();
    final next = Set<String>.from(state);
    if (next.contains(userCardId)) {
      next.remove(userCardId);
    } else {
      next.add(userCardId);
    }
    state = next;
    await prefs.setStringList(_dueDateRemindersKey, next.toList());
    _ref.read(settingsSyncProvider).pushKeyQuietly(_dueDateRemindersKey);
  }
}

/// Task D-4: on-device only, never uploaded — see NeedsReviewRepository's
/// own doc-comment for why. Repository writes feed the existing financial
/// revision stream, keeping the cheap badge count and reconciled list current.
final _reviewFinancialChangesProvider = FutureProvider<void>((ref) async {
  StreamSubscription<FinancialChange>? subscription;
  var disposed = false;
  ref.onDispose(() {
    disposed = true;
    subscription?.cancel();
  });
  final cache = await _cacheOrNull(ref);
  if (disposed || cache == null) return;
  final store = cache.financialStore;
  subscription = NeedsReviewRepository.changesFor(store.database).listen(
    (change) => store.notifyExternalChanges(change.namespace, [change.entity]),
  );
});

final needsReviewRepositoryProvider = Provider<NeedsReviewRepository>((ref) {
  final namespace = ref.watch(cacheNamespaceProvider);
  final cacheFuture = ref.watch(responseCacheProvider.future);
  final notificationsReady = ref.watch(_reviewFinancialChangesProvider.future);
  return NeedsReviewRepository(
    namespace: namespace,
    loadDatabase: () async {
      await notificationsReady;
      final store = (await cacheFuture).financialStore;
      return store.database;
    },
  );
});

final needsReviewItemsProvider = FutureProvider<List<NeedsReviewItem>>((
  ref,
) async {
  final markReady = _financialChanges(ref, 'needs_review');
  final markTransactionsReady = _financialChanges(ref, 'transactions');
  final markObservationsReady = _financialChanges(ref, 'observations');
  final items = await ref.watch(needsReviewRepositoryProvider).fetchAll();
  markReady();
  markTransactionsReady();
  markObservationsReady();
  return items;
});

/// Tier-1 auto-resolution receipts, newest first. A resolution is a normal
/// financial-store change (entity 'auto_resolved_history'), so the same
/// revision stream that refreshes transactions also refreshes this list.
final autoResolvedHistoryProvider =
    FutureProvider<List<AutoResolvedHistoryEntry>>((ref) async {
      final markReady = _financialChanges(ref, 'auto_resolved_history');
      final markTransactionsReady = _financialChanges(ref, 'transactions');
      final store = (await ref.watch(
        responseCacheProvider.future,
      )).financialStore;
      final rows = AutoResolvedHistoryRepository(
        store.database,
        namespace: ref.watch(cacheNamespaceProvider),
      ).fetchAll();
      markReady();
      markTransactionsReady();
      return rows;
    });

final autoResolvedCountProvider = FutureProvider<int>((ref) async {
  final markReady = _financialChanges(ref, 'auto_resolved_history');
  final store = (await ref.watch(responseCacheProvider.future)).financialStore;
  final count = AutoResolvedHistoryRepository(
    store.database,
    namespace: ref.watch(cacheNamespaceProvider),
  ).count();
  markReady();
  return count;
});

/// Undo/correct actions for the Auto-Resolved tab. Synchronous by contract:
/// the Needs Review flow always initializes [responseCacheProvider] first, so
/// a missing cache is a programming error rather than a loading state.
final smsAutoResolutionControllerProvider =
    Provider<SmsAutoResolutionController>((ref) {
      final cache = ref.watch(responseCacheProvider).valueOrNull;
      if (cache == null) {
        throw StateError(
          'smsAutoResolutionControllerProvider requires responseCacheProvider '
          'to be initialized before it is read',
        );
      }
      return SmsAutoResolutionController(
        database: cache.financialStore.database,
        store: cache.financialStore,
        reviewRepository: ref.watch(needsReviewRepositoryProvider),
        namespace: ref.watch(cacheNamespaceProvider),
      );
    });

/// The shared SMS rule bundle the server publishes: a versioned set of
/// sender/word patterns the device applies locally, so a parser improvement
/// reaches a phone without an app release.
final smsRuleBundleStoreProvider = FutureProvider<SmsRuleBundleStore>((
  ref,
) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return SmsRuleBundleStore(db);
});

/// The bundle currently in force on this device.
final activeSmsRuleBundleProvider = FutureProvider<SmsRuleBundle?>((ref) async {
  final store = await ref.watch(smsRuleBundleStoreProvider.future);
  return store.loadActiveBundle();
});

/// D1's badge (ui-spec §1: "Activity... with badge for D4 count") and
/// Insights Hub's tile both read this rather than the full list, so
/// neither has to unwrap an AsyncValue just to show a number.
final needsReviewCountProvider = FutureProvider<int>((ref) async {
  final markReady = _financialChanges(ref, 'needs_review');
  final count = await ref.watch(needsReviewRepositoryProvider).count();
  markReady();
  return count;
});

final commitmentsRepositoryProvider = Provider<CommitmentsRepository>((ref) {
  final ns = ref.watch(cacheNamespaceProvider);
  return CommitmentsRepository(
    namespace: ns,
    loadDatabase: () async =>
        (await ref.watch(responseCacheProvider.future)).financialStore.database,
  );
});

final commitmentsProvider = FutureProvider<List<Commitment>>((ref) async {
  final markCommitmentsReady = _financialChanges(ref, 'commitments');
  final markObservationsReady = _financialChanges(ref, 'observations');
  final repo = ref.watch(commitmentsRepositoryProvider);
  final manualList = await repo.fetchAll();

  try {
    final cache = await ref.watch(responseCacheProvider.future);
    final ns = ref.watch(cacheNamespaceProvider);
    final observations = cache.financialStore.entities(ns, 'sms_observations');
    final today = DateTime.now();
    final startOfToday = DateTime(today.year, today.month, today.day);

    final detectedByIdentity = <String, Commitment>{};
    String identityFor(
      CommitmentCategory category,
      String title,
      String? account,
    ) {
      final suffix = RegExp(r'(\d{4})$').firstMatch(account ?? '')?.group(1);
      return [
        category.name,
        title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ''),
        suffix ?? account ?? '',
      ].join('|');
    }

    final manualIdentities = <String>{
      for (final item in manualList)
        identityFor(item.category, item.title, item.identifier),
    };
    final orderedObservations = observations.toList()
      ..sort(
        (a, b) => ((b['received_at'] as String?) ?? '').compareTo(
          (a['received_at'] as String?) ?? '',
        ),
      );
    for (final obs in orderedObservations) {
      if (obs['event_type'] != 'bill') continue;
      // Card dues with card_last4 belong to Credit Card Dues section
      if (obs['card_last4'] != null) continue;

      final dueDateStr = obs['due_date'] as String?;
      if (dueDateStr == null) continue;
      final dueDate = DateTime.tryParse(dueDateStr);
      if (dueDate == null || dueDate.isBefore(startOfToday)) continue;

      final sender = (obs['sender_bank'] as String? ?? 'Bill').trim();
      final biller = (obs['biller_name'] as String?)?.trim();
      final title = biller == null || biller.isEmpty
          ? (sender.toUpperCase().contains('LIC') ? 'LIC policy' : sender)
          : biller;
      // Message fragments and amounts are not trustworthy biller names.
      if (RegExp(
            r'^(?:rs\.?|inr)?\s*[\d,./-]+\s*$',
            caseSensitive: false,
          ).hasMatch(title) ||
          RegExp(
            r'\b(?:a/c|account|towards|due|payment)\b',
            caseSensitive: false,
          ).hasMatch(title) ||
          (biller == null &&
              !RegExp(
                r'LIC|ALEGRA|AIRTEL|JIO|BSNL|BESCOM|MSEDCL|HDFC|ICICI|AXIS|SBI',
                caseSensitive: false,
              ).hasMatch(sender))) {
        continue;
      }
      final amountPaise = (obs['amount_due_paise'] as num?)?.toInt();
      final account = obs['account_last4'] as String?;
      final category = CommitmentCategory.fromText('$title $sender');
      // Credit-card statements belong to issuer cards, even if the SMS
      // omitted the last four digits used by the card observation parser.
      if (RegExp(
        r'credit\s*card',
        caseSensitive: false,
      ).hasMatch('$title $sender')) {
        continue;
      }
      final identity = identityFor(category, title, account);
      final confidence = (obs['confidence'] as num?)?.toDouble() ?? 0.55;
      final identifiedLicPolicy =
          category == CommitmentCategory.insurance &&
          sender.toUpperCase().contains('LIC') &&
          account != null;
      if (confidence < 0.85 && !identifiedLicPolicy) continue;
      final cadenceHint = obs['cadence_hint'] as String?;
      final cadence = CommitmentCadence.values.firstWhere(
        (value) => value.name == cadenceHint,
        orElse: () => CommitmentCadence.oneTime,
      );

      // Observations are evidence, not separate bills. Keep the newest
      // reminder for one biller/account pair so monthly alerts do not create
      // a growing list of duplicate commitments.
      if (manualIdentities.contains(identity) ||
          detectedByIdentity.containsKey(identity)) {
        continue;
      }

      detectedByIdentity[identity] = Commitment(
        id: 'sms-commitment-${sha256.convert(utf8.encode(identity))}',
        title: title,
        category: category,
        amount: amountPaise != null ? Money.fromPaise(amountPaise) : null,
        dueOn: dueDate,
        identifier: account != null ? '••••$account' : null,
        cadence: cadence,
        status: CommitmentStatus.due,
        source: CommitmentSource.sms,
        confidence: identifiedLicPolicy && confidence < 0.85
            ? 0.85
            : confidence,
      );
    }

    markCommitmentsReady();
    markObservationsReady();
    return [...manualList, ...detectedByIdentity.values];
  } catch (_) {
    markCommitmentsReady();
    markObservationsReady();
    return manualList;
  }
});

final _pastBillReceiptRevisionProvider = StreamProvider.family<int, String>((
  ref,
  namespace,
) async* {
  var version = 0;
  await for (final changed in PastBillReceiptRepository.changes) {
    if (changed == namespace) yield ++version;
  }
});

final pastBillReceiptsProvider = FutureProvider<List<PastBillReceipt>>((
  ref,
) async {
  var ready = false;
  ref.listen(financialStoreRevisionProvider('observations'), (_, next) {
    if (ready) ref.invalidateSelf();
  });
  final namespace = ref.watch(cacheNamespaceProvider);
  ref.listen(_pastBillReceiptRevisionProvider(namespace), (_, next) {
    if (ready) ref.invalidateSelf();
  });
  final db = await ref.watch(appDatabaseProvider.future);
  final repository = PastBillReceiptRepository(db, namespace: namespace);
  final allArchived = repository.fetchAll(limit: null);
  final archived = allArchived.take(1000).toList(growable: false);
  final knownSources = <String>{
    for (final item in allArchived) item.sourceKey,
    for (final item in allArchived)
      if (item.sourceKey.startsWith('commitment:'))
        item.sourceKey.substring('commitment:'.length),
  };
  String cycleKey(
    String merchant,
    String? cardLast4,
    String? accountLast4,
    DateTime due,
    int? amountPaise,
  ) => [
    smsBillSlug(merchant),
    cardLast4 ?? '',
    accountLast4 ?? '',
    DateTime(due.year, due.month, due.day).toIso8601String(),
    amountPaise ?? '',
  ].join('|');
  final archivedCycles = <String>{
    for (final item in allArchived)
      if (item.kind == PastBillReceiptKind.bill && item.dueDate != null)
        cycleKey(
          item.merchant,
          item.cardLast4,
          item.accountLast4,
          item.dueDate!,
          item.amount?.paise,
        ),
  };
  final cache = await ref.watch(responseCacheProvider.future);
  final today = DateTime.now();
  final currentMonth = DateTime(today.year, today.month);
  final archiveCutoff = today.subtract(const Duration(days: 90));
  final observedBillsByCycle = <String, PastBillReceipt>{};
  for (final observation in cache.financialStore.entities(
    namespace,
    'sms_observations',
  )) {
    final event = observation['event_type'] as String?;
    if (event != 'bill' && event != 'autopay') continue;
    final id = observation['id'] as String?;
    final received = DateTime.tryParse(
      observation['received_at'] as String? ?? '',
    );
    if (id == null || knownSources.contains(id) || received == null) continue;
    final premium = parseMonthOnlyPremium(observation);
    if (premium != null) {
      if (!premium.month.isBefore(currentMonth)) continue;
      final premiumCycle = [
        'premium',
        smsBillSlug(premium.title),
        premium.accountLast4 ?? '',
        premium.month.toIso8601String(),
      ].join('|');
      final previous = observedBillsByCycle[premiumCycle];
      if (previous != null && !received.isAfter(previous.receivedAt)) continue;
      observedBillsByCycle[premiumCycle] = PastBillReceipt(
        id: 'historical-sms-bill-$id',
        sourceKey: id,
        merchant: premium.title,
        kind: PastBillReceiptKind.bill,
        amount: null,
        occurredAt: received,
        receivedAt: received,
        status: PastBillReceiptStatus.needsConfirmation,
        accountLast4: premium.accountLast4,
        sender: (observation['sender_bank'] as String?)?.trim(),
        body: premium.body,
      );
      continue;
    }
    final due = DateTime.tryParse(observation['due_date'] as String? ?? '');
    if (due == null) continue;
    final dueDay = DateTime(due.year, due.month, due.day);
    final todayDay = DateTime(today.year, today.month, today.day);
    if (!dueDay.isBefore(todayDay) || !received.isBefore(archiveCutoff)) {
      continue;
    }
    final biller = (observation['biller_name'] as String?)?.trim() ?? '';
    final sender = (observation['sender_bank'] as String?)?.trim() ?? '';
    final amountPaise =
        observation['amount_due_paise'] as int? ??
        observation['minimum_due_paise'] as int?;
    if (biller.length < 3 && sender.length < 3) continue;
    final merchant = biller.length >= 3 ? biller : sender;
    // Reminder messages from the same bill cycle may have separate SMS IDs.
    // Collapse only when the merchant, instrument, due day, and amount agree.
    final billCycle = cycleKey(
      merchant,
      observation['card_last4'] as String?,
      observation['account_last4'] as String?,
      dueDay,
      amountPaise,
    );
    if (archivedCycles.contains(billCycle)) continue;
    final previous = observedBillsByCycle[billCycle];
    if (previous != null && !received.isAfter(previous.receivedAt)) continue;
    observedBillsByCycle[billCycle] = PastBillReceipt(
      id: 'historical-sms-bill-$id',
      sourceKey: id,
      merchant: merchant,
      kind: PastBillReceiptKind.bill,
      amount: amountPaise == null ? null : Money.fromPaise(amountPaise),
      occurredAt: due,
      receivedAt: received,
      dueDate: due,
      status: PastBillReceiptStatus.needsConfirmation,
      cardLast4: observation['card_last4'] as String?,
      accountLast4: observation['account_last4'] as String?,
      sender: sender,
      body: observation['sample_body'] as String?,
    );
  }
  ready = true;
  return [...archived, ...observedBillsByCycle.values]
    ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
});

/// Bills pane input: bill/autopay sms_observations resolved against the
/// logged transaction history. Covers what the commitments sections skip —
/// card-linked bills, autopay reminders, any bill whose payment the app
/// never saw — with the settled/pending/payment-not-detected state each.
final smsBillRowsProvider = FutureProvider<List<SmsBillRow>>((ref) async {
  var ready = false;
  ref.listen(financialStoreRevisionProvider('observations'), (_, next) {
    if (ready) ref.invalidateSelf();
  });
  ref.listen(financialStoreRevisionProvider('transactions'), (_, next) {
    if (ready) ref.invalidateSelf();
  });
  final clockNow = ref.watch(clockProvider).now();
  final cache = await ref.watch(responseCacheProvider.future);
  final ns = ref.watch(cacheNamespaceProvider);
  final observations = cache.financialStore.entities(ns, 'sms_observations');
  final cardsLast4ById = {
    for (final card in await ref.watch(myCardsProvider.future))
      if (card.last4 != null) card.id: card.last4!,
  };
  final repo = ref.watch(userCardsRepositoryProvider);
  final transactions = repo == null
      ? const <TransactionEntry>[]
      : await loadTransactionsWithOfflineCache(
          ref,
          repo: repo,
          cacheKey: 'transactions:sms_bills',
          from: clockNow.subtract(const Duration(days: 120)),
        );
  final taken = <String>{
    for (final commitment in await ref.watch(commitmentsProvider.future))
      smsBillIdentityForCommitment(commitment),
  };
  ready = true;
  return deriveSmsBillRows(
    observations: observations,
    transactions: transactions,
    cardsLast4ById: cardsLast4ById,
    takenIdentities: taken,
    now: clockNow,
  );
});

/// Insurance renewals whose SMS named only a month. Past months belong to
/// archived history, and rows with an amount already appear in the SMS bill
/// list, so this feed is the only Bills surface for the remaining reminders.
final premiumRemindersProvider = Provider<List<PremiumReminder>>((ref) {
  ref.watch(financialStoreRevisionProvider('observations'));
  final cache = ref.watch(responseCacheProvider).valueOrNull;
  if (cache == null) return const [];
  final namespace = ref.watch(cacheNamespaceProvider);
  return derivePremiumReminders(
    observations: cache.financialStore.entities(namespace, 'sms_observations'),
    commitments: ref.watch(commitmentsProvider).valueOrNull ?? const [],
    now: ref.watch(clockProvider).now(),
  );
});

/// UA-3: the signed-in user's own profiles row (owner-scoped via RLS —
/// api/'s GET /profile, proved end to end back in Chunk 1 but never called
/// from the app itself until this chunk). Null when signed out or when a
/// signed-in user hasn't completed onboarding yet (no profile row exists).
///
/// Cache-first, like `userCardsProvider`: this used to await the live request
/// before returning anything, so the You tab held its whole first frame on
/// GET /profile. A slow or unreachable API — or a backend busy with the
/// launch-time refresh burst — showed a blank page with a spinner even though
/// the last snapshot was already on disk. The cached row now paints
/// immediately and [_warmDisplay] refreshes it behind the UI.
final profileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final api = ref.watch(profileApiProvider);
  if (api == null) return null;
  const profileCacheKey = 'profile';
  final namespace = ref.read(cacheNamespaceProvider);
  final cache = await _cacheOrNull(ref);
  final key = _scopedCacheKey(ref, profileCacheKey);
  final cached = await _readCacheOrNull(ref, cache, key);

  Map<String, dynamic>? decodeCached() {
    if (cached == null) return null;
    final body = jsonDecode(cached.rawJson) as Map<String, dynamic>;
    return body['profile'] as Map<String, dynamic>?;
  }

  Future<Map<String, dynamic>?> fetch() async {
    final profile = await api.fetchProfile();
    if (profile != null) {
      cache?.financialStore.database.saveProfileDisplayName(
        namespace,
        profile['display_name'] as String?,
      );
    }
    return profile;
  }

  if (cached != null) {
    try {
      final profile = decodeCached();
      _warmDisplay(
        ref,
        cache,
        key,
        cached.fetchedAt,
        fetch,
        (profile) => {'profile': profile},
      );
      return profile;
    } catch (_) {
      // A corrupt snapshot is not fatal; the request below repairs it.
      await cache?.clear(key);
    }
  }

  // Offline with nothing cached: a profile row is display metadata, not the
  // session itself. Render the signed-in shell instead of waiting out a
  // request that cannot succeed.
  if (_isKnownOffline()) return null;

  try {
    final profile = await fetch();
    try {
      await cache?.put(key, jsonEncode({'profile': profile}));
    } catch (_) {}
    return profile;
  } catch (error) {
    if (_isAuthenticationFailure(error)) {
      // A profile row is optional display metadata, not the account
      // session itself. When the API rejects a stale access token and no
      // profile snapshot exists yet, return null so You/settings can still
      // render their local card and transaction data. Treating this as a
      // page-fatal error made the whole tab look broken even though the
      // account was still signed in locally and its cached data was safe.
      return null;
    }
    rethrow;
  }
});

/// Task C-7/C-8: null when signed out, same pattern as every other
/// auth-gated repository provider in this file — both card-requests and
/// data-error-reports are owner-scoped writes (RLS `for all to public
/// using (profile_id = pandapay.uid())`), so there's no meaningful
/// signed-out path to support.
final cardFeedbackRepositoryProvider = Provider<CardFeedbackRepository>((ref) {
  final token = _stableSessionToken(ref);
  return CardFeedbackRepository(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

final userCardsRepositoryProvider = Provider<UserCardsRepository?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  final namespace = ref.read(cacheNamespaceProvider);
  late final UserCardsRepository repository;
  repository = UserCardsRepository(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
    dismissalOutbox: () async {
      if (ref.read(cacheNamespaceProvider) != namespace) {
        throw StateError('Account changed before dismissal sync');
      }
      final cache = await ref.read(responseCacheProvider.future);
      return SmsDismissalOutbox(cache.financialStore.database, namespace);
    },
    onTransactionSaved: (mutationId, transactionId) {
      if (ref.read(cacheNamespaceProvider) != namespace) return;
      ref
          .read(transactionTagsProvider)
          ?.remapTransaction('local-outbox:$mutationId', transactionId);
    },
    onSmsCaptured: (message) async {
      if (ref.read(cacheNamespaceProvider) != namespace) {
        throw StateError(
          'Account changed. Retry this import from the current account.',
        );
      }
      final cache = await ref.read(responseCacheProvider.future);
      cache.financialStore.migrateLegacy(namespace);
      final bundle = SmsRuleBundleStore(cache.financialStore.database)
          .loadActiveBundleSync(
            clientVersion: ref.read(appVersionProvider).valueOrNull ?? '1.0.0',
          );
      SmsImportStore(
        cache.financialStore,
        downloadedRules: bundle,
        candidateRules: SmsRuleBundleStore(cache.financialStore.database)
            .loadCandidateBundlesSync(
              clientVersion:
                  ref.read(appVersionProvider).valueOrNull ?? '1.0.0',
              namespace: namespace,
            ),
      ).capture(
        namespace,
        QueuedSms(
          sender: message.sender,
          body: message.body,
          receivedAt: message.occurredAt,
        ),
      );
      ref.invalidate(commitmentsProvider);
    },
    onSmsBatchCaptured: (messages) async {
      final cache = await ref.read(responseCacheProvider.future);
      cache.financialStore.migrateLegacy(namespace);
      for (var start = 0; start < messages.length; start += 100) {
        if (ref.read(cacheNamespaceProvider) != namespace) {
          throw StateError('Account changed during import');
        }
        final end = (start + 100).clamp(0, messages.length);
        final bundle = SmsRuleBundleStore(cache.financialStore.database)
            .loadActiveBundleSync(
              clientVersion:
                  ref.read(appVersionProvider).valueOrNull ?? '1.0.0',
            );
        SmsImportStore(
          cache.financialStore,
          downloadedRules: bundle,
          candidateRules: SmsRuleBundleStore(cache.financialStore.database)
              .loadCandidateBundlesSync(
                clientVersion:
                    ref.read(appVersionProvider).valueOrNull ?? '1.0.0',
                namespace: namespace,
              ),
        ).captureBatch(namespace, [
          for (final message in messages.sublist(start, end))
            QueuedSms(
              sender: message.sender,
              body: message.body,
              receivedAt: message.occurredAt,
            ),
        ]);
        ref.invalidate(commitmentsProvider);
        await Future<void>.delayed(Duration.zero);
      }
    },
    onSmsUploaded: (messages, results, notifyNewTransactions) async {
      if (ref.read(cacheNamespaceProvider) != namespace) return;
      final cache = await ref.read(responseCacheProvider.future);
      final store = cache.financialStore;
      final intake = SmsIntakeRepository(store.database);
      final localEventByKey = <String, String>{
        for (final observation in store.entities(namespace, 'sms_observations'))
          if (observation['id'] is String &&
              observation['event_type'] is String)
            observation['id'] as String: observation['event_type'] as String,
      };
      List<TransactionEntry>? confirmed;
      try {
        // One reconciliation request per batch, not one request per message.
        final dates = messages.map((m) => m.occurredAt).toList()..sort();
        if (dates.isNotEmpty) {
          confirmed = await repository.fetchTransactions(
            from: dates.first.subtract(const Duration(days: 2)),
            to: dates.last.add(const Duration(days: 1)),
          );
          if (ref.read(cacheNamespaceProvider) != namespace) return;
          store.saveTransactions(namespace, confirmed);
        }
      } catch (_) {
        /* The durable intake retries reconciliation later. */
      }
      final acknowledgements = <void Function()>[];
      for (final result in results) {
        final index = (result['index'] as num?)?.toInt();
        if (index == null || index < 0 || index >= messages.length) continue;
        final message = messages[index];
        final key = smsSourceKey(namespace, message.sender, message.body);
        final outcome = result['outcome'];
        if (outcome == 'error' || outcome == 'invalid') continue;
        final serverId = result['transactionId'] as String?;
        final matched =
            confirmed
                ?.where(
                  (t) =>
                      t.sourceKey == key ||
                      (serverId != null && t.id == serverId),
                )
                .toList() ??
            const <TransactionEntry>[];
        if (notifyNewTransactions && outcome == 'imported') {
          final recorded = matched
              .where((transaction) => transaction.id == serverId)
              .where((transaction) => transaction.status == 'active')
              .firstOrNull;
          if (recorded != null) {
            final merchant = recorded.merchantName?.trim();
            final detail = merchant == null || merchant.isEmpty
                ? '${recorded.amount.format(hidePaise: true)} was added to your spending.'
                : '${recorded.amount.format(hidePaise: true)} at $merchant was added to your spending.';
            try {
              await ref
                  .read(notificationGateProvider)
                  .fire(
                    category: 'transactions',
                    title: 'Transaction recorded',
                    body: detail,
                    dedupeKey: 'transaction_recorded:${recorded.id}',
                  );
            } catch (_) {
              // A notification failure must never hold up SMS reconciliation.
            }
          }
        }
        final negative =
            outcome == 'unparsed' &&
            _isIgnorableSmsReason(result['reason'] as String?);
        final returned = result['transaction'] as Map?;
        final inactive =
            serverId != null &&
            returned?['status'] != null &&
            returned!['status'] != 'active';
        if (matched.isNotEmpty ||
            negative ||
            inactive ||
            outcome == 'imported' ||
            outcome == 'duplicate' ||
            store.hasReceipt(namespace, key)) {
          acknowledgements.add(() {
            store.discardProvisional(
              namespace,
              key,
              confirmedId: matched.isNotEmpty
                  ? matched.first.id
                  : inactive
                  ? serverId
                  : outcome == 'imported'
                  ? serverId
                  : null,
            );
            intake.acknowledge(namespace, key);
          });
        } else if (localEventByKey[key] == 'bill') {
          // A bill observation is intentionally not a transaction. If the
          // hosted transaction parser does not understand it, acknowledge the
          // intake here and leave any bill-specific review item untouched.
          acknowledgements.add(() {
            store.discardProvisional(namespace, key);
            intake.acknowledge(namespace, key);
          });
        } else if (outcome == 'needs_review' || outcome == 'unparsed') {
          final isNoise = NeedsReviewRepository.isNoiseItem(
            NeedsReviewItem(
              id: key,
              sender: message.sender,
              body: message.body,
              receivedAt: message.occurredAt,
            ),
          );
          final isFinancialCandidate =
              capturesFinancialSms(message.body, sender: message.sender) &&
              !isNoise;
          if (isNoise || (outcome == 'unparsed' && !isFinancialCandidate)) {
            acknowledgements.add(() {
              store.discardProvisional(namespace, key);
              intake.acknowledge(namespace, key);
            });
          } else {
            // Preserve unsupported input for review without silently retrying it
            // forever or treating an unconfirmed local parse as final spending.
            // Best-effort submit to the server AI queue for background classification.
            repository
                .submitAiJob(
                  sourceKey: key,
                  sender: message.sender,
                  body: message.body,
                  occurredAt: message.occurredAt,
                )
                .ignore();
            await ref
                .read(needsReviewRepositoryProvider)
                .add(
                  NeedsReviewItem(
                    id: key,
                    sender: message.sender,
                    body: message.body,
                    receivedAt: message.occurredAt,
                    reason: result['reason'] as String?,
                  ),
                );
            acknowledgements.add(() {
              store.discardProvisional(namespace, key);
              intake.acknowledge(namespace, key);
            });
          }
        }
      }
      if (ref.read(cacheNamespaceProvider) != namespace) return;
      store.batch(() {
        for (final acknowledge in acknowledgements) {
          acknowledge();
        }
      });
      if (acknowledgements.isNotEmpty) {
        ref.invalidate(pendingRecoveryStatusProvider);
      }
    },
  );
  repository.flushDismissalQueue().ignore();
  return repository;
});

/// Future merchant category rules are a separate owner-scoped API contract
/// from the one-time transaction bulk review.  Keeping this provider separate
/// lets the bulk flow remain usable while rule creation is unavailable or
/// disabled server-side.
final merchantCategoryRulesRepositoryProvider =
    Provider<MerchantCategoryRulesRepository?>((ref) {
      final token = _stableSessionToken(ref);
      if (token == null) return null;
      return MerchantCategoryRulesRepository(
        apiBaseUrl: _apiBaseUrl,
        accessToken: token,
        client: ref.read(authenticatedHttpClientProvider),
      );
    });

/// Future merchant issue-flag rules use the same authenticated API contract
/// as category rules but carry `action: flag`. Keeping a separate provider
/// prevents a flag report from sharing category state or mutating a category
/// rule accidentally.
final merchantIssueRulesRepositoryProvider =
    Provider<MerchantIssueRulesRepository?>((ref) {
      final token = _stableSessionToken(ref);
      if (token == null) return null;
      return MerchantIssueRulesRepository(
        apiBaseUrl: _apiBaseUrl,
        accessToken: token,
        client: ref.read(authenticatedHttpClientProvider),
      );
    });

/// Invalidates all projections whose values can change after a category bulk
/// apply. This is deliberately lazy: visible consumers fetch their own fresh
/// snapshot instead of issuing a burst of requests for every report.
void invalidateTransactionViews(Ref ref) {
  ref.invalidate(transactionsProvider);
  ref.invalidate(utilizationTransactionsProvider);
  ref.invalidate(userCardsProvider);
  ref.invalidate(homeSummaryProvider);
  ref.invalidate(categorySpendProvider);
  ref.invalidate(spendReportProvider);
  ref.invalidate(bankAccountSummariesProvider);
  ref.invalidate(budgetsProvider);
  ref.invalidate(recurringReportProvider);
  ref.invalidate(currentMonthlyReportProvider);
}

/// Spend trends and budgets. Null in guest mode, like every other
/// server-backed repository here: both read `transactions`, which is
/// owner-scoped and has no local-only counterpart.
final spendReportsRepositoryProvider = Provider<SpendReportsRepository?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return SpendReportsRepository(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

/// The Trends screen's data, for the selected period.
///
/// A family over [SpendReportQuery] rather than a provider plus a separate
/// "selected period" fetch: switching period or custom dates is a different
/// request, and keying the cache by query means flipping back to a selection
/// already looked at is instant instead of re-fetching.
final FutureProviderFamily<SpendReport?, SpendReportQuery>
spendReportProvider = FutureProvider.family<SpendReport?, SpendReportQuery>((
  ref,
  query,
) async {
  final markReady = _financialChanges(ref, 'transactions');
  try {
    final repo = ref.watch(spendReportsRepositoryProvider);
    if (repo == null) return null;
    final anchor = query.isCustom ? null : DateTime.now().toUtc();
    final timeZone = ref.watch(deviceTimeZoneProvider);
    final bucket = query.isCustom
        ? query.from!
        : _spendReportBucket(query.period, DateTime.now());
    final key = _scopedCacheKey(
      ref,
      '$_spendReportCacheKey:${query.cacheKey}:${_cacheDate(bucket)}:$timeZone',
    );
    final cache = await _cacheOrNull(ref);
    final cached = await _readCacheOrNull(ref, cache, key);
    SpendReport decodeCached() {
      if (cached == null) throw StateError('No cached spend report available');
      return SpendReport.fromJson(
        jsonDecode(cached.rawJson) as Map<String, dynamic>,
      );
    }

    if (cached == null ||
        cache?.financialStore.hasPendingTransactions(
              ref.read(cacheNamespaceProvider),
            ) ==
            true) {
      final local = await _buildLocalSpendReport(ref, query);
      if (local != null) {
        ref.read(transactionsProvider);
        return local;
      }
    } else {
      try {
        final saved = decodeCached();
        _warmDisplay(
          ref,
          cache,
          key,
          cached.fetchedAt,
          () => repo.fetchReportJson(
            period: query.period,
            anchor: anchor,
            from: query.from,
            to: query.to,
            timeZone: timeZone,
          ),
          (raw) => raw,
        );
        return saved;
      } catch (_) {
        await cache?.clear(key);
      }
    }

    try {
      final raw = await repo.fetchReportJson(
        period: query.period,
        // Periods are about the user's device calendar. Sending the device
        // instant prevents a server clock that is a few hours/days behind from
        // reporting September when the user is already in October.
        anchor: anchor,
        from: query.from,
        to: query.to,
        timeZone: timeZone,
      );
      try {
        await cache?.put(key, jsonEncode(raw));
      } catch (_) {
        // A disk/cache failure must never make a successful report unusable.
      }
      return SpendReport.fromJson(raw);
    } catch (error) {
      // A refresh attempt can fail as a transport exception before the
      // repository receives a 401. The local transaction snapshot is still
      // usable for this read-only report.
      if (cached == null) {
        final local = await _buildLocalSpendReport(ref, query);
        if (local != null) return local;
      }
      if (!_canUseReadCache(error)) {
        if (_isAuthenticationFailure(error)) {
          final local = await _buildLocalSpendReport(ref, query);
          if (local != null) {
            return local;
          }
          throw const AuthenticationUnavailableException();
        }
        rethrow;
      }
      if (cached == null) {
        if (_isAuthenticationFailure(error)) {
          final local = await _buildLocalSpendReport(ref, query);
          if (local != null) {
            return local;
          }
          throw const AuthenticationUnavailableException();
        }
        rethrow;
      }
      try {
        return decodeCached();
      } catch (_) {
        try {
          await cache?.clear(key);
        } catch (_) {}
        rethrow;
      }
    }
  } finally {
    markReady();
  }
});

/// The period or custom range the Trends screen is currently showing.
final selectedSpendQueryProvider = StateProvider<SpendReportQuery>(
  (ref) => const SpendReportQuery.preset(SpendPeriod.month),
);

/// Every active budget with its current-period progress.
final budgetsProvider = FutureProvider<List<BudgetStatus>>((ref) async {
  final repo = ref.watch(spendReportsRepositoryProvider);
  if (repo == null) return const [];
  final cache = await _cacheOrNull(ref);
  final key = _scopedCacheKey(ref, 'budgets');
  final cached = await _readCacheOrNull(ref, cache, key);
  List<BudgetStatus> decode(CachedResponse snapshot) =>
      ((jsonDecode(snapshot.rawJson) as Map<String, dynamic>)['budgets']
              as List)
          .cast<Map<String, dynamic>>()
          .map(BudgetStatus.fromJson)
          .toList();
  if (cached != null) {
    try {
      final saved = decode(cached);
      _warmDisplay(
        ref,
        cache,
        key,
        cached.fetchedAt,
        repo.fetchBudgets,
        (rows) => {'budgets': rows.map((b) => b.toJson()).toList()},
      );
      return saved;
    } catch (_) {
      await cache?.clear(key);
    }
  }
  try {
    final budgets = await repo.fetchBudgets();
    try {
      await cache?.put(
        key,
        jsonEncode({
          'budgets': budgets.map((budget) => budget.toJson()).toList(),
        }),
      );
    } catch (_) {}
    return budgets;
  } catch (error) {
    if (!_canUseReadCache(error) || cached == null) {
      if (_isAuthenticationFailure(error)) {
        return const [];
      }
      rethrow;
    }
    try {
      return decode(cached);
    } catch (_) {
      await cache?.clear(key);
      rethrow;
    }
  }
});

/// Detected subscriptions, biggest annual cost first.
final FutureProvider<RecurringReport?>
recurringReportProvider = FutureProvider<RecurringReport?>((ref) async {
  final markReady = _financialChanges(ref, 'transactions');
  try {
    final repo = ref.watch(spendReportsRepositoryProvider);
    if (repo == null) return null;
    final cache = await _cacheOrNull(ref);
    final key = _scopedCacheKey(ref, 'recurring_report');
    final cached = await _readCacheOrNull(ref, cache, key);
    RecurringReport decode(CachedResponse snapshot) => RecurringReport(
      series:
          ((jsonDecode(snapshot.rawJson) as Map<String, dynamic>)['series']
                  as List)
              .cast<Map<String, dynamic>>()
              .map(
                (item) => _normalizeLegacyServiceMandate(
                  RecurringSeries.fromJson(item),
                ),
              )
              .toList(),
      totalAnnual: Money.fromRupees(
        (((jsonDecode(snapshot.rawJson)
                    as Map<String, dynamic>)['totalAnnualInr'])
                as num)
            .toDouble(),
      ),
    );
    // Pending SMS can lack the category/history used by the local detector.
    // Keep established server series (and dismissal state) through that work.
    if (cached == null) {
      final local = await _buildLocalRecurringReport(ref);
      if (local != null) {
        ref.read(transactionsProvider);
        _warmDisplay(
          ref,
          cache,
          key,
          DateTime.fromMillisecondsSinceEpoch(0),
          repo.fetchRecurring,
          (report) => report.toJson(),
        );
        return local;
      }
    }
    if (cached != null) {
      try {
        final saved = decode(cached);
        _warmDisplay(
          ref,
          cache,
          key,
          cached.fetchedAt,
          repo.fetchRecurring,
          (report) => report.toJson(),
        );
        return await _mergeLocalSetupSeries(ref, saved);
      } catch (_) {
        await cache?.clear(key);
      }
    }
    try {
      final report = await repo.fetchRecurring();
      try {
        await cache?.put(key, jsonEncode(report.toJson()));
      } catch (_) {}
      return await _mergeLocalSetupSeries(ref, report);
    } catch (error) {
      if (cached == null) {
        final local = await _buildLocalRecurringReport(ref);
        if (local != null) return local;
      }
      if (!_canUseReadCache(error) || cached == null) {
        if (_isAuthenticationFailure(error)) {
          final local = await _buildLocalRecurringReport(ref);
          if (local != null) {
            return local;
          }
          // A signed-in user with no local transaction snapshot has a truthful
          // empty result, not a page-fatal transport error. Once transactions
          // have been synced, the local detector above supplies a useful
          // offline result until the server report is available again.
          return const RecurringReport(series: [], totalAnnual: Money.zero());
        }
        rethrow;
      }
      try {
        return await _mergeLocalSetupSeries(ref, decode(cached));
      } catch (_) {
        await cache?.clear(key);
        rethrow;
      }
    }
  } finally {
    markReady();
  }
});

/// Budgets that need saying something about, worst first.
///
/// Over-budget outranks off-pace, and within each the more extreme comes
/// first — Home and the notification trigger both want "the one thing worth
/// mentioning", not a list to re-sort themselves.
final budgetsNeedingAttentionProvider = Provider<List<BudgetStatus>>((ref) {
  final budgets = ref.watch(budgetsProvider).valueOrNull ?? const [];
  final flagged = budgets.where((b) => b.isOver || b.isOffPace).toList()
    ..sort((a, b) {
      if (a.isOver != b.isOver) return a.isOver ? -1 : 1;
      return b.consumedFraction.compareTo(a.consumedFraction);
    });
  return flagged;
});

/// Guest/no-account counterpart to [userCardsRepositoryProvider] (ui-spec.md
/// A3) — always available, even signed in, but only actually read by
/// [userCardsProvider]/[myCardsProvider] when [userCardsRepositoryProvider]
/// is null. A FutureProvider because opening the sqlite file
/// ([appDatabaseProvider]) is itself async.
final localUserCardsRepositoryProvider =
    FutureProvider<LocalUserCardsRepository>((ref) async {
      return LocalUserCardsRepository(
        await ref.watch(appDatabaseProvider.future),
      );
    });

/// The signed-in user's own wallet — empty (not an error) when signed out,
/// so rankedRecommendationsProvider below can fall back to the whole
/// catalogue without a special-cased branch for "not signed in" vs.
/// "signed in but owns nothing yet."
final FutureProvider<List<UserCard>>
userCardsProvider = FutureProvider<List<UserCard>>((ref) async {
  final markReady = _financialChanges(ref, 'cards');
  try {
    final repo = ref.watch(userCardsRepositoryProvider);
    if (repo == null) {
      final local = await ref.watch(localUserCardsRepositoryProvider.future);
      final catalogue = await ref.watch(catalogueProvider.future);
      return await local.fetchUserCards(catalogue: catalogue);
    }
    final stored = await _readUserCardsCache(ref, includeArchived: false);
    if (stored != null) return stored;
    // Home is a read-mostly decision surface. If a prior sync exists, return it
    // immediately even while the device is online; homeDataRefreshProvider
    // refreshes the same snapshot in the background and invalidates this
    // provider after the write completes.
    final cache = await _cacheOrNull(ref);
    final cacheKey = _scopedCacheKey(ref, _userCardsCacheKey);
    final cached = await cache?.get(cacheKey);
    if (cached != null) {
      try {
        final body = jsonDecode(cached) as Map<String, dynamic>;
        return (body['userCards'] as List)
            .cast<Map<String, dynamic>>()
            .map(UserCard.fromJson)
            .where((card) => !card.isArchived)
            .toList();
      } catch (_) {
        // A corrupt snapshot is not fatal; the normal server path below repairs
        // it and the next launch can use the repaired copy.
      }
    }
    return await _loadUserCardsWithOfflineCache(ref, repo);
  } finally {
    markReady();
  }
});

Future<List<UserCard>> _loadUserCardsWithOfflineCache(
  Ref ref,
  UserCardsRepository repo, {
  bool includeArchived = false,
}) async {
  final cache = await _cacheOrNull(ref);
  final cacheKey = _scopedCacheKey(
    ref,
    includeArchived ? _userCardsWithArchivedCacheKey : _userCardsCacheKey,
  );
  final cached = await cache?.get(cacheKey);

  List<UserCard> decodeCached() {
    if (cached == null) throw StateError('No cached user cards available');
    final body = jsonDecode(cached) as Map<String, dynamic>;
    return (body['userCards'] as List)
        .cast<Map<String, dynamic>>()
        .map(UserCard.fromJson)
        .toList();
  }

  List<UserCard> visibleCards(Iterable<UserCard> cards) =>
      cards.where((card) => card.isArchived == includeArchived).toList();

  if (_isKnownOffline() && cached != null) {
    return visibleCards(decodeCached());
  }

  try {
    final cards = await repo
        .fetchUserCards(includeArchived: includeArchived)
        .timeout(_homeRequestTimeout);
    try {
      await cache?.put(
        cacheKey,
        jsonEncode({'userCards': cards.map((c) => c.toJson()).toList()}),
      );
    } catch (_) {
      // A local-database write must never turn a successful wallet fetch into
      // an error. The next successful fetch will repair the snapshot.
    }
    return visibleCards(cards);
  } catch (error) {
    if (!_canUseReadCache(error) || cached == null) {
      if (_isAuthenticationFailure(error)) {
        return const [];
      }
      rethrow;
    }
    return visibleCards(decodeCached());
  }
}

/// UA-3+ (Chunk 18): the Activity tab's data — empty (not an error) when
/// signed out, same reasoning as userCardsProvider above.
final transactionsProvider = FutureProvider<List<TransactionEntry>>((
  ref,
) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  return loadTransactionsWithOfflineCache(
    ref,
    repo: repo,
    cacheKey: '$_transactionsCacheKey:all',
  );
});

/// Transactions needed by credit utilization. The ordinary activity provider
/// intentionally keeps its unfiltered call capped at the newest 50 rows; a
/// utilization calculation must instead fetch the complete recent statement
/// window so an older purchase cannot disappear merely because more activity
/// arrived.
final utilizationTransactionsProvider = FutureProvider<List<TransactionEntry>>((
  ref,
) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  final now = ref.watch(clockProvider).now();
  final from = DateTime(now.year, now.month - 2, 1);
  return loadTransactionsWithOfflineCache(
    ref,
    repo: repo,
    cacheKey: '$_transactionsCacheKey:utilization:${_cacheDate(from)}',
    from: from,
  );
});

/// The compact per-card spend snapshot used by card surfaces. This deliberately
/// shares the same definition as credit utilization: active credit-card spend
/// since the current statement cycle (or the current calendar month when the
/// statement day is not known). Keeping this in one provider prevents the
/// amount shown on a card from disagreeing with the utilization and detail
/// screens.
class CardSpendSummary {
  final Money cycleTotal;
  final TransactionEntry? latestSpend;

  const CardSpendSummary({required this.cycleTotal, required this.latestSpend});
}

final cardSpendSummaryProvider = Provider<Map<String, CardSpendSummary>>((ref) {
  final cardsValue = ref.watch(myCardsProvider);
  final transactionsValue = ref.watch(utilizationTransactionsProvider);
  final cards = cardsValue.valueOrNull ?? const <UserCard>[];
  // Do not flash a misleading ₹0 while the transaction window is still
  // loading. An empty map makes the card omit spend metadata until the real
  // snapshot is available; once loaded, a genuine zero is shown correctly.
  if (!cardsValue.hasValue || !transactionsValue.hasValue) return const {};
  final transactions = transactionsValue.requireValue;
  final now = ref.watch(clockProvider).now();
  final result = <String, CardSpendSummary>{};

  for (final card in cards) {
    result[card.id] = _cardSpendSummary(card, transactions, now);
  }

  return result;
});

CardSpendSummary _cardSpendSummary(
  UserCard card,
  List<TransactionEntry> transactions,
  DateTime now,
) {
  final cycleStart = card.statementDay == null
      ? DateTime(now.year, now.month, 1)
      : _previousStatementOccurrence(card.statementDay!, now);
  var total = const Money.zero();
  TransactionEntry? latest;

  for (final txn in transactions) {
    if (txn.status != 'active' || txn.userCardId != card.id) continue;
    if (txn.entryKind != TxnEntryKind.spend ||
        txn.instrument != TxnInstrument.creditCard ||
        txn.occurredAt.isBefore(cycleStart)) {
      continue;
    }
    total += txn.amount;
    if (latest == null || txn.occurredAt.isAfter(latest.occurredAt)) {
      latest = txn;
    }
  }

  return CardSpendSummary(cycleTotal: total, latestSpend: latest);
}

final cardOverridesRepositoryProvider = Provider<CardOverridesRepository?>((
  ref,
) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return CardOverridesRepository(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

/// B8 — every override rule the signed-in user owns (enabled or disabled).
/// Empty (not an error) when signed out, same reasoning as userCardsProvider.
final cardOverridesProvider = FutureProvider<List<CardOverride>>((ref) async {
  final repo = ref.watch(cardOverridesRepositoryProvider);
  if (repo == null) return const [];
  final cache = await _cacheOrNull(ref);
  final cacheKey = _scopedCacheKey(ref, _cardOverridesCacheKey);
  final cached = await cache?.get(cacheKey);

  List<CardOverride>? decodeCached() {
    if (cached == null) return null;
    try {
      final body = jsonDecode(cached) as Map<String, dynamic>;
      return (body['overrides'] as List)
          .cast<Map<String, dynamic>>()
          .map(CardOverride.fromJson)
          .toList();
    } catch (_) {
      return null;
    }
  }

  // After a live edit/delete/toggle invalidates this provider, fetch first so
  // the screen cannot immediately rehydrate the pre-mutation snapshot.
  // Cached data remains the fallback for an offline or unavailable API.
  try {
    final overrides = await repo.fetchOverrides().timeout(_homeRequestTimeout);
    try {
      await cache?.put(
        cacheKey,
        jsonEncode({'overrides': overrides.map((o) => o.toJson()).toList()}),
      );
    } catch (_) {
      // A local-database write must never turn a successful override fetch
      // into an error. The next successful fetch will repair the snapshot.
    }
    return overrides;
  } catch (error) {
    if (!_canUseReadCache(error)) rethrow;
    // Overrides are an enhancement to ranking, not a prerequisite for
    // showing the wallet. If this is the first signed-in request and there is
    // no cache yet, fail open with the base catalogue instead of replacing
    // Home with an error state while the API is unavailable.
    return decodeCached() ?? const [];
  }
});

/// Refreshes Home's small set of inputs without blocking its first frame.
/// Read providers above are cache-first; this provider writes a fresh snapshot
/// in parallel and publishes it only after the local writes complete.
final homeDataRefreshProvider = FutureProvider<void>((ref) async {
  final userRepo = ref.watch(userCardsRepositoryProvider);
  final cache = await _cacheOrNull(ref);
  if (cache == null) return;

  Future<void> refreshUserCards() async {
    if (userRepo == null) return;
    try {
      final cards = await userRepo.fetchUserCards().timeout(
        _homeRequestTimeout,
      );
      await cache.put(
        _scopedCacheKey(ref, _userCardsCacheKey),
        jsonEncode({'userCards': cards.map((c) => c.toJson()).toList()}),
      );
    } catch (_) {}
  }

  Future<void> refreshCatalogue() async {
    try {
      final cards = await ref
          .read(catalogueRepositoryProvider)
          .fetchCatalogue()
          .timeout(_homeRequestTimeout);
      if (cards.isNotEmpty) {
        await cache.put(
          _catalogueCacheKey,
          jsonEncode({'cards': cards.map((c) => c.toJson()).toList()}),
        );
      }
    } catch (_) {}
  }

  Future<void> refreshCategories() async {
    try {
      final categories = await ref
          .read(categoryRepositoryProvider)
          .fetchCategories()
          .timeout(_homeRequestTimeout);
      await cache.put(
        _categoriesCacheKey,
        jsonEncode({'categories': categories.map((c) => c.toJson()).toList()}),
      );
    } catch (_) {}
  }

  Future<void> refreshOverrides() async {
    if (userRepo == null) return;
    final overridesRepo = ref.read(cardOverridesRepositoryProvider);
    if (overridesRepo == null) return;
    try {
      final overrides = await overridesRepo.fetchOverrides().timeout(
        _homeRequestTimeout,
      );
      await cache.put(
        _scopedCacheKey(ref, _cardOverridesCacheKey),
        jsonEncode({'overrides': overrides.map((o) => o.toJson()).toList()}),
      );
    } catch (_) {}
  }

  Future<void> refreshHomeSummary() async {
    if (userRepo == null) return;
    try {
      final summary = await userRepo
          .fetchHomeSummary(
            anchor: DateTime.now().toUtc(),
            timeZone: ref.read(deviceTimeZoneProvider),
          )
          .timeout(_homeRequestTimeout);
      if (summary != null) {
        await cache.put(
          _scopedCacheKey(ref, 'home_summary'),
          jsonEncode({
            'rewardsThisMonthInr': summary.rewardsThisMonth.rupees,
            'rewardsAllTimeInr': summary.rewardsAllTime.rupees,
            'transactionCount': summary.transactionCount,
            'streakDays': summary.streakDays,
          }),
        );
      }
    } catch (_) {}
  }

  Future<void> refreshTransactions() async {
    if (userRepo == null) return;
    try {
      // Refresh the canonical provider instead of writing around it. Activity
      // watches this provider, so resume/online refreshes now publish the
      // freshly fetched rows to every consumer rather than leaving an older
      // in-memory Activity result alive beside a newer SQLite snapshot.
      ref.invalidate(transactionsProvider);
      await ref.read(transactionsProvider.future).timeout(_homeRequestTimeout);
    } catch (_) {}
  }

  void refreshSecondaryDisplayData() {
    // Invalidate projections so visible consumers update. Do not eagerly run
    // eight report requests for screens the user has not opened: they read the
    // same captured history and warm their server projection when needed.
    ref.invalidate(categorySpendProvider);
    ref.invalidate(
      spendReportProvider(const SpendReportQuery.preset(SpendPeriod.month)),
    );
    ref.invalidate(bankAccountSummariesProvider);
    ref.invalidate(budgetsProvider);
    ref.invalidate(recurringReportProvider);
    ref.invalidate(loungeUsageProvider);
    ref.invalidate(currentMonthlyReportProvider);
    ref.invalidate(notificationsProvider);
  }

  refreshSecondaryDisplayData();

  await Future.wait([
    refreshUserCards(),
    refreshCatalogue(),
    refreshCategories(),
    refreshOverrides(),
    refreshHomeSummary(),
    refreshTransactions(),
  ]);
  ref.invalidate(userCardsProvider);
  ref.invalidate(catalogueProvider);
  ref.invalidate(categoriesProvider);
  ref.invalidate(cardOverridesProvider);
  ref.invalidate(homeSummaryProvider);
  ref.invalidate(lastSyncedAtProvider);
});

/// Keeps the same core snapshot refresh alive while the user is on a
/// secondary tab. Home used to be the only screen that watched this refresh,
/// so opening Wallet/Insights after a long pause could leave the app showing
/// a live-only error until Home was visited again.
final displayDataSyncLifecycleProvider = Provider<void>((ref) {
  var refreshing = false;
  var disposed = false;
  DateTime? lastStarted;
  String? lastNamespace;
  ref.onDispose(() => disposed = true);
  Future<void> refreshWhenPossible({bool force = false}) async {
    if (disposed || refreshing) return;
    if (ref.read(cacheNamespaceProvider) == 'signed-out') return;
    if (ref.read(isOnlineProvider).valueOrNull == false) return;
    final namespace = ref.read(cacheNamespaceProvider);
    final now = DateTime.now();
    if (!force &&
        lastNamespace == namespace &&
        lastStarted != null &&
        now.difference(lastStarted!) < const Duration(seconds: 15)) {
      return;
    }
    lastStarted = now;
    lastNamespace = namespace;
    refreshing = true;
    try {
      // Resume/connectivity/auth callbacks can arrive together. Do not
      // invalidate an in-flight refresh and start duplicate network work.
      ref.invalidate(homeDataRefreshProvider);
      await ref.read(homeDataRefreshProvider.future);
    } catch (_) {
      // The individual refresh tasks are best-effort. A transient failure
      // must not surface as a lifecycle error or interrupt navigation.
    } finally {
      refreshing = false;
      if (!disposed && ref.read(cacheNamespaceProvider) != namespace) {
        unawaited(refreshWhenPossible(force: true));
      }
    }
  }

  ref.listen<String>(cacheNamespaceProvider, (previous, next) {
    if (previous == 'signed-out' && next != 'signed-out') {
      unawaited(refreshWhenPossible(force: true));
    }
  });
  ref.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) {
    final cameOnline =
        previous?.valueOrNull == false && next.valueOrNull == true;
    if (cameOnline) unawaited(refreshWhenPossible(force: true));
  });

  final lifecycle = AppLifecycleListener(
    onResume: () => unawaited(refreshWhenPossible()),
  );
  ref.onDispose(lifecycle.dispose);
});

/// Privacy: user_cards/card_overrides cache entries are per-signed-in-user
/// and must not leak across a sign-out -> sign-in-as-different-user
/// sequence, same bug class already found once this session in quick-add's
/// SharedPreferences last-used-card key. catalogue/categories are public
/// and deliberately NOT cleared here.
final cacheLifecycleProvider = Provider<void>((ref) {
  ref.listen<String>(cacheNamespaceProvider, (previous, next) async {
    if (previous != 'signed-out' && next == 'signed-out') {
      final cache = await _cacheOrNull(ref);
      final namespace = previous;
      await cache?.clearPrefix('$namespace:');
    }
  });
});

/// connectivity_plus reports interface state, not internet reachability —
/// intentionally scoped that way here: this drives "should the offline
/// banner show / should the outbox try to flush," not a guarantee the
/// server is actually reachable (a flush attempt can still fail and stay
/// queued even when this reads true).
bool connectivityResultToIsOnline(List<ConnectivityResult> results) {
  return results.any((r) => r != ConnectivityResult.none);
}

final isOnlineProvider = StreamProvider<bool>((ref) {
  return Connectivity().onConnectivityChanged.map((results) {
    final online = connectivityResultToIsOnline(results);
    _lastKnownOffline = !online;
    return online;
  });
});

final outboxRepositoryProvider = FutureProvider<TransactionOutboxRepository>((
  ref,
) async {
  final namespace = ref.watch(cacheNamespaceProvider);
  final cache = await ref.watch(responseCacheProvider.future);
  final repository = TransactionOutboxRepository(
    cache.financialStore.database,
    namespace: namespace,
    financialStore: cache.financialStore,
  );
  await repository.restoreLocalEntries();
  return repository;
});

final duplicateResolutionOutboxRepositoryProvider =
    FutureProvider<DuplicateResolutionOutboxRepository>((ref) async {
      final namespace = ref.watch(cacheNamespaceProvider);
      final cache = await ref.watch(responseCacheProvider.future);
      return DuplicateResolutionOutboxRepository(
        cache.financialStore.database,
        namespace: namespace,
      );
    });

final transactionAttachmentsRepositoryProvider =
    FutureProvider<TransactionAttachmentsRepository>((ref) async {
      return TransactionAttachmentsRepository(
        await ref.watch(appDatabaseProvider.future),
      );
    });

final transactionAttachmentsProvider =
    FutureProvider.family<List<TransactionAttachment>, String>((ref, id) async {
      final repository = await ref.watch(
        transactionAttachmentsRepositoryProvider.future,
      );
      return repository.list(id);
    });

final pendingOutboxCountProvider = FutureProvider<int>((ref) async {
  final items = await (await ref.watch(
    outboxRepositoryProvider.future,
  )).pending();
  final duplicateOutbox = await ref.watch(
    duplicateResolutionOutboxRepositoryProvider.future,
  );
  return items.length + duplicateOutbox.pendingCount;
});

/// Flushes the outbox the moment connectivity comes back — read once from
/// _AppShell alongside cacheLifecycleProvider/sessionKeepAliveProvider so
/// it runs for the app's whole lifetime, not just while Home is visible.
final outboxFlushProvider = Provider<void>((ref) {
  var running = false;
  var disposed = false;
  Future<void> flush() async {
    if (running || disposed) return;
    final namespace = ref.read(cacheNamespaceProvider);
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null || ref.read(isOnlineProvider).valueOrNull == false) return;
    running = true;
    try {
      final outbox = await ref.read(outboxRepositoryProvider.future);
      if (disposed || outbox.namespace != namespace) return;
      final sent = await outbox.flush(repo);
      final duplicateOutbox = await ref.read(
        duplicateResolutionOutboxRepositoryProvider.future,
      );
      final duplicateSent = await duplicateOutbox.flush(repo);
      if (!disposed &&
          ref.read(cacheNamespaceProvider) == namespace &&
          (sent > 0 || duplicateSent > 0)) {
        ref.invalidate(pendingOutboxCountProvider);
        ref.invalidate(transactionsProvider);
        ref.invalidate(utilizationTransactionsProvider);
        ref.invalidate(homeSummaryProvider);
        ref.invalidate(duplicateCandidatesProvider);
        ref.invalidate(userCardsProvider);
        ref.invalidate(myCardsProvider);
      }
    } catch (_) {
      /* Durable entries remain queued. */
    } finally {
      running = false;
    }
  }

  ref.listen(isOnlineProvider, (_, next) {
    if (next.valueOrNull == true) unawaited(flush());
  });
  ref.listen(cacheNamespaceProvider, (_, next) {
    if (next != 'signed-out') unawaited(flush());
  });
  final lifecycle = AppLifecycleListener(onResume: () => unawaited(flush()));
  ref.onDispose(() {
    disposed = true;
    lifecycle.dispose();
  });
  unawaited(flush());
});

/// Task D-5: pending duplicate-candidate pairs; empty (not an error) when
/// signed out, same pattern as every other repository-backed provider here.
final duplicateCandidatesProvider = FutureProvider<List<DuplicateCandidate>>((
  ref,
) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  try {
    return await repo.fetchDuplicateCandidates();
  } catch (error) {
    if (isAuthenticationFailure(error)) return const [];
    rethrow;
  }
});

/// Task C-1 (C1 My Cards' active/archived filter). Deliberately a SEPARATE
/// provider from userCardsProvider above, not a parameterized version of
/// it — every other consumer (ranking, ownedCardsWithProductProvider, cap
/// assembly) must never see an archived card, and a shared family provider
/// keyed by this toggle would risk one of them silently picking up
/// showArchivedCardsProvider's current value. C1 is the only screen that
/// reads this.
final showArchivedCardsProvider = StateProvider<bool>((ref) => false);

final FutureProvider<List<UserCard>>
myCardsProvider = FutureProvider<List<UserCard>>((ref) async {
  final markReady = _financialChanges(ref, 'cards');
  try {
    final repo = ref.watch(userCardsRepositoryProvider);
    final includeArchived = ref.watch(showArchivedCardsProvider);
    if (repo == null) {
      final local = await ref.watch(localUserCardsRepositoryProvider.future);
      final catalogue = await ref.watch(catalogueProvider.future);
      final cards = await local.fetchUserCards(
        includeArchived: includeArchived,
        catalogue: catalogue,
      );
      return cards.where((card) => card.isArchived == includeArchived).toList();
    }

    // Keep Wallet consistent with Home: render the cached account snapshot
    // first. Card mutations clear it before invalidating this provider, so this
    // cannot replay a card that was just removed or replaced.
    final cached = await _readUserCardsCache(
      ref,
      includeArchived: includeArchived,
    );
    if (cached != null) return cached;

    return await _loadUserCardsWithOfflineCache(
      ref,
      repo,
      includeArchived: includeArchived,
    );
  } finally {
    markReady();
  }
});

/// Cards the user has removed from their wallet. Wallet itself reads
/// [myCardsProvider] (active cards only); this is the one surface that needs
/// archived rows, so it keeps its own include-archived read rather than
/// making every ranking/spend consumer filter them out.
///
/// Deliberately network-first through [_loadUserCardsWithOfflineCache]: the
/// shared entity cache can legitimately hold active cards only after the last
/// Wallet refresh, and treating that as "no archived cards" would wrongly
/// render an empty Deleted cards screen. The include-archived snapshot is
/// still used when the device is offline.
///
/// This build has no guest sessions — Settings is behind the auth gate — so a
/// missing repository means the user is signed out, and the screen renders its
/// sign-in state instead of reading stale local card rows.
final archivedCardsProvider = FutureProvider<List<UserCard>>((ref) async {
  final markReady = _financialChanges(ref, 'cards');
  try {
    final repo = ref.watch(userCardsRepositoryProvider);
    if (repo == null) return const [];
    return await _loadUserCardsWithOfflineCache(
      ref,
      repo,
      includeArchived: true,
    );
  } finally {
    markReady();
  }
});

Future<List<UserCard>?> _readUserCardsCache(
  Ref ref, {
  required bool includeArchived,
}) async {
  final cache = await _cacheOrNull(ref);
  final namespace = ref.read(cacheNamespaceProvider);
  cache?.financialStore.migrateLegacy(namespace);
  final stored = cache?.financialStore.entities(namespace, 'cards');
  if (stored != null && stored.isNotEmpty) {
    final key =
        '$namespace:${includeArchived ? _userCardsWithArchivedCacheKey : _userCardsCacheKey}';
    final at = await cache?.fetchedAt(key);
    if (!_isKnownOffline() &&
        (at == null ||
            cache?.needsRefresh(key) == true ||
            DateTime.now().difference(at) >= const Duration(seconds: 15)) &&
        !_backgroundCardRefreshes.containsKey(key)) {
      final repository = ref.read(userCardsRepositoryProvider);
      if (repository != null) {
        final work = repository
            .fetchUserCards(includeArchived: includeArchived)
            .then((cards) async {
              if (ref.read(cacheNamespaceProvider) == namespace) {
                await cache?.put(
                  key,
                  jsonEncode({
                    'userCards': cards.map((c) => c.toJson()).toList(),
                  }),
                );
              }
            })
            .catchError((_) {})
            .whenComplete(() => _backgroundCardRefreshes.remove(key));
        _backgroundCardRefreshes[key] = work;
        unawaited(work);
      }
    }
    return stored
        .map(UserCard.fromJson)
        .where((card) => card.isArchived == includeArchived)
        .toList();
  }
  final cacheKey = _scopedCacheKey(
    ref,
    includeArchived ? _userCardsWithArchivedCacheKey : _userCardsCacheKey,
  );
  final cached = await cache?.get(cacheKey);
  if (cached == null) return null;
  try {
    final body = jsonDecode(cached) as Map<String, dynamic>;
    final cards = (body['userCards'] as List)
        .cast<Map<String, dynamic>>()
        .map(UserCard.fromJson)
        .toList();
    return cards.where((card) => card.isArchived == includeArchived).toList();
  } catch (_) {
    try {
      await cache?.clear(cacheKey);
    } catch (_) {}
    return null;
  }
}

/// Task C-1/C-2: same join as ownedCardsWithProductProvider, but sourced
/// from myCardsProvider so C1 (with its archived toggle on) and C2 (deep-
/// linked into an archived card from C1) can both resolve a product for a
/// card ownedCardsWithProductProvider would have silently excluded.
final myCardsWithProductProvider =
    Provider<AsyncValue<List<(UserCard, CardProduct)>>>((ref) {
      final userCards = ref.watch(myCardsProvider);
      final catalogue = ref.watch(catalogueProvider);

      final userCardList = userCards.valueOrNull;
      final catalogueList = catalogue.valueOrNull;
      if (userCardList == null || catalogueList == null) {
        final combinedError = userCards.error ?? catalogue.error;
        if (combinedError != null) {
          return AsyncValue.error(
            combinedError,
            userCards.stackTrace ?? catalogue.stackTrace ?? StackTrace.current,
          );
        }
        return const AsyncValue.loading();
      }

      final products = {for (final p in catalogueList) p.id: p};
      final pairs = [
        for (final uc in userCardList)
          if (products[uc.cardProductId] case final product?) (uc, product),
      ];
      return AsyncValue.data(pairs);
    });

/// Task 7: pairs each owned [UserCard] (consumption/progress state) with its
/// [CardProduct] (the actual rule DEFINITIONS — cap values, milestone
/// thresholds, forex/fuel terms). Both are already fetched separately by
/// userCardsProvider/catalogueProvider; every Insights screen (Caps,
/// Milestones, Billing Float, Benefits Cheat Sheet) needs both halves
/// together, so this is the one join point rather than four screens
/// re-deriving it.
final ownedCardsWithProductProvider =
    Provider<AsyncValue<List<(UserCard, CardProduct)>>>((ref) {
      final userCards = ref.watch(userCardsProvider);
      final catalogue = ref.watch(catalogueProvider);

      final userCardList = userCards.valueOrNull;
      final catalogueList = catalogue.valueOrNull;
      if (userCardList == null || catalogueList == null) {
        final combinedError = userCards.error ?? catalogue.error;
        if (combinedError != null) {
          return AsyncValue.error(
            combinedError,
            userCards.stackTrace ?? catalogue.stackTrace ?? StackTrace.current,
          );
        }
        return const AsyncValue.loading();
      }

      final products = {for (final p in catalogueList) p.id: p};
      final pairs = [
        for (final uc in userCardList)
          if (products[uc.cardProductId] case final product?) (uc, product),
      ];
      return AsyncValue.data(pairs);
    });

/// Task G-0 (scoped to what E3 needs): wraps `creditUtilization()` per owned
/// card that has a [UserCard.creditLimit] set. The balance input is the
/// active credit-card spend logged in PandaPay since the current statement
/// cycle (or the current calendar month when no statement day is known).
/// It deliberately excludes UPI/debit/cash, transfers, ignored rows, and
/// cardless transactions. This is still a tracked-spend estimate, not the
/// issuer's statement balance, but it is now the same transaction ledger the
/// rest of the app reports instead of reward-cap consumption.
final creditUtilizationProvider = Provider<Map<String, UtilizationResult>>((
  ref,
) {
  final pairs =
      ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
  final transactions =
      ref.watch(utilizationTransactionsProvider).valueOrNull ?? const [];
  final now = ref.watch(clockProvider).now();
  final result = <String, UtilizationResult>{};
  for (final (userCard, _) in pairs) {
    final limit = userCard.creditLimit;
    if (limit == null || limit.isZero) continue;
    final trackedSpend = _trackedCreditCardSpend(userCard, transactions, now);
    result[userCard.id] = creditUtilization(trackedSpend, limit);
  }
  return result;
});

Money _trackedCreditCardSpend(
  UserCard card,
  List<TransactionEntry> transactions,
  DateTime now,
) => _cardSpendSummary(card, transactions, now).cycleTotal;

DateTime _previousStatementOccurrence(int day, DateTime from) {
  final thisMonth = DateTime(
    from.year,
    from.month,
    _clampDay(from.year, from.month, day),
  );
  if (!thisMonth.isAfter(from)) return thisMonth;
  return DateTime(
    from.year,
    from.month - 1,
    _clampDay(from.year, from.month - 1, day),
  );
}

int _clampDay(int year, int month, int day) {
  final lastDay = DateTime(year, month + 1, 0).day;
  return day > lastDay ? lastDay : day;
}

/// Task G-0 (the rest of it — E3's slice landed in Chunk 36): G2's amount
/// input. A dedicated provider rather than reusing enteredAmountProvider —
/// Home's amount field and the split planner's amount are two different
/// user intents (one txn vs. a total to divide) that happen to share a
/// widget shape; sharing the same provider would mean typing on Home
/// silently changed what G2 last planned, and vice versa.
final splitPlannerAmountProvider = StateProvider<Money>(
  (ref) => const Money.zero(),
);

final splitOptimizerProvider = Provider<SplitOptimizer>(
  (ref) => const SplitOptimizer(),
);

/// G2 Multi-Card Split Planner. `SplitOptimizer.optimize()` (calculators.dart)
/// was already fully built with zero callers per the plan's own audit — this
/// is the "build the screen" provider the plan asked for, not new algorithm
/// work. `utilizationCeiling` is derived from creditUtilizationProvider's
/// same 30%-threshold constant so the split "respects... utilization" per
/// spec wording, keyed by each owned-card snapshot so two cards of the same
/// product retain independent headroom. Cards with no credit limit are absent
/// from the ceiling map, which SplitOptimizer already treats as effectively
/// unlimited (its own default when a key is missing).
final splitPlanProvider = Provider<List<SplitAllocation>>((ref) {
  final amount = ref.watch(splitPlannerAmountProvider);
  final pairs =
      ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
  if (amount.isZero || pairs.isEmpty) return const [];

  final snapshots = [
    for (final (uc, product) in pairs)
      _userCardSnapshots([product], [uc]).single,
  ];
  final transactions =
      ref.watch(utilizationTransactionsProvider).valueOrNull ?? const [];
  final now = ref.watch(clockProvider).now();

  final utilizationCeiling = <CardSnapshot, Money>{};
  for (var i = 0; i < pairs.length; i++) {
    final userCard = pairs[i].$1;
    final limit = userCard.creditLimit;
    if (limit == null || limit.isZero) continue;
    final threshold = limit * 0.30;
    final trackedSpend = _trackedCreditCardSpend(userCard, transactions, now);
    final headroom = threshold - trackedSpend;
    utilizationCeiling[snapshots[i]] = headroom.isNegative
        ? const Money.zero()
        : headroom;
  }

  // No category filter: G2's "total amount to split" is deliberately
  // category-agnostic per spec wording ("total amount... optimal split") —
  // unlike Home's per-transaction category chips, the split planner ranks
  // each card on its base rate plus whatever caps/travel-mode apply, not a
  // specific spend category the user hasn't been asked to pick here.
  final optimizer = ref.watch(splitOptimizerProvider);
  final baseContext = RecommendationContext(
    amount: amount,
    rail: TxnRail.swipe,
    travelMode: ref.watch(travelModeProvider),
    now: ref.watch(clockProvider).now(),
  );
  return optimizer.optimize(
    amount,
    baseContext,
    snapshots,
    snapshotCeilings: utilizationCeiling,
  );
});

/// G3 EMI Advisor. `adviseEmi()` (calculators.dart) already returns exactly
/// the shape the screen needs — this family just supplies its one
/// non-obvious input, `forgoneRewardValue`: what the chosen card would have
/// earned at its own base rate had this amount been paid outright instead
/// of put on EMI, via the same RecommendationEngine every other ranking
/// path in this app already uses (not a second, EMI-specific reward
/// calculation). Spec doesn't say whether "the card" is user-picked or the
/// current top recommendation — this pass defaults to letting the user pick
/// from their own wallet (the EMI screen's own card dropdown), since EMI is
/// normally initiated from an existing purchase on a specific card, not a
/// fresh "which card should I use" decision.
typedef EmiAdviceParams = ({
  String cardProductId,
  double principalRupees,
  int tenureMonths,
  double annualInterestRatePercent,
});

final emiAdviceProvider = Provider.family<EmiAdvice?, EmiAdviceParams>((
  ref,
  params,
) {
  if (params.principalRupees <= 0 || params.tenureMonths <= 0) return null;
  final pairs =
      ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
  final match = pairs.firstWhereOrNull((p) => p.$2.id == params.cardProductId);
  if (match == null) return null;
  final (userCard, product) = match;

  final engine = ref.watch(recommendationEngineProvider);
  final principal = Money.fromRupees(params.principalRupees);
  final snapshot = _userCardSnapshots([product], [userCard]).first;
  final rec = engine.rank(
    RecommendationContext(
      amount: principal,
      rail: TxnRail.swipe,
      now: ref.watch(clockProvider).now(),
    ),
    [snapshot],
  ).first;
  final forgoneRewardValue = rec.isExcluded
      ? const Money.zero()
      : rec.expectedValue;

  return adviseEmi(
    principal: principal,
    annualInterestRatePercent: params.annualInterestRatePercent,
    tenureMonths: params.tenureMonths,
    forgoneRewardValue: forgoneRewardValue,
  );
});

/// G4 Emergency Card Info. Public — no accessTokenProvider gate, unlike
/// every other repository provider in this file, because this data has no
/// per-user sensitivity and the spec requires it reachable with zero login
/// (see api/'s GET /issuer-emergency-contacts doc-comment).
final emergencyContactsRepositoryProvider =
    Provider<EmergencyContactsRepository>((ref) {
      return HttpEmergencyContactsRepository(baseUrl: _apiBaseUrl);
    });

final emergencyContactsCacheProvider = Provider<EmergencyContactsCache>(
  (ref) => EmergencyContactsCache(),
);

/// Never throws (see EmergencyContactsService.load's own doc-comment) —
/// always resolves to real, renderable content, live/cached/bundled, so
/// G4's screen has no "offline" error path to design around, only a
/// data-freshness banner reflecting whichever of the three it got.
final emergencyContactsProvider = FutureProvider<EmergencyContactsResult>((
  ref,
) async {
  final service = EmergencyContactsService(
    repository: ref.watch(emergencyContactsRepositoryProvider),
    cache: ref.watch(emergencyContactsCacheProvider),
  );
  return service.load();
});

/// Task E6: lounge visits are owner-scoped server-side; empty (not an
/// error) when signed out, same pattern as userCardsProvider.
final loungeUsageProvider = FutureProvider<List<LoungeVisit>>((ref) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  final cache = await _cacheOrNull(ref);
  final key = _scopedCacheKey(ref, 'lounge_usage');
  final cached = await _readCacheOrNull(ref, cache, key);
  List<LoungeVisit> decode(CachedResponse snapshot) =>
      ((jsonDecode(snapshot.rawJson) as Map<String, dynamic>)['loungeUsage']
              as List)
          .cast<Map<String, dynamic>>()
          .map(LoungeVisit.fromJson)
          .toList();
  if (_isKnownOffline() && cached != null) return decode(cached);
  try {
    final visits = await repo.fetchLoungeUsage();
    try {
      await cache?.put(
        key,
        jsonEncode({
          'loungeUsage': visits.map((visit) => visit.toJson()).toList(),
        }),
      );
    } catch (_) {}
    return visits;
  } catch (error) {
    if (!_canUseReadCache(error) || cached == null) {
      if (_isAuthenticationFailure(error)) {
        return const [];
      }
      rethrow;
    }
    try {
      return decode(cached);
    } catch (_) {
      await cache?.clear(key);
      rethrow;
    }
  }
});

/// Task C-6: per-card points ledger, family-keyed by userCardId — C6 shows
/// every owned card's programs on one screen, each needing its own fetch
/// (unlike userCardsProvider's single lifetime SUM, this is the individual
/// rows behind it). Empty (not an error) when signed out.
final pointsLedgerProvider =
    FutureProvider.family<List<PointsLedgerEntry>, String>((
      ref,
      userCardId,
    ) async {
      final repo = ref.watch(userCardsRepositoryProvider);
      if (repo == null) return const [];
      final cache = await _cacheOrNull(ref);
      final key = _scopedCacheKey(ref, 'points_ledger:$userCardId');
      final cached = await _readCacheOrNull(ref, cache, key);
      List<PointsLedgerEntry> decode(CachedResponse snapshot) =>
          ((jsonDecode(snapshot.rawJson) as Map<String, dynamic>)['entries']
                  as List)
              .cast<Map<String, dynamic>>()
              .map(PointsLedgerEntry.fromJson)
              .toList();
      if (_isKnownOffline() && cached != null) return decode(cached);
      try {
        final entries = await repo.fetchPointsLedger(userCardId);
        try {
          await cache?.put(
            key,
            jsonEncode({
              'entries': entries.map((entry) => entry.toJson()).toList(),
            }),
          );
        } catch (_) {}
        return entries;
      } catch (error) {
        if (isAuthenticationFailure(error)) return const [];
        if (!_canUseReadCache(error) || cached == null) rethrow;
        try {
          return decode(cached);
        } catch (_) {
          await cache?.clear(key);
          rethrow;
        }
      }
    });

/// Task E9: current month's report, recomputed on demand server-side each
/// time this is watched/invalidated (see GET /monthly-reports' doc-comment
/// for why only the current month is safe to always-recompute).
final FutureProvider<MonthlyReport?>
currentMonthlyReportProvider = FutureProvider<MonthlyReport?>((ref) async {
  final markReady = _financialChanges(ref, 'transactions');
  try {
    final repo = ref.watch(userCardsRepositoryProvider);
    if (repo == null) return null;
    final cache = await _cacheOrNull(ref);
    final now = DateTime.now();
    final key = _scopedCacheKey(
      ref,
      'monthly_report:${now.year}-${now.month.toString().padLeft(2, '0')}',
    );
    final cached = await _readCacheOrNull(ref, cache, key);
    MonthlyReport? decode(CachedResponse snapshot) {
      final body = jsonDecode(snapshot.rawJson) as Map<String, dynamic>;
      final raw = body['monthlyReport'];
      return raw == null
          ? null
          : MonthlyReport.fromJson(raw as Map<String, dynamic>);
    }

    if (cached == null ||
        cache?.financialStore.hasPendingTransactions(
              ref.read(cacheNamespaceProvider),
            ) ==
            true) {
      final local = await _buildLocalMonthlyReport(ref, now);
      if (local != null) {
        ref.read(transactionsProvider);
        return local;
      }
    }
    if (cached != null) {
      try {
        final saved = decode(cached);
        _warmDisplay(
          ref,
          cache,
          key,
          cached.fetchedAt,
          repo.fetchMonthlyReport,
          (report) => {'monthlyReport': report?.toJson()},
        );
        return saved;
      } catch (_) {
        await cache?.clear(key);
      }
    }

    try {
      final report = await repo.fetchMonthlyReport();
      try {
        await cache?.put(key, jsonEncode({'monthlyReport': report?.toJson()}));
      } catch (_) {}
      return report;
    } catch (error) {
      if (cached == null) {
        final local = await _buildLocalMonthlyReport(ref, now);
        if (local != null) return local;
      }
      if (!_canUseReadCache(error) || cached == null) {
        if (_isAuthenticationFailure(error)) {
          final local = await _buildLocalMonthlyReport(ref, now);
          if (local != null) {
            return local;
          }
          // There is no trustworthy local history yet. The reward screen will
          // show its existing "building your first report" state rather than a
          // generic session error.
          return null;
        }
        rethrow;
      }
      try {
        return decode(cached);
      } catch (_) {
        await cache?.clear(key);
        rethrow;
      }
    }
  } finally {
    markReady();
  }
});

/// Design 01's header figures (this month / all time / streak) — see
/// `GET /home-summary` in api/src/index.js. Null while signed out: guest
/// mode keeps cards locally but has no transaction history to aggregate,
/// and the header hides the figures rather than showing ₹0 as if that were
/// a measured result.
final homeSummaryProvider = FutureProvider<HomeSummary?>((ref) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return null;
  final key = _scopedCacheKey(ref, 'home_summary');
  final cache = await _cacheOrNull(ref);
  final cached = await _readCacheOrNull(ref, cache, key);
  if (cached != null) {
    try {
      return HomeSummary.fromJson(
        jsonDecode(cached.rawJson) as Map<String, dynamic>,
      );
    } catch (_) {
      // The live request below repairs an invalid snapshot.
    }
  }
  try {
    final summary = await repo
        .fetchHomeSummary(
          anchor: DateTime.now().toUtc(),
          timeZone: ref.watch(deviceTimeZoneProvider),
        )
        .timeout(_homeRequestTimeout);
    if (summary != null) {
      try {
        await cache?.put(
          key,
          jsonEncode({
            'rewardsThisMonthInr': summary.rewardsThisMonth.rupees,
            'rewardsAllTimeInr': summary.rewardsAllTime.rupees,
            'transactionCount': summary.transactionCount,
            'streakDays': summary.streakDays,
          }),
        );
      } catch (_) {
        // A cache write must never make a successful header unusable.
      }
    }
    return summary;
  } catch (error) {
    if (isAuthenticationFailure(error)) return null;
    if (!_canUseStaleCache(error)) rethrow;
    if (cached == null) rethrow;
    return HomeSummary.fromJson(
      jsonDecode(cached.rawJson) as Map<String, dynamic>,
    );
  }
});

/// A Home visit is the user's explicit, foreground check-in for the referral
/// activity streak. Home watches this date-keyed provider only while that
/// screen is mounted; signed receipts are fetched live and never cached.
final homeEngagementCheckInProvider = FutureProvider.family<void, String>((
  ref,
  activityDay,
) async {
  final repository = ref.watch(userCardsRepositoryProvider);
  if (repository == null || activityDay.isEmpty) return;

  try {
    final recorded = await repository
        .recordHomeEngagementCheckIn(
          anchor: ref.read(clockProvider).now(),
          timeZone: ref.read(deviceTimeZoneProvider),
        )
        .timeout(_homeRequestTimeout);
    if (recorded) {
      ref.invalidate(referralsProvider);
      ref.invalidate(referralDashboardProvider(ref.read(referralYearProvider)));
    }
  } catch (_) {
    // Check-in is an optional referral enhancement. Network or campaign
    // failures must never block Home or replace the transaction streak.
  }
});

/// Bank-account snapshots derived from SMS observations. Empty when signed
/// out or when no imported SMS has exposed a masked source account yet.
final bankAccountSummariesProvider = FutureProvider<List<BankAccountSummary>>((
  ref,
) async {
  var ready = false;
  ref.listen(financialStoreRevisionProvider('observations'), (_, next) {
    if (ready) ref.invalidateSelf();
  });
  ref.listen(financialStoreRevisionProvider('manual_bank_balances'), (_, next) {
    if (ready) ref.invalidateSelf();
  });
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  const cacheKey = 'bank_account_summaries';
  final cache = await _cacheOrNull(ref);
  final localAccounts = cache?.financialStore.bankAccounts(
    ref.read(cacheNamespaceProvider),
  );
  final manualBalances =
      cache?.financialStore.manualBankBalances(
        ref.read(cacheNamespaceProvider),
      ) ??
      const {};
  final key = _scopedCacheKey(ref, cacheKey);
  final cached = await _readCacheOrNull(ref, cache, key);
  // UPI-platform families (SBIUPI & friends) quote the counterparty's masked
  // account, never the user's — they mint phantom account rows. Applied at
  // every list source (cache decode + server merge); the local store filters
  // its own rows in bankAccounts(). Checked on the RAW issuer strings —
  // canonicalBankSender collapses 'sbiupi' to 'sbi', hiding the marker.
  // ponytail: remove once server dedupes.
  bool isNonDepositAccount(BankAccountSummary account) =>
      RegExp(r'upi|axio').hasMatch(
        [
          account.issuerSlug,
          account.issuerShortName,
          account.issuerName,
        ].whereType<String>().join(' ').toLowerCase(),
      );

  List<BankAccountSummary> decode(CachedResponse snapshot) =>
      ((jsonDecode(snapshot.rawJson) as Map<String, dynamic>)['accounts']
              as List)
          .cast<Map<String, dynamic>>()
          .map(BankAccountSummary.fromJson)
          .where((account) => !isNonDepositAccount(account))
          .toList();

  bool sameAccount(BankAccountSummary a, BankAccountSummary b) {
    if (a.accountLast4 != b.accountLast4) return false;
    // DLT sender IDs differ per channel (AD-HDFCBK-S vs AX-HDFCBK vs the
    // canonical code the local store already uses); compare on the canonical
    // bank code so one real account never splits across rows.
    final issuerA = canonicalBankSender(
      a.issuerSlug ?? a.issuerShortName ?? a.issuerName,
    );
    final issuerB = canonicalBankSender(
      b.issuerSlug ?? b.issuerShortName ?? b.issuerName,
    );
    return issuerA.isEmpty || issuerB.isEmpty || issuerA == issuerB;
  }

  List<BankAccountSummary> mergeAccounts(
    List<BankAccountSummary> local,
    List<BankAccountSummary> remote,
  ) {
    // UPI-platform families from rows the server parsed before the exclusion
    // existed — drop them at the merge point as well.
    remote = remote.where((r) => !isNonDepositAccount(r)).toList();
    final merged = [...local];
    for (final incoming in remote) {
      final index = merged.indexWhere(
        (existing) => sameAccount(existing, incoming),
      );
      if (index < 0) {
        merged.add(incoming);
        continue;
      }
      final existing = merged[index];
      final existingAt = existing.latestSmsAt;
      final incomingAt = incoming.latestSmsAt;
      final incomingIsNewer =
          existingAt == null ||
          (incomingAt != null && incomingAt.isAfter(existingAt));
      final primary = incomingIsNewer ? incoming : existing;
      final secondary = incomingIsNewer ? existing : incoming;
      final latestAt = existingAt == null
          ? incomingAt
          : incomingAt == null
          ? existingAt
          : (incomingAt.isAfter(existingAt) ? incomingAt : existingAt);
      final existingBalanceAt = existing.latestBalanceSmsAt;
      final incomingBalanceAt = incoming.latestBalanceSmsAt;
      final balanceFromIncoming =
          existingBalanceAt == null ||
          (incomingBalanceAt != null &&
              incomingBalanceAt.isAfter(existingBalanceAt));
      final balancePrimary = balanceFromIncoming ? incoming : existing;
      final balanceSecondary = balanceFromIncoming ? existing : incoming;
      final latestBalanceAt = existingBalanceAt == null
          ? incomingBalanceAt
          : incomingBalanceAt == null
          ? existingBalanceAt
          : (incomingBalanceAt.isAfter(existingBalanceAt)
                ? incomingBalanceAt
                : existingBalanceAt);
      merged[index] = BankAccountSummary(
        accountLast4: primary.accountLast4,
        availableBalance:
            balancePrimary.availableBalance ??
            balanceSecondary.availableBalance,
        latestBalanceSmsAt: latestBalanceAt,
        latestSmsAt: latestAt,
        smsCount: existing.smsCount > incoming.smsCount
            ? existing.smsCount
            : incoming.smsCount,
        issuerSlug: primary.issuerSlug ?? secondary.issuerSlug,
        issuerName: primary.issuerName ?? secondary.issuerName,
        issuerShortName: primary.issuerShortName ?? secondary.issuerShortName,
        issuerLogoUrl: primary.issuerLogoUrl ?? secondary.issuerLogoUrl,
        isBalanceManuallySet: primary.isBalanceManuallySet,
        manualBalanceUpdatedAt: primary.manualBalanceUpdatedAt,
      );
    }
    return merged;
  }

  List<BankAccountSummary> applyManualBalances(
    List<BankAccountSummary> accounts,
  ) => accounts.map((account) {
    final issuer = canonicalBankSender(
      account.issuerSlug ?? account.issuerShortName ?? account.issuerName,
    );
    final manual = manualBalances['$issuer:${account.accountLast4}'];
    if (manual == null) return account;
    return BankAccountSummary(
      accountLast4: account.accountLast4,
      availableBalance: manual.balance,
      latestBalanceSmsAt: account.latestBalanceSmsAt,
      latestSmsAt: account.latestSmsAt,
      smsCount: account.smsCount,
      issuerSlug: account.issuerSlug,
      issuerName: account.issuerName,
      issuerShortName: account.issuerShortName,
      issuerLogoUrl: account.issuerLogoUrl,
      isBalanceManuallySet: true,
      manualBalanceUpdatedAt: manual.updatedAt,
    );
  }).toList();

  if (_isKnownOffline()) {
    final offlineAccounts = localAccounts != null && localAccounts.isNotEmpty
        ? localAccounts
        : cached != null
        ? decode(cached)
        : null;
    if (offlineAccounts != null) {
      final known = {
        for (final account in offlineAccounts)
          '${canonicalBankSender(account.issuerSlug ?? account.issuerShortName ?? account.issuerName)}:${account.accountLast4}',
      };
      return applyManualBalances([
        ...offlineAccounts,
        for (final manual in manualBalances.entries)
          if (!known.contains(manual.key))
            BankAccountSummary(
              accountLast4: manual.key.split(':').last,
              availableBalance: manual.value.balance,
              latestBalanceSmsAt: null,
              latestSmsAt: null,
              smsCount: 0,
              issuerSlug: manual.key.split(':').first,
              issuerShortName: bankDisplayLabel(manual.key.split(':').first),
              isBalanceManuallySet: true,
              manualBalanceUpdatedAt: manual.value.updatedAt,
            ),
      ]);
    }
  }
  try {
    final accounts = await repo.fetchBankAccountSummaries().timeout(
      _homeRequestTimeout,
    );
    final combined = mergeAccounts(localAccounts ?? const [], accounts);
    try {
      await cache?.put(
        key,
        jsonEncode({
          'accounts': combined
              .map(
                (account) => {
                  'accountLast4': account.accountLast4,
                  'availableBalanceInr': account.availableBalance?.rupees,
                  'latestBalanceSmsAt': account.latestBalanceSmsAt
                      ?.toIso8601String(),
                  'latestSmsAt': account.latestSmsAt?.toIso8601String(),
                  'smsCount': account.smsCount,
                  'issuerSlug': account.issuerSlug,
                  'issuerName': account.issuerName,
                  'issuerShortName': account.issuerShortName,
                  'issuerLogoUrl': account.issuerLogoUrl,
                },
              )
              .toList(),
        }),
      );
    } catch (_) {}
    ready = true;
    final known = {
      for (final account in combined)
        '${canonicalBankSender(account.issuerSlug ?? account.issuerShortName ?? account.issuerName)}:${account.accountLast4}',
    };
    return applyManualBalances([
      ...combined,
      for (final manual in manualBalances.entries)
        if (!known.contains(manual.key))
          BankAccountSummary(
            accountLast4: manual.key.split(':').last,
            availableBalance: manual.value.balance,
            latestBalanceSmsAt: null,
            latestSmsAt: null,
            smsCount: 0,
            issuerSlug: manual.key.split(':').first,
            issuerShortName: bankDisplayLabel(manual.key.split(':').first),
            isBalanceManuallySet: true,
            manualBalanceUpdatedAt: manual.value.updatedAt,
          ),
    ]);
  } catch (error) {
    if (localAccounts != null && localAccounts.isNotEmpty) {
      ready = true;
      return applyManualBalances(localAccounts);
    }
    if (!_canUseReadCache(error) || cached == null) {
      if (_isAuthenticationFailure(error)) {
        return const [];
      }
      rethrow;
    }
    try {
      return applyManualBalances(decode(cached));
    } catch (_) {
      await cache?.clear(key);
      rethrow;
    }
  }
});

/// Per-card credit-card bill state derived from imported bank SMS — the
/// bill-generated message ("Total amount due ₹X, due date dd MMM") and the
/// card-bill payment receipts. Reactive to both SMS capture and the
/// transaction snapshot so a payment flips its bill to Paid on the next
/// rebuild. Empty map when signed out.
final cardBillLedgerProvider = FutureProvider<Map<String, CardBillLedger>>((
  ref,
) async {
  final markReady = _financialChanges(ref, 'observations');
  final markTransactionsReady = _financialChanges(ref, 'transactions');
  final repo = ref.watch(userCardsRepositoryProvider);
  List<UserCard> cards;
  try {
    cards = await ref.watch(myCardsProvider.future);
  } catch (_) {
    // No cards → no bill can attach; the ledger waits for the card list.
    cards = const [];
  }
  final now = ref.watch(clockProvider).now();
  final cache = await _cacheOrNull(ref);
  final store = cache?.financialStore;
  final namespace = ref.watch(cacheNamespaceProvider);
  store?.migrateLegacy(namespace);

  final evidence = <CardBillEvidence>[];
  final billAssignments =
      store?.cardBillAssignments(namespace) ??
      const <String, Map<String, dynamic>>{};
  DateTime? earliestAnchor;
  for (final obs
      in store?.entities(namespace, 'sms_observations') ?? const []) {
    if (obs['event_type'] != 'bill') continue;
    final sourceId = obs['id'] as String?;
    final correction = billAssignments[sourceId];
    final selectedId = correction?['user_card_id'] as String?;
    final chosenCardId = cards.any((card) => card.id == selectedId)
        ? selectedId
        : null;
    // Only admit observations with positive credit-card evidence into the
    // card-bill ledger. Bills delivered via aggregator senders (MYTNEU,
    // TNBPAY) also carry utility bills; sender-family alone is not enough.
    final hasCcEvidence =
        chosenCardId != null ||
        obs['card_last4'] != null ||
        _isCreditCardBillObs(obs);
    if (!hasCcEvidence) continue;
    final parsedStatement = DateTime.tryParse(
      obs['statement_date'] as String? ?? '',
    );
    final statementDateExplicit = obs['statement_date_explicit'] == true;
    final received = DateTime.tryParse(obs['received_at'] as String? ?? '');
    final anchor = statementDateExplicit
        ? parsedStatement
        : (received ?? parsedStatement);
    if (anchor == null) continue;
    final correctedStatement = DateTime.tryParse(
      correction?['statement_date'] as String? ?? '',
    );
    final correctedDue = DateTime.tryParse(
      correction?['due_date'] as String? ?? '',
    );
    earliestAnchor = earliestAnchor == null || anchor.isBefore(earliestAnchor)
        ? anchor
        : earliestAnchor;
    evidence.add(
      CardBillEvidence(
        sourceId: sourceId,
        userCardId: chosenCardId,
        cardLast4: obs['card_last4'] as String?,
        billerName: obs['biller_name'] as String?,
        family: obs['sender_bank'] as String?,
        statementDate: correctedStatement ?? anchor,
        statementDateExplicit:
            correctedStatement != null ||
            (statementDateExplicit && parsedStatement != null),
        dueDate:
            correctedDue ?? DateTime.tryParse(obs['due_date'] as String? ?? ''),
        amountDue: _moneyFromPaise(
          correction?['amount_due_paise'] ?? obs['amount_due_paise'],
        ),
        minimumDue: _moneyFromPaise(obs['minimum_due_paise']),
        confidence: (obs['confidence'] as num?)?.toDouble() ?? 0.5,
        isAutopay: obs['is_autopay'] == true,
      ),
    );
  }

  var payments = const <TransactionEntry>[];
  if (repo != null && earliestAnchor != null) {
    final from = earliestAnchor.subtract(const Duration(days: 92)).toUtc();
    try {
      payments = await loadTransactionsWithOfflineCache(
        ref,
        repo: repo,
        cacheKey: 'transactions:bill_payments',
        from: from,
      );
    } catch (_) {
      payments = const [];
    }
    if (ref.read(cacheNamespaceProvider) != namespace) return const {};
  }

  var allTxns = payments;
  if (allTxns.isEmpty && store != null) {
    final localRows = store.entities(namespace, 'transactions');
    allTxns = [for (final raw in localRows) TransactionEntry.fromJson(raw)];
  }

  final usable = [
    for (final txn in allTxns)
      if (isCardBillPaymentTxn(txn)) txn,
  ];
  markReady();
  markTransactionsReady();
  if (evidence.isEmpty && usable.isEmpty) return const {};
  return deriveCardBills(
    cards: cards,
    evidence: evidence,
    payments: usable,
    transactions: allTxns,
    now: now,
  );
});

final cardBillReviewItemsProvider = FutureProvider<List<CardBillReviewItem>>((
  ref,
) async {
  final ledgers = await ref.watch(cardBillLedgerProvider.future);
  final cache = await _cacheOrNull(ref);
  final store = cache?.financialStore;
  if (store == null) return const [];
  final namespace = ref.watch(cacheNamespaceProvider);
  final assignments = store.cardBillAssignments(namespace);
  final linkedSources = {
    for (final ledger in ledgers.values)
      for (final bill in ledger.history) ...bill.sourceIds,
  };
  final rows = <CardBillReviewItem>[];
  for (final obs in store.entities(namespace, 'sms_observations')) {
    if (obs['event_type'] != 'bill' ||
        (obs['card_last4'] == null && !_isCreditCardBillObs(obs))) {
      continue;
    }
    final id = obs['id'] as String?;
    if (id == null ||
        (linkedSources.contains(id) && !assignments.containsKey(id))) {
      continue;
    }
    final correction = assignments[id];
    final received = DateTime.tryParse(obs['received_at'] as String? ?? '');
    if (received == null) continue;
    rows.add(
      CardBillReviewItem(
        id: id,
        sender: obs['sender_bank'] as String? ?? '',
        billerName: obs['biller_name'] as String?,
        body: obs['sample_body'] as String?,
        receivedAt: received,
        dueDate:
            DateTime.tryParse(correction?['due_date'] as String? ?? '') ??
            DateTime.tryParse(obs['due_date'] as String? ?? ''),
        statementDate:
            DateTime.tryParse(correction?['statement_date'] as String? ?? '') ??
            (obs['statement_date_explicit'] == true
                ? DateTime.tryParse(obs['statement_date'] as String? ?? '')
                : null),
        amountDue: _moneyFromPaise(
          correction?['amount_due_paise'] ?? obs['amount_due_paise'],
        ),
        assignedCardId: correction?['user_card_id'] as String?,
      ),
    );
  }
  rows.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
  return rows;
});

/// Returns true when an sms_observations row carries positive evidence that
/// it describes a credit-card bill (not a utility bill routed via an
/// aggregator sender such as MYTNEU or TNBPAY).
///
/// A row qualifies when it has an explicit [card_last4], or when its
/// [reason_codes] contain 'credit_card_bill' (emitted by the local parser
/// whenever "credit card" or "card bill" language appears in the body), or
/// when the stored [biller_name] contains those phrases.
bool _isCreditCardBillObs(Map<String, dynamic> obs) {
  final codes = obs['reason_codes'];
  if (codes is List && codes.contains('credit_card_bill')) return true;
  final biller = ((obs['biller_name'] as String?) ?? '').toLowerCase();
  return biller.contains('credit card') || biller.contains('card bill');
}

Money? _moneyFromPaise(Object? value) {
  final paise = (value as num?)?.toInt();
  if (paise == null || paise <= 0) return null;
  return Money.fromPaise(paise);
}

/// Design 19's notification inbox. Empty (not an error) when signed out —
/// the inbox lives server-side, so guest mode simply has none.
final notificationsProvider =
    FutureProvider<({List<AppNotification> items, int unreadCount})>((
      ref,
    ) async {
      final repo = ref.watch(userCardsRepositoryProvider);
      if (repo == null) {
        return (items: const <AppNotification>[], unreadCount: 0);
      }
      final cache = await _cacheOrNull(ref);
      final key = _scopedCacheKey(ref, 'notifications');
      final cached = await _readCacheOrNull(ref, cache, key);
      ({List<AppNotification> items, int unreadCount}) decode(
        CachedResponse snapshot,
      ) {
        final body = jsonDecode(snapshot.rawJson) as Map<String, dynamic>;
        return (
          items: ((body['notifications'] as List?) ?? const [])
              .cast<Map<String, dynamic>>()
              .map(AppNotification.fromJson)
              .toList(),
          unreadCount: (body['unreadCount'] as num?)?.toInt() ?? 0,
        );
      }

      if (_isKnownOffline() && cached != null) return decode(cached);

      try {
        final inbox = await repo.fetchNotifications();
        try {
          await cache?.put(
            key,
            jsonEncode({
              'notifications': inbox.items
                  .map((item) => item.toJson())
                  .toList(),
              'unreadCount': inbox.unreadCount,
            }),
          );
        } catch (_) {}
        return inbox;
      } catch (error) {
        if (isAuthenticationFailure(error)) {
          return (items: const <AppNotification>[], unreadCount: 0);
        }
        if (!_canUseReadCache(error) || cached == null) rethrow;
        try {
          return decode(cached);
        } catch (_) {
          await cache?.clear(key);
          rethrow;
        }
      }
    });

/// Records an inbox entry for something the app itself just observed, and
/// refreshes the inbox so the badge updates immediately.
///
/// Deliberately a helper rather than a side effect inside
/// `UserCardsRepository.addCard`: "add a card" and "tell the user a card was
/// added" are different decisions, and a repository that silently writes
/// notifications is one you can't call from a bulk import without spamming
/// someone's inbox. Failures are swallowed — a missing read-receipt must
/// never fail the action that earned it.
Future<void> recordAppNotification(
  // Typed loosely on purpose: `Ref` and `WidgetRef` both expose read() and
  // invalidate() but share no supertype, and this is called from both a
  // widget and (in future) a provider body.
  dynamic ref, {
  required String category,
  required String title,
  String? body,
  String severity = 'info',
  String? deepLink,
  String? dedupeKey,
}) async {
  final repo = ref.read(userCardsRepositoryProvider);
  if (repo == null) return; // guest mode has no server-side inbox
  try {
    await repo.recordNotification(
      category: category,
      title: title,
      body: body,
      severity: severity,
      deepLink: deepLink,
      dedupeKey: dedupeKey,
    );
    ref.invalidate(notificationsProvider);
  } catch (_) {
    // Intentionally silent — see the doc comment.
  }
}

/// Just the badge count, so a widget showing the badge doesn't rebuild on
/// every unrelated change to the list itself.
final unreadNotificationCountProvider = Provider<int>((ref) {
  return ref.watch(notificationsProvider).valueOrNull?.unreadCount ?? 0;
});

/// Task H3 (moved from notification_settings_screen.dart, which owns the
/// write side): same null-when-signed-out pattern as
/// userCardsRepositoryProvider above. notification_gate.dart (Part B) reads
/// these directly — it needs the exact preferences this screen shows, not a
/// second copy of them.
final notificationPreferencesRepositoryProvider =
    Provider<NotificationPreferencesRepository?>((ref) {
      final token = _stableSessionToken(ref);
      if (token == null) return null;
      return NotificationPreferencesRepository(
        apiBaseUrl: _apiBaseUrl,
        accessToken: token,
        client: ref.read(authenticatedHttpClientProvider),
      );
    });

final notificationPreferencesProvider =
    FutureProvider<NotificationPreferences?>((ref) async {
      final repo = ref.watch(notificationPreferencesRepositoryProvider);
      if (repo == null) return null;
      try {
        return await repo.fetch();
      } catch (error) {
        if (isAuthenticationFailure(error)) return null;
        rethrow;
      }
    });

/// Design 25's Invite friends payload. Null when signed out — an invite
/// code belongs to an account.
final referralsProvider = FutureProvider<ReferralInfo?>((ref) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return null;
  try {
    return await repo.fetchReferrals();
  } catch (error) {
    if (isAuthenticationFailure(error)) return null;
    rethrow;
  }
});

/// Dedicated v2 referral client. It is deliberately separate from the
/// legacy referral DTO embedded in UserCardsRepository, which continues to
/// support older app builds using GET /referrals.
final referralRepositoryProvider = Provider<ReferralRepository?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return HttpReferralRepository(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    cache: LocalAccountScopedJsonCache(
      () => ref.read(responseCacheProvider.future),
    ),
    cacheNamespace: () => ref.read(cacheNamespaceProvider),
    client: ref.read(authenticatedHttpClientProvider),
  );
});

final referralYearProvider = StateProvider<int>(
  (ref) =>
      DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30)).year,
);

final referralDashboardProvider =
    FutureProvider.family<ReferralDashboard?, int>((ref, year) async {
      final repository = ref.watch(referralRepositoryProvider);
      if (repository == null) return null;
      return repository.loadDashboard(year: year);
    });

final subscriptionCreditsRepositoryProvider =
    Provider<SubscriptionCreditsRepository?>((ref) {
      final token = _stableSessionToken(ref);
      if (token == null) return null;
      return HttpSubscriptionCreditsRepository(
        apiBaseUrl: _apiBaseUrl,
        accessToken: token,
        cache: LocalAccountScopedJsonCache(
          () => ref.read(responseCacheProvider.future),
        ),
        cacheNamespace: () => ref.read(cacheNamespaceProvider),
        client: ref.read(authenticatedHttpClientProvider),
      );
    });

final subscriptionCreditDataProvider = FutureProvider<SubscriptionCreditData?>((
  ref,
) async {
  final repository = ref.watch(subscriptionCreditsRepositoryProvider);
  if (repository == null) return null;
  return repository.load();
});

/// The device's IANA zone name, overridable in tests. `DateTime.now()`'s
/// offset can't be turned back into a zone name (+05:30 is India *and*
/// Sri Lanka), so this is a plain, honest default rather than a guess —
/// the server falls back to the same value for an unknown name.
final deviceTimeZoneProvider = Provider<String>((ref) => 'Asia/Kolkata');

/// Task E12: network-wide aggregate stats (see ContributionNetworkStats'
/// doc-comment for the R2 privacy reason this isn't per-user).
final contributionNetworkStatsProvider =
    FutureProvider<ContributionNetworkStats?>((ref) async {
      final repo = ref.watch(userCardsRepositoryProvider);
      if (repo == null) return null;
      const statsCacheKey = 'contribution_network_stats';
      final cache = await _cacheOrNull(ref);
      final key = _scopedCacheKey(ref, statsCacheKey);
      final cached = await _readCacheOrNull(ref, cache, key);

      ContributionNetworkStats decodeCached() {
        if (cached == null) {
          throw StateError('No cached contribution stats available');
        }
        return ContributionNetworkStats.fromJson(
          jsonDecode(cached.rawJson) as Map<String, dynamic>,
        );
      }

      try {
        final stats = await repo.fetchContributionNetworkStats();
        try {
          await cache?.put(
            key,
            jsonEncode({
              'published_merchant_count': stats.publishedMerchantCount,
              'contributing_device_count': stats.contributingDeviceCount,
            }),
          );
        } catch (_) {}
        return stats;
      } catch (error) {
        if (isAuthenticationFailure(error)) return null;
        if (!_canUseReadCache(error) || cached == null) rethrow;
        return decodeCached();
      }
    });

/// Task E12: this profile's own opt-in flag, read off profileProvider's
/// already-fetched row (profiles.contributions_opt_in) rather than a
/// second fetch — mirrors how AccountScreen already reads other profile
/// fields directly off the same map.
final contributionsOptInProvider = Provider<bool>((ref) {
  final profile = ref.watch(profileProvider).valueOrNull;
  return profile?['contributions_opt_in'] as bool? ?? false;
});

/// Group F (Data Import & Sync) — implementation-plan-group-e-f-g.md §3.
/// Same null-when-signed-out shape as userCardsRepositoryProvider above.
final importRepositoryProvider = Provider<ImportRepository?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return ImportRepository(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

/// F3: this profile's forwarding address, or null if never issued.
final forwardingAddressProvider = FutureProvider<ForwardingAddress?>((
  ref,
) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return null;
  try {
    return await repo.fetchForwardingAddress();
  } catch (error) {
    if (isAuthenticationFailure(error)) return null;
    rethrow;
  }
});

/// Task F-8: the forwarding confirmation code/link a provider sent to the
/// issued address, if one has arrived. Null is the normal state — it only
/// becomes non-null during the few minutes between the user starting setup
/// in Gmail and finishing it.
final forwardingVerificationProvider = FutureProvider<ForwardingVerification?>((
  ref,
) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return null;
  try {
    return await repo.fetchForwardingVerification();
  } catch (error) {
    if (isAuthenticationFailure(error)) return null;
    rethrow;
  }
});

/// F3: this profile's recently received forwarded emails, newest first.
/// Real data once a mail provider is wired to POST /inbound-emails/webhook
/// for a given deployment — empty (not fake) until then.
final inboundEmailsProvider = FutureProvider<List<InboundEmail>>((ref) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return const [];
  try {
    return await repo.fetchInboundEmails();
  } catch (error) {
    if (isAuthenticationFailure(error)) return const [];
    rethrow;
  }
});

/// F2/F1: recent statement imports, newest first.
final statementImportsProvider = FutureProvider<List<StatementImport>>((
  ref,
) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return const [];
  try {
    return await repo.fetchStatementImports();
  } catch (error) {
    if (isAuthenticationFailure(error)) return const [];
    rethrow;
  }
});

/// F4/F1: recent SMS backup-file import batches.
final smsImportBatchesProvider = FutureProvider<List<SmsImportBatch>>((
  ref,
) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return const [];
  try {
    return await repo.fetchSmsImportBatches();
  } catch (error) {
    if (isAuthenticationFailure(error)) return const [];
    rethrow;
  }
});

/// F5: backup/restore status + this user's sync-conflict log.
final backupStatusProvider = FutureProvider<BackupStatus?>((ref) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return null;
  try {
    return await repo.fetchBackupStatus();
  } catch (error) {
    if (isAuthenticationFailure(error)) return null;
    rethrow;
  }
});

/// F7/F1: this profile's IMAP connection, or null if never configured.
final imapConnectionProvider = FutureProvider<ImapConnection?>((ref) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return null;
  try {
    return await repo.fetchImapConnection();
  } catch (error) {
    if (isAuthenticationFailure(error)) return null;
    rethrow;
  }
});

final catalogueRepositoryProvider = Provider<CatalogueRepository>((ref) {
  return HttpCatalogueRepository(baseUrl: _apiBaseUrl);
});

final categoryRepositoryProvider = Provider<CategoryRepository>((ref) {
  return HttpCategoryRepository(baseUrl: _apiBaseUrl);
});

/// B5 — public read, no auth, same pattern as catalogueRepositoryProvider.
final merchantSearchRepositoryProvider = Provider<MerchantSearchRepository>((
  ref,
) {
  return HttpMerchantSearchRepository(
    baseUrl: _apiBaseUrl,
    accessToken: ref.watch(accessTokenProvider),
  );
});

/// Exact-VPA merchant directory lookup used by QR scan. It is intentionally
/// best-effort: scan results render from local data immediately, and a
/// directory/network miss must never prevent a user from choosing a category.
final merchantResolutionProvider =
    FutureProvider.family<MerchantResolution?, String>((ref, vpa) async {
      try {
        return await ref
            .watch(merchantSearchRepositoryProvider)
            .resolveVpa(vpa);
      } catch (_) {
        return null;
      }
    });

/// S5/S6 (ui-spec System Surfaces, GAP_ANALYSIS.md §3) — forced upgrade /
/// maintenance mode. Public, no auth, same pattern as
/// catalogueRepositoryProvider above.
final appStatusRepositoryProvider = Provider<AppStatusRepository>((ref) {
  return HttpAppStatusRepository(baseUrl: _apiBaseUrl);
});

/// Deliberately fails open: if the status check itself can't be reached
/// (offline, server hiccup), the app must still be usable rather than
/// blocking on an inability to confirm it *shouldn't* block — a status
/// check that can accidentally lock every user out on its own outage would
/// be worse than the forced-upgrade/maintenance gate it exists to enforce.
/// router.dart's redirect only acts when this has a real (non-null,
/// non-error) value.
final appStatusProvider = FutureProvider<AppStatus?>((ref) async {
  try {
    return await ref.watch(appStatusRepositoryProvider).fetchStatus();
  } catch (_) {
    return null;
  }
});

/// The installed app's own version — resolved once via package_info_plus,
/// compared against appStatusProvider's minSupportedVersion by
/// router.dart's redirect guard (via isVersionOlderThan).
final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
});

/// UA-0.3 offline cache (GAP_ANALYSIS.md §2, plan
/// docs/superpowers/plans/2026-08-08-offline-first-local-cache.md). Not a
/// relational mirror of the Supabase schema — a raw-JSON-blob cache backed
/// by plain sqlite3 (see app_database.dart's doc-comment for why not
/// drift), closed via ref.onDispose so tests get a fresh in-memory DB per
/// container. AppDatabase.open() is inherently async (path_provider
/// resolves the documents directory via a platform channel) — same
/// FutureProvider shape as tokenStoreProvider above, for the same reason.
final appDatabaseProvider = FutureProvider<AppDatabase>((ref) async {
  final db = await AppDatabase.open();
  ref.onDispose(db.close);
  return db;
});

final responseCacheProvider = FutureProvider<ResponseCache>((ref) async {
  final cache = ResponseCache(await ref.watch(appDatabaseProvider.future));
  final store = cache.financialStore;
  ref.onDispose(store.dispose);
  return cache;
});

final transactionTagsProvider =
    ChangeNotifierProvider<TransactionTagsRepository?>((ref) {
      final token = _stableSessionToken(ref);
      if (token == null) return null;
      final namespace = ref.watch(cacheNamespaceProvider);
      final database = ref.watch(appDatabaseProvider).valueOrNull;
      if (database == null) return null;
      final repository = TransactionTagsRepository(
        database: database,
        namespace: namespace,
        apiBaseUrl: _apiBaseUrl,
        accessToken: token,
        client: ref.read(authenticatedHttpClientProvider),
        onChanged: () {
          ref
              .read(responseCacheProvider)
              .valueOrNull
              ?.markAccountStale(namespace);
          ref.invalidate(budgetsProvider);
        },
      );
      Future.microtask(repository.sync);
      return repository;
    });

/// Reactive entity commits, independent of token rotation and screen-specific
/// invalidation lists. No initial event: opening a store is not a data change.
final financialStoreRevisionProvider = StreamProvider.family<int, String>((
  ref,
  entity,
) async* {
  final namespace = ref.watch(cacheNamespaceProvider);
  final notificationsReady = ref.watch(_reviewFinancialChangesProvider.future);
  final cacheFuture = _cacheOrNull(ref);
  await notificationsReady;
  final cache = await cacheFuture;
  if (cache == null) return;
  var version = 0;
  await for (final changed in cache.financialStore.changes) {
    if (changed.namespace == namespace &&
        (changed.entity == entity || changed.entity == 'all')) {
      yield ++version;
    }
  }
});

void Function() _financialChanges(Ref ref, String entity) {
  var ready = false;
  ref.listen(financialStoreRevisionProvider(entity), (_, next) {
    if (ready) ref.invalidateSelf();
  });
  return () => ready = true;
}

final financialSyncStatusProvider = StreamProvider<String>((ref) async* {
  final namespace = ref.watch(cacheNamespaceProvider);
  final cache = await _cacheOrNull(ref);
  if (cache == null) return;
  final store = cache.financialStore;
  String message() {
    final state = store.syncStatus(namespace);
    if (state == 'storage_error') {
      return 'Device storage is unavailable. Check free space and retry.';
    }
    // A background read can get a 401 while the app still has a locally
    // restored account and another refresh is in flight. Neither that nor a
    // transient transport failure warrants a sign-in warning on every page.
    // Pending SMS imports can be a large historical inbox. They are durable
    // and visible in Sync & backup, but a global banner makes a normal app
    // launch look like thousands of urgent failed payments.
    final blocked =
        store.database.db.select(
              'SELECT COUNT(*) AS count FROM sync_pending_changes WHERE namespace=? AND attempts>=5',
              [namespace],
            ).single['count']
            as int;
    if (blocked > 0) {
      return '$blocked saved ${blocked == 1 ? 'change needs' : 'changes need'} attention in Sync & backup.';
    }
    // Partial history and routine refresh failures are background states.
    // A screen can render its saved content without an app-wide warning.
    return '';
  }

  yield message();
  await for (final changed in store.statusChanges) {
    if (changed == namespace) yield message();
  }
});

String _scopedCacheKey(Ref ref, String key) =>
    '${ref.watch(cacheNamespaceProvider)}:$key';

/// Do not replace an authenticated user's data with a cached snapshot when
/// the server explicitly rejected the session. Network timeouts, offline
/// sockets, and transient 5xx responses are safe stale-data fallbacks; 401
/// and 403 are not.
bool _canUseStaleCache(Object error) =>
    error is! ApiException ||
    (error.statusCode != 401 && error.statusCode != 403);

/// Read-only account snapshots remain safe to show after a token rejection:
/// they are scoped to the current account namespace and are erased on explicit
/// sign-out. This covers an expired access token, a refresh race, or a
/// temporary API/auth deployment mismatch without hiding the user's data.
bool _canUseReadCache(Object error) =>
    _canUseStaleCache(error) ||
    (error is ApiException &&
        (error.statusCode == 401 || error.statusCode == 403));

/// A rejected access token is different from a malformed response or a
/// failed write. Read-only surfaces can safely keep showing their account-
/// scoped snapshot—or an honest empty state when no snapshot exists—while the
/// shared client retries refresh. This predicate is deliberately narrow so a
/// real parsing/data error is still visible to tests and to the user.
bool _isAuthenticationFailure(Object error) {
  return isAuthenticationFailure(error);
}

bool _lastKnownOffline = false;

bool _isKnownOffline() => _lastKnownOffline;

/// The cache is always best-effort — every offline-cache-aware provider
/// below calls this instead of watching responseCacheProvider directly, so
/// a local-DB init failure (an unavailable platform channel in a plain
/// unit test, or a genuine device I/O error) degrades to "no cache" rather
/// than taking down the whole provider and everything that depends on it.
Future<ResponseCache?> _cacheOrNull(Ref ref) async {
  try {
    // Resolve all Ref values before the async gap. Riverpod can invalidate
    // this provider while the cache initializes; using ref.read afterwards
    // then throws before the provider gets a chance to rebuild. Since this is
    // a best-effort helper, that assertion used to be mistaken for a missing
    // cache and caused reads of valid offline snapshots to hang on a fetch.
    final namespace = ref.read(cacheNamespaceProvider);
    final token = ref.read(accessTokenProvider);
    final cacheFuture = ref.watch(responseCacheProvider.future);
    final cache = await cacheFuture;
    if (namespace.startsWith('user:') && token != null) {
      cache.migratePrefix(
        'session:${sha256.convert(utf8.encode(token))}:',
        '$namespace:',
      );
    }
    return cache;
  } catch (_) {
    return null;
  }
}

Future<void> _clearUserCardsCacheValues(
  ResponseCache? cache,
  String namespace,
) async {
  if (cache == null) return;
  await Future.wait([
    cache.clear('$namespace:$_userCardsCacheKey'),
    cache.clear('$namespace:$_userCardsWithArchivedCacheKey'),
  ]);
}

Future<void> _clearUserCardsCacheForRef(Ref ref) async {
  final cache = await _cacheOrNull(ref);
  await _clearUserCardsCacheValues(cache, ref.read(cacheNamespaceProvider));
}

/// Clears authenticated wallet snapshots after a card mutation.
///
/// Wallet reads are intentionally cache-first so Home can render quickly on
/// a cold launch. Invalidating a provider alone can therefore replay the
/// pre-mutation snapshot. Mutation flows call this before invalidating their
/// providers so Find My Cards and Wallet agree immediately.
Future<void> clearUserCardsCache(WidgetRef ref) async {
  ResponseCache? cache;
  try {
    cache = await ref.read(responseCacheProvider.future);
  } catch (_) {
    return;
  }
  await _clearUserCardsCacheValues(cache, ref.read(cacheNamespaceProvider));
}

/// Publishes a card archive/unarchive to the local-first snapshot immediately
/// after a successful write or an offline queue. The next provider read checks
/// this snapshot before attempting the network, so a removed card cannot
/// reappear while the authoritative refresh is still in flight.
Future<void> applyUserCardArchiveToCache(
  WidgetRef ref, {
  required String userCardId,
  required bool archived,
}) async {
  try {
    final cache = await ref.read(responseCacheProvider.future);
    cache.financialStore.patchCard(
      ref.read(cacheNamespaceProvider),
      userCardId,
      {'is_archived': archived},
    );
  } catch (_) {
    // Cache repair is best effort; the server write or sync queue remains the
    // source of truth and the next full fetch will repair this snapshot.
  }
}

Future<CachedResponse?> _readCacheOrNull(
  Ref ref,
  ResponseCache? cache,
  String key,
) async {
  try {
    final current = await cache?.read(key);
    if (current != null || cache == null) return current;

    // Older builds keyed private snapshots by a hash of the access token.
    // Refreshing a token must not make those snapshots look deleted. Migrate
    // the legacy key to the subject-scoped key before returning it. The
    // legacy key is derived from the currently restored credential, so this
    // cannot make another account's snapshot visible.
    final namespace = ref.read(cacheNamespaceProvider);
    final token = ref.read(accessTokenProvider);
    if (token == null || !namespace.startsWith('user:')) return null;
    final prefix = '$namespace:';
    if (!key.startsWith(prefix)) return null;
    final legacyNamespace =
        'session:${sha256.convert(utf8.encode(token)).toString()}';
    final legacyKey = '$legacyNamespace:${key.substring(prefix.length)}';
    final legacy = await cache.read(legacyKey);
    if (legacy == null) return null;
    await cache.put(key, legacy.rawJson);
    await cache.clear(legacyKey);
    return legacy;
  } catch (_) {
    return null;
  }
}

/// Design 21's "Showing your last synced balances from 6:40 PM" — the
/// newest write across the whole response cache (see
/// [ResponseCache.lastFetchedAt] for why newest-of-all rather than
/// per-key).
///
/// Null when nothing has ever been cached, which is a real state: a user
/// who has been offline since install has no synced data to date-stamp,
/// and the banner drops the timestamp clause rather than inventing one.
/// Best-effort like every other cache-aware provider here — a local-DB
/// failure degrades to "no timestamp", never to an error the banner would
/// have to render.
final lastSyncedAtProvider = FutureProvider<DateTime?>((ref) async {
  final cache = await _cacheOrNull(ref);
  if (cache == null) return null;
  try {
    return await cache.lastFetchedAt(
      keyPrefix: '${ref.watch(cacheNamespaceProvider)}:',
    );
  } catch (_) {
    return null;
  }
});

const _catalogueCacheKey = 'catalogue';
const _categoriesCacheKey = 'categories';
const _userCardsCacheKey = 'user_cards';
const _userCardsWithArchivedCacheKey = 'user_cards_with_archived';
const _cardOverridesCacheKey = 'card_overrides';
// Home is a decision surface, not a background report. A socket that never
// completes must become a cache/fallback/error state instead of leaving the
// recommendation section in AsyncLoading forever.
const _homeRequestTimeout = Duration(seconds: 15);
const _spendReportCacheKey = 'spend_report';
const _transactionsCacheKey = 'transactions';

// A report may be opened by more than one surface while the app is syncing.
// Keep one quiet refresh per cache key so local-first rendering never creates
// a burst of identical network requests.
final _backgroundTransactionRefreshes = <String, Future<void>>{};
final _backgroundCardRefreshes = <String, Future<void>>{};
final _backgroundDisplayRefreshes = <String, Future<void>>{};

/// Saved display data is published before any HTTP work. Refresh errors only
/// change sync status, never replace a usable snapshot with an error page.
void _warmDisplay<T>(
  Ref ref,
  ResponseCache? cache,
  String key,
  DateTime fetchedAt,
  Future<T> Function() fetch,
  Object? Function(T) encode,
) {
  if (cache == null ||
      _isKnownOffline() ||
      _backgroundDisplayRefreshes.containsKey(key) ||
      (!cache.needsRefresh(key) &&
          DateTime.now().difference(fetchedAt) < const Duration(seconds: 15))) {
    return;
  }
  final namespace = ref.read(cacheNamespaceProvider);
  var disposed = false;
  ref.onDispose(() => disposed = true);
  final work = fetch()
      .then((value) async {
        if (disposed || ref.read(cacheNamespaceProvider) != namespace) return;
        await cache.put(key, jsonEncode(encode(value)));
        if (!disposed) ref.invalidateSelf();
      })
      .catchError((Object error) {
        if (!disposed) {
          cache.financialStore.setSyncStatus(
            namespace,
            isAuthenticationFailure(error)
                ? 'authentication_required'
                : 'waiting_for_connection',
          );
        }
      })
      .whenComplete(() => _backgroundDisplayRefreshes.remove(key));
  _backgroundDisplayRefreshes[key] = work;
  unawaited(work);
}

String _cacheDate(DateTime value) => value.toIso8601String();

DateTime _spendReportBucket(SpendPeriod period, DateTime now) {
  switch (period) {
    case SpendPeriod.week:
      return DateTime(now.year, now.month, now.day - (now.weekday - 1));
    case SpendPeriod.month:
      return DateTime(now.year, now.month);
    case SpendPeriod.quarter:
      final firstMonth = ((now.month - 1) ~/ 3) * 3 + 1;
      return DateTime(now.year, firstMonth);
    case SpendPeriod.year:
      return DateTime(now.year);
    case SpendPeriod.custom:
      // Custom queries use their selected start date as the cache bucket and
      // never call this helper. Keep the switch exhaustive for future callers.
      return DateTime(now.year, now.month, now.day);
  }
}

/// Reads the canonical transaction snapshot without making another network
/// request. Report screens use this only after their aggregate endpoint has
/// failed; the normal online path remains server-authoritative.
Future<List<TransactionEntry>?> _cachedTransactionsForReports(Ref ref) async {
  final cache = await _cacheOrNull(ref);
  if (cache == null) return null;
  final namespace = ref.read(cacheNamespaceProvider);
  cache.financialStore.migrateLegacy(namespace);
  return cache.financialStore
      .transactions(namespace, const TransactionQuery())
      ?.rows;
}

/// Local SMS evidence can confirm that a named service has AutoPay enabled,
/// even before a charge or billing term appears. Keep this allowlist semantic:
/// card bills and utility billers must remain in Bills & Commitments.
String? _namedServiceAutoPayName(String? raw) {
  final name = raw?.trim();
  if (name == null || name.length < 2) return null;
  final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final lower = name.toLowerCase();
  if (RegExp(
    r'\b(?:credit|debit)?\s*card\b|\bbill\b|\bstatement\b|\b(?:electricity|water|gas|utility|municipal|broadband|telecom)\b',
  ).hasMatch(lower)) {
    return null;
  }
  const serviceTokens = [
    'openai',
    'openaillc',
    'chatgpt',
    'netflix',
    'spotify',
    'amazonprime',
    'primevideo',
    'googleone',
    'googleplay',
    'google',
    'youtube',
    'hotstar',
    'jiocinema',
    'sonyliv',
    'zee5',
    'canva',
    'adobe',
    'notion',
    'dropbox',
    'linkedinpremium',
    'microsoft365',
    'apple',
    'claude',
    'anthropic',
    'midjourney',
    'cursor',
    'github',
  ];
  if (!serviceTokens.any(normalized.contains)) return null;
  if (normalized.contains('creditcard') || normalized.contains('utility')) {
    return null;
  }
  if (normalized.contains('openai') || normalized.contains('openaillc')) {
    return 'OpenAI';
  }
  if (normalized.contains('chatgpt')) return 'ChatGPT';
  if (normalized.contains('googleplay')) return 'Google Play';
  if (normalized.contains('googleone')) return 'Google One';
  return name;
}

/// Older cached/server reports used `detectionSource: mandate` for every
/// AutoPay setup. Reclassify only a known named service; card bills, utility
/// billers, and generic mandates stay hidden from Subscriptions.
RecurringSeries _normalizeLegacyServiceMandate(RecurringSeries item) {
  if (!item.isMandate && item.detectionSource != 'mandate') return item;
  final service = _namedServiceAutoPayName(item.displayName);
  if (service == null) return item;
  final lifecycle = item.lifecycleStatus.trim().toLowerCase();
  return RecurringSeries(
    id: item.id,
    displayName: service,
    typicalAmount: Money.zero(),
    amountKnown: false,
    cadenceDays: 0,
    occurrenceCount: 0,
    annualCost: Money.zero(),
    categoryName: item.categoryName,
    subcategoryName: item.subcategoryName,
    cardName: item.cardName,
    paymentMethod: item.paymentMethod,
    detectionSource: 'local_setup',
    isMandate: false,
    isUserEdited: item.isUserEdited,
    lifecycleStatus: item.lifecycleStatus,
    autopayStatus: item.autopayStatus,
    mandateReference: item.mandateReference,
    sourceKey: item.sourceKey,
    cadenceConfirmed: false,
    setupConfirmed: true,
    engineStatus: lifecycle.isEmpty || lifecycle == 'active'
        ? 'candidate'
        : lifecycle,
  );
}

({DateTime from, DateTime to, DateTime previousFrom, DateTime previousTo})
_localReportBounds(SpendReportQuery query, DateTime now) {
  late DateTime from;
  late DateTime to;
  if (query.isCustom) {
    from = DateTime(query.from!.year, query.from!.month, query.from!.day);
    to = DateTime(query.to!.year, query.to!.month, query.to!.day + 1);
  } else {
    switch (query.period) {
      case SpendPeriod.week:
        final today = DateTime(now.year, now.month, now.day);
        from = today.subtract(Duration(days: today.weekday - 1));
        to = from.add(const Duration(days: 7));
      case SpendPeriod.month:
        from = DateTime(now.year, now.month);
        to = DateTime(now.year, now.month + 1);
      case SpendPeriod.quarter:
        final firstMonth = ((now.month - 1) ~/ 3) * 3 + 1;
        from = DateTime(now.year, firstMonth);
        to = DateTime(now.year, firstMonth + 3);
      case SpendPeriod.year:
        from = DateTime(now.year);
        to = DateTime(now.year + 1);
      case SpendPeriod.custom:
        // Covered by the branch above; retained for exhaustiveness.
        from = DateTime(now.year, now.month, now.day);
        to = from.add(const Duration(days: 1));
    }
  }
  final length = to.difference(from);
  return (
    from: from,
    to: to,
    previousFrom: from.subtract(length),
    previousTo: from,
  );
}

List<TransactionEntry> _activeLocalRows(
  Iterable<TransactionEntry> rows,
  DateTime from,
  DateTime to,
) => rows
    .where(
      (row) =>
          row.status == 'active' &&
          !row.occurredAt.isBefore(from) &&
          row.occurredAt.isBefore(to),
    )
    .toList();

Money _sumLocalAmounts(Iterable<TransactionEntry> rows) {
  var total = const Money.zero();
  for (final row in rows) {
    total += row.amount;
  }
  return total;
}

Money _sumLocalRewards(Iterable<TransactionEntry> rows) {
  var total = const Money.zero();
  for (final row in rows) {
    final reward = row.rewardValue;
    if (reward != null) total += reward;
  }
  return total;
}

EntryKindTotals _localEntryTotals(
  Iterable<TransactionEntry> rows,
  TxnEntryKind kind,
) {
  final matching = rows.where((row) => row.entryKind == kind).toList();
  return EntryKindTotals(
    total: _sumLocalAmounts(matching),
    txnCount: matching.length,
    rewards: _sumLocalRewards(matching),
  );
}

List<SpendBreakdownRow> _localBreakdownRows(
  Iterable<TransactionEntry> rows, {
  required String Function(TransactionEntry) keyFor,
  required String Function(TransactionEntry) labelFor,
  String? Function(TransactionEntry)? categoryIdFor,
}) {
  final totals = <String, Money>{};
  final counts = <String, int>{};
  final labels = <String, String>{};
  final categoryIds = <String, String?>{};
  for (final row in rows) {
    final key = keyFor(row);
    totals[key] = (totals[key] ?? const Money.zero()) + row.amount;
    counts[key] = (counts[key] ?? 0) + 1;
    labels[key] = labelFor(row);
    categoryIds[key] = categoryIdFor?.call(row);
  }
  final keys = totals.keys.toList()
    ..sort((a, b) => totals[b]!.paise.compareTo(totals[a]!.paise));
  return [
    for (final key in keys)
      SpendBreakdownRow(
        label: labels[key]!,
        total: totals[key]!,
        txnCount: counts[key]!,
        categoryId: categoryIds[key],
      ),
  ];
}

String _localSourceKey(TransactionEntry row) {
  final instrument = row.instrumentKnown ? row.instrument : TxnInstrument.other;
  return row.userCardId != null
      ? 'card:${row.userCardId}'
      : instrument == TxnInstrument.creditCard ||
            instrument == TxnInstrument.debitCard
      ? 'card-source:${instrument.wireValue}:${row.cardLast4 ?? 'unknown'}'
      : row.accountLast4 != null
      ? 'bank-account:${row.accountLast4}'
      : 'source:${instrument.wireValue}';
}

List<CardSpendRow> _localCardRows(Iterable<TransactionEntry> rows) {
  final totals = <String, Money>{};
  final rewards = <String, Money>{};
  final counts = <String, int>{};
  final names = <String, String>{};
  final ids = <String, String?>{};
  for (final row in rows) {
    final instrument = row.instrumentKnown
        ? row.instrument
        : TxnInstrument.other;
    final key = _localSourceKey(row);
    totals[key] = (totals[key] ?? const Money.zero()) + row.amount;
    rewards[key] =
        (rewards[key] ?? const Money.zero()) +
        (row.rewardValue ?? const Money.zero());
    counts[key] = (counts[key] ?? 0) + 1;
    names[key] =
        row.cardDisplayName ??
        (instrument == TxnInstrument.creditCard ||
                instrument == TxnInstrument.debitCard
            ? '${instrument.label}${row.cardLast4 == null ? ' (unlinked)' : ' ••${row.cardLast4} (unlinked)'}'
            : row.accountLast4 != null
            ? 'Bank account ••${row.accountLast4}'
            : switch (instrument) {
                TxnInstrument.upiBank => 'UPI bank account',
                TxnInstrument.wallet => 'Wallet',
                TxnInstrument.cash => 'Cash',
                _ => 'Unknown source',
              });
    ids[key] = row.userCardId;
  }
  final keys = totals.keys.toList()
    ..sort((a, b) => totals[b]!.paise.compareTo(totals[a]!.paise));
  return [
    for (final key in keys)
      CardSpendRow(
        cardId: ids[key],
        cardName: names[key]!,
        total: totals[key]!,
        rewards: rewards[key]!,
        txnCount: counts[key]!,
        annualFee: null,
        effectiveRatePerRupee: totals[key]!.isZero
            ? null
            : rewards[key]!.paise / totals[key]!.paise,
      ),
  ];
}

List<InstrumentSpendRow> _localInstrumentRows(Iterable<TransactionEntry> rows) {
  final totals = <String, Money>{};
  final counts = <String, int>{};
  for (final row in rows) {
    final instrument = row.instrumentKnown ? row.instrument.wireValue : 'other';
    totals[instrument] =
        (totals[instrument] ?? const Money.zero()) + row.amount;
    counts[instrument] = (counts[instrument] ?? 0) + 1;
  }
  final keys = totals.keys.toList()
    ..sort((a, b) => totals[b]!.paise.compareTo(totals[a]!.paise));
  return [
    for (final key in keys)
      InstrumentSpendRow(
        instrument: key,
        total: totals[key]!,
        txnCount: counts[key]!,
      ),
  ];
}

List<CardCategorySpendRow> _localCardCategoryRows(
  Iterable<TransactionEntry> rows,
) {
  final totals = <String, Money>{};
  final counts = <String, int>{};
  final names = <String, (String?, String, String?, String)>{};
  for (final row in rows) {
    final card = SpendingSelection.sourceName(row);
    final category = row.categoryName ?? 'Other';
    final categoryId =
        row.parentCategoryId ??
        row.parentUserCategoryId ??
        row.userCategoryId ??
        row.categoryId?.replaceFirst(RegExp(r'^custom:'), '');
    final categoryKey = categoryId == null
        ? 'label:$category'
        : 'id:$categoryId';
    final key = '${_localSourceKey(row)}\u0000$categoryKey';
    totals[key] = (totals[key] ?? const Money.zero()) + row.amount;
    counts[key] = (counts[key] ?? 0) + 1;
    names[key] = (row.userCardId, card, categoryId, category);
  }
  final keys = totals.keys.toList()
    ..sort((a, b) => totals[b]!.paise.compareTo(totals[a]!.paise));
  return [
    for (final key in keys)
      CardCategorySpendRow(
        cardId: names[key]!.$1,
        cardName: names[key]!.$2,
        categoryId: names[key]!.$3,
        categoryName: names[key]!.$4,
        total: totals[key]!,
        txnCount: counts[key]!,
      ),
  ];
}

List<SpendSeriesPoint> _localSpendSeries(
  List<TransactionEntry> rows,
  DateTime from,
  DateTime to,
  SpendPeriod period,
) {
  final bucketCount = switch (period) {
    SpendPeriod.week => 7,
    SpendPeriod.month => 12,
    SpendPeriod.quarter => 12,
    SpendPeriod.year => 12,
    SpendPeriod.custom => 12,
  };
  final length = to.difference(from).inMicroseconds;
  DateTime boundary(int index) =>
      from.add(Duration(microseconds: (length * index) ~/ bucketCount));
  return [
    for (var i = 0; i < bucketCount; i++)
      () {
        final bucketFrom = boundary(i);
        final bucketTo = boundary(i + 1);
        final bucketRows = rows
            .where(
              (row) =>
                  !row.occurredAt.isBefore(bucketFrom) &&
                  row.occurredAt.isBefore(bucketTo),
            )
            .toList();
        return SpendSeriesPoint(
          periodStart: bucketFrom,
          spend: _sumLocalAmounts(
            bucketRows.where((row) => row.entryKind == TxnEntryKind.spend),
          ),
          rewards: _sumLocalRewards(
            bucketRows.where((row) => row.entryKind == TxnEntryKind.spend),
          ),
          txnCount: bucketRows
              .where((row) => row.entryKind == TxnEntryKind.spend)
              .length,
        );
      }(),
  ];
}

SpendReport _makeLocalSpendReport(
  SpendReportQuery query,
  DateTime now,
  List<TransactionEntry> allRows,
) {
  final bounds = _localReportBounds(query, now);
  final current = _activeLocalRows(allRows, bounds.from, bounds.to);
  final previous = _activeLocalRows(
    allRows,
    bounds.previousFrom,
    bounds.previousTo,
  );
  final spendRows = current
      .where((row) => row.entryKind == TxnEntryKind.spend)
      .toList();
  final elapsed = now.isBefore(bounds.from)
      ? 0.0
      : now.isAfter(bounds.to)
      ? 1.0
      : now.difference(bounds.from).inMicroseconds /
            bounds.to.difference(bounds.from).inMicroseconds;
  return SpendReport(
    period: query.period,
    periodStart: bounds.from,
    periodEnd: bounds.to,
    elapsedFraction: elapsed,
    spend: _localEntryTotals(current, TxnEntryKind.spend),
    income: _localEntryTotals(current, TxnEntryKind.income),
    investment: _localEntryTotals(current, TxnEntryKind.investment),
    previousSpend: _localEntryTotals(previous, TxnEntryKind.spend),
    byCategory: _localBreakdownRows(
      spendRows,
      keyFor: (row) => row.categoryId ?? row.categoryName ?? 'other',
      labelFor: (row) => row.categoryName ?? 'Other',
      categoryIdFor: (row) => row.categoryId,
    ),
    byMerchant: _localBreakdownRows(
      spendRows,
      keyFor: (row) => row.merchantName ?? row.categoryName ?? 'other',
      labelFor: (row) => row.merchantName ?? row.categoryName ?? 'Other',
    ),
    byCard: _localCardRows(spendRows),
    byInstrument: _localInstrumentRows(spendRows),
    byCardCategory: _localCardCategoryRows(spendRows),
    series: _localSpendSeries(current, bounds.from, bounds.to, query.period),
  );
}

Future<SpendReport?> _buildLocalSpendReport(
  Ref ref,
  SpendReportQuery query,
) async {
  final rows = await _cachedTransactionsForReports(ref);
  if (rows == null) return null;
  return _makeLocalSpendReport(query, DateTime.now(), rows);
}

Future<MonthlyReport?> _buildLocalMonthlyReport(Ref ref, DateTime now) async {
  final rows = await _cachedTransactionsForReports(ref);
  if (rows == null) return null;
  final monthStart = DateTime(now.year, now.month);
  final monthEnd = DateTime(now.year, now.month + 1);
  final monthRows = _activeLocalRows(rows, monthStart, monthEnd);
  final spendRows = monthRows
      .where((row) => row.entryKind == TxnEntryKind.spend)
      .toList();
  var rewards = _sumLocalRewards(spendRows);

  // Older transaction snapshots may not contain expected_value_inr yet. The
  // home-summary snapshot is still an account-scoped server aggregate for the
  // same month, so use it when row-level reward values are unavailable.
  if (spendRows.every((row) => row.rewardValue == null)) {
    final cache = await _cacheOrNull(ref);
    final summarySnapshot = await _readCacheOrNull(
      ref,
      cache,
      _scopedCacheKey(ref, 'home_summary'),
    );
    if (summarySnapshot != null) {
      try {
        rewards = HomeSummary.fromJson(
          jsonDecode(summarySnapshot.rawJson) as Map<String, dynamic>,
        ).rewardsThisMonth;
      } catch (_) {}
    }
  }
  return MonthlyReport(
    periodMonth: monthStart,
    totalSpend: _sumLocalAmounts(spendRows),
    rewardsEarned: rewards,
    baselineSingleCard: const Money.zero(),
    valueMissed: const Money.zero(),
    extraEarned: rewards,
  );
}

int _medianInt(List<int> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

/// Charges per year implied by a cadence: calendar buckets (12 monthly
/// payments, 4 quarterly, ...) matching the server engine's annual estimate,
/// so a ₹1,499 monthly plan costs ₹17,988/year, not 365/30 blocks worth
/// ₹18,244. Non-calendar cycles fall back to 365/days.
double _chargesPerYear(int cadenceDays) {
  if (cadenceDays >= 350) return 1;
  if (cadenceDays >= 175) return 2;
  if (cadenceDays >= 85) return 4;
  if (cadenceDays >= 26 && cadenceDays <= 32) return 12;
  if (cadenceDays >= 13 && cadenceDays <= 17) return 26;
  if (cadenceDays >= 5 && cadenceDays <= 10) return 52;
  return 365 / cadenceDays;
}

DateTime _nextRecurringDateAfter(
  DateTime lastSeen,
  int cadenceDays, {
  DateTime? now,
}) {
  var next = DateUtils.dateOnly(lastSeen);
  final anchorDay = next.day;
  final calendarMonthly = cadenceDays >= 26 && cadenceDays <= 32;
  final calendarYearly = cadenceDays >= 350;

  DateTime advance(DateTime value) {
    if (calendarYearly) {
      final year = value.year + 1;
      final lastDay = DateTime(year, value.month + 2, 0).day;
      return DateTime(year, value.month, anchorDay.clamp(1, lastDay));
    }
    if (calendarMonthly) {
      final year = value.month == 12 ? value.year + 1 : value.year;
      final month = value.month == 12 ? 1 : value.month + 1;
      final lastDay = DateTime(year, month + 1, 0).day;
      return DateTime(year, month, anchorDay.clamp(1, lastDay));
    }
    return value.add(Duration(days: cadenceDays));
  }

  next = advance(next);
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  while (!next.isAfter(today)) {
    next = advance(next);
  }
  return next;
}

Future<RecurringReport?> _buildLocalRecurringReport(Ref ref) async {
  final cachedRows = await _cachedTransactionsForReports(ref);
  final rows = cachedRows ?? const [];
  final groups = <String, List<TransactionEntry>>{};
  for (final row in rows) {
    final merchant = row.merchantName?.trim();
    final category = row.categoryName?.toLowerCase() ?? '';
    // Repeated transfers to a person are not subscriptions. Without a
    // subscription-like category, cadence alone is insufficient evidence.
    final serviceCategory = const [
      'subscription',
      'streaming',
      'entertainment',
      'software',
      'membership',
      'telecom',
      'utilities',
      'insurance',
    ].any(category.contains);
    if (row.status != 'active' ||
        row.entryKind != TxnEntryKind.spend ||
        row.amount.paise <= 0 ||
        !serviceCategory ||
        merchant == null ||
        merchant.isEmpty) {
      continue;
    }
    final key = merchant.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    groups.putIfAbsent(key, () => []).add(row);
  }

  final series = <RecurringSeries>[];
  for (final entry in groups.entries) {
    final items = [...entry.value]
      ..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
    // Match the server screen's confidence rule: two charges can be a
    // coincidence, while three give a minimally defensible recurrence.
    if (items.length < 3) continue;
    final gaps = <int>[];
    for (var i = 1; i < items.length; i++) {
      final gap = items[i].occurredAt.difference(items[i - 1].occurredAt);
      gaps.add((gap.inHours / 24).round());
    }
    final cadence = _medianInt(gaps);
    if (cadence < 6 || cadence > 370) continue;
    final minGap = (cadence * 0.55).round();
    final maxGap = (cadence * 1.45).round();
    if (gaps.any((gap) => gap < minGap || gap > maxGap)) continue;

    final typical = Money.fromPaise(
      (items.fold<int>(0, (sum, row) => sum + row.amount.paise) / items.length)
          .round(),
    );
    if (typical.isZero) continue;
    if (items.any(
      (row) =>
          (row.amount.paise - typical.paise).abs() * 100 > typical.paise * 40,
    )) {
      continue;
    }
    final latest = items.last;
    final annual = Money.fromPaise(
      (typical.paise * _chargesPerYear(cadence)).round(),
    );
    series.add(
      RecurringSeries(
        id: 'local-recurring:${entry.key}',
        displayName: latest.merchantName!.trim(),
        typicalAmount: typical,
        cadenceDays: cadence,
        occurrenceCount: items.length,
        annualCost: annual,
        lastSeenOn: latest.occurredAt,
        nextExpectedOn: _nextRecurringDateAfter(latest.occurredAt, cadence),
        categoryName: latest.categoryName,
        subcategoryName: latest.subcategoryName,
        cardName: latest.cardDisplayName,
        paymentMethod: latest.instrumentKnown ? latest.instrument.label : null,
        detectionSource: 'local_cache',
      ),
    );
  }
  // A named service AutoPay setup is a presence signal. It intentionally has
  // no amount, cadence, renewal date, or annual cost until a later fact proves
  // one. Card and utility AutoPay observations do not pass the service
  // allowlist and remain available to Bills & Commitments.
  final cache = await _cacheOrNull(ref);
  final namespace = ref.read(cacheNamespaceProvider);
  final observations =
      cache?.financialStore.entities(namespace, 'sms_observations') ??
      const <Map<String, dynamic>>[];
  final existing = {
    for (final item in series)
      item.displayName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''),
  };
  for (final observation in observations) {
    if (observation['event_type'] != 'autopay' ||
        observation['is_autopay'] != true) {
      continue;
    }
    final service = _namedServiceAutoPayName(
      observation['biller_name'] as String?,
    );
    if (service == null) continue;
    final key = service.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (!existing.add(key)) continue;
    series.add(
      RecurringSeries(
        id: 'local-setup:${observation['id'] ?? key}',
        sourceKey: observation['id'] as String?,
        displayName: service,
        typicalAmount: Money.zero(),
        amountKnown: false,
        cadenceDays: 0,
        occurrenceCount: 0,
        annualCost: Money.zero(),
        detectionSource: 'local_setup',
        setupConfirmed: true,
        cadenceConfirmed: false,
        engineStatus: 'candidate',
      ),
    );
  }
  if (cachedRows == null && series.isEmpty) {
    return null;
  }
  series.sort((a, b) => b.annualCost.paise.compareTo(a.annualCost.paise));
  return RecurringReport(
    series: series,
    // The headline counts series whose cycle is proven and still billing,
    // matching the server engine's confirmed-only total.
    totalAnnual: series
        .where((item) => item.status == 'confirmed')
        .fold(const Money.zero(), (total, item) => total + item.annualCost),
  );
}

/// Preserve a locally observed named-service setup when a cached or live
/// server report predates that fact. Only setup rows are merged; established
/// server charge series remain authoritative and are matched by service name
/// so an OpenAILLC/OpenAI spelling difference cannot duplicate a row.
Future<RecurringReport> _mergeLocalSetupSeries(
  Ref ref,
  RecurringReport report,
) async {
  final normalizedReport = RecurringReport(
    series: report.series.map(_normalizeLegacyServiceMandate).toList(),
    totalAnnual: report.totalAnnual,
  );
  final local = await _buildLocalRecurringReport(ref);
  if (local == null) return normalizedReport;
  final serviceKeys = {
    for (final item in normalizedReport.series)
      _recurringServiceKey(item.displayName),
  };
  final additions = <RecurringSeries>[];
  for (final item in local.series.where((item) => item.setupConfirmed)) {
    if (!serviceKeys.add(_recurringServiceKey(item.displayName))) continue;
    additions.add(item);
  }
  if (additions.isEmpty) return normalizedReport;
  return RecurringReport(
    series: [...normalizedReport.series, ...additions],
    totalAnnual: normalizedReport.totalAnnual,
  );
}

String _recurringServiceKey(String name) {
  final canonical = _namedServiceAutoPayName(name) ?? name;
  return canonical.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// Shared stale-safe transaction loader for Activity, Insights, and the
/// period detail rows in Spending. The server remains authoritative, but a
/// successful response is persisted before it is rendered so a cold offline
/// launch still has a truthful last-known view.
Future<List<TransactionEntry>> loadTransactionsWithOfflineCache(
  Ref ref, {
  required UserCardsRepository repo,
  required String cacheKey,
  DateTime? from,
  DateTime? to,
  String? cardId,
  String? categoryId,
  String? userCategoryId,
  String? source,
  String? query,
  bool preferCached = false,
  bool useReportSnapshots = true,
  FutureOr<void> Function()? onBackgroundRefresh,
}) async {
  var ready = false;
  ref.listen(financialStoreRevisionProvider('transactions'), (_, next) {
    if (ready) ref.invalidateSelf();
  });
  final namespace = ref.watch(cacheNamespaceProvider);
  final filter = TransactionQuery(
    from: from,
    to: to,
    cardId: cardId,
    categoryId: categoryId,
    userCategoryId: userCategoryId,
    source: source,
    query: query,
  );
  final cache = await _cacheOrNull(ref);
  final store = cache?.financialStore;
  store?.migrateLegacy(namespace);
  final local = store?.transactions(namespace, filter);
  final key = '$namespace:${filter.key}';

  Future<List<TransactionEntry>> fetchAndStore() async {
    final requestedAt = DateTime.now();
    try {
      final rows = await repo.fetchTransactions(
        from: from,
        to: to,
        cardId: cardId,
        categoryId: categoryId,
        userCategoryId: userCategoryId,
        source: source,
        query: query,
      );
      // An old request must not write into a new account after logout/login.
      if (ref.read(cacheNamespaceProvider) != namespace) return rows;
      store?.saveTransactions(
        namespace,
        rows,
        completeQuery: filter,
        at: requestedAt,
      );
      store?.setSyncStatus(namespace, 'idle');
      // Compatibility only; all new transaction reads use FinancialStore.
      await cache?.put(
        '$namespace:$cacheKey',
        jsonEncode({'transactions': rows.map((r) => r.toJson()).toList()}),
      );
      return store?.transactions(namespace, filter)?.rows ?? rows;
    } catch (error) {
      store?.setSyncStatus(
        namespace,
        isAuthenticationFailure(error)
            ? 'authentication_required'
            : 'waiting_for_connection',
      );
      rethrow;
    }
  }

  // A known empty result has coverage too. Reading any surface never waits
  // for a network refresh when its saved content is available.
  if (local != null) {
    if (!_isKnownOffline() &&
        (!preferCached ||
            DateTime.now().difference(local.fetchedAt) >=
                const Duration(seconds: 15)) &&
        !_backgroundTransactionRefreshes.containsKey(key)) {
      final work = fetchAndStore()
          .then((_) async {
            if (onBackgroundRefresh != null) await onBackgroundRefresh();
          })
          .catchError((_) {})
          .whenComplete(() {
            _backgroundTransactionRefreshes.remove(key);
          });
      _backgroundTransactionRefreshes[key] = work;
      unawaited(work);
    }
    ready = true;
    return local.rows;
  }
  try {
    final rows = await fetchAndStore();
    ready = true;
    return rows;
  } catch (error) {
    if (isAuthenticationFailure(error)) {
      throw const AuthenticationUnavailableException();
    }
    rethrow;
  }
}

/// Returns one transaction from the last successful Activity snapshot without
/// making a network request. Detail screens use this before their live fetch,
/// so opening a row remains useful when the access token or connection is
/// temporarily unavailable.
Future<TransactionEntry?> cachedTransactionById(Ref ref, String id) async {
  final cache = await _cacheOrNull(ref);
  final namespace = ref.read(cacheNamespaceProvider);
  cache?.financialStore.migrateLegacy(namespace);
  final records =
      cache?.financialStore.entities(namespace, 'transactions', id: id) ??
      const [];
  for (final row in records) {
    if (row['id'] == id) return TransactionEntry.fromJson(row);
  }
  final snapshot = await _readCacheOrNull(
    ref,
    cache,
    _scopedCacheKey(ref, '$_transactionsCacheKey:all'),
  );
  if (snapshot == null) return null;
  try {
    final body = jsonDecode(snapshot.rawJson) as Map<String, dynamic>;
    for (final raw
        in (body['transactions'] as List).cast<Map<String, dynamic>>()) {
      final entry = TransactionEntry.fromJson(raw);
      if (entry.id == id) return entry;
    }
  } catch (_) {
    // A corrupt snapshot must never make a detail route crash.
  }
  return null;
}

/// UA-0.3 offline step: live fetch first, caching the raw response on
/// success; on ANY fetch failure, falls back to the last cached response
/// rather than leaving Home with nothing to rank against. Only fires the
/// fallback on a genuine failure — a successful-but-empty catalogue is
/// never treated as "fetch failed."
final catalogueProvider = FutureProvider<List<CardProduct>>((ref) async {
  final cache = await _cacheOrNull(ref);
  final cached = await cache?.get(_catalogueCacheKey);
  if (cached != null) {
    try {
      final body = jsonDecode(cached) as Map<String, dynamic>;
      final cards = (body['cards'] as List)
          .cast<Map<String, dynamic>>()
          .map(CardProductJson.fromJson)
          .toList();
      if (cards.isNotEmpty) return cards;
    } catch (_) {
      // Fall through to the live/bundled catalogue below.
    }
  }
  try {
    final cards = await ref
        .watch(catalogueRepositoryProvider)
        .fetchCatalogue()
        .timeout(const Duration(seconds: 15));
    if (cards.isNotEmpty) {
      await cache?.put(
        _catalogueCacheKey,
        jsonEncode({'cards': cards.map((c) => c.toJson()).toList()}),
      );
      return cards;
    }
  } catch (_) {}

  try {
    if (cached != null) {
      final body = jsonDecode(cached) as Map<String, dynamic>;
      final cards = (body['cards'] as List)
          .cast<Map<String, dynamic>>()
          .map(CardProductJson.fromJson)
          .toList();
      if (cards.isNotEmpty) return cards;
    }
  } catch (_) {}

  try {
    final raw = await rootBundle.loadString(
      'assets/data/bundled_catalogue.json',
    );
    final body = jsonDecode(raw) as Map<String, dynamic>;
    final cards = (body['cards'] as List)
        .cast<Map<String, dynamic>>()
        .map(CardProductJson.fromJson)
        .toList();
    if (cards.isNotEmpty) return cards;
  } catch (_) {}

  return const [];
});

final categoriesProvider = FutureProvider<List<SpendCategory>>((ref) async {
  final cache = await _cacheOrNull(ref);
  final namespace = ref.read(cacheNamespaceProvider);
  final customCategories = await _readCustomCategories(ref, namespace);
  final cached = await cache?.get(_categoriesCacheKey);
  if (cached != null) {
    try {
      final body = jsonDecode(cached) as Map<String, dynamic>;
      final categories = (body['categories'] as List)
          .cast<Map<String, dynamic>>()
          .map(SpendCategory.fromJson)
          .toList();
      final hasEmi = categories.any((category) => category.slug == 'emi');
      if (categories.isNotEmpty && hasEmi) {
        return [...categories, ...customCategories];
      }
    } catch (_) {}
  }
  try {
    final categories = await ref
        .watch(categoryRepositoryProvider)
        .fetchCategories()
        .timeout(_homeRequestTimeout);
    try {
      await cache?.put(
        _categoriesCacheKey,
        jsonEncode({'categories': categories.map((c) => c.toJson()).toList()}),
      );
    } catch (_) {
      // A cache write must never keep the Home recommendation state pending.
    }
    return [...categories, ...customCategories];
  } catch (_) {
    try {
      if (cached != null) {
        final body = jsonDecode(cached) as Map<String, dynamic>;
        return [
          ...(body['categories'] as List).cast<Map<String, dynamic>>().map(
            SpendCategory.fromJson,
          ),
          ...customCategories,
        ];
      }
    } catch (_) {
      // Fall through to the category-less ranking path below.
    }

    // Category ids improve the ranking but are not required to produce a
    // truthful base-rate recommendation. The engine safely falls back to
    // catch-all card rules until the next refresh can load the ids.
    return customCategories;
  }
});

/// Adds a category for the current account and refreshes every category
/// picker. The account namespace prevents one user's local categories from
/// appearing after another user signs in on the same device.
Future<SpendCategory?> addCustomCategory(
  WidgetRef ref,
  String name, {
  String? parentId,
  List<String> matchTerms = const [],
}) async {
  final namespace = ref.read(cacheNamespaceProvider);
  if (namespace == 'signed-out') return null;
  final cache = await ref.read(responseCacheProvider.future);
  final queue = await ref.read(syncQueueProvider.future);
  final category = await const UserCategoriesRepository().add(
    database: cache.financialStore.database,
    queue: queue,
    namespace: namespace,
    name: name,
    parentId: parentId,
    matchTerms: matchTerms,
  );
  ref.invalidate(categoriesProvider);
  unawaited(ref.read(syncEngineProvider).sync());
  return category;
}

Future<List<SpendCategory>> _readCustomCategories(
  Ref ref,
  String namespace,
) async {
  try {
    final cache = await ref.read(responseCacheProvider.future);
    final preferences = await SharedPreferences.getInstance();
    final queue = await ref.read(syncQueueProvider.future);
    final repository = const UserCategoriesRepository();
    await repository.migrateLegacy(
      cache.financialStore.database,
      queue,
      preferences,
      namespace,
    );
    return repository.readLocal(cache.financialStore.database, namespace);
  } catch (_) {
    return const [];
  }
}

/// B1 category chips (ui-spec) — the primary card selector when there's no
/// location/merchant context yet (scan flow, UA-4, isn't wired up either).
/// Holds a *slug* ('online'), matching what the chips display and what the
/// seed data / product-plan refer to categories as — resolved to the UUID
/// reward_rules.category_id actually needs by rankedRecommendationsProvider
/// below via categoriesProvider. Passing the slug straight through as if it
/// were the FK was a real bug caught by tool/verify_live_catalogue.dart
/// (every card came back excluded against live data) before this existed.
final selectedCategoryProvider = StateProvider<String?>((ref) => 'online');

/// G1 Travel Mode. RecommendationContext.travelMode/ForexRule.effective
/// MarkupFraction() already existed and were already load-bearing in
/// RecommendationEngine._evaluate (engine.dart's UA-2.2.5 branch) — this is
/// the toggle that was missing, not new ranking logic. Flipping it re-ranks
/// Home live via rankedRecommendationsProvider below, same as toggling
/// selectedCategoryProvider already does; no new fetch, no network in the
/// critical path (Cross-Cutting Requirements' performance rule).
final travelModeProvider = StateProvider<bool>((ref) => false);

/// Chunk 19: the real user-entered spend amount, typed into Home's amount
/// field — replaces the fixed ₹1,000/₹20,000 demo amounts previously
/// hardcoded everywhere ranking or "log a spend" needed a number. Both
/// rankedRecommendationsProvider (below) and Cards' log-spend button read
/// this same provider, so what a user types on Home is exactly what gets
/// logged if they then tap "log spend" on a card.
final enteredAmountProvider = StateProvider<Money>(
  (ref) => const Money.fromPaise(100000),
);

/// Bridges the app shell's central scan FAB (main.dart, tab-agnostic) to
/// Cards' `_AddCardForm` (Chunk 30's scan flow was originally only reachable
/// from inside that form). The FAB pushes ScanCardScreen itself, switches to
/// the Cards tab on a pick, and sets this; the form listens and pre-fills
/// its dropdown selection from it, then clears it back to null so it's a
/// one-shot handoff, not a sticky value that reappears on next visit.
final pendingScannedCardIdProvider = StateProvider<String?>((ref) => null);

final recommendationEngineProvider = Provider<RecommendationEngine>((ref) {
  return const RecommendationEngine();
});

/// Ranks the fetched catalogue for the selected category, scoped to the
/// signed-in user's own wallet (Chunk 16's user_cards) when they own any —
/// falling back to the three highest-ranked catalogue cards when signed out
/// or before they've added a first card. A user should not receive an
/// unbounded list of cards they do not own; their Wallet still ranks every
/// card they have added. Still no cap-consumption or
/// milestone-progress state (that's user-usage tracking, a separate,
/// larger surface than "which cards does this person actually have") —
/// every card is evaluated as if its caps/milestones are fully fresh.
final rankedRecommendationsProvider =
    Provider<AsyncValue<List<Recommendation>>>((ref) {
      final selectedSlug = ref.watch(selectedCategoryProvider);
      final nearby = ref.watch(homeNearbyContextProvider);
      final match = nearby?.match;
      String? merchantName;
      String? nearbyCategoryId;

      if (match != null) {
        final candidate = match.candidate;
        final categories =
            ref.watch(categoriesProvider).valueOrNull ?? const [];
        final cat = categories.firstWhereOrNull(
          (c) => c.id == candidate.categoryId || c.slug == candidate.categoryId,
        );
        final merchantCategorySlug = cat?.slug ?? candidate.categoryId;
        if (selectedSlug == null || selectedSlug == merchantCategorySlug) {
          merchantName = candidate.displayName;
          nearbyCategoryId = candidate.categoryId ?? cat?.id;
        }
      }

      return _rankRecommendations(
        ref,
        amount: ref.watch(enteredAmountProvider),
        categoryId: nearbyCategoryId,
        categorySlug: selectedSlug,
        merchantName: merchantName,
      );
    });

/// Context passed by Quick Add as the user fills in a transaction. Keeping
/// the rank request tied to the actual form values makes its card verdict use
/// the same engine, wallet state, caps, overrides, and reward rules as Home.
typedef QuickAddRecommendationQuery = ({
  Money amount,
  String? categoryId,
  String? categorySlug,
  String? merchantName,
  DateTime? transactionDate,
});

final quickAddRecommendationsProvider = Provider.autoDispose
    .family<AsyncValue<List<Recommendation>>, QuickAddRecommendationQuery>(
      (ref, query) => _rankRecommendations(
        ref,
        amount: query.amount,
        categoryId: query.categoryId,
        categorySlug: query.categorySlug,
        merchantName: query.merchantName,
        transactionDate: query.transactionDate,
        ownedCardType: 'credit',
      ),
    );

AsyncValue<List<Recommendation>> _rankRecommendations(
  Ref ref, {
  required Money amount,
  String? categoryId,
  String? categorySlug,
  String? merchantName,
  DateTime? transactionDate,
  String? ownedCardType,
}) {
  final catalogue = ref.watch(catalogueProvider);
  final categories = ref.watch(categoriesProvider);
  final userCards = ref.watch(userCardsProvider);
  final overrides = ref.watch(cardOverridesProvider);
  final engine = ref.watch(recommendationEngineProvider);

  // Riverpod keeps the previous value on an AsyncValue while a provider is
  // being refreshed. Continue to use those snapshots rather than replacing
  // a stable recommendation with a spinner during wallet sync/session refresh.
  final allCards = catalogue.valueOrNull;
  final categoryList = categories.valueOrNull ?? const <SpendCategory>[];
  final wallet = userCards.valueOrNull;
  final overrideList = overrides.valueOrNull ?? const <CardOverride>[];
  final combinedError = catalogue.error ?? userCards.error;

  if (allCards == null || wallet == null) {
    if (combinedError != null) {
      return AsyncValue.error(
        combinedError,
        catalogue.stackTrace ??
            userCards.stackTrace ??
            categories.stackTrace ??
            overrides.stackTrace ??
            StackTrace.current,
      );
    }
    return const AsyncValue.loading();
  }

  final resolvedCategory = categoryId == null
      ? categoryList.firstWhereOrNull(
          (category) => category.slug == categorySlug,
        )
      : categoryList.firstWhereOrNull(
          (category) =>
              category.id == categoryId || category.slug == categoryId,
        );
  final requestedCategoryId = categoryId ?? resolvedCategory?.id;
  // Private subcategories are transaction labels, not published reward-rule
  // categories. Rank against their built-in parent while retaining the child
  // id separately in the transaction form.
  final resolvedCategoryId = categoryIdForServer(
    requestedCategoryId,
    categoryList,
  );
  final resolvedCategorySlug =
      categoryList
          .where((category) => category.id == resolvedCategoryId)
          .firstOrNull
          ?.slug ??
      categorySlug;

  final cards = ownedCardType == null && wallet.isEmpty
      ? allCards
      : allCards.where((product) {
          final owned = wallet.firstWhereOrNull(
            (card) => card.cardProductId == product.id,
          );
          if (owned == null) return false;
          if (ownedCardType == null) return true;
          final type = (owned.cardType ?? product.cardType)?.toLowerCase();
          return type == null || type == ownedCardType;
        }).toList();

  final overrideProductId = resolveActiveOverrideCardProductId(
    overrides: overrideList,
    wallet: wallet,
    categoryId: resolvedCategoryId,
  );
  final context = RecommendationContext(
    amount: amount,
    categoryId: resolvedCategoryId,
    categorySlug: resolvedCategorySlug,
    merchantName: merchantName,
    rail: TxnRail.swipe,
    travelMode: ref.watch(travelModeProvider),
    now: transactionDate ?? ref.watch(clockProvider).now(),
  );
  final snapshots = _userCardSnapshots(
    cards,
    wallet,
    forcedOverrideCardId: overrideProductId,
  );
  final ranked = engine.rank(context, snapshots);
  return AsyncValue.data(
    ownedCardType == null && wallet.isEmpty ? ranked.take(3).toList() : ranked,
  );
}

/// Chunk 38: factored out of rankedRecommendationsProvider and
/// bestCardForMerchantProvider, which both built an identical
/// CardSnapshot list inline — G2/G3 need the exact same "owned card ->
/// CardSnapshot with real capRemaining/milestoneProgress" assembly, so this
/// is now the one place that logic lives rather than a fourth copy.
List<CardSnapshot> _userCardSnapshots(
  List<CardProduct> cards,
  List<UserCard> wallet, {
  String? forcedOverrideCardId,
}) {
  return cards.map((c) {
    final owned = wallet.firstWhereOrNull((w) => w.cardProductId == c.id);
    final capRemaining = owned == null
        ? const <String, Money>{}
        : {
            for (final cap in uniqueCapRules(c.capRules))
              if (owned.capConsumed.containsKey(cap.id))
                cap.id: cap.capValue - owned.capConsumed[cap.id]!,
          };
    return CardSnapshot(
      product: c,
      capRemaining: capRemaining,
      milestoneProgress: owned?.milestoneQualifiedSpend ?? const {},
      forcedOverrideCardId: forcedOverrideCardId,
    );
  }).toList();
}

/// UA-8 (Chunk 32): the app's first use of injectable `Clock` outside
/// pandapay_domain itself — `HomeWidgetService.updateBestCardWidget` needs a
/// timestamp and the `no_datetime_now_outside_clock` custom_lint rule
/// forbids a bare `DateTime.now()` call in app/, so this is the one place
/// that source of truth lives for the whole app, ready for other screens to
/// share instead of each hand-rolling their own.
final clockProvider = Provider<Clock>((ref) => const Clock.system());

/// UA-8: public read, no auth needed — same shape as catalogueRepositoryProvider/
/// categoryRepositoryProvider above.
final nearbyMerchantsRepositoryProvider = Provider<NearbyMerchantsRepository>((
  ref,
) {
  final repository = HttpNearbyMerchantsRepository(
    baseUrl: _apiBaseUrl,
    localCache: SharedPreferencesNearbyMerchantCache(
      namespace: ref.watch(cacheNamespaceProvider),
    ),
  );
  ref.onDispose(repository.close);
  return repository;
});

/// Keeps the resolved Home context alive while the Home route is remounted
/// during tab navigation. The snapshot is intentionally in memory only and
/// is cleared when its freshness window expires by the consumer.
final homeNearbyContextProvider = StateProvider<NearbyContextSnapshot?>(
  (ref) => null,
);

/// UA-8.3 (B1): one FlutterLocalNotificationsPlugin instance for the whole
/// app. Previously GeofenceMonitorService was the only caller and
/// constructed its own — fine when it was the only notification path, but
/// NotificationGate (B2) needs to show OS notifications too, and two
/// independent plugin instances means two independent (and possibly
/// racing) `initialize()` calls registering the same Android channel.
final localNotificationsPluginProvider =
    Provider<FlutterLocalNotificationsPlugin>((ref) {
      return FlutterLocalNotificationsPlugin();
    });

/// UA-8.3 (B2): the single choke point every real (OS-level) notification
/// must pass through — see notification_gate.dart's own doc-comment for
/// what it enforces and why POST /notifications alone isn't enough.
final notificationGateProvider = Provider<NotificationGate>((ref) {
  return NotificationGate(
    ref: ref,
    notifications: ref.watch(localNotificationsPluginProvider),
  );
});

/// The mobile app authenticates to PandaPay, never directly to the private
/// notification service. This provider is therefore the only place where the
/// current access token is connected to FCM token registration.
final notificationDevicesApiProvider = Provider<NotificationDevicesApi?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return NotificationDevicesApi(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

/// FCM is additive to the existing inbox and local-notification system. The
/// service is kept alive by the app shell and restarted after sign-in.
final pushNotificationServiceProvider = Provider<PushNotificationService?>((
  ref,
) {
  final api = ref.watch(notificationDevicesApiProvider);
  if (api == null) return null;
  final service = PushNotificationService(
    api: api,
    gate: ref.watch(notificationGateProvider),
  );
  ref.onDispose(service.stop);
  return service;
});

final pushNotificationLifecycleProvider = Provider<void>((ref) {
  final service = ref.watch(pushNotificationServiceProvider);
  if (service == null) return;
  unawaited(service.start());
  ref.listen<String>(cacheNamespaceProvider, (previous, next) {
    if (next == 'signed-out') {
      unawaited(service.stop());
    } else if (previous == 'signed-out') {
      unawaited(service.start());
    }
  });
});

/// One native monitor for the current account's nearby repository.
final geofenceMonitorServiceProvider = Provider<GeofenceMonitorService>((ref) {
  final service = GeofenceMonitorService(
    repo: ref.watch(nearbyMerchantsRepositoryProvider),
    notifications: ref.watch(localNotificationsPluginProvider),
    namespace: ref.watch(cacheNamespaceProvider),
    // UA-8.3 (B2): closes the one real spec violation this pass found —
    // _notify() used to call flutter_local_notifications directly, bypassing
    // category_location, quiet hours, and the daily cap entirely.
    gate: ref.watch(notificationGateProvider),
    recommendationTextBuilder: (match) {
      final recommendation = ref
          .read(
            bestCardForMerchantProvider(
              MerchantRecommendationQuery(
                categoryId: match.candidate.categoryId,
                merchantName: match.candidate.displayName,
              ),
            ),
          )
          .valueOrNull;
      if (recommendation == null || recommendation.isExcluded) return null;
      final rate = recommendation.effectiveRatePerRupee;
      if (rate != null && rate > 0) {
        final percent = rate * 100;
        final formatted = percent == percent.roundToDouble()
            ? percent.toStringAsFixed(0)
            : percent.toStringAsFixed(1);
        return 'Use ${recommendation.card.name} here · earn $formatted% reward.';
      }
      return 'Use ${recommendation.card.name} here · estimated ${recommendation.expectedValue.format(hidePaise: true)} back.';
    },
  );
  ref.onDispose(() => service.stop());
  return service;
});

final backgroundAlertsControllerProvider =
    ChangeNotifierProvider<BackgroundAlertsController>((ref) {
      return BackgroundAlertsController(
        monitor: ref.watch(geofenceMonitorServiceProvider),
        namespace: ref.watch(cacheNamespaceProvider),
      );
    });

/// Restore the saved opt-in even when Nearby merchants is never opened.
/// Recheck permissions and location services whenever the app resumes.
final backgroundAlertsLifecycleProvider = Provider<void>((ref) {
  final controller = ref.watch(backgroundAlertsControllerProvider.notifier);
  unawaited(controller.restore());
  final listener = AppLifecycleListener(
    onResume: () => unawaited(controller.restore()),
  );
  ref.onDispose(listener.dispose);
});

/// UA-8.3 (B3): the trigger side — see notification_triggers.dart's own
/// doc-comment for what it checks and why this is the realistic ceiling
/// for a client-only (no push/cron backend) notification system.
final notificationTriggerRunnerProvider = Provider<NotificationTriggerRunner>((
  ref,
) {
  return NotificationTriggerRunner(ref);
});

/// Runs the B3 trigger sweep on app foreground/resume, and whenever
/// userCardsProvider changes — the one invalidation point every
/// transaction-affecting write in this app already calls through (29 call
/// sites as of this pass), which is the closest thing to "after a
/// transaction syncs" this app can observe without a dedicated hook at
/// every entry point. Read once from _AppShell, same pattern as
/// analyticsLifecycleProvider just above sessionKeepAliveProvider's own
/// wiring in router.dart.
final notificationTriggerLifecycleProvider = Provider<void>((ref) {
  final runner = ref.read(notificationTriggerRunnerProvider);

  final listener = AppLifecycleListener(onResume: () => runner.runAll());
  ref.onDispose(listener.dispose);

  ref.listen<AsyncValue<List<UserCard>>>(userCardsProvider, (previous, next) {
    if (next.hasValue) runner.runAll();
  });
});

/// Uploads any bank SMS the background isolate queued while the app was
/// away, on every resume and once at startup.
///
/// The background handler can only write messages down — it has no access
/// to the auth token or the HTTP client (see [SmsBackgroundQueue]) — so
/// this is the other half of background capture. Without it, background
/// delivery would collect messages on disk that nothing ever sent.
///
/// A message stays queued unless the upload actually dealt with it, so a
/// resume while offline loses nothing.
/// Incremented to request an immediate on-demand reconciliation of pending SMS
/// and AI review status (e.g. on pull-to-refresh).
final smsFlushTriggerProvider = StateProvider<int>((ref) => 0);

final smsBackgroundFlushProvider = Provider<void>((ref) {
  var workInProgress = false;
  var rerunRequested = false;
  var disposed = false;
  ref.onDispose(() => disposed = true);
  Timer? inFlightPollTimer;
  ref.onDispose(() => inFlightPollTimer?.cancel());
  late final void Function(List<NeedsReviewItem> items) scheduleInFlightAiPoll;

  Future<int> flush() async {
    final summary = await ref.read(smsAutoImportProvider).syncPendingMessages();
    return summary.imported +
        summary.needsReview +
        summary.dueDatesUpdated +
        summary.statementDaysUpdated;
  }

  // The local review row is the durable source of truth for unresolved SMSs.
  // Reconcile by the existing source key; a crash between local capture and
  // POST /ai/jobs can then safely retry without rereading the inbox.
  Future<void> reconcileAiNeedsReview() async {
    inFlightPollTimer?.cancel();
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null || ref.read(isOnlineProvider).valueOrNull == false) return;
    final namespace = ref.read(cacheNamespaceProvider);
    final reviewRepo = ref.read(needsReviewRepositoryProvider);
    final items = await reviewRepo.fetchAll();
    var changed = false;
    for (final item in items) {
      if (ref.read(cacheNamespaceProvider) != namespace) break;
      // A completed job returns its original fact list; do not restore facts
      // the user already resolved from a still-open multi-fact review item.
      if (item.aiSuggestions?.isNotEmpty == true) continue;
      final cleanId = item.id.startsWith('commitment:')
          ? item.id.substring('commitment:'.length)
          : item.id;
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(cleanId) ||
          LocalSmsParser.sensitive(item.body)) {
        continue;
      }
      try {
        final status = await repo.fetchAiJobStatus(cleanId);
        if (status == null) {
          // Recover only the crash window where local capture persisted but
          // the initial POST was never acknowledged. A completed/failed local
          // result must never be re-submitted just because the server record
          // is temporarily missing; successful empty-fact decisions are still
          // completed decisions and should not spend provider tokens again.
          if (item.aiStatus != AiReviewStatus.notChecked) {
            if (item.aiStatus == AiReviewStatus.queued ||
                item.aiStatus == AiReviewStatus.processing) {
              changed =
                  await reviewRepo.updateAiStatus(
                    item.id,
                    AiReviewStatus.unavailable,
                    failureReason: 'job_not_found',
                  ) ||
                  changed;
            }
            continue;
          }
          final jobId = await repo.submitAiJob(
            sourceKey: cleanId,
            sender: item.sender,
            body: item.body,
            occurredAt: item.receivedAt,
          );
          changed =
              await reviewRepo.updateAiStatus(
                item.id,
                jobId == null
                    ? AiReviewStatus.unavailable
                    : AiReviewStatus.queued,
              ) ||
              changed;
          continue;
        }

        if (status['status'] == 'failed') {
          // Failed jobs are terminal for this pipeline revision. Reopening on
          // every reconciliation reset the attempt budget and caused a retry
          // storm. Keep the local message available for manual review.
          changed =
              await reviewRepo.updateAiStatus(
                item.id,
                AiReviewStatus.unavailable,
                failureReason:
                    status['failureReason'] as String? ?? 'worker_failed',
              ) ||
              changed;
          continue;
        }

        final statusValue = switch (status['status']) {
          'queued' => AiReviewStatus.queued,
          'leased' => AiReviewStatus.processing,
          'done' => AiReviewStatus.checked,
          'failed' => AiReviewStatus.unavailable,
          _ => item.aiStatus,
        };
        changed =
            await reviewRepo.updateAiStatus(item.id, statusValue) || changed;
        final rawSuggestions = status['suggestions'];
        final result = status['result'];
        final decision = (status['decision'] is Map
            ? Map<String, dynamic>.from(status['decision'] as Map)
            : (result is Map && result['decision'] is Map)
            ? Map<String, dynamic>.from(result['decision'] as Map)
            : null);
        if (status['status'] == 'done') {
          final suggestions = (rawSuggestions is List)
              ? rawSuggestions
                    .whereType<Map>()
                    .map((v) => Map<String, dynamic>.from(v))
                    .toList()
              : <Map<String, dynamic>>[];
          // High-confidence complete facts auto-file; uncertain or incomplete
          // results stay editable in Needs Review. Only an explicit negative
          // decision may dismiss the row. Triage uses the server's composite
          // score, so a stale/failed poll cannot bypass the confidence gate.
          final cache = await ref.read(responseCacheProvider.future);
          final resolution = SmsImportStore(cache.financialStore)
              .resolveAiSuggestions(
                namespace,
                item,
                suggestions,
                decision: decision,
                reviewRequired: result is Map
                    ? result['reviewRequired'] as bool?
                    : null,
                serverScore: result is Map && result['confidenceScore'] is num
                    ? (result['confidenceScore'] as num).toDouble()
                    : null,
              );
          if (resolution.outcome == SmsAiResolutionOutcome.needsReview) {
            changed =
                await reviewRepo.updateAiSuggestions(
                  item.id,
                  suggestions,
                  aiTopic: decision?['topic'] as String?,
                  aiDecision: decision,
                ) ||
                changed;
            changed =
                await reviewRepo.updateAiStatus(
                  item.id,
                  AiReviewStatus.checked,
                ) ||
                changed;
          } else {
            // The row is already gone: never recreate it by updating.
            changed = true;
          }
        }
      } on Object catch (e) {
        if (_isExplicitAiRefusal(e)) {
          changed =
              await reviewRepo.updateAiStatus(
                item.id,
                AiReviewStatus.unavailable,
                failureReason: e is ApiException
                    ? (e.errorCode ?? 'http_${e.statusCode}')
                    : 'request_refused',
              ) ||
              changed;
        }
        // If fetchAiJobStatus or submitAiJob throws a network error,
        // DO NOT mark the item as AiReviewStatus.unavailable!
        // Leave it as notChecked (or its current status) and continue.
        continue;
      }
    }
    if (changed) {
      ref.invalidate(needsReviewItemsProvider);
      ref.invalidate(needsReviewCountProvider);
      ref.invalidate(autoResolvedHistoryProvider);
      ref.invalidate(autoResolvedCountProvider);
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
      ref.invalidate(homeSummaryProvider);
      ref.invalidate(bankAccountSummariesProvider);
    }
    final remainingItems = await reviewRepo.fetchAll();
    scheduleInFlightAiPoll(remainingItems);
  }

  scheduleInFlightAiPoll = (List<NeedsReviewItem> items) {
    if (disposed) return;
    final hasInFlight = items.any(
      (item) =>
          item.aiStatus == AiReviewStatus.queued ||
          item.aiStatus == AiReviewStatus.processing,
    );
    if (!hasInFlight) return;
    inFlightPollTimer?.cancel();
    inFlightPollTimer = Timer(const Duration(seconds: 4), () async {
      if (disposed) return;
      try {
        await reconcileAiNeedsReview();
      } catch (_) {}
    });
  };

  // Local scanning has no API dependency. Progress advances only after each
  // page has been captured, and later passes read strictly newer provider IDs.
  Future<bool> reconcileInbox() async {
    if (ref.read(userCardsRepositoryProvider) == null) return false;
    final scanned = await ref
        .read(smsAutoImportProvider)
        .captureExistingInbox();
    return scanned > 0;
  }

  Future<void> flushAndRetry() async {
    if (disposed) return;
    if (workInProgress) {
      // Startup, auth restoration, and resume may all request the same pass.
      // Coalesce those requests instead of silently dropping the one that
      // arrived while the first pass was still waiting on the API.
      rerunRequested = true;
      return;
    }
    workInProgress = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        smsCaptureNamespaceKey,
        ref.read(cacheNamespaceProvider),
      );
      // The shared rule bundle is downloaded, not local, so the device has to
      // be online to learn a new rule. It refreshes here — on the lifecycle
      // pass — rather than inside the SMS sync: a sync pass must make
      // exactly one request, and an offline pass must make none.
      if (ref.read(isOnlineProvider).valueOrNull == true) {
        try {
          final cache = await ref.read(responseCacheProvider.future);
          final bundleStore = SmsRuleBundleStore(cache.financialStore.database);
          final updated = await bundleStore.syncRules(
            ref.read(authenticatedHttpClientProvider),
            apiBaseUrl: _apiBaseUrl,
            bearerToken: ref.read(accessTokenProvider),
            clientVersion: ref.read(appVersionProvider).valueOrNull ?? '1.0.0',
            namespace: ref.read(cacheNamespaceProvider),
          );
          if (updated) {
            ref.invalidate(activeSmsRuleBundleProvider);
          }
        } catch (_) {
          // Best effort: the cached bundle keeps working offline.
        }
      }
      do {
        rerunRequested = false;
        // Start the receiver from the same authenticated lifecycle pass as the
        // inbox reconciliation. Previously these were two independent startup
        // providers: after an update, the listener could register while the
        // reconciliation pass ran before SMS permission/token restoration had
        // settled, leaving the app listening but never importing the existing
        // inbox until a later resume.
        await ref.read(smsAutoImportProvider).start();
        var changed = false;
        try {
          changed = await reconcileInbox();
        } catch (e, st) {
          debugPrint('reconcileInbox error: $e\n$st');
          // A provider/permission/network failure must not abort the remaining
          // queue retry and must not surface as an unhandled lifecycle error.
        }
        // Network reconciliation drains durable local rows; it never rereads
        // inbox history and can fail without undoing completed local capture.
        changed = await flush() > 0 || changed;
        // Repair rows imported by older builds, including categories and
        // cross-source duplicate candidates that need a user's decision.
        // Run once per migration revision/account, not every five minutes.
        final repo = ref.read(userCardsRepositoryProvider);
        final prefs = await SharedPreferences.getInstance();
        final repairKey =
            'pandapay_app.sms_history_repaired_at_v2_${ref.read(cacheNamespaceProvider)}';
        final lastRepair = prefs.getInt(repairKey);
        final repairDue = lastRepair == null;
        if (repo != null &&
            repairDue &&
            ref.read(isOnlineProvider).valueOrNull != false) {
          try {
            final repaired = await repo.reconcileSmsHistory();
            // An older API may accept this route but not include the v2
            // cross-source repair. Retry after the backend rollout.
            if (repaired.reconciliationVersion >= 2) {
              await prefs.setInt(
                repairKey,
                DateTime.now().millisecondsSinceEpoch,
              );
            }
            if (repaired.crossSourceCandidatesCreated > 0) {
              ref.invalidate(duplicateCandidatesProvider);
            }
            changed =
                repaired.duplicateSuppressed > 0 ||
                repaired.crossSourceCandidatesCreated > 0 ||
                repaired.linkedCards > 0 ||
                repaired.reclassified > 0 ||
                repaired.classificationReclassified > 0 ||
                repaired.remappedTransactions > 0 ||
                changed;
          } catch (_) {
            /* Retry the one-time migration after connectivity returns. */
          }
        }
        try {
          await reconcileAiNeedsReview();
        } catch (_) {
          // Review rows remain local and retry on the next lifecycle pass.
        }
        final reviewRepo = ref.read(needsReviewRepositoryProvider);
        scheduleInFlightAiPoll(await reviewRepo.fetchAll());
        if (changed) {
          ref.invalidate(userCardsProvider);
          ref.invalidate(transactionsProvider);
          ref.invalidate(utilizationTransactionsProvider);
          ref.invalidate(homeSummaryProvider);
          // Reconciliation can change active-row counts and categories, so
          // refresh dependent reports once after a real change only.
          ref.invalidate(spendReportProvider);
          ref.invalidate(budgetsProvider);
          ref.invalidate(recurringReportProvider);
        }
      } while (rerunRequested && !disposed);
    } catch (_) {
      // Local capture and outbox rows remain durable. Lifecycle callbacks
      // must not turn an unavailable database/API into an unhandled error.
    } finally {
      workInProgress = false;
    }
  }

  // Auth restoration is asynchronous. The first startup pass can happen
  // while there is no repository yet, so retry again as soon as the token is
  // restored instead of leaving valid SMS spends stranded in the old local
  // review queue.
  ref.listen<String>(cacheNamespaceProvider, (previous, next) {
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setString(smsCaptureNamespaceKey, next),
      ),
    );
    if (next != 'signed-out' && next != previous) {
      unawaited(flushAndRetry());
    }
  });

  ref.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) {
    if (previous?.valueOrNull == false && next.valueOrNull == true) {
      unawaited(flushAndRetry());
    }
  });

  ref.listen<int>(smsFlushTriggerProvider, (_, _) {
    unawaited(flushAndRetry());
  });

  final listener = AppLifecycleListener(
    onResume: () => unawaited(flushAndRetry()),
  );
  ref.onDispose(listener.dispose);
  final aiReconcileTimer = Timer.periodic(
    const Duration(seconds: 90),
    (_) => unawaited(flushAndRetry()),
  );
  ref.onDispose(aiReconcileTimer.cancel);
  // Once at startup too: the most common case is the app being opened
  // fresh after messages arrived, which fires no resume event.
  unawaited(flushAndRetry());
});

/// Owns the one live SMS registration for the whole app. The old listener
/// was only started from SmsImportScreen, which meant QR payments made from
/// Home/Scan were never captured unless the user had opened that screen and
/// tapped "Start listening" first.
class SmsInboxSyncSummary {
  final int scanned;
  final int imported;
  final int duplicates;
  final int ignored;
  final int needsReview;
  final int dueDatesUpdated;
  final int statementDaysUpdated;

  const SmsInboxSyncSummary({
    required this.scanned,
    required this.imported,
    required this.duplicates,
    required this.ignored,
    this.needsReview = 0,
    this.dueDatesUpdated = 0,
    this.statementDaysUpdated = 0,
  });
}

final smsListenerServiceProvider = Provider<SmsListenerService>(
  (ref) => const SmsListenerService(),
);

class SmsInboxOverview {
  final int bankAlerts;
  final int spends;
  final int pendingSync;
  const SmsInboxOverview({
    required this.bankAlerts,
    required this.spends,
    required this.pendingSync,
  });
}

class SmsAutoImportController {
  SmsAutoImportController(this._ref)
    : _service = _ref.read(smsListenerServiceProvider) {
    _ref.onDispose(() {
      _disposed = true;
      _retryTimer?.cancel();
      _captureWorker?.dispose();
      inboxScanProgress.dispose();
    });
  }

  final Ref _ref;
  final SmsListenerService _service;
  final inboxScanProgress = ValueNotifier<SmsInboxScanProgress>(
    const SmsInboxScanProgress(),
  );
  bool _registered = false;
  String? _userCardIdOverride;
  Future<SmsInboxSyncSummary>? _activeInboxSync;
  String? _activeUploadNamespace;
  Future<int>? _activeInboxCapture;
  String? _activeCaptureNamespace;
  Timer? _retryTimer;
  bool _disposed = false;
  bool _uploadAgainRequested = false;
  Future<void>? _starting;
  SmsCaptureWorker? _captureWorker;

  void setCardOverride(String? userCardId) => _userCardIdOverride = userCardId;

  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    if (_disposed ||
        _registered ||
        !await _service.hasPermissions() ||
        _disposed) {
      return;
    }
    _service.listenForeground((sender, body, receivedAt) {
      unawaited(_handle(sender, body, receivedAt));
    });
    _registered = true;
  }

  /// Both the existing SMS screen and app lifecycle use this one owner.
  /// Ordinary display pages only read the shared financial store.
  Future<SmsInboxSyncSummary> syncExistingInbox() async {
    final scanned = await captureExistingInbox();
    return syncPendingMessages(scanned: scanned);
  }

  Future<int> captureExistingInbox() async {
    if (_disposed) return 0;
    final namespace = _ref.read(cacheNamespaceProvider);
    final active = _activeInboxCapture;
    if (active != null) {
      if (_activeCaptureNamespace == namespace) return active;
      try {
        await active;
      } catch (_) {
        /* Previous account stopped. */
      }
      return captureExistingInbox();
    }
    final work = _captureExistingInbox(namespace);
    _activeInboxCapture = work;
    _activeCaptureNamespace = namespace;
    try {
      return await work;
    } finally {
      _activeInboxCapture = null;
      _activeCaptureNamespace = null;
    }
  }

  Future<int> _captureExistingInbox(String namespace) async {
    if (!await _service.hasPermissions()) return 0;
    final cache = await _ref.read(responseCacheProvider.future);
    final store = cache.financialStore;
    store.migrateLegacy(namespace);
    void checkAccount() {
      if (_disposed || _ref.read(cacheNamespaceProvider) != namespace) {
        throw StateError('Account changed during SMS capture');
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final lastScanVer = prefs.getInt('pandapay_app.sms_inbox_scanner_ver_${namespace}') ?? 0;
    if (lastScanVer < LocalSmsParser.version) {
      SmsInboxProgress(store.database).rewind(namespace, 300);
      await prefs.setInt('pandapay_app.sms_inbox_scanner_ver_${namespace}', LocalSmsParser.version);
    }

    final scanner = SmsInboxScanner(
      progress: SmsInboxProgress(store.database),
      head: _service.inboxHeadId,
      read: (afterId, throughId) =>
          _service.readInboxPage(afterId: afterId, throughId: throughId),
      checkAccount: checkAccount,
      onProgress: (progress) {
        if (!_disposed) inboxScanProgress.value = progress;
      },
      capture: (messages) async {
        checkAccount();
        // Upgrade scans establish row-ID progress once. Already confirmed
        // financial sources are not parsed or uploaded a second time.
        final queued = [
          for (final message in messages)
            QueuedSms(
              sender: message.sender,
              body: message.body,
              receivedAt: message.receivedAt,
            ),
        ];
        await _captureMessages(namespace, cache, queued);
      },
    );
    return scanner.scan(namespace);
  }

  Future<void> _captureMessages(
    String namespace,
    ResponseCache cache,
    List<QueuedSms> messages,
  ) async {
    if (messages.isEmpty) return;
    if (_disposed || _ref.read(cacheNamespaceProvider) != namespace) {
      throw StateError('Account changed during SMS capture');
    }
    final store = cache.financialStore;
    final path = store.database.filePath;
    void captureDirect() {
      final clientVersion =
          _ref.read(appVersionProvider).valueOrNull ?? '1.0.0';
      final ruleStore = SmsRuleBundleStore(store.database);
      final rules = ruleStore.loadActiveBundleSync(
        clientVersion: clientVersion,
      );
      final candidateRules = ruleStore.loadCandidateBundlesSync(
        clientVersion: clientVersion,
        namespace: namespace,
      );
      SmsImportStore(
        store,
        downloadedRules: rules,
        candidateRules: candidateRules,
      ).captureBatch(namespace, messages);
    }

    if (path == null) {
      // In-memory test databases cannot be reopened by another isolate.
      captureDirect();
    } else {
      try {
        final worker = _captureWorker ??= SmsCaptureWorker(
          path,
          clientVersion: _ref.read(appVersionProvider).valueOrNull ?? '1.0.0',
        );
        final changed = await worker.capture(namespace, messages);
        if (_disposed || _ref.read(cacheNamespaceProvider) != namespace) {
          throw StateError('Account changed during SMS capture');
        }
        store.notifyExternalChanges(namespace, changed);
      } catch (e) {
        debugPrint(
          'Worker capture failed ($e), falling back to direct store capture',
        );
        captureDirect();
      }
    }
    _ref.invalidate(commitmentsProvider);
    _ref.invalidate(pendingRecoveryStatusProvider);
  }

  /// Read the same account-scoped store used by Spending. Counts include
  /// earlier capture passes, including one coalesced with app resume.
  Future<SmsInboxOverview> inboxOverview() async {
    final namespace = _ref.read(cacheNamespaceProvider);
    final cache = await _ref.read(responseCacheProvider.future);
    if (_disposed || _ref.read(cacheNamespaceProvider) != namespace) {
      throw StateError('Account changed during SMS setup');
    }
    final store = cache.financialStore;
    final counts = SmsIntakeRepository(store.database).counts(namespace);
    final spends =
        store
            .transactions(namespace, const TransactionQuery(source: 'sms'))
            ?.rows
            .length ??
        0;
    return SmsInboxOverview(
      bankAlerts: counts.captured,
      spends: spends,
      pendingSync: counts.pending,
    );
  }

  /// Card discovery uses the same captured messages as every financial view.
  /// This only catches up newer IDs; it never launches a separate history scan.
  Future<List<String>> capturedSmsBodies({int limit = 500}) async {
    final namespace = _ref.read(cacheNamespaceProvider);
    await captureExistingInbox();
    if (_ref.read(cacheNamespaceProvider) != namespace) {
      throw StateError('Account changed during card discovery');
    }
    final cache = await _ref.read(responseCacheProvider.future);
    return SmsIntakeRepository(
      cache.financialStore.database,
    ).capturedBodies(namespace, limit: limit);
  }

  Future<SmsInboxSyncSummary> syncPendingMessages({int scanned = 0}) async {
    if (_disposed) {
      return SmsInboxSyncSummary(
        scanned: scanned,
        imported: 0,
        duplicates: 0,
        ignored: 0,
      );
    }
    final namespace = _ref.read(cacheNamespaceProvider);
    final active = _activeInboxSync;
    if (active != null) {
      if (_activeUploadNamespace == namespace) {
        _uploadAgainRequested = true;
        return active;
      }
      try {
        await active;
      } catch (_) {
        /* Previous account stopped. */
      }
      return syncPendingMessages(scanned: scanned);
    }
    _retryTimer?.cancel();
    _uploadAgainRequested = false;
    final work = _syncPendingMessages(namespace, scanned);
    _activeInboxSync = work;
    _activeUploadNamespace = namespace;
    try {
      return await work;
    } finally {
      _activeInboxSync = null;
      _activeUploadNamespace = null;
      if (!_disposed && _ref.read(cacheNamespaceProvider) == namespace) {
        final cache = _ref.read(responseCacheProvider).valueOrNull;
        final next = cache == null
            ? null
            : SmsIntakeRepository(
                cache.financialStore.database,
              ).nextRetryAt(namespace);
        if (next != null &&
            _ref.read(userCardsRepositoryProvider) != null &&
            _ref.read(isOnlineProvider).valueOrNull != false) {
          final wait = next.difference(DateTime.now());
          final delay = wait.isNegative || wait == Duration.zero
              ? (_uploadAgainRequested
                    ? const Duration(milliseconds: 100)
                    : const Duration(seconds: 30))
              : wait;
          _retryTimer = Timer(delay, () async {
            if (_disposed || _ref.read(cacheNamespaceProvider) != namespace) {
              return;
            }
            try {
              await syncPendingMessages();
            } catch (_) {
              /* Resume/reconnect also retries. */
            }
          });
        }
      }
    }
  }

  Future<SmsInboxSyncSummary> _syncPendingMessages(
    String namespace,
    int scanned,
  ) async {
    var imported = 0,
        duplicates = 0,
        ignored = 0,
        needsReview = 0,
        dueDatesUpdated = 0,
        statementDaysUpdated = 0;
    final repo = _ref.read(userCardsRepositoryProvider);
    if (repo == null) {
      return SmsInboxSyncSummary(
        scanned: scanned,
        imported: 0,
        duplicates: 0,
        ignored: 0,
      );
    }
    final cache = await _ref.read(responseCacheProvider.future);
    final intake = SmsIntakeRepository(cache.financialStore.database);
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    // Old preference queues are upgrade-only input, isolated until account
    // ownership can be recovered through the existing recovery flow.
    for (final message in SmsBackgroundQueue.read(prefs)) {
      if (!LocalSmsParser.sensitive(message.body)) {
        intake.capture('legacy', message);
      }
    }
    await SmsBackgroundQueue.clear(prefs);
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);
    for (var batch = 0; batch < 100; batch++) {
      if (_ref.read(cacheNamespaceProvider) != namespace ||
          _ref.read(isOnlineProvider).valueOrNull == false) {
        break;
      }
      final pending = intake.pending(
        namespace,
        readyOnly: true,
        billingPriority: true,
      );
      if (pending.isEmpty) break;
      try {
        // Historical statement alerts must reach the server before the
        // current-month fallback. Otherwise a current reminder can fill
        // statement_day before September/August history gets a chance to
        // establish the recurring billing day.
        for (final backfill in [true, false]) {
          final messages = [
            for (final entry in pending)
              if ((DateTime(
                        entry.message.receivedAt.year,
                        entry.message.receivedAt.month,
                      ) !=
                      currentMonth) ==
                  backfill)
                SmsBatchMessage(
                  userCardId: _userCardIdOverride,
                  sender: entry.message.sender,
                  body: entry.message.body,
                  occurredAt: entry.message.receivedAt,
                ),
          ];
          if (messages.isEmpty) continue;
          if (_ref.read(cacheNamespaceProvider) != namespace) break;
          final result = await repo.logTransactionsFromSmsBatch(
            messages: messages,
            backfill: backfill,
            captureLocally: false,
            notifyNewTransactions: !backfill,
          );
          imported += result.imported;
          duplicates += result.duplicate;
          ignored += result.unparsed + result.invalid + result.errored;
          needsReview += result.needsReview;
          dueDatesUpdated += result.dueDatesUpdated;
          statementDaysUpdated += result.statementDaysUpdated;
        }
      } catch (e, st) {
        debugPrint('_syncPendingMessages batch error: $e\n$st');
        // Local capture/progress is already durable. Retry only this outbox.
        for (final entry in pending) {
          intake.failed(namespace, entry.id);
        }
        break;
      }
      final remaining = intake.pending(namespace).map((e) => e.id).toSet();
      final unresolved = pending
          .where((e) => remaining.contains(e.id))
          .toList();
      if (unresolved.isNotEmpty) {
        for (final entry in unresolved) {
          intake.failed(namespace, entry.id);
        }
        break;
      }
      await Future<void>.delayed(Duration.zero);
    }
    // Phase 2: drain the typed-facts outbox (balance snapshots, autopay
    // mandate life-cycle, failed attempts). Raw bodies never ride this
    // path; facts are replay-idempotent under the same source key. Failures
    // keep the row queued; a 404 (older backend image) also keeps it.
    try {
      final factsOutbox = SmsFactsOutbox(cache.financialStore.database);
      for (final entry in factsOutbox.pending(namespace)) {
        if (_ref.read(cacheNamespaceProvider) != namespace) break;
        if (_ref.read(isOnlineProvider).valueOrNull == false) break;
        final accepted = await repo.logSmsFacts(envelope: entry.envelope);
        if (accepted) {
          factsOutbox.acknowledge(namespace, entry.id);
        } else {
          factsOutbox.failed(namespace, entry.id);
        }
      }
      for (final correction in factsOutbox.pendingOverrides(namespace)) {
        if (_ref.read(cacheNamespaceProvider) != namespace) break;
        if (_ref.read(isOnlineProvider).valueOrNull == false) break;
        final accepted = await repo.overrideSmsFact(
          sourceKey: correction.sourceKey,
          factIndex: correction.factIndex,
          patch: correction.patch,
          reason: correction.reason,
          sampleBody: correction.sampleBody,
          templateText: correction.templateText,
        );
        if (accepted) {
          factsOutbox.acknowledgeOverride(
            namespace,
            correction.sourceKey,
            correction.factIndex,
          );
        } else {
          factsOutbox.failedOverride(
            namespace,
            correction.sourceKey,
            correction.factIndex,
          );
        }
      }
      final exposureOutbox = SmsRuleExposureOutbox(
        cache.financialStore.database,
      );
      final pendingExposures = exposureOutbox.pending(namespace);
      if (pendingExposures.isNotEmpty &&
          _ref.read(isOnlineProvider).valueOrNull != false &&
          _ref.read(cacheNamespaceProvider) == namespace) {
        final accepted = await repo.logSmsRuleExposures(
          exposures: pendingExposures,
        );
        for (final exposure in pendingExposures) {
          final candidateId = exposure['candidateId'] as String;
          final sourceKey = exposure['sourceKey'] as String;
          final stage = exposure['stage'] as String;
          final stageVersion = (exposure['stageVersion'] as int?) ?? 1;
          if (accepted) {
            exposureOutbox.acknowledge(
              namespace,
              candidateId,
              sourceKey,
              stage,
              stageVersion: stageVersion,
            );
          } else {
            exposureOutbox.failed(
              namespace,
              candidateId,
              sourceKey,
              stage,
              stageVersion: stageVersion,
            );
          }
        }
      }
    } catch (_) {
      // Facts accumulate durably; the next sync retries.
    }
    if (_ref.read(cacheNamespaceProvider) == namespace &&
        (imported > 0 ||
            needsReview > 0 ||
            dueDatesUpdated > 0 ||
            statementDaysUpdated > 0)) {
      if (dueDatesUpdated > 0 || statementDaysUpdated > 0) {
        await _clearUserCardsCacheForRef(_ref);
      }
      _ref.invalidate(userCardsProvider);
      _ref.invalidate(myCardsProvider);
      _ref.invalidate(transactionsProvider);
      _ref.invalidate(utilizationTransactionsProvider);
      _ref.invalidate(homeSummaryProvider);
      _ref.invalidate(needsReviewCountProvider);
      _ref.invalidate(spendReportProvider);
      _ref.invalidate(budgetsProvider);
      _ref.invalidate(recurringReportProvider);
    }
    return SmsInboxSyncSummary(
      scanned: scanned,
      imported: imported,
      duplicates: duplicates,
      ignored: ignored,
      needsReview: needsReview,
      dueDatesUpdated: dueDatesUpdated,
      statementDaysUpdated: statementDaysUpdated,
    );
  }

  Future<void> _handle(String sender, String body, DateTime receivedAt) async {
    if (_disposed || LocalSmsParser.sensitive(body)) return;
    final namespace = _ref.read(cacheNamespaceProvider);
    try {
      final cache = await _ref.read(responseCacheProvider.future);
      if (_ref.read(cacheNamespaceProvider) != namespace) return;
      await _captureMessages(namespace, cache, [
        QueuedSms(sender: sender, body: body, receivedAt: receivedAt),
      ]);
      // Delivery never advances scan progress: there may still be unread
      // provider rows before this broadcast. All uploads use one outbox owner.
      await syncPendingMessages();
    } catch (_) {
      // Inbox recovery remains available if local storage/delivery failed.
      // If only HTTP failed, the durable pending row already remains queued.
    }
  }
}

final smsAutoImportProvider = Provider<SmsAutoImportController>((ref) {
  return SmsAutoImportController(ref);
});

/// Starts live capture at app startup and retries after every resume. This
/// matters when permission is granted from the SMS settings screen after the
/// app shell has already been built.
final smsListenerLifecycleProvider = Provider<void>((ref) {
  final controller = ref.read(smsAutoImportProvider);
  final listener = AppLifecycleListener(
    onResume: () => unawaited(controller.start()),
  );
  ref.onDispose(listener.dispose);
  unawaited(controller.start());
});

final _bestCardForWidgetProvider = Provider<BestCardForWidget>((ref) {
  return BestCardForWidget(engine: ref.watch(recommendationEngineProvider));
});

/// UA-8.1/8.3: "which card should I use at *this* merchant" — the
/// geofence screen's per-tile ranking. Deliberately reuses the same
/// catalogue/userCards state rankedRecommendationsProvider already
/// fetches, and the same BestCardForWidget.pickBestCard the home-screen
/// widget uses (packages/pandapay_domain/lib/src/geo/best_card_for_widget.dart)
/// — one "pick the best card" implementation, called from two different
/// UI entry points (a nearby-merchant tile here, a home-screen widget
/// there), not two competing ranking paths.
// Note: deliberately NOT wired to card_overrides (unlike
// rankedRecommendationsProvider above) — B8's spec scopes override
// wiring to Home's ranking; extending it to the geofence tile's
// per-merchant ranking is a natural follow-up, not done here.
/// B8 manual overrides now feed this too, not just Home's
/// rankedRecommendationsProvider — this is what Nearby Merchants'
/// per-tile "Use X" recommendation actually calls
/// ([bestCardForMerchantProvider] usage in nearby_merchants_screen.dart),
/// so an override the user set for a category previously had no effect
/// there even though it visibly changed the exact same category's
/// recommendation on Home. Same resolveActiveOverrideCardProductId call
/// rankedRecommendationsProvider makes, so the two never disagree about
/// which override is active for a given category.
class MerchantRecommendationQuery {
  final String? categoryId;
  final String? merchantName;

  const MerchantRecommendationQuery({this.categoryId, this.merchantName});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MerchantRecommendationQuery &&
          other.categoryId == categoryId &&
          other.merchantName == merchantName;

  @override
  int get hashCode => Object.hash(categoryId, merchantName);
}

final bestCardForMerchantProvider =
    Provider.family<AsyncValue<Recommendation?>, Object?>((ref, arg) {
      final String? categoryId;
      final String? merchantName;
      if (arg is MerchantRecommendationQuery) {
        categoryId = arg.categoryId;
        merchantName = arg.merchantName;
      } else if (arg is ({String? categoryId, String? merchantName})) {
        categoryId = arg.categoryId;
        merchantName = arg.merchantName;
      } else if (arg is String?) {
        categoryId = arg;
        merchantName = null;
      } else {
        categoryId = null;
        merchantName = null;
      }

      final catalogue = ref.watch(catalogueProvider);
      final userCards = ref.watch(userCardsProvider);
      final overrides = ref.watch(cardOverridesProvider);
      final picker = ref.watch(_bestCardForWidgetProvider);

      if (catalogue.isLoading || userCards.isLoading || overrides.isLoading) {
        return const AsyncValue.loading();
      }
      final combinedError =
          catalogue.error ?? userCards.error ?? overrides.error;
      if (combinedError != null) {
        return AsyncValue.error(
          combinedError,
          catalogue.stackTrace ?? userCards.stackTrace ?? overrides.stackTrace!,
        );
      }

      final allCards = catalogue.requireValue;
      final wallet = userCards.requireValue;
      final cards = wallet.isEmpty
          ? allCards
          : allCards
                .where((c) => wallet.any((w) => w.cardProductId == c.id))
                .toList();

      final categories = ref.watch(categoriesProvider);
      final categoryList = categories.valueOrNull ?? const <SpendCategory>[];
      final matchedCategory = categoryList.firstWhereOrNull(
        (c) => c.id == categoryId || c.slug == categoryId,
      );
      final resolvedCategoryId = matchedCategory?.id ?? categoryId;
      final categorySlug = matchedCategory?.slug;

      final overrideProductId = resolveActiveOverrideCardProductId(
        overrides: overrides.requireValue,
        wallet: wallet,
        categoryId: resolvedCategoryId,
      );

      final snapshots = _userCardSnapshots(
        cards,
        wallet,
        forcedOverrideCardId: overrideProductId,
      );

      return AsyncValue.data(
        picker.pickBestCard(
          cards: snapshots,
          categoryId: resolvedCategoryId,
          categorySlug: categorySlug,
          merchantName: merchantName,
          now: ref.watch(clockProvider).now(),
        ),
      );
    });

final homeWidgetServiceProvider = Provider<HomeWidgetService>(
  (ref) => HomeWidgetService(),
);

/// UA-8.2: "top overall card" default the widget falls back to when there's
/// no last-used-category context — reuses bestCardForMerchantProvider(null),
/// which already collapses to "no category filter" when its family
/// argument is null.
final bestOverallCardProvider = Provider<AsyncValue<Recommendation?>>((ref) {
  return ref.watch(bestCardForMerchantProvider(null));
});

extension _FirstWhereOrNull<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
