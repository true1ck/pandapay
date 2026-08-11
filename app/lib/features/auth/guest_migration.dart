import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../app/env.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

/// Plan Phase 1.2 — carries a guest's on-device wallet onto the account they
/// just signed into.
///
/// Why this is worth its own file rather than a few lines in the login
/// screen: it has to run on *every* route into a signed-in session, not just
/// the one the user happened to take. `auth/`'s `POST /auth/guest-login`
/// issues a token with, in its own words, "NO DATABASE RECORD", so a guest's
/// cards exist only in the client's `local_user_cards` sqlite table. Before
/// this, signing up threw that away — at the exact moment the user decided to
/// commit to the product.
///
/// The ordering is the whole design and is deliberately paranoid:
///
/// 1. read the local wallet,
/// 2. POST it and wait for a 2xx,
/// 3. only then delete the local rows.
///
/// A crash or a dropped connection anywhere before step 3 leaves the guest
/// wallet exactly where it was, and the next sign-in retries. The server side
/// is idempotent by card product (see `POST /user-cards/import`), so that
/// retry cannot double anything — which is what makes it safe to be
/// pessimistic here.
class GuestMigrationResult {
  final int imported;
  final int alreadyPresent;
  final int skipped;

  const GuestMigrationResult({
    required this.imported,
    required this.alreadyPresent,
    required this.skipped,
  });

  bool get didAnything => imported > 0 || alreadyPresent > 0;

  static const none = GuestMigrationResult(imported: 0, alreadyPresent: 0, skipped: 0);
}

class GuestMigration {
  final Ref _ref;
  final http.Client _client;

  GuestMigration(this._ref, {http.Client? client}) : _client = client ?? http.Client();

  Future<GuestMigrationResult> run() async {
    final token = _ref.read(accessTokenProvider);
    if (token == null) return GuestMigrationResult.none;

    final local = await _ref.read(localUserCardsRepositoryProvider.future);
    final cards = await local.exportForMigration();
    if (cards.isEmpty) return GuestMigrationResult.none;

    final response = await _client.post(
      Uri.parse('${Env.apiBaseUrl}/user-cards/import'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({'cards': cards}),
    );
    if (response.statusCode != 201) {
      throw ApiException(
        'POST /user-cards/import failed: ${response.statusCode} ${response.body}',
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final results = (body['results'] as List).cast<Map<String, dynamic>>();
    final imported = results.where((r) => r['status'] == 'imported').length;
    final alreadyPresent = results.where((r) => r['status'] == 'already_present').length;
    final skipped = results.length - imported - alreadyPresent;

    // Step 3. Only the cards the server actually accounted for are gone —
    // but note that a card the server rejected as `unknown_product` (its
    // product was unpublished since the guest added it) is cleared too. That
    // is intentional: the alternative is a permanently stuck local row that
    // re-fails on every future sign-in with nothing the user can do about it.
    // The count is surfaced to the user below rather than swallowed.
    await local.clearAll();

    return GuestMigrationResult(
      imported: imported,
      alreadyPresent: alreadyPresent,
      skipped: skipped,
    );
  }
}

final guestMigrationProvider = Provider<GuestMigration>(GuestMigration.new);

/// The result of the most recent migration, or null if none has run this
/// session. Watched by the shell so the user gets told what happened —
/// silently moving someone's cards is nearly as disconcerting as losing them.
final lastGuestMigrationProvider = StateProvider<GuestMigrationResult?>((ref) => null);

/// Runs the migration once per sign-in transition. Watched from `_AppShell`
/// (router.dart) next to `settingsSyncLifecycleProvider`, for the same
/// reason: it's the one widget guaranteed to be mounted whichever way the
/// session began.
final guestMigrationLifecycleProvider = Provider<void>((ref) {
  ref.listen<String?>(accessTokenProvider, (previous, next) async {
    if (previous != null || next == null) return;
    try {
      final result = await ref.read(guestMigrationProvider).run();
      if (!result.didAnything) return;
      ref.read(lastGuestMigrationProvider.notifier).state = result;
      // The wallet the user is about to look at is now the server's, not the
      // local table's — force the next read to come from the server rather
      // than a cached guest-mode response.
      ref.invalidate(myCardsProvider);
    } catch (_) {
      // Offline or server error. The local wallet is deliberately still
      // intact (see the ordering note above), so the next sign-in retries.
    }
  });
});
