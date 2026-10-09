import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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
import '../data/authenticated_http_client.dart';
import '../data/card_feedback_repository.dart';
import '../data/card_overrides_repository.dart';
import '../data/card_requests_api.dart';
import '../data/catalogue_repository.dart';
import '../data/consents_api.dart';
import '../data/device_identity.dart';
import '../data/devices_api.dart';
import '../data/emergency_contacts_repository.dart';
import '../data/import_repository.dart';
import '../data/local/app_database.dart';
import '../data/local/response_cache.dart';
import '../data/local/sync_queue.dart';
import '../data/local/transaction_outbox_repository.dart';
import '../data/local_user_cards_repository.dart';
import '../data/merchant_search_repository.dart';
import '../data/needs_review_repository.dart';
import '../data/notification_preferences_repository.dart';
import '../data/notification_devices_api.dart';
import '../data/override_resolver.dart';
import '../data/partner_apply_repository.dart';
import '../data/recovery_api.dart';
import '../data/spend_by_category_repository.dart';
import '../data/spend_reports_repository.dart';
import '../data/sync_api.dart';
import '../data/token_store.dart';
import '../data/upi_payment_service.dart';
import '../data/user_cards_repository.dart';
import '../data/user_settings_api.dart';
import '../features/geofence/geofence_monitor_service.dart';
import '../features/geofence/nearby_merchants_repository.dart';
import '../features/home_widget/home_widget_service.dart';
import '../features/notifications/notification_gate.dart';
import '../features/notifications/notification_triggers.dart';
import '../features/notifications/push_notification_service.dart';
import '../features/sms_import/sms_listener_service.dart';
import '../features/sms_import/sms_background_queue.dart';
import '../features/settings/settings_sync.dart';
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
bool _isIgnorableSmsResult(SmsImportResult result) =>
    result.reason == 'security_message' ||
    result.reason == 'not_a_successful_spend';

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

/// The signed-in access token, or null when signed out. Seeded on startup
/// by sessionInitProvider from a stored refresh token; login_screen.dart
/// persists both tokens on a fresh OTP sign-in.
final accessTokenProvider = StateProvider<String?>((ref) => null);

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
  return _cacheNamespaceForToken(ref.watch(accessTokenProvider));
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
  return repo.fetchSpendByCategory();
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

      if (catalogue.isLoading ||
          userCards.isLoading ||
          categorySpend.isLoading) {
        return const AsyncValue.loading();
      }
      final combinedError =
          catalogue.error ?? userCards.error ?? categorySpend.error;
      if (combinedError != null) {
        return AsyncValue.error(
          combinedError,
          catalogue.stackTrace ??
              userCards.stackTrace ??
              categorySpend.stackTrace!,
        );
      }

      final allCards = catalogue.requireValue;
      final wallet = userCards.requireValue;
      final spend = categorySpend.requireValue;

      final ownedProducts = allCards
          .where((c) => wallet.any((w) => w.cardProductId == c.id))
          .toList();
      final profile = SpendProfile(
        annualSpendByCategory: {
          for (final s in spend) s.categoryId: s.totalSpend,
        },
      );

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

  ref.listen<String?>(accessTokenProvider, (previous, next) {
    // Flush on sign-out too, so events buffered before it aren't attributed
    // to whoever signs in next on the same device.
    if (previous != null && next == null) {
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
  return SyncQueue(await ref.watch(appDatabaseProvider.future));
});

/// Local edits not yet accepted by the server. Distinct from
/// [pendingOutboxCountProvider], which counts B6 quick-adds that were never
/// created server-side at all — these are edits to rows that already exist.
final pendingSyncCountProvider = FutureProvider<int>((ref) async {
  return (await ref.watch(syncQueueProvider.future)).pendingCount;
});

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
  return api.fetchStatus();
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
/// on startup. Temporary refresh failures preserve the cached session, while
/// a definitive 401/403 clears unrecoverable credentials and returns to login.
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

Future<AuthTokens> _refreshWithTransientRetry(
  AuthApi api,
  String refreshToken,
) async {
  Object? lastError;
  StackTrace? lastStack;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      return await api.refresh(refreshToken);
    } catch (error, stack) {
      if (_isRejectedCredentialRefresh(error) || attempt == 2) rethrow;
      lastError = error;
      lastStack = stack;
      await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
    }
  }
  Error.throwWithStackTrace(lastError!, lastStack!);
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
      final tokens = await _refreshWithTransientRetry(authApi, refreshToken);
      // A fresh login or another coordinator invocation may have won while
      // the network request was in flight. Never overwrite that session.
      if (readAccessToken() != accessTokenBeforeRefresh &&
          readAccessToken() != null) {
        return readAccessToken();
      }
      await store.save(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      writeAccessToken(tokens.accessToken);
      return tokens.accessToken;
    } catch (error) {
      if (_isRejectedCredentialRefresh(error) &&
          readAccessToken() == accessTokenBeforeRefresh &&
          store.refreshToken == refreshToken) {
        await store.clear();
        writeAccessToken(null);
      }
      // Network/5xx errors are recoverable. Keep the last known credentials
      // so cached screens remain usable and the next lifecycle/API retry can
      // recover without forcing a login.
      return null;
    }
  }
}

final sessionInitProvider = FutureProvider<void>((ref) async {
  final store = await ref.watch(tokenStoreProvider.future);
  final refreshToken = store.refreshToken;
  final storedAccessToken = store.accessToken;
  if (refreshToken == null) {
    // A legacy/partially-written session may contain only an access token.
    // Keep it available for the normal offline-cache path; there is no
    // refresh request we can make until the user signs in again.
    if (storedAccessToken != null) {
      ref.read(accessTokenProvider.notifier).state = storedAccessToken;
    }
    return;
  }

  final refreshed = await ref.read(sessionRefreshCoordinatorProvider).refresh();
  if (refreshed == null &&
      storedAccessToken != null &&
      store.accessToken != null) {
    // Temporary startup failures keep the last access token available for
    // local cache reads; a rejected refresh has already cleared both values.
    ref.read(accessTokenProvider.notifier).state = storedAccessToken;
  }
});

bool _isRejectedCredentialRefresh(Object error) {
  if (error is! ApiException) return false;
  final statusCode = error.statusCode;
  return statusCode == 401 || statusCode == 403;
}

/// Keeps a signed-in session alive for as long as the app stays open, not
/// just at startup. sessionInitProvider above only ever calls /auth/refresh
/// once, when the app launches; auth/'s access tokens expire after
/// JWT_ACCESS_TTL (15 minutes by default), so without this, anyone who kept
/// the app open past that window would silently start getting 401s on
/// every API call while accessTokenProvider still held the now-dead token
/// — "signed in" on screen, broken underneath. This re-reads the CURRENT
/// refresh token from storage (not a captured value) every 10 minutes,
/// comfortably inside the 15-minute TTL. Temporary refresh failures leave
/// the current session intact; a definitive 401/403 clears credentials and
/// returns the user to login.
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

  ref.listen<String?>(accessTokenProvider, (previous, next) {
    timer?.cancel();
    if (next != null) {
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
/// own doc-comment for why. `needsReviewItemsProvider` invalidates itself
/// whenever an item is added/removed (each mutation site calls
/// `ref.invalidate`), same pull-based refresh pattern as every other
/// FutureProvider in this file rather than a StateNotifier — the store is
/// a dumb list, not something with derived state worth a controller class.
final needsReviewRepositoryProvider = Provider<NeedsReviewRepository>(
  (ref) => NeedsReviewRepository(),
);

final needsReviewItemsProvider = FutureProvider<List<NeedsReviewItem>>((ref) {
  return ref.watch(needsReviewRepositoryProvider).fetchAll();
});

/// D1's badge (ui-spec §1: "Activity... with badge for D4 count") and
/// Insights Hub's tile both read this rather than the full list, so
/// neither has to unwrap an AsyncValue just to show a number.
final needsReviewCountProvider = Provider<int>((ref) {
  return ref.watch(needsReviewItemsProvider).valueOrNull?.length ?? 0;
});

/// UA-3: the signed-in user's own profiles row (owner-scoped via RLS —
/// api/'s GET /profile, proved end to end back in Chunk 1 but never called
/// from the app itself until this chunk). Null when signed out or when a
/// signed-in user hasn't completed onboarding yet (no profile row exists).
final profileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final api = ref.watch(profileApiProvider);
  if (api == null) return null;
  return api.fetchProfile();
});

/// Task C-7/C-8: null when signed out, same pattern as every other
/// auth-gated repository provider in this file — both card-requests and
/// data-error-reports are owner-scoped writes (RLS `for all to public
/// using (profile_id = pandapay.uid())`), so there's no meaningful
/// signed-out path to support.
final cardFeedbackRepositoryProvider = Provider<CardFeedbackRepository?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return CardFeedbackRepository(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

final userCardsRepositoryProvider = Provider<UserCardsRepository?>((ref) {
  final token = _stableSessionToken(ref);
  if (token == null) return null;
  return UserCardsRepository(
    apiBaseUrl: _apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

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
/// A family over [SpendPeriod] rather than a provider plus a separate
/// "selected period" StateProvider: switching period is a different fetch,
/// and keying the cache by period means flipping back to a period already
/// looked at is instant instead of re-fetching.
final spendReportProvider = FutureProvider.family<SpendReport?, SpendPeriod>((
  ref,
  period,
) async {
  final repo = ref.watch(spendReportsRepositoryProvider);
  if (repo == null) return null;
  final anchor = DateTime.now().toUtc();
  final timeZone = ref.watch(deviceTimeZoneProvider);
  final bucket = _spendReportBucket(period, DateTime.now());
  final key = _scopedCacheKey(
    ref,
    '$_spendReportCacheKey:${period.wireValue}:${_cacheDate(bucket)}:$timeZone',
  );
  final cache = await _cacheOrNull(ref);
  final cached = await _readCacheOrNull(cache, key);
  if (_isKnownOffline() && cached != null) {
    return SpendReport.fromJson(
      jsonDecode(cached.rawJson) as Map<String, dynamic>,
    );
  }
  try {
    final raw = await repo.fetchReportJson(
      period: period,
      // Periods are about the user's device calendar. Sending the device
      // instant prevents a server clock that is a few hours/days behind from
      // reporting September when the user is already in October.
      anchor: anchor,
      timeZone: timeZone,
    );
    try {
      await cache?.put(key, jsonEncode(raw));
    } catch (_) {
      // A disk/cache failure must never make a successful report unusable.
    }
    return SpendReport.fromJson(raw);
  } catch (error) {
    if (!_canUseStaleCache(error)) rethrow;
    if (cached == null) rethrow;
    try {
      return SpendReport.fromJson(
        jsonDecode(cached.rawJson) as Map<String, dynamic>,
      );
    } catch (_) {
      try {
        await cache?.clear(key);
      } catch (_) {}
      rethrow;
    }
  }
});

/// The period the Trends screen is currently showing.
final selectedSpendPeriodProvider = StateProvider<SpendPeriod>(
  (ref) => SpendPeriod.month,
);

/// Every active budget with its current-period progress.
final budgetsProvider = FutureProvider<List<BudgetStatus>>((ref) async {
  final repo = ref.watch(spendReportsRepositoryProvider);
  if (repo == null) return const [];
  return repo.fetchBudgets();
});

/// Detected subscriptions, biggest annual cost first.
final recurringReportProvider = FutureProvider<RecurringReport?>((ref) async {
  final repo = ref.watch(spendReportsRepositoryProvider);
  if (repo == null) return null;
  return repo.fetchRecurring();
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
final userCardsProvider = FutureProvider<List<UserCard>>((ref) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) {
    final local = await ref.watch(localUserCardsRepositoryProvider.future);
    final catalogue = await ref.watch(catalogueProvider.future);
    return local.fetchUserCards(catalogue: catalogue);
  }
  final cache = await _cacheOrNull(ref);
  final cacheKey = _scopedCacheKey(ref, _userCardsCacheKey);
  final cached = await cache?.get(cacheKey);
  if (_isKnownOffline() && cached != null) {
    final body = jsonDecode(cached) as Map<String, dynamic>;
    return (body['userCards'] as List)
        .cast<Map<String, dynamic>>()
        .map(UserCard.fromJson)
        .toList();
  }
  try {
    final cards = await repo.fetchUserCards().timeout(_homeRequestTimeout);
    try {
      await cache?.put(
        cacheKey,
        jsonEncode({'userCards': cards.map((c) => c.toJson()).toList()}),
      );
    } catch (_) {
      // A local-database write must never turn a successful wallet fetch into
      // an error. The next successful fetch will repair the snapshot.
    }
    return cards;
  } catch (error) {
    if (!_canUseStaleCache(error)) rethrow;
    if (cached == null) rethrow;
    final body = jsonDecode(cached) as Map<String, dynamic>;
    return (body['userCards'] as List)
        .cast<Map<String, dynamic>>()
        .map(UserCard.fromJson)
        .toList();
  }
});

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
  try {
    final overrides = await repo.fetchOverrides().timeout(_homeRequestTimeout);
    final cache = await _cacheOrNull(ref);
    try {
      await cache?.put(
        _scopedCacheKey(ref, _cardOverridesCacheKey),
        jsonEncode({'overrides': overrides.map((o) => o.toJson()).toList()}),
      );
    } catch (_) {
      // A local-database write must never turn a successful override fetch
      // into an error. The next successful fetch will repair the snapshot.
    }
    return overrides;
  } catch (error) {
    if (!_canUseStaleCache(error)) rethrow;
    final cache = await _cacheOrNull(ref);
    final cached = await cache?.get(
      _scopedCacheKey(ref, _cardOverridesCacheKey),
    );
    // Overrides are an enhancement to ranking, not a prerequisite for
    // showing the wallet. If this is the first signed-in request and there is
    // no cache yet, fail open with the base catalogue instead of replacing
    // Home with an error state while the API is unavailable.
    if (cached == null) return const [];
    final body = jsonDecode(cached) as Map<String, dynamic>;
    return (body['overrides'] as List)
        .cast<Map<String, dynamic>>()
        .map(CardOverride.fromJson)
        .toList();
  }
});

/// Privacy: user_cards/card_overrides cache entries are per-signed-in-user
/// and must not leak across a sign-out -> sign-in-as-different-user
/// sequence, same bug class already found once this session in quick-add's
/// SharedPreferences last-used-card key. catalogue/categories are public
/// and deliberately NOT cleared here.
final cacheLifecycleProvider = Provider<void>((ref) {
  ref.listen<String?>(accessTokenProvider, (previous, next) async {
    if (previous != null && next == null) {
      final cache = await _cacheOrNull(ref);
      final namespace = _cacheNamespaceForToken(previous);
      await cache?.clear('$namespace:$_userCardsCacheKey');
      await cache?.clear('$namespace:$_cardOverridesCacheKey');
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
  return TransactionOutboxRepository(
    await ref.watch(appDatabaseProvider.future),
  );
});

final pendingOutboxCountProvider = FutureProvider<int>((ref) async {
  final items = await (await ref.watch(
    outboxRepositoryProvider.future,
  )).pending();
  return items.length;
});

/// Flushes the outbox the moment connectivity comes back — read once from
/// _AppShell alongside cacheLifecycleProvider/sessionKeepAliveProvider so
/// it runs for the app's whole lifetime, not just while Home is visible.
final outboxFlushProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) async {
    final wasOffline = previous?.valueOrNull == false;
    final isNowOnline = next.valueOrNull == true;
    if (!wasOffline || !isNowOnline) return;
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) return;
    final outboxRepo = await ref.read(outboxRepositoryProvider.future);
    final sent = await outboxRepo.flush(repo);
    if (sent > 0) {
      ref.invalidate(pendingOutboxCountProvider);
      ref.invalidate(userCardsProvider);
      ref.invalidate(transactionsProvider);
      ref.invalidate(utilizationTransactionsProvider);
    }
  });
});

/// Task D-5: pending duplicate-candidate pairs; empty (not an error) when
/// signed out, same pattern as every other repository-backed provider here.
final duplicateCandidatesProvider = FutureProvider<List<DuplicateCandidate>>((
  ref,
) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  return repo.fetchDuplicateCandidates();
});

/// Task C-1 (C1 My Cards' active/archived filter). Deliberately a SEPARATE
/// provider from userCardsProvider above, not a parameterized version of
/// it — every other consumer (ranking, ownedCardsWithProductProvider, cap
/// assembly) must never see an archived card, and a shared family provider
/// keyed by this toggle would risk one of them silently picking up
/// showArchivedCardsProvider's current value. C1 is the only screen that
/// reads this.
final showArchivedCardsProvider = StateProvider<bool>((ref) => false);

final myCardsProvider = FutureProvider<List<UserCard>>((ref) async {
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
  final cards = await repo.fetchUserCards(includeArchived: includeArchived);
  return cards.where((card) => card.isArchived == includeArchived).toList();
});

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
) {
  final cycleStart = card.statementDay == null
      ? DateTime(now.year, now.month, 1)
      : _previousStatementOccurrence(card.statementDay!, now);
  var total = const Money.zero();
  for (final txn in transactions) {
    if (txn.status != 'active' || txn.userCardId != card.id) continue;
    if (txn.entryKind != TxnEntryKind.spend ||
        txn.instrument != TxnInstrument.creditCard ||
        txn.occurredAt.isBefore(cycleStart)) {
      continue;
    }
    total += txn.amount;
  }
  return total;
}

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
/// spec wording, keyed by CardProduct.id (what SplitOptimizer indexes by,
/// not UserCard.id) — cards with no credit limit entered are simply absent
/// from the ceiling map, which SplitOptimizer already treats as effectively
/// unlimited (its own default when a key is missing).
final splitPlanProvider = Provider<List<SplitAllocation>>((ref) {
  final amount = ref.watch(splitPlannerAmountProvider);
  final pairs =
      ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
  if (amount.isZero || pairs.isEmpty) return const [];

  final wallet = [for (final (uc, _) in pairs) uc];
  final products = [for (final (_, p) in pairs) p];
  final snapshots = _userCardSnapshots(products, wallet);
  final transactions =
      ref.watch(utilizationTransactionsProvider).valueOrNull ?? const [];
  final now = ref.watch(clockProvider).now();

  final utilizationCeiling = <String, Money>{};
  for (final (userCard, product) in pairs) {
    final limit = userCard.creditLimit;
    if (limit == null || limit.isZero) continue;
    final threshold = limit * 0.30;
    final trackedSpend = _trackedCreditCardSpend(userCard, transactions, now);
    final headroom = threshold - trackedSpend;
    utilizationCeiling[product.id] = headroom.isNegative
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
    utilizationCeiling: utilizationCeiling,
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
  return repo.fetchLoungeUsage();
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
      return repo.fetchPointsLedger(userCardId);
    });

/// Task E9: current month's report, recomputed on demand server-side each
/// time this is watched/invalidated (see GET /monthly-reports' doc-comment
/// for why only the current month is safe to always-recompute).
final currentMonthlyReportProvider = FutureProvider<MonthlyReport?>((
  ref,
) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return null;
  return repo.fetchMonthlyReport();
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
  final cached = await _readCacheOrNull(cache, key);
  if (_isKnownOffline() && cached != null) {
    return HomeSummary.fromJson(
      jsonDecode(cached.rawJson) as Map<String, dynamic>,
    );
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
    if (!_canUseStaleCache(error)) rethrow;
    if (cached == null) rethrow;
    return HomeSummary.fromJson(
      jsonDecode(cached.rawJson) as Map<String, dynamic>,
    );
  }
});

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
      return repo.fetchNotifications();
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
      return repo.fetch();
    });

/// Design 25's Invite friends payload. Null when signed out — an invite
/// code belongs to an account.
final referralsProvider = FutureProvider<ReferralInfo?>((ref) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return null;
  return repo.fetchReferrals();
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
      return repo.fetchContributionNetworkStats();
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
  return repo.fetchForwardingAddress();
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
  return repo.fetchForwardingVerification();
});

/// F3: this profile's recently received forwarded emails, newest first.
/// Real data once a mail provider is wired to POST /inbound-emails/webhook
/// for a given deployment — empty (not fake) until then.
final inboundEmailsProvider = FutureProvider<List<InboundEmail>>((ref) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return const [];
  return repo.fetchInboundEmails();
});

/// F2/F1: recent statement imports, newest first.
final statementImportsProvider = FutureProvider<List<StatementImport>>((
  ref,
) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return const [];
  return repo.fetchStatementImports();
});

/// F4/F1: recent SMS backup-file import batches.
final smsImportBatchesProvider = FutureProvider<List<SmsImportBatch>>((
  ref,
) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return const [];
  return repo.fetchSmsImportBatches();
});

/// F5: backup/restore status + this user's sync-conflict log.
final backupStatusProvider = FutureProvider<BackupStatus?>((ref) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return null;
  return repo.fetchBackupStatus();
});

/// F7/F1: this profile's IMAP connection, or null if never configured.
final imapConnectionProvider = FutureProvider<ImapConnection?>((ref) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return null;
  return repo.fetchImapConnection();
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
  return HttpMerchantSearchRepository(baseUrl: _apiBaseUrl);
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

/// Identity of the installed build, including the Android build number. SMS
/// reconciliation uses this rather than a permanent boolean: an app update
/// must get one fresh inbox pass even when the previous version already
/// reconciled this device.
final appBuildIdentityProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version}+${info.buildNumber}';
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
  return ResponseCache(await ref.watch(appDatabaseProvider.future));
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

bool _lastKnownOffline = false;

bool _isKnownOffline() => _lastKnownOffline;

/// The cache is always best-effort — every offline-cache-aware provider
/// below calls this instead of watching responseCacheProvider directly, so
/// a local-DB init failure (an unavailable platform channel in a plain
/// unit test, or a genuine device I/O error) degrades to "no cache" rather
/// than taking down the whole provider and everything that depends on it.
Future<ResponseCache?> _cacheOrNull(Ref ref) async {
  try {
    return await ref.watch(responseCacheProvider.future);
  } catch (_) {
    return null;
  }
}

Future<CachedResponse?> _readCacheOrNull(
  ResponseCache? cache,
  String key,
) async {
  try {
    return await cache?.read(key);
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
const _cardOverridesCacheKey = 'card_overrides';
// Home is a decision surface, not a background report. A socket that never
// completes must become a cache/fallback/error state instead of leaving the
// recommendation section in AsyncLoading forever.
const _homeRequestTimeout = Duration(seconds: 15);
const _spendReportCacheKey = 'spend_report';
const _transactionsCacheKey = 'transactions';

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
  }
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
  String? source,
  String? query,
}) async {
  final key = _scopedCacheKey(ref, cacheKey);
  final cache = await _cacheOrNull(ref);
  final cached = await _readCacheOrNull(cache, key);

  Future<List<TransactionEntry>> decodeCached() async {
    if (cached == null) {
      throw StateError('No cached transactions available');
    }
    final body = jsonDecode(cached.rawJson) as Map<String, dynamic>;
    return (body['transactions'] as List)
        .cast<Map<String, dynamic>>()
        .map(TransactionEntry.fromJson)
        .toList();
  }

  // Interface loss is a known offline state. Use the local snapshot
  // immediately instead of waiting for a mobile socket timeout.
  if (_isKnownOffline() && cached != null) {
    return decodeCached();
  }
  try {
    final transactions = await repo.fetchTransactions(
      from: from,
      to: to,
      cardId: cardId,
      categoryId: categoryId,
      source: source,
      query: query,
    );
    try {
      await cache?.put(
        key,
        jsonEncode({
          'transactions': transactions
              .map((transaction) => transaction.toJson())
              .toList(),
        }),
      );
    } catch (_) {
      // A cache write must never turn a successful online read into an error.
    }
    return transactions;
  } catch (error) {
    if (!_canUseStaleCache(error)) rethrow;
    if (cached == null) rethrow;
    try {
      return await decodeCached();
    } catch (_) {
      // A partial/corrupt local row should be discarded rather than trapping
      // every future request in the same parse failure.
      try {
        await cache?.clear(key);
      } catch (_) {}
      rethrow;
    }
  }
}

/// UA-0.3 offline step: live fetch first, caching the raw response on
/// success; on ANY fetch failure, falls back to the last cached response
/// rather than leaving Home with nothing to rank against. Only fires the
/// fallback on a genuine failure — a successful-but-empty catalogue is
/// never treated as "fetch failed."
final catalogueProvider = FutureProvider<List<CardProduct>>((ref) async {
  final cache = await _cacheOrNull(ref);
  final cached = await cache?.get(_catalogueCacheKey);
  if (_isKnownOffline() && cached != null) {
    try {
      final body = jsonDecode(cached) as Map<String, dynamic>;
      return (body['cards'] as List)
          .cast<Map<String, dynamic>>()
          .map(CardProductJson.fromJson)
          .toList();
    } catch (_) {
      // Fall through to the bundled catalogue below.
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
  final cached = await cache?.get(_categoriesCacheKey);
  if (_isKnownOffline() && cached != null) {
    try {
      final body = jsonDecode(cached) as Map<String, dynamic>;
      return (body['categories'] as List)
          .cast<Map<String, dynamic>>()
          .map(SpendCategory.fromJson)
          .toList();
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
    return categories;
  } catch (_) {
    try {
      if (cached != null) {
        final body = jsonDecode(cached) as Map<String, dynamic>;
        return (body['categories'] as List)
            .cast<Map<String, dynamic>>()
            .map(SpendCategory.fromJson)
            .toList();
      }
    } catch (_) {
      // Fall through to the category-less ranking path below.
    }

    // Category ids improve the ranking but are not required to produce a
    // truthful base-rate recommendation. The engine safely falls back to
    // catch-all card rules until the next refresh can load the ids.
    return const [];
  }
});

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
final rankedRecommendationsProvider = Provider<AsyncValue<List<Recommendation>>>(
  (ref) {
    final catalogue = ref.watch(catalogueProvider);
    final categories = ref.watch(categoriesProvider);
    final userCards = ref.watch(userCardsProvider);
    final overrides = ref.watch(cardOverridesProvider);
    final selectedSlug = ref.watch(selectedCategoryProvider);
    final engine = ref.watch(recommendationEngineProvider);

    // Riverpod keeps the previous value on an AsyncValue while a provider is
    // being refreshed. Do not throw that value away just because one of the
    // dependencies is temporarily loading: Home can continue to show the
    // last known recommendations while the refresh completes. Returning a
    // fresh loading state here made SMS reconciliation, wallet sync, and
    // auth/session refreshes replace a stable Home section with a spinner.
    final allCards = catalogue.valueOrNull;
    // Category ids and overrides enrich the verdict, but neither is required
    // to render a safe base-rate recommendation. They may be loading after a
    // cold start or recovering from a transient API failure; do not make the
    // whole Home section wait for either optional dependency.
    final categoryList = categories.valueOrNull ?? const <SpendCategory>[];
    final wallet = userCards.valueOrNull;
    final overrideList = overrides.valueOrNull ?? const <CardOverride>[];
    final combinedError = catalogue.error ?? userCards.error;

    // No previous value exists on the first load. In that case preserve the
    // normal loading/error states; during a refresh, the valueOrNull checks
    // below are satisfied and the stale data path remains usable.
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

    final categoryId = categoryList
        .firstWhereOrNull((c) => c.slug == selectedSlug)
        ?.id;

    final cards = wallet.isEmpty
        ? allCards
        : allCards
              .where((c) => wallet.any((w) => w.cardProductId == c.id))
              .toList();

    // B8: resolve once per rank() call — Home only carries category context
    // (no merchant/vpa yet, that's B3's scan-result context), so vpa/
    // merchantName are omitted here on purpose.
    final overrideProductId = resolveActiveOverrideCardProductId(
      overrides: overrideList,
      wallet: wallet,
      categoryId: categoryId,
    );

    final context = RecommendationContext(
      amount: ref.watch(enteredAmountProvider),
      categoryId: categoryId,
      categorySlug: selectedSlug,
      rail: TxnRail.swipe,
      // G1: the toggle. Everything else about ranking is unchanged — this is
      // the entire wiring the plan called "the cheapest part of G1."
      travelMode: ref.watch(travelModeProvider),
      // Rules carry a catalogue validity window and the engine only checks it
      // when given a date. Without this, a promo rate that ended last quarter
      // would keep winning Home's verdict indefinitely.
      now: ref.watch(clockProvider).now(),
    );
    // Chunk 17: real capRemaining/milestoneProgress for owned cards, derived
    // from cap_states.consumed / milestone_states.qualified_spend — a card
    // not in the wallet (whole-catalogue fallback above) has no state to
    // look up, so it's evaluated as freshly-uncapped, same as before Chunk 17.
    final snapshots = _userCardSnapshots(
      cards,
      wallet,
      forcedOverrideCardId: overrideProductId,
    );
    final ranked = engine.rank(context, snapshots);
    return AsyncValue.data(wallet.isEmpty ? ranked.take(3).toList() : ranked);
  },
);

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
            for (final cap in c.capRules)
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
  return HttpNearbyMerchantsRepository(baseUrl: _apiBaseUrl);
});

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
  ref.listen<String?>(accessTokenProvider, (previous, next) {
    if (next == null) {
      unawaited(service.stop());
    } else if (previous == null) {
      unawaited(service.start());
    }
  });
});

/// Background geofence monitor — one instance for the app's lifetime, kept
/// alive by `ref.keepAlive()` since starting/stopping it is a deliberate
/// user action (a settings toggle), not something that should reset on
/// every rebuild of whatever screen happens to read it.
final geofenceMonitorServiceProvider = Provider<GeofenceMonitorService>((ref) {
  final service = GeofenceMonitorService(
    repo: ref.watch(nearbyMerchantsRepositoryProvider),
    notifications: ref.watch(localNotificationsPluginProvider),
    // UA-8.3 (B2): closes the one real spec violation this pass found —
    // _notify() used to call flutter_local_notifications directly, bypassing
    // category_location, quiet hours, and the daily cap entirely.
    gate: ref.watch(notificationGateProvider),
    recommendationTextBuilder: (match) {
      final recommendation = ref
          .read(bestCardForMerchantProvider(match.candidate.categoryId))
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

/// Whether background geofence monitoring is currently on — a plain
/// StateProvider the toggle UI reads/writes; the actual start()/stop()
/// call happens in the widget (needs a BuildContext for permission-denied
/// messaging), this just tracks the resulting on/off state for display.
final geofenceMonitoringEnabledProvider = StateProvider<bool>((ref) => false);

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
final smsBackgroundFlushProvider = Provider<void>((ref) {
  var workInProgress = false;
  var rerunRequested = false;
  const inboxReconciliationInterval = Duration(minutes: 5);

  Future<void> saveAmbiguousSmsForConfirmation(
    String sender,
    String body,
    DateTime receivedAt,
    SmsImportResult result,
  ) async {
    // Non-transaction alerts are intentionally ignored. An account debit
    // without explicit UPI evidence is different: it may be a transfer or a
    // bill payment, so keep it on-device for one confirmation instead of
    // silently adding it to spending.
    if (result.parsed || result.reason != 'ambiguous_account_debit') return;
    await ref
        .read(needsReviewRepositoryProvider)
        .add(
          NeedsReviewItem(
            id: '${sender}_${receivedAt.microsecondsSinceEpoch}',
            sender: sender,
            body: body,
            reason: result.reason,
            receivedAt: receivedAt,
          ),
        );
    ref.invalidate(needsReviewItemsProvider);
    ref.invalidate(needsReviewCountProvider);
  }

  Future<int> flush() async {
    final repo = ref.read(userCardsRepositoryProvider);
    // Guest mode has no server to send to; the queue simply waits until
    // there is one rather than being discarded.
    if (repo == null) return 0;
    try {
      final handled = await SmsListenerService().flushBackgroundQueue((
        sender,
        body,
        receivedAt,
      ) async {
        final result = await repo.logTransactionFromSms(
          sender: sender,
          body: body,
          occurredAt: receivedAt,
        );
        await saveAmbiguousSmsForConfirmation(sender, body, receivedAt, result);
        // Every one of these is "dealt with": imported, recognised as
        // already imported, or explicitly ignored as a non-spend. Successful
        // spends are recorded without requiring card attribution. Only a
        // network or server failure (which throws) leaves it queued.
        return true;
      });
      // Refresh Spending immediately after a queue upload. If a later inbox
      // reconciliation request times out, an open report must not stay stale.
      if (handled > 0) {
        ref.invalidate(userCardsProvider);
        ref.invalidate(transactionsProvider);
        ref.invalidate(utilizationTransactionsProvider);
        ref.invalidate(spendReportProvider);
        ref.invalidate(budgetsProvider);
        ref.invalidate(recurringReportProvider);
      }
      return handled;
    } catch (_) {
      // Offline or server down — the queue keeps what it couldn't send.
      return 0;
    }
  }

  // Parser improvements must also help messages that were already placed in
  // the on-device review queue before this app version was installed. Retry
  // once at startup through the same server path. Successful imports,
  // cardless imports, and explicitly recognised security/non-spend messages
  // are removed from the old queue.
  Future<void> retryExistingNeedsReview() async {
    final repo = ref.read(userCardsRepositoryProvider);
    if (repo == null) return;
    final reviewRepo = ref.read(needsReviewRepositoryProvider);
    final items = await reviewRepo.fetchAll();
    var changed = false;
    for (final item in items) {
      try {
        final result = await repo.logTransactionFromSms(
          sender: item.sender,
          body: item.body,
          occurredAt: item.receivedAt,
        );
        final canRemove =
            (result.parsed && !result.needsReview) ||
            _isIgnorableSmsResult(result);
        if (canRemove) {
          await reviewRepo.remove(item.id);
          changed = true;
        }
      } catch (_) {
        // Keep the remaining items for the next app start if the API is
        // offline or auth has not finished restoring yet.
        break;
      }
    }
    if (changed) {
      ref.invalidate(needsReviewItemsProvider);
      ref.invalidate(needsReviewCountProvider);
      ref.invalidate(userCardsProvider);
      ref.invalidate(transactionsProvider);
      ref.invalidate(utilizationTransactionsProvider);
    }
  }

  /// Reconcile recent provider SMS in addition to the broadcast listener.
  ///
  /// This is deliberately automatic and idempotent. Some Android emulator
  /// and OEM messaging stacks write an incoming SMS to the provider but do
  /// not deliver the third-party SMS_RECEIVED callback consistently. The
  /// server source key makes re-reading recent rows safe, while `backfill`
  /// prevents old inbox history from changing current reward-cycle state.
  Future<bool> reconcileInbox() async {
    if (ref.read(userCardsRepositoryProvider) == null) return false;

    final prefs = await SharedPreferences.getInstance();
    String buildIdentity;
    try {
      buildIdentity = await ref.read(appBuildIdentityProvider.future);
    } catch (_) {
      // A platform-info failure must not prevent SMS capture. `unknown` is
      // deliberately retryable: a later launch that can read PackageInfo
      // will use the real build key and perform the full pass.
      buildIdentity = 'unknown';
    }
    final safeBuildIdentity = buildIdentity.replaceAll(
      RegExp(r'[^A-Za-z0-9._+-]'),
      '_',
    );
    final inboxReconciliationKey =
        'pandapay_app.sms_inbox_reconciled_at_v3_$safeBuildIdentity';
    final serverObservationCountKey =
        'pandapay_app.sms_server_observation_count_v1_$safeBuildIdentity';
    final now = DateTime.now();
    final lastRunMillis = prefs.getInt(inboxReconciliationKey);

    // A server-side cleanup/reset must not strand the device behind its old
    // local checkpoint. Once a prior positive count drops, recover from the
    // complete on-device inbox; source keys keep that replay idempotent.
    var forceFullScan = lastRunMillis == null;
    var serverResetDetected = false;
    final previousServerCount = prefs.getInt(serverObservationCountKey);
    try {
      final serverState = await ref
          .read(userCardsRepositoryProvider)!
          .fetchSmsImportState();
      final currentServerCount = serverState.smsObservationCount;
      if (previousServerCount != null &&
          previousServerCount > 0 &&
          currentServerCount != null &&
          currentServerCount < previousServerCount) {
        forceFullScan = true;
        serverResetDetected = true;
      }
      // Keep the old positive checkpoint until a forced recovery succeeds.
      // Otherwise a transient network failure during that recovery would
      // turn the reset into a normal incremental scan on the next launch.
      if (currentServerCount != null && !serverResetDetected) {
        await prefs.setInt(serverObservationCountKey, currentServerCount);
      }
    } catch (_) {
      // Import must continue when the optional checkpoint endpoint is
      // temporarily unavailable. The date-bounded path remains safe and the
      // next launch will retry the reset check.
    }

    // The lightweight checkpoint query above is allowed on every launch so a
    // server-side cleanup is noticed immediately. Normal launches still use
    // the five-minute inbox interval and do not reread the device inbox.
    if (!forceFullScan &&
        lastRunMillis != null &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(lastRunMillis)) <
            inboxReconciliationInterval) {
      return false;
    }

    // Reuse the same bounded batch path as the explicit SMS screen. In
    // particular, do not force these messages through `backfill: true`: a
    // live SMS received while the app was paused must still update the
    // current month's card/reward state when reconciliation catches it.
    // The first run after this version is installed is a complete recovery
    // pass so a new user does not see only the newest alerts. Later resume
    // passes query by date from the previous successful scan, with a small
    // overlap that covers clock skew/offline handover. The server source key
    // makes that overlap idempotent.
    final summary = await ref
        .read(smsAutoImportProvider)
        .syncExistingInbox(
          limit: 0,
          since: forceFullScan
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  lastRunMillis!,
                ).subtract(const Duration(days: 2)),
        );
    await prefs.setInt(inboxReconciliationKey, now.millisecondsSinceEpoch);
    try {
      final serverState = await ref
          .read(userCardsRepositoryProvider)!
          .fetchSmsImportState();
      final currentServerCount = serverState.smsObservationCount;
      if (currentServerCount != null) {
        await prefs.setInt(serverObservationCountKey, currentServerCount);
      }
    } catch (_) {
      // The next reconciliation will refresh the checkpoint.
    }
    return summary.imported > 0 || summary.needsReview > 0;
  }

  Future<void> flushAndRetry() async {
    if (workInProgress) {
      // Startup, auth restoration, and resume may all request the same pass.
      // Coalesce those requests instead of silently dropping the one that
      // arrived while the first pass was still waiting on the API.
      rerunRequested = true;
      return;
    }
    workInProgress = true;
    try {
      do {
        rerunRequested = false;
        // Start the receiver from the same authenticated lifecycle pass as the
        // inbox reconciliation. Previously these were two independent startup
        // providers: after an update, the listener could register while the
        // reconciliation pass ran before SMS permission/token restoration had
        // settled, leaving the app listening but never importing the existing
        // inbox until a later resume.
        await ref.read(smsAutoImportProvider).start();
        var changed = await flush() > 0;
        try {
          changed = await reconcileInbox() || changed;
        } catch (_) {
          // A provider/permission/network failure must not abort the remaining
          // queue retry and must not surface as an unhandled lifecycle error.
        }
        // Repair rows imported by older builds: this suppresses only a
        // high-confidence SMS replay and fills categories for legacy rows.
        // It is idempotent, but still a server request, so throttle it rather
        // than repeating it on every foreground transition.
        final repo = ref.read(userCardsRepositoryProvider);
        final prefs = await SharedPreferences.getInstance();
        final repairKey =
            'pandapay_app.sms_history_repaired_at_v1_${ref.read(cacheNamespaceProvider)}';
        final lastRepair = prefs.getInt(repairKey);
        final repairDue =
            lastRepair == null ||
            DateTime.now().difference(
                  DateTime.fromMillisecondsSinceEpoch(lastRepair),
                ) >=
                const Duration(minutes: 5);
        if (repo != null && repairDue) {
          final repaired = await repo.reconcileSmsHistory();
          await prefs.setInt(repairKey, DateTime.now().millisecondsSinceEpoch);
          changed =
              repaired.duplicateSuppressed > 0 ||
              repaired.linkedCards > 0 ||
              repaired.reclassified > 0 ||
              changed;
        }
        await retryExistingNeedsReview();
        if (changed) {
          ref.invalidate(userCardsProvider);
          ref.invalidate(transactionsProvider);
          ref.invalidate(utilizationTransactionsProvider);
          // Reconciliation can change active-row counts and categories, so
          // refresh dependent reports once after a real change only.
          ref.invalidate(spendReportProvider);
          ref.invalidate(budgetsProvider);
          ref.invalidate(recurringReportProvider);
        }
      } while (rerunRequested);
    } finally {
      workInProgress = false;
    }
  }

  // Auth restoration is asynchronous. The first startup pass can happen
  // while there is no repository yet, so retry again as soon as the token is
  // restored instead of leaving valid SMS spends stranded in the old local
  // review queue.
  ref.listen<String>(cacheNamespaceProvider, (previous, next) {
    if (next != 'signed-out' && next != previous) {
      unawaited(flushAndRetry());
    }
  });

  final listener = AppLifecycleListener(
    onResume: () => unawaited(flushAndRetry()),
  );
  ref.onDispose(listener.dispose);
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

  const SmsInboxSyncSummary({
    required this.scanned,
    required this.imported,
    required this.duplicates,
    required this.ignored,
    this.needsReview = 0,
  });
}

class SmsAutoImportController {
  SmsAutoImportController(this._ref) : _service = SmsListenerService();

  final Ref _ref;
  final SmsListenerService _service;
  bool _registered = false;
  String? _userCardIdOverride;
  Future<SmsInboxSyncSummary>? _activeInboxSync;

  void setCardOverride(String? userCardId) => _userCardIdOverride = userCardId;

  Future<void> start() async {
    if (_registered || !await _service.hasPermissions()) return;
    _service.listenForeground((sender, body, receivedAt) {
      unawaited(_handle(sender, body, receivedAt));
    });
    _registered = true;
  }

  /// Reads the existing on-device inbox once when the user starts SMS
  /// tracking. The receiver only handles future messages; without this pass a
  /// newly-installed app appears to do nothing until the next bank alert.
  ///
  /// The server's source key makes this safe to repeat: messages already
  /// imported by the app shell or a previous scan are reported as duplicates,
  /// not inserted again.
  Future<SmsInboxSyncSummary> syncExistingInbox({
    int limit = 0,
    DateTime? since,
  }) async {
    // The app shell and the explicit SMS screen can both request recovery at
    // the same time (for example when the user opens Settings while the
    // post-update startup pass is still running). Share the in-flight work;
    // never read/upload the inbox twice concurrently.
    final active = _activeInboxSync;
    if (active != null) return active;

    final future = _syncExistingInbox(limit: limit, since: since);
    _activeInboxSync = future;
    try {
      return await future;
    } finally {
      if (identical(_activeInboxSync, future)) _activeInboxSync = null;
    }
  }

  Future<SmsInboxSyncSummary> _syncExistingInbox({
    required int limit,
    required DateTime? since,
  }) async {
    final repo = _ref.read(userCardsRepositoryProvider);
    if (repo == null) {
      return const SmsInboxSyncSummary(
        scanned: 0,
        imported: 0,
        duplicates: 0,
        ignored: 0,
      );
    }

    final messages = await _service.readInboxSms(limit: limit, since: since);
    var imported = 0;
    var duplicates = 0;
    var ignored = 0;
    var needsReview = 0;
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);

    // Import in bounded requests. Current-month messages are live cycle
    // activity; older messages remain history and must not inflate current
    // caps/rewards.
    for (final backfill in [false, true]) {
      final selected = messages.where((message) {
        final messageMonth = DateTime(
          message.receivedAt.year,
          message.receivedAt.month,
        );
        final isCurrentMonth = messageMonth == currentMonth;
        return backfill ? !isCurrentMonth : isCurrentMonth;
      }).toList();

      for (var start = 0; start < selected.length; start += 200) {
        // Yield between chunks so a large first-install/update recovery pass
        // does not monopolise Flutter's frame/input loop.
        await Future<void>.delayed(Duration.zero);
        final end = (start + 200).clamp(0, selected.length);
        final chunk = selected.sublist(start, end);
        final result = await repo.logTransactionsFromSmsBatch(
          messages: [
            for (final message in chunk)
              SmsBatchMessage(
                userCardId: _userCardIdOverride,
                sender: message.sender,
                body: message.body,
                occurredAt: message.receivedAt,
              ),
          ],
          backfill: backfill,
        );
        imported += result.imported;
        duplicates += result.duplicate;
        ignored += result.unparsed + result.invalid + result.errored;
        needsReview += result.needsReview;
      }
    }

    // Publish once after the complete bounded pass. Re-reading the inbox can
    // find messages the server already knows; that is not a data change and
    // must not trigger a full-screen refresh.
    if (imported > 0 || needsReview > 0) {
      _ref.invalidate(userCardsProvider);
      _ref.invalidate(transactionsProvider);
      _ref.invalidate(utilizationTransactionsProvider);
      _ref.invalidate(needsReviewCountProvider);
      _ref.invalidate(spendReportProvider);
      _ref.invalidate(budgetsProvider);
      _ref.invalidate(recurringReportProvider);
    }
    return SmsInboxSyncSummary(
      scanned: messages.length,
      imported: imported,
      duplicates: duplicates,
      ignored: ignored,
      needsReview: needsReview,
    );
  }

  Future<void> _handle(String sender, String body, DateTime receivedAt) async {
    final repo = _ref.read(userCardsRepositoryProvider);
    if (repo == null) {
      final prefs = await SharedPreferences.getInstance();
      await SmsBackgroundQueue.enqueue(
        prefs,
        QueuedSms(sender: sender, body: body, receivedAt: receivedAt),
      );
      return;
    }
    try {
      final result = await repo.logTransactionFromSms(
        userCardId: _userCardIdOverride,
        sender: sender,
        body: body,
        occurredAt: receivedAt,
      );
      if (!result.parsed && result.reason == 'ambiguous_account_debit') {
        await _ref
            .read(needsReviewRepositoryProvider)
            .add(
              NeedsReviewItem(
                id: '${sender}_${receivedAt.microsecondsSinceEpoch}',
                sender: sender,
                body: body,
                reason: result.reason,
                receivedAt: receivedAt,
              ),
            );
        _ref.invalidate(needsReviewItemsProvider);
        _ref.invalidate(needsReviewCountProvider);
      }
      _ref.invalidate(userCardsProvider);
      _ref.invalidate(transactionsProvider);
      _ref.invalidate(utilizationTransactionsProvider);
      _ref.invalidate(needsReviewCountProvider);
      _ref.invalidate(spendReportProvider);
      _ref.invalidate(budgetsProvider);
      _ref.invalidate(recurringReportProvider);
    } catch (_) {
      // Never lose a valid alert because auth/network was temporarily down.
      final prefs = await SharedPreferences.getInstance();
      await SmsBackgroundQueue.enqueue(
        prefs,
        QueuedSms(sender: sender, body: body, receivedAt: receivedAt),
      );
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
final bestCardForMerchantProvider =
    Provider.family<AsyncValue<Recommendation?>, String?>((ref, categoryId) {
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

      final overrideProductId = resolveActiveOverrideCardProductId(
        overrides: overrides.requireValue,
        wallet: wallet,
        categoryId: categoryId,
      );

      final snapshots = _userCardSnapshots(
        cards,
        wallet,
        forcedOverrideCardId: overrideProductId,
      );

      final categories = ref.watch(categoriesProvider);
      final categorySlug = categories.valueOrNull
          ?.firstWhereOrNull((c) => c.id == categoryId)
          ?.slug;

      return AsyncValue.data(
        picker.pickBestCard(
          cards: snapshots,
          categoryId: categoryId,
          categorySlug: categorySlug,
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
