import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../data/auth_api.dart';
import '../data/catalogue_repository.dart';
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

/// UA-3: the signed-in user's own profiles row (owner-scoped via RLS —
/// api/'s GET /profile, proved end to end back in Chunk 1 but never called
/// from the app itself until this chunk). Null when signed out or when a
/// signed-in user hasn't completed onboarding yet (no profile row exists).
final profileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final api = ref.watch(profileApiProvider);
  if (api == null) return null;
  return api.fetchProfile();
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
  );
  // Chunk 17: real capRemaining/milestoneProgress for owned cards, derived
  // from cap_states.consumed / milestone_states.qualified_spend — a card
  // not in the wallet (whole-catalogue fallback above) has no state to
  // look up, so it's evaluated as freshly-uncapped, same as before Chunk 17.
  final snapshots = cards.map((c) {
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
  return AsyncValue.data(engine.rank(context, snapshots));
});

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

  final snapshots = cards.map((c) {
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
