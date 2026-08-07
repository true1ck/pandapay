import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/auth_api.dart';
import '../data/card_feedback_repository.dart';
import '../data/card_requests_api.dart';
import '../data/catalogue_repository.dart';
import '../data/emergency_contacts_repository.dart';
import '../data/import_repository.dart';
import '../data/token_store.dart';
import '../data/user_cards_repository.dart';
import '../features/geofence/nearby_merchants_repository.dart';
import '../features/home_widget/home_widget_service.dart';

/// api/'s and auth/'s default local dev ports. Overridden per-flavor once
/// flavors exist (UA-0.1.2) — there is only one build target today.
const _apiBaseUrl = 'http://localhost:4000';
const _authBaseUrl = 'http://localhost:3210';

final authApiProvider = Provider<AuthApi>((ref) => AuthApi(authBaseUrl: _authBaseUrl));

final tokenStoreProvider = FutureProvider<TokenStore>((ref) => TokenStore.load());

/// The signed-in access token, or null when signed out. Seeded on startup
/// by sessionInitProvider from a stored refresh token; login_screen.dart
/// persists both tokens on a fresh OTP sign-in.
final accessTokenProvider = StateProvider<String?>((ref) => null);

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
final sessionRefreshIntervalProvider =
    Provider<Duration>((ref) => const Duration(minutes: 10));

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
      timer = Timer.periodic(
          ref.read(sessionRefreshIntervalProvider), (_) => tick());
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

final onboardingCompleteProvider =
    StateNotifierProvider<OnboardingController, AsyncValue<bool>>(
        (ref) => OnboardingController());

class OnboardingController extends StateNotifier<AsyncValue<bool>> {
  OnboardingController() : super(const AsyncValue.loading()) {
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
  }

  /// Settings' "Replay tutorial" (Task 21) hook — lets a user re-see the
  /// coach marks without losing anything else, never a way to re-trigger
  /// account choice or sign-up.
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingCompleteKey, false);
    state = const AsyncValue.data(false);
  }
}

/// Task 5 (ui-spec.md A11): whether the first-run coach-mark tutorial has
/// been seen. Deliberately a SEPARATE flag from onboardingCompleteProvider
/// above, not a reuse of it — Settings' future "Replay tutorial" (Task 21)
/// must reset only the coach marks, never send a returning user back
/// through Welcome/Account Choice.
const _tutorialSeenKey = 'pandapay_app.tutorial_seen_v1';

final tutorialSeenProvider = StateNotifierProvider<TutorialController, AsyncValue<bool>>(
    (ref) => TutorialController());

class TutorialController extends StateNotifier<AsyncValue<bool>> {
  TutorialController() : super(const AsyncValue.loading()) {
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
  }

  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_tutorialSeenKey, false);
    state = const AsyncValue.data(false);
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
    StateNotifierProvider<DueDateRemindersController, Set<String>>((ref) => DueDateRemindersController());

class DueDateRemindersController extends StateNotifier<Set<String>> {
  DueDateRemindersController() : super(const {}) {
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
  }
}

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

/// The signed-in user's own wallet — empty (not an error) when signed out,
/// so rankedRecommendationsProvider below can fall back to the whole
/// catalogue without a special-cased branch for "not signed in" vs.
/// "signed in but owns nothing yet."
final userCardsProvider = FutureProvider<List<UserCard>>((ref) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  return repo.fetchUserCards();
});

/// UA-3+ (Chunk 18): the Activity tab's data — empty (not an error) when
/// signed out, same reasoning as userCardsProvider above.
final transactionsProvider = FutureProvider<List<TransactionEntry>>((ref) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  return repo.fetchTransactions();
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
  if (repo == null) return const [];
  final includeArchived = ref.watch(showArchivedCardsProvider);
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
      .rank(RecommendationContext(amount: principal, rail: TxnRail.swipe), [snapshot])
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

final catalogueProvider = FutureProvider<List<CardProduct>>((ref) {
  return ref.watch(catalogueRepositoryProvider).fetchCatalogue();
});

final categoriesProvider = FutureProvider<List<SpendCategory>>((ref) {
  return ref.watch(categoryRepositoryProvider).fetchCategories();
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
  final selectedSlug = ref.watch(selectedCategoryProvider);
  final engine = ref.watch(recommendationEngineProvider);

  if (catalogue.isLoading || categories.isLoading || userCards.isLoading) {
    return const AsyncValue.loading();
  }
  final combinedError = catalogue.error ?? categories.error ?? userCards.error;
  if (combinedError != null) {
    return AsyncValue.error(
      combinedError,
      catalogue.stackTrace ?? categories.stackTrace ?? userCards.stackTrace!,
    );
  }

  final allCards = catalogue.requireValue;
  final categoryList = categories.requireValue;
  final wallet = userCards.requireValue;
  final categoryId = categoryList.firstWhereOrNull((c) => c.slug == selectedSlug)?.id;

  final cards = wallet.isEmpty
      ? allCards
      : allCards.where((c) => wallet.any((w) => w.cardProductId == c.id)).toList();

  final context = RecommendationContext(
    amount: ref.watch(enteredAmountProvider),
    categoryId: categoryId,
    rail: TxnRail.swipe,
    // G1: the toggle. Everything else about ranking is unchanged — this is
    // the entire wiring the plan called "the cheapest part of G1."
    travelMode: ref.watch(travelModeProvider),
  );
  // Chunk 17: real capRemaining/milestoneProgress for owned cards, derived
  // from cap_states.consumed / milestone_states.qualified_spend — a card
  // not in the wallet (whole-catalogue fallback above) has no state to
  // look up, so it's evaluated as freshly-uncapped, same as before Chunk 17.
  final snapshots = _userCardSnapshots(cards, wallet);
  return AsyncValue.data(engine.rank(context, snapshots));
});

/// Chunk 38: factored out of rankedRecommendationsProvider and
/// bestCardForMerchantProvider, which both built an identical
/// CardSnapshot list inline — G2/G3 need the exact same "owned card ->
/// CardSnapshot with real capRemaining/milestoneProgress" assembly, so this
/// is now the one place that logic lives rather than a fourth copy.
List<CardSnapshot> _userCardSnapshots(List<CardProduct> cards, List<UserCard> wallet) {
  return cards.map((c) {
    final owned = wallet.firstWhereOrNull((w) => w.cardProductId == c.id);
    if (owned == null) return CardSnapshot(product: c);
    final capRemaining = {
      for (final cap in c.capRules)
        if (owned.capConsumed.containsKey(cap.id)) cap.id: cap.capValue - owned.capConsumed[cap.id]!,
    };
    return CardSnapshot(
      product: c,
      capRemaining: capRemaining,
      milestoneProgress: owned.milestoneQualifiedSpend,
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
final bestCardForMerchantProvider =
    Provider.family<AsyncValue<Recommendation?>, String?>((ref, categoryId) {
  final catalogue = ref.watch(catalogueProvider);
  final userCards = ref.watch(userCardsProvider);
  final picker = ref.watch(_bestCardForWidgetProvider);

  if (catalogue.isLoading || userCards.isLoading) {
    return const AsyncValue.loading();
  }
  final combinedError = catalogue.error ?? userCards.error;
  if (combinedError != null) {
    return AsyncValue.error(combinedError, catalogue.stackTrace ?? userCards.stackTrace!);
  }

  final allCards = catalogue.requireValue;
  final wallet = userCards.requireValue;
  final cards = wallet.isEmpty
      ? allCards
      : allCards.where((c) => wallet.any((w) => w.cardProductId == c.id)).toList();

  final snapshots = _userCardSnapshots(cards, wallet);

  return AsyncValue.data(picker.pickBestCard(cards: snapshots, categoryId: categoryId));
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
