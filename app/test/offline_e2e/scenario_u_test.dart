// Scenario u: local first for the remaining writes. A "try later" answer
// (408/429/5xx) is never shown as an error, and a save never waits on the
// network. Synthetic data only.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/cards/add_card_local_first.dart';
import 'package:pandapay/features/cards/card_state_local_first.dart';

import 'harness.dart';

void main() {
  late OfflineApp app;
  setUp(() async => app = await OfflineApp.create());
  tearDown(() => app.dispose());

  for (final status in [429, 408, 500, 503]) {
    test('u1. add card while the server answers $status: saved, queued, sent later',
        () async {
      app.server.seedCard(nickname: 'Daily', last4: '1111');
      await app.start();
      await app.firstSyncOnline();
      app.server.failWhen =
          (m, p, b) => m == 'POST' && p == '/user-cards' ? status : null;

      final added = await addCardLocalFirst(
        app.ref,
        cardProductId: 'product-2',
        nickname: 'Travel',
        last4: '4444',
      );
      expect(added.queued, isTrue, reason: '$status means later, not no');
      app.refreshViews();
      final wallet = await app.c.read(userCardsProvider.future);
      expect(wallet.any((c) => c.id == added.id && c.last4 == '4444'), isTrue);

      app.server.failWhen = null;
      app.advance(const Duration(hours: 1));
      await app.flushAll();
      expect(
        app.server.cards.values.where((c) => c['last4'] == '4444'),
        hasLength(1),
      );
      expect(app.attention, 0);
    });
  }

  test('u2. restoring an archived card works offline and reaches the server',
      () async {
    final card = app.server.seedCard(nickname: 'Old', last4: '2222');
    card['is_archived'] = true;
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();

    expect(
      await setCardArchived(app.ref, card['id'] as String, archived: false),
      CardChange.queued,
    );
    expect(app.pending, greaterThan(0));

    await app.goOnline();
    await app.flushAll();
    expect(app.server.cards[card['id']]!['is_archived'], isFalse);
  });
}
