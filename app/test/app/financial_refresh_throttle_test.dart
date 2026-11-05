import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';

void main() {
  const namespace = 'user:11111111-1111-4111-8111-111111111111';

  test('one change refreshes at once; an import burst refreshes once per window', () {
    fakeAsync((async) {
      final database = openInMemoryForTesting();
      final cache = ResponseCache(database);
      final container = ProviderContainer(
        overrides: [
          cacheNamespaceProvider.overrideWithValue(namespace),
          responseCacheProvider.overrideWith((ref) async => cache),
        ],
      );
      final seen = <int>[];
      container.listen(
        financialStoreRevisionProvider('transactions'),
        (_, next) => next.whenData(seen.add),
        fireImmediately: true,
      );
      async.flushMicrotasks();

      cache.financialStore.notifyExternalChanges(namespace, const ['transactions']);
      async.flushMicrotasks();
      expect(seen, [1], reason: 'a single change is shown at once');

      // An import writes a batch every 200 ms for 30 seconds.
      for (var i = 0; i < 150; i++) {
        async.elapse(const Duration(milliseconds: 200));
        cache.financialStore.notifyExternalChanges(namespace, const ['transactions']);
      }
      async.elapse(financialRefreshWindow);
      async.flushMicrotasks();
      // 30 s of batches plus the final flush: a handful of refreshes, not 150.
      expect(seen.length, inInclusiveRange(2, 4));

      // Another account's change never refreshes this one.
      final before = seen.length;
      async.elapse(financialRefreshWindow * 2);
      cache.financialStore.notifyExternalChanges('user:other', const ['transactions']);
      async.elapse(financialRefreshWindow);
      async.flushMicrotasks();
      expect(seen.length, before);

      container.dispose();
      database.close();
    });
  });
}
