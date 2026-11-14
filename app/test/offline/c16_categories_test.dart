import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';

class _OfflineCategories implements CategoryRepository {
  @override
  Future<List<SpendCategory>> fetchCategories() async =>
      throw const SocketException('offline');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled categories parse with the network model', () {
    final raw = File('assets/data/bundled_categories.json').readAsStringSync();
    final categories = parseBundledCategories(raw);
    expect(categories.length, greaterThanOrEqualTo(10));
    expect(categories.map((c) => c.slug), containsAll(['groceries', 'emi', 'other']));
    expect(categories.every((c) => isBundledCategoryId(c.id)), isTrue);
    expect(categoryIdForServer(categories.first.id, categories), isNull);
  });

  test('first-ever offline launch returns the built-in categories', () async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final container = ProviderContainer(
      overrides: [
        responseCacheProvider.overrideWith(
          (ref) async => ResponseCache(database),
        ),
        categoryRepositoryProvider.overrideWithValue(_OfflineCategories()),
      ],
    );
    addTearDown(container.dispose);

    final categories = await container.read(categoriesProvider.future);

    expect(categories.map((c) => c.slug), contains('groceries'));
  });
}
