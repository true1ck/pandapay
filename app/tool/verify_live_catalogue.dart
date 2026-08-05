// Manual verification script (not part of the automated test suite):
// hits the REAL api/ HTTP endpoint via HttpCatalogueRepository — the exact
// class the app uses — and runs the results through RecommendationEngine,
// proving the app-side data layer works against a live backend, not just
// against fixtures. Run with api/ already running on localhost:4000.
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

Future<void> main() async {
  final repo = HttpCatalogueRepository(baseUrl: 'http://localhost:4000');
  final categoryRepo = HttpCategoryRepository(baseUrl: 'http://localhost:4000');
  final cards = await repo.fetchCatalogue();
  final categories = await categoryRepo.fetchCategories();
  print('Fetched ${cards.length} cards and ${categories.length} categories '
      'from the live api/ service:');
  for (final c in cards) {
    print('  - ${c.name} (${c.network.name}, upi=${c.isUpiLinkable}, '
        '${c.rewardRules.length} reward rules)');
  }

  final onlineCategoryId = categories.firstWhere((c) => c.slug == 'online').id;
  final engine = RecommendationEngine();
  final ctx = RecommendationContext(
    amount: Money.fromRupees(2000),
    categoryId: onlineCategoryId,
    rail: TxnRail.swipe,
  );
  final results = engine.rank(ctx, cards.map((c) => CardSnapshot(product: c)).toList());

  print('\nRanked for ₹2000 online spend, swipe rail:');
  for (final r in results) {
    if (r.isExcluded) {
      print('  ${r.card.name}: EXCLUDED — ${r.exclusionReason}');
    } else {
      print('  ${r.card.name}: ${r.expectedValue.format()} — ${r.reasonLines.join('; ')}');
    }
  }

  if (cards.isEmpty) {
    throw StateError('Expected real seeded cards from api/, got none — is db/seed/0001_demo_cards.sql applied?');
  }
  print('\nOK: live end-to-end fetch + ranking succeeded.');
}
