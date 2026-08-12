// ignore_for_file: avoid_print
// This is a standalone CLI verification script (`dart run tool/verify_live_wallet.dart`);
// stdout is its output, not stray debug logging.
// Manual verification script (not part of the automated test suite):
// hits the REAL api/ HTTP endpoints via UserCardsRepository + CatalogueRepository
// (the exact classes the app uses), scopes the catalogue to the wallet, and
// runs the result through RecommendationEngine with real capRemaining derived
// from a live cap_states row — proving Chunk 17's wiring end to end against
// the live backend, not fixtures. Pass a real access token as the sole arg
// (see /tmp/user_token.txt from the verification session).
import 'dart:io';

import 'package:pandapay/app/env.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart run tool/verify_live_wallet.dart <access_token>');
    exit(1);
  }
  final token = args.first.trim();
  const baseUrl = Env.apiBaseUrl;

  final catalogueRepo = HttpCatalogueRepository(baseUrl: baseUrl);
  final categoryRepo = HttpCategoryRepository(baseUrl: baseUrl);
  final userCardsRepo = UserCardsRepository(apiBaseUrl: baseUrl, accessToken: token);

  final catalogue = await catalogueRepo.fetchCatalogue();
  final categories = await categoryRepo.fetchCategories();
  final onlineCategoryId = categories.firstWhere((c) => c.slug == 'online').id;
  final wallet = await userCardsRepo.fetchUserCards();
  print('Fetched ${catalogue.length} catalogue cards, wallet has ${wallet.length} card(s).');
  for (final w in wallet) {
    print('  - ${w.cardName} (user_card ${w.id})');
    for (final entry in w.capConsumed.entries) {
      print('      capRule ${entry.key}: consumed ${entry.value.format()}');
    }
  }

  if (wallet.isEmpty) {
    throw StateError('Expected a non-empty wallet for this verification run.');
  }

  final owned = catalogue.where((c) => wallet.any((w) => w.cardProductId == c.id)).toList();
  final snapshots = owned.map((c) {
    final w = wallet.firstWhere((w) => w.cardProductId == c.id);
    final capRemaining = {
      for (final cap in c.capRules)
        if (w.capConsumed.containsKey(cap.id)) cap.id: cap.capValue - w.capConsumed[cap.id]!,
    };
    return CardSnapshot(product: c, capRemaining: capRemaining, milestoneProgress: w.milestoneQualifiedSpend);
  }).toList();

  final engine = RecommendationEngine();
  final ctx = RecommendationContext(
    amount: Money.fromRupees(20000),
    categoryId: onlineCategoryId,
    rail: TxnRail.swipe,
  );
  final results = engine.rank(ctx, snapshots);

  print('\nRanked for a further Rs.20,000 spend against the real wallet state:');
  for (final r in results) {
    print('  ${r.card.name}: ${r.expectedValue.format()} — ${r.reasonLines.join('; ')}');
  }

  print('\nOK: live wallet fetch + cap-aware ranking succeeded.');
}
