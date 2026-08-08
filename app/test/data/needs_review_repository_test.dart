import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('add then fetchAll round-trips an item, newest first', () async {
    final repo = NeedsReviewRepository();
    await repo.add(NeedsReviewItem(
      id: '1',
      sender: 'VM-HDFCBK',
      body: 'first message',
      receivedAt: DateTime(2026, 1, 1),
    ));
    await repo.add(NeedsReviewItem(
      id: '2',
      sender: 'AX-AxisBk',
      body: 'second message',
      reason: 'unparseable_amount',
      receivedAt: DateTime(2026, 1, 2),
    ));

    final all = await repo.fetchAll();
    expect(all, hasLength(2));
    expect(all.first.id, '2'); // newest first
    expect(all.first.reason, 'unparseable_amount');
    expect(all.last.body, 'first message');
  });

  test('remove drops exactly the matching item', () async {
    final repo = NeedsReviewRepository();
    await repo.add(NeedsReviewItem(id: '1', sender: 's1', body: 'b1', receivedAt: DateTime(2026, 1, 1)));
    await repo.add(NeedsReviewItem(id: '2', sender: 's2', body: 'b2', receivedAt: DateTime(2026, 1, 2)));

    await repo.remove('1');

    final all = await repo.fetchAll();
    expect(all, hasLength(1));
    expect(all.first.id, '2');
  });

  test('removeAll drops every id in the set', () async {
    final repo = NeedsReviewRepository();
    await repo.add(NeedsReviewItem(id: '1', sender: 's1', body: 'b1', receivedAt: DateTime(2026, 1, 1)));
    await repo.add(NeedsReviewItem(id: '2', sender: 's2', body: 'b2', receivedAt: DateTime(2026, 1, 2)));
    await repo.add(NeedsReviewItem(id: '3', sender: 's3', body: 'b3', receivedAt: DateTime(2026, 1, 3)));

    await repo.removeAll(['1', '3']);

    final all = await repo.fetchAll();
    expect(all, hasLength(1));
    expect(all.first.id, '2');
  });

  test('fetchAll on an empty store returns an empty list, not an error', () async {
    final repo = NeedsReviewRepository();
    expect(await repo.fetchAll(), isEmpty);
  });
}
