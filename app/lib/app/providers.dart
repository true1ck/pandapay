import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../data/auth_api.dart';
import '../data/catalogue_repository.dart';
import '../data/token_store.dart';

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

final recommendationEngineProvider = Provider<RecommendationEngine>((ref) {
  return const RecommendationEngine();
});

/// Ranks the fetched catalogue for the selected category. No user_cards,
/// cap-consumption, or milestone-progress state exists yet (that's the
/// backend surface chunk 6+ would add) — every card is evaluated as if its
/// caps/milestones are fully fresh. This is a real ranking over real data,
/// just not yet personalized to an actual signed-in user's usage.
final rankedRecommendationsProvider = Provider<AsyncValue<List<Recommendation>>>((ref) {
  final catalogue = ref.watch(catalogueProvider);
  final categories = ref.watch(categoriesProvider);
  final selectedSlug = ref.watch(selectedCategoryProvider);
  final engine = ref.watch(recommendationEngineProvider);

  if (catalogue.isLoading || categories.isLoading) {
    return const AsyncValue.loading();
  }
  final combinedError = catalogue.error ?? categories.error;
  if (combinedError != null) {
    return AsyncValue.error(combinedError, catalogue.stackTrace ?? categories.stackTrace!);
  }

  final cards = catalogue.requireValue;
  final categoryList = categories.requireValue;
  final categoryId = categoryList.firstWhereOrNull((c) => c.slug == selectedSlug)?.id;

  final context = RecommendationContext(
    amount: _defaultDemoAmount,
    categoryId: categoryId,
    rail: TxnRail.swipe,
  );
  final snapshots = cards.map((c) => CardSnapshot(product: c)).toList();
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

// Placeholder until B6 quick-add / B1 amount entry exists — a fixed ₹1,000
// demo amount so ranking has something concrete to show.
const _defaultDemoAmount = Money.fromPaise(100000);
