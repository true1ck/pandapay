import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  test(
    'a background auth rejection does not ask a signed-in user to sign in',
    () async {
      final db = openInMemoryForTesting();
      final cache = ResponseCache(db);
      addTearDown(() {
        cache.financialStore.dispose();
        db.close();
      });
      cache.financialStore.setSyncStatus('user:one', 'authentication_required');
      cache.financialStore.saveProvisional(
        'user:one',
        TransactionEntry(
          id: 'local-sms:one',
          amount: Money.fromPaise(10000),
          occurredAt: DateTime(2026, 10, 18),
          sourceKey: 'one',
          merchantName: 'Shop',
          source: 'sms',
          status: 'active',
        ),
      );
      final container = ProviderContainer(
        overrides: [
          cacheNamespaceProvider.overrideWithValue('user:one'),
          responseCacheProvider.overrideWith((ref) async => cache),
        ],
      );
      addTearDown(container.dispose);

      expect(await container.read(financialSyncStatusProvider.future), isEmpty);
    },
  );
}
