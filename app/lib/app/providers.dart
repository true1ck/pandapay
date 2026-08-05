import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../data/catalogue_repository.dart';

/// api/'s default local dev port. Overridden per-flavor once flavors exist
/// (UA-0.1.2) — there is only one build target today.
const _apiBaseUrl = 'http://localhost:4000';

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
