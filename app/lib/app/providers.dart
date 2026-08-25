import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/acceptance_reports_repository.dart';
import '../data/analytics.dart';
import '../data/app_status_repository.dart';
import '../data/auth_api.dart';
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
import '../data/override_resolver.dart';
import '../data/partner_apply_repository.dart';
import '../data/recovery_api.dart';
import '../data/spend_by_category_repository.dart';
import '../data/spend_reports_repository.dart';
import '../data/sync_api.dart';
import '../data/token_store.dart';
import '../data/user_cards_repository.dart';
import '../data/user_settings_api.dart';
import '../features/geofence/geofence_monitor_service.dart';
import '../features/geofence/nearby_merchants_repository.dart';
import '../features/home_widget/home_widget_service.dart';
import '../features/notifications/notification_gate.dart';
import '../features/notifications/notification_triggers.dart';
import '../features/sms_import/sms_listener_service.dart';
import '../features/settings/settings_sync.dart';
import 'env.dart';

/// api/'s and auth/'s base URLs, fixed at compile time by `--dart-define`
/// (plan Phase 0.3). These were plain hardcoded `localhost` consts until
/// `env.dart` was added — see that file for the build flags and for why a
/// release build compiled without them throws on startup instead of silently
/// trying to reach the handset itself.
const _apiBaseUrl = Env.apiBaseUrl;
const _authBaseUrl = Env.authBaseUrl;

final authApiProvider = Provider<AuthApi>((ref) => AuthApi(authBaseUrl: _authBaseUrl));

final tokenStoreProvider = FutureProvider<TokenStore>((ref) => TokenStore.load());

/// This install's stable device identifier — see device_identity.dart's
/// own doc-comment for why this exists (every install used to send the
/// same literal `'app-mobile'` string, so there was nothing real to
/// generate/persist/compare here before).
final localDeviceIdProvider = FutureProvider<String>((ref) => DeviceIdentity().localDeviceId());

/// The signed-in access token, or null when signed out. Seeded on startup
/// by sessionInitProvider from a stored refresh token; login_screen.dart
/// persists both tokens on a fresh OTP sign-in.
final accessTokenProvider = StateProvider<String?>((ref) => null);

/// Whether this app PROCESS has already passed biometric_lock_screen.dart's
/// challenge. Deliberately plain in-memory state, never persisted — a
/// fresh cold start must always re-lock when the toggle
/// (account_settings_screen.dart's biometricLockProvider) is on, matching
/// its own copy: "Require Face/Touch ID to open the app," not "...once per
/// install."
final biometricUnlockedProvider = StateProvider<bool>((ref) => false);

final profileApiProvider = Provider<ProfileApi?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return ProfileApi(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

/// A8/C8 Request Unsupported Card. Same null-when-signed-out shape as every
/// other repository provider in this file.
final cardRequestsApiProvider = Provider<CardRequestsApi?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return CardRequestsApi(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

/// A4/H4 consent writes (DPDP §8.2). Same null-when-signed-out shape as
/// every other repository provider in this file.
final consentsApiProvider = Provider<ConsentsApi?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return ConsentsApi(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

/// Plan Phase 2.3 — attributed outbound "Apply" links. Null when signed out:
/// a click has to belong to a profile for the attribution to mean anything.
final partnerApplyRepositoryProvider = Provider<PartnerApplyRepository?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return PartnerApplyRepository(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

/// New-card-acquisition recommender's data input. Null when signed out: a
/// guest has no server-side transaction history to project a spend pattern
/// from, same reasoning as every other repository provider in this file.
final spendByCategoryRepositoryProvider = Provider<SpendByCategoryRepository?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return SpendByCategoryRepository(apiBaseUrl: _apiBaseUrl, accessToken: token);
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

final acquisitionRecommenderProvider = Provider<CardAcquisitionRecommender>((ref) {
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
final acquisitionCandidatesProvider = Provider<AsyncValue<List<AcquisitionCandidate>>>((ref) {
  final catalogue = ref.watch(catalogueProvider);
  final userCards = ref.watch(userCardsProvider);
  final categorySpend = ref.watch(categorySpendProvider);
  final recommender = ref.watch(acquisitionRecommenderProvider);

  if (catalogue.isLoading || userCards.isLoading || categorySpend.isLoading) {
    return const AsyncValue.loading();
  }
  final combinedError = catalogue.error ?? userCards.error ?? categorySpend.error;
  if (combinedError != null) {
    return AsyncValue.error(
      combinedError,
      catalogue.stackTrace ?? userCards.stackTrace ?? categorySpend.stackTrace!,
    );
  }

  final allCards = catalogue.requireValue;
  final wallet = userCards.requireValue;
  final spend = categorySpend.requireValue;

  final ownedProducts = allCards.where((c) => wallet.any((w) => w.cardProductId == c.id)).toList();
  final profile = SpendProfile(annualSpendByCategory: {for (final s in spend) s.categoryId: s.totalSpend});

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
final acceptanceReportsRepositoryProvider = Provider<AcceptanceReportsRepository?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return AcceptanceReportsRepository(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

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
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return SyncApi(apiBaseUrl: _apiBaseUrl, accessToken: token);
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
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return RecoveryApi(authBaseUrl: _authBaseUrl, accessToken: token);
});

final recoveryStatusProvider = FutureProvider.autoDispose<RecoveryStatus?>((ref) async {
  final api = ref.watch(recoveryApiProvider);
  if (api == null) return null;
  return api.fetchStatus();
});

/// Plan Phase 1.4 — linked-device management. Points at `authBaseUrl`, not
/// `apiBaseUrl`: `user_devices` is the auth service's own table.
final devicesApiProvider = Provider<DevicesApi?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return DevicesApi(authBaseUrl: _authBaseUrl, accessToken: token);
});

/// Plan Phase 1.1 — account-level preference sync (migration 0028). Same
/// null-when-signed-out shape as every other repository provider here, which
/// is also what makes `SettingsSync` a no-op for a guest: there is no account
/// for their preferences to follow, so they stay device-local.
final userSettingsApiProvider = Provider<UserSettingsApi?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return UserSettingsApi(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

/// Same pattern as console/lib/app/providers.dart's sessionInitProvider:
/// resolve a stored refresh token through auth/'s real POST /auth/refresh
/// on startup; on any failure (expired/reused/invalid), clear storage and
/// stay signed out rather than retry-looping.
final sessionInitProvider = FutureProvider<void>((ref) async {
  final store = await ref.watch(tokenStoreProvider.future);
  final refreshToken = store.refreshToken;
  if (refreshToken == null) return;

  final authApi = ref.read(authApiProvider);
  try {
    final tokens = await authApi.refresh(refreshToken);
    await store.save(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken);
    ref.read(accessTokenProvider.notifier).state = tokens.accessToken;
  } catch (_) {
    await store.clear();
  }
});

/// Keeps a signed-in session alive for as long as the app stays open, not
/// just at startup. sessionInitProvider above only ever calls /auth/refresh
/// once, when the app launches; auth/'s access tokens expire after
/// JWT_ACCESS_TTL (15 minutes by default), so without this, anyone who kept
/// the app open past that window would silently start getting 401s on
/// every API call while accessTokenProvider still held the now-dead token
/// — "signed in" on screen, broken underneath. This re-reads the CURRENT
/// refresh token from storage (not a captured value) every 10 minutes,
/// comfortably inside the 15-minute TTL, and signs the user out cleanly
/// (matching sessionInitProvider's own failure behavior) if the refresh
/// token itself turns out to be dead rather than retry-looping against it.
/// Read once from `_AppShell` in main.dart so it runs for the app's whole
/// lifetime regardless of which tab is showing.
/// How often to proactively rotate the access token. Must stay comfortably
/// below auth/'s JWT_ACCESS_TTL (15m by default) — overridable so tests can
/// drive the timer without waiting in real time.
final sessionRefreshIntervalProvider = Provider<Duration>((ref) => const Duration(minutes: 10));

final sessionKeepAliveProvider = Provider<void>((ref) {
  Timer? timer;

  Future<void> tick() async {
    final currentToken = ref.read(accessTokenProvider);
    if (currentToken == null) return; // signed out since the timer was scheduled

    final store = await ref.read(tokenStoreProvider.future);
    final refreshToken = store.refreshToken;
    if (refreshToken == null) return;

    try {
      final tokens = await ref.read(authApiProvider).refresh(refreshToken);
      await store.save(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken);
      ref.read(accessTokenProvider.notifier).state = tokens.accessToken;
    } catch (_) {
      await store.clear();
      ref.read(accessTokenProvider.notifier).state = null;
    }
  }

  ref.listen<String?>(accessTokenProvider, (previous, next) {
    timer?.cancel();
    if (next != null) {
      timer = Timer.periodic(ref.read(sessionRefreshIntervalProvider), (_) => tick());
    }
  }, fireImmediately: true);

  ref.onDispose(() => timer?.cancel());
});

/// Tasks 4-6: whether the first-run onboarding flow (Welcome -> Account
/// Choice -> optional sign-up/sign-in -> Tutorial) has ever been completed
/// on this device. Persisted directly via SharedPreferences (not through
/// TokenStore — this has nothing to do with auth; it must stay `true` even
/// after a sign-out, per ui-spec.md A3's "no nagging later" principle:
/// finishing onboarding once and later signing out must never show the
/// welcome flow again).
const _onboardingCompleteKey = 'pandapay_app.onboarding_complete_v1';

final onboardingCompleteProvider = StateNotifierProvider<OnboardingController, AsyncValue<bool>>(
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
    // through Welcome and Account Choice as though they were brand new.
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
/// through Welcome/Account Choice.
const _tutorialSeenKey = 'pandapay_app.tutorial_seen_v1';

final tutorialSeenProvider = StateNotifierProvider<TutorialController, AsyncValue<bool>>(
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

final dueDateRemindersProvider = StateNotifierProvider<DueDateRemindersController, Set<String>>(
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
final needsReviewRepositoryProvider = Provider<NeedsReviewRepository>((ref) => NeedsReviewRepository());

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
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return CardFeedbackRepository(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

final userCardsRepositoryProvider = Provider<UserCardsRepository?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return UserCardsRepository(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

/// Spend trends and budgets. Null in guest mode, like every other
/// server-backed repository here: both read `transactions`, which is
/// owner-scoped and has no local-only counterpart.
final spendReportsRepositoryProvider = Provider<SpendReportsRepository?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return SpendReportsRepository(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

/// The Trends screen's data, for the selected period.
///
/// A family over [SpendPeriod] rather than a provider plus a separate
/// "selected period" StateProvider: switching period is a different fetch,
/// and keying the cache by period means flipping back to a period already
/// looked at is instant instead of re-fetching.
final spendReportProvider = FutureProvider.family<SpendReport?, SpendPeriod>((ref, period) async {
  final repo = ref.watch(spendReportsRepositoryProvider);
  if (repo == null) return null;
  return repo.fetchReport(period: period);
});

/// The period the Trends screen is currently showing.
final selectedSpendPeriodProvider = StateProvider<SpendPeriod>((ref) => SpendPeriod.month);

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
final localUserCardsRepositoryProvider = FutureProvider<LocalUserCardsRepository>((ref) async {
  return LocalUserCardsRepository(await ref.watch(appDatabaseProvider.future));
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
  try {
    final cards = await repo.fetchUserCards();
    final cache = await _cacheOrNull(ref);
    await cache?.put(_userCardsCacheKey, jsonEncode({'userCards': cards.map((c) => c.toJson()).toList()}));
    return cards;
  } catch (_) {
    final cache = await _cacheOrNull(ref);
    final cached = await cache?.get(_userCardsCacheKey);
    if (cached == null) rethrow;
    final body = jsonDecode(cached) as Map<String, dynamic>;
    return (body['userCards'] as List).cast<Map<String, dynamic>>().map(UserCard.fromJson).toList();
  }
});

/// UA-3+ (Chunk 18): the Activity tab's data — empty (not an error) when
/// signed out, same reasoning as userCardsProvider above.
final transactionsProvider = FutureProvider<List<TransactionEntry>>((ref) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  return repo.fetchTransactions();
});

final cardOverridesRepositoryProvider = Provider<CardOverridesRepository?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return CardOverridesRepository(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

/// B8 — every override rule the signed-in user owns (enabled or disabled).
/// Empty (not an error) when signed out, same reasoning as userCardsProvider.
final cardOverridesProvider = FutureProvider<List<CardOverride>>((ref) async {
  final repo = ref.watch(cardOverridesRepositoryProvider);
  if (repo == null) return const [];
  try {
    final overrides = await repo.fetchOverrides();
    final cache = await _cacheOrNull(ref);
    await cache?.put(
      _cardOverridesCacheKey,
      jsonEncode({'overrides': overrides.map((o) => o.toJson()).toList()}),
    );
    return overrides;
  } catch (_) {
    final cache = await _cacheOrNull(ref);
    final cached = await cache?.get(_cardOverridesCacheKey);
    if (cached == null) rethrow;
    final body = jsonDecode(cached) as Map<String, dynamic>;
    return (body['overrides'] as List).cast<Map<String, dynamic>>().map(CardOverride.fromJson).toList();
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
      await cache?.clear(_userCardsCacheKey);
      await cache?.clear(_cardOverridesCacheKey);
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
  return Connectivity().onConnectivityChanged.map(connectivityResultToIsOnline);
});

final outboxRepositoryProvider = FutureProvider<TransactionOutboxRepository>((ref) async {
  return TransactionOutboxRepository(await ref.watch(appDatabaseProvider.future));
});

final pendingOutboxCountProvider = FutureProvider<int>((ref) async {
  final items = await (await ref.watch(outboxRepositoryProvider.future)).pending();
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
    }
  });
});

/// Task D-5: pending duplicate-candidate pairs; empty (not an error) when
/// signed out, same pattern as every other repository-backed provider here.
final duplicateCandidatesProvider = FutureProvider<List<DuplicateCandidate>>((ref) async {
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
    return local.fetchUserCards(includeArchived: includeArchived, catalogue: catalogue);
  }
  return repo.fetchUserCards(includeArchived: includeArchived);
});

/// Task C-1/C-2: same join as ownedCardsWithProductProvider, but sourced
/// from myCardsProvider so C1 (with its archived toggle on) and C2 (deep-
/// linked into an archived card from C1) can both resolve a product for a
/// card ownedCardsWithProductProvider would have silently excluded.
final myCardsWithProductProvider = Provider<AsyncValue<List<(UserCard, CardProduct)>>>((ref) {
  final userCards = ref.watch(myCardsProvider);
  final catalogue = ref.watch(catalogueProvider);

  if (userCards.isLoading || catalogue.isLoading) return const AsyncValue.loading();
  final combinedError = userCards.error ?? catalogue.error;
  if (combinedError != null) {
    return AsyncValue.error(combinedError, userCards.stackTrace ?? catalogue.stackTrace!);
  }

  final products = {for (final p in catalogue.requireValue) p.id: p};
  final pairs = [
    for (final uc in userCards.requireValue)
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
final ownedCardsWithProductProvider = Provider<AsyncValue<List<(UserCard, CardProduct)>>>((ref) {
  final userCards = ref.watch(userCardsProvider);
  final catalogue = ref.watch(catalogueProvider);

  if (userCards.isLoading || catalogue.isLoading) return const AsyncValue.loading();
  final combinedError = userCards.error ?? catalogue.error;
  if (combinedError != null) {
    return AsyncValue.error(combinedError, userCards.stackTrace ?? catalogue.stackTrace!);
  }

  final products = {for (final p in catalogue.requireValue) p.id: p};
  final pairs = [
    for (final uc in userCards.requireValue)
      if (products[uc.cardProductId] case final product?) (uc, product),
  ];
  return AsyncValue.data(pairs);
});

/// Task G-0 (scoped to what E3 needs): wraps `creditUtilization()` per
/// owned card that has a [UserCard.creditLimit] set — cards without one are
/// simply absent from the map, matching E3's "exclude cards with no limit
/// entered, prompt to add it" requirement rather than defaulting to a
/// fabricated limit. Recomputes automatically whenever
/// ownedCardsWithProductProvider changes (a new transaction, a limit being
/// added), same as every other derived provider in this file.
final creditUtilizationProvider = Provider<Map<String, UtilizationResult>>((ref) {
  final pairs = ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
  final result = <String, UtilizationResult>{};
  for (final (userCard, _) in pairs) {
    final limit = userCard.creditLimit;
    if (limit == null || limit.isZero) continue;
    // "Current balance" isn't tracked as its own figure anywhere yet (no
    // statement-balance concept exists client-side) — the best available
    // proxy is this cycle's spend-measure cap consumption summed across the
    // card's own cap rules is too narrow (caps are category-specific, not
    // whole-card). Lacking a real running balance, total points-earning
    // spend isn't tracked either, so this pass uses the sum of every
    // spend-measure cap's consumed amount as a lower-bound estimate and
    // marks the figure as such in the screen (E3's own confidence badge) —
    // flagged explicitly in the final report rather than silently treated
    // as an exact balance.
    final spendProxy = userCard.capConsumed.values.fold<Money>(const Money.zero(), (a, b) => a + b);
    result[userCard.id] = creditUtilization(spendProxy, limit);
  }
  return result;
});

/// Task G-0 (the rest of it — E3's slice landed in Chunk 36): G2's amount
/// input. A dedicated provider rather than reusing enteredAmountProvider —
/// Home's amount field and the split planner's amount are two different
/// user intents (one txn vs. a total to divide) that happen to share a
/// widget shape; sharing the same provider would mean typing on Home
/// silently changed what G2 last planned, and vice versa.
final splitPlannerAmountProvider = StateProvider<Money>((ref) => const Money.zero());

final splitOptimizerProvider = Provider<SplitOptimizer>((ref) => const SplitOptimizer());

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
  final pairs = ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
  if (amount.isZero || pairs.isEmpty) return const [];

  final wallet = [for (final (uc, _) in pairs) uc];
  final products = [for (final (_, p) in pairs) p];
  final snapshots = _userCardSnapshots(products, wallet);

  final utilizationCeiling = <String, Money>{};
  for (final (userCard, product) in pairs) {
    final limit = userCard.creditLimit;
    if (limit == null || limit.isZero) continue;
    final threshold = limit * 0.30;
    final spendProxy = userCard.capConsumed.values.fold<Money>(const Money.zero(), (a, b) => a + b);
    final headroom = threshold - spendProxy;
    utilizationCeiling[product.id] = headroom.isNegative ? const Money.zero() : headroom;
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
  return optimizer.optimize(amount, baseContext, snapshots, utilizationCeiling: utilizationCeiling);
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

final emiAdviceProvider = Provider.family<EmiAdvice?, EmiAdviceParams>((ref, params) {
  if (params.principalRupees <= 0 || params.tenureMonths <= 0) return null;
  final pairs = ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
  final match = pairs.firstWhereOrNull((p) => p.$2.id == params.cardProductId);
  if (match == null) return null;
  final (userCard, product) = match;

  final engine = ref.watch(recommendationEngineProvider);
  final principal = Money.fromRupees(params.principalRupees);
  final snapshot = _userCardSnapshots([product], [userCard]).first;
  final rec = engine
      .rank(
        RecommendationContext(amount: principal, rail: TxnRail.swipe, now: ref.watch(clockProvider).now()),
        [snapshot],
      )
      .first;
  final forgoneRewardValue = rec.isExcluded ? const Money.zero() : rec.expectedValue;

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
final emergencyContactsRepositoryProvider = Provider<EmergencyContactsRepository>((ref) {
  return HttpEmergencyContactsRepository(baseUrl: _apiBaseUrl);
});

final emergencyContactsCacheProvider = Provider<EmergencyContactsCache>((ref) => EmergencyContactsCache());

/// Never throws (see EmergencyContactsService.load's own doc-comment) —
/// always resolves to real, renderable content, live/cached/bundled, so
/// G4's screen has no "offline" error path to design around, only a
/// data-freshness banner reflecting whichever of the three it got.
final emergencyContactsProvider = FutureProvider<EmergencyContactsResult>((ref) async {
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
final pointsLedgerProvider = FutureProvider.family<List<PointsLedgerEntry>, String>((ref, userCardId) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  return repo.fetchPointsLedger(userCardId);
});

/// Task E9: current month's report, recomputed on demand server-side each
/// time this is watched/invalidated (see GET /monthly-reports' doc-comment
/// for why only the current month is safe to always-recompute).
final currentMonthlyReportProvider = FutureProvider<MonthlyReport?>((ref) async {
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
  return repo.fetchHomeSummary(timeZone: ref.watch(deviceTimeZoneProvider));
});

/// Design 19's notification inbox. Empty (not an error) when signed out —
/// the inbox lives server-side, so guest mode simply has none.
final notificationsProvider = FutureProvider<({List<AppNotification> items, int unreadCount})>((ref) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return (items: const <AppNotification>[], unreadCount: 0);
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
final notificationPreferencesRepositoryProvider = Provider<NotificationPreferencesRepository?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return NotificationPreferencesRepository(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

final notificationPreferencesProvider = FutureProvider<NotificationPreferences?>((ref) async {
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
final contributionNetworkStatsProvider = FutureProvider<ContributionNetworkStats?>((ref) async {
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
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return ImportRepository(apiBaseUrl: _apiBaseUrl, accessToken: token);
});

/// F3: this profile's forwarding address, or null if never issued.
final forwardingAddressProvider = FutureProvider<ForwardingAddress?>((ref) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return null;
  return repo.fetchForwardingAddress();
});

/// Task F-8: the forwarding confirmation code/link a provider sent to the
/// issued address, if one has arrived. Null is the normal state — it only
/// becomes non-null during the few minutes between the user starting setup
/// in Gmail and finishing it.
final forwardingVerificationProvider = FutureProvider<ForwardingVerification?>((ref) async {
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
final statementImportsProvider = FutureProvider<List<StatementImport>>((ref) async {
  final repo = ref.watch(importRepositoryProvider);
  if (repo == null) return const [];
  return repo.fetchStatementImports();
});

/// F4/F1: recent SMS backup-file import batches.
final smsImportBatchesProvider = FutureProvider<List<SmsImportBatch>>((ref) async {
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
final merchantSearchRepositoryProvider = Provider<MerchantSearchRepository>((ref) {
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
    return await cache.lastFetchedAt();
  } catch (_) {
    return null;
  }
});

const _catalogueCacheKey = 'catalogue';
const _categoriesCacheKey = 'categories';
const _userCardsCacheKey = 'user_cards';
const _cardOverridesCacheKey = 'card_overrides';

/// UA-0.3 offline step: live fetch first, caching the raw response on
/// success; on ANY fetch failure, falls back to the last cached response
/// rather than leaving Home with nothing to rank against. Only fires the
/// fallback on a genuine failure — a successful-but-empty catalogue is
/// never treated as "fetch failed."
final catalogueProvider = FutureProvider<List<CardProduct>>((ref) async {
  try {
    final cards = await ref.watch(catalogueRepositoryProvider).fetchCatalogue();
    final cache = await _cacheOrNull(ref);
    await cache?.put(_catalogueCacheKey, jsonEncode({'cards': cards.map((c) => c.toJson()).toList()}));
    return cards;
  } catch (_) {
    final cache = await _cacheOrNull(ref);
    final cached = await cache?.get(_catalogueCacheKey);
    if (cached == null) rethrow;
    final body = jsonDecode(cached) as Map<String, dynamic>;
    return (body['cards'] as List).cast<Map<String, dynamic>>().map(CardProductJson.fromJson).toList();
  }
});

final categoriesProvider = FutureProvider<List<SpendCategory>>((ref) async {
  try {
    final categories = await ref.watch(categoryRepositoryProvider).fetchCategories();
    final cache = await _cacheOrNull(ref);
    await cache?.put(
      _categoriesCacheKey,
      jsonEncode({'categories': categories.map((c) => c.toJson()).toList()}),
    );
    return categories;
  } catch (_) {
    final cache = await _cacheOrNull(ref);
    final cached = await cache?.get(_categoriesCacheKey);
    if (cached == null) rethrow;
    final body = jsonDecode(cached) as Map<String, dynamic>;
    return (body['categories'] as List).cast<Map<String, dynamic>>().map(SpendCategory.fromJson).toList();
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
final enteredAmountProvider = StateProvider<Money>((ref) => const Money.fromPaise(100000));

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
/// falling back to the whole catalogue when signed out or before they've
/// added a first card, so Home is never empty just because nobody's built
/// UA-1.2's onboarding flow yet. Still no cap-consumption or
/// milestone-progress state (that's user-usage tracking, a separate,
/// larger surface than "which cards does this person actually have") —
/// every card is evaluated as if its caps/milestones are fully fresh.
final rankedRecommendationsProvider = Provider<AsyncValue<List<Recommendation>>>((ref) {
  final catalogue = ref.watch(catalogueProvider);
  final categories = ref.watch(categoriesProvider);
  final userCards = ref.watch(userCardsProvider);
  final overrides = ref.watch(cardOverridesProvider);
  final selectedSlug = ref.watch(selectedCategoryProvider);
  final engine = ref.watch(recommendationEngineProvider);

  if (catalogue.isLoading || categories.isLoading || userCards.isLoading || overrides.isLoading) {
    return const AsyncValue.loading();
  }
  final combinedError = catalogue.error ?? categories.error ?? userCards.error ?? overrides.error;
  if (combinedError != null) {
    return AsyncValue.error(
      combinedError,
      catalogue.stackTrace ?? categories.stackTrace ?? userCards.stackTrace ?? overrides.stackTrace!,
    );
  }

  final allCards = catalogue.requireValue;
  final categoryList = categories.requireValue;
  final wallet = userCards.requireValue;
  final categoryId = categoryList.firstWhereOrNull((c) => c.slug == selectedSlug)?.id;

  final cards = wallet.isEmpty
      ? allCards
      : allCards.where((c) => wallet.any((w) => w.cardProductId == c.id)).toList();

  // B8: resolve once per rank() call — Home only carries category context
  // (no merchant/vpa yet, that's B3's scan-result context), so vpa/
  // merchantName are omitted here on purpose.
  final overrideProductId = resolveActiveOverrideCardProductId(
    overrides: overrides.requireValue,
    wallet: wallet,
    categoryId: categoryId,
  );

  final context = RecommendationContext(
    amount: ref.watch(enteredAmountProvider),
    categoryId: categoryId,
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
  final snapshots = _userCardSnapshots(cards, wallet, forcedOverrideCardId: overrideProductId);
  return AsyncValue.data(engine.rank(context, snapshots));
});

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
              if (owned.capConsumed.containsKey(cap.id)) cap.id: cap.capValue - owned.capConsumed[cap.id]!,
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
final nearbyMerchantsRepositoryProvider = Provider<NearbyMerchantsRepository>((ref) {
  return HttpNearbyMerchantsRepository(baseUrl: _apiBaseUrl);
});

/// UA-8.3 (B1): one FlutterLocalNotificationsPlugin instance for the whole
/// app. Previously GeofenceMonitorService was the only caller and
/// constructed its own — fine when it was the only notification path, but
/// NotificationGate (B2) needs to show OS notifications too, and two
/// independent plugin instances means two independent (and possibly
/// racing) `initialize()` calls registering the same Android channel.
final localNotificationsPluginProvider = Provider<FlutterLocalNotificationsPlugin>((ref) {
  return FlutterLocalNotificationsPlugin();
});

/// UA-8.3 (B2): the single choke point every real (OS-level) notification
/// must pass through — see notification_gate.dart's own doc-comment for
/// what it enforces and why POST /notifications alone isn't enough.
final notificationGateProvider = Provider<NotificationGate>((ref) {
  return NotificationGate(ref: ref, notifications: ref.watch(localNotificationsPluginProvider));
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
final notificationTriggerRunnerProvider = Provider<NotificationTriggerRunner>((ref) {
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
  Future<void> flush() async {
    final repo = ref.read(userCardsRepositoryProvider);
    // Guest mode has no server to send to; the queue simply waits until
    // there is one rather than being discarded.
    if (repo == null) return;
    try {
      await SmsListenerService().flushBackgroundQueue((sender, body, receivedAt) async {
        await repo.logTransactionFromSms(sender: sender, body: body, occurredAt: receivedAt);
        // Every one of these is "dealt with": imported, recognised as
        // already imported, filed for review because the card is unknown,
        // or logged as an unparseable shape server-side. Only a network or
        // server failure (which throws) leaves it queued.
        return true;
      });
      ref.invalidate(userCardsProvider);
    } catch (_) {
      // Offline or server down — the queue keeps what it couldn't send.
    }
  }

  final listener = AppLifecycleListener(onResume: flush);
  ref.onDispose(listener.dispose);
  // Once at startup too: the most common case is the app being opened
  // fresh after messages arrived, which fires no resume event.
  flush();
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
final bestCardForMerchantProvider = Provider.family<AsyncValue<Recommendation?>, String?>((ref, categoryId) {
  final catalogue = ref.watch(catalogueProvider);
  final userCards = ref.watch(userCardsProvider);
  final overrides = ref.watch(cardOverridesProvider);
  final picker = ref.watch(_bestCardForWidgetProvider);

  if (catalogue.isLoading || userCards.isLoading || overrides.isLoading) {
    return const AsyncValue.loading();
  }
  final combinedError = catalogue.error ?? userCards.error ?? overrides.error;
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
      : allCards.where((c) => wallet.any((w) => w.cardProductId == c.id)).toList();

  final overrideProductId = resolveActiveOverrideCardProductId(
    overrides: overrides.requireValue,
    wallet: wallet,
    categoryId: categoryId,
  );

  final snapshots = _userCardSnapshots(cards, wallet, forcedOverrideCardId: overrideProductId);

  return AsyncValue.data(
    picker.pickBestCard(
      cards: snapshots,
      categoryId: categoryId,
      now: ref.watch(clockProvider).now(),
    ),
  );
});

final homeWidgetServiceProvider = Provider<HomeWidgetService>((ref) => HomeWidgetService());

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
