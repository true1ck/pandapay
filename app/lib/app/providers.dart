import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../data/auth_api.dart';
import '../data/catalogue_repository.dart';
import '../data/token_store.dart';
import '../data/user_cards_repository.dart';

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

extension _FirstWhereOrNull<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
