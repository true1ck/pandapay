import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';

void main() {
  late AppDatabase appDb;
  late ResponseCache cache;

  setUp(() {
    appDb = openInMemoryForTesting();
    cache = ResponseCache(appDb);
  });
  tearDown(() => appDb.close());

  test('get returns null when nothing cached for that key', () async {
    expect(await cache.get('catalogue'), isNull);
  });

  test('put then get round-trips the raw json', () async {
    await cache.put('catalogue', '{"cards":[]}');
    expect(await cache.get('catalogue'), '{"cards":[]}');
  });

  test('put overwrites a previous value for the same key', () async {
    await cache.put('catalogue', 'first');
    await cache.put('catalogue', 'second');
    expect(await cache.get('catalogue'), 'second');
  });

  test('different keys do not collide', () async {
    await cache.put('catalogue', 'cat-value');
    await cache.put('categories', 'cats-value');
    expect(await cache.get('catalogue'), 'cat-value');
    expect(await cache.get('categories'), 'cats-value');
  });

  test('clear removes only the given key', () async {
    await cache.put('user_cards', 'wallet');
    await cache.put('catalogue', 'cat');
    await cache.clear('user_cards');
    expect(await cache.get('user_cards'), isNull);
    expect(await cache.get('catalogue'), 'cat');
  });
}
