import 'dart:convert';

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

  test('cleans old promotional review items while retaining real alerts', () async {
    final prefs = await SharedPreferences.getInstance();
    final oldOffer = NeedsReviewItem(
      id: 'old-offer',
      sender: 'TX-WAKFTT-P',
      body: 'Treat yourself to a sofa at just Rs.28,125. Grab offer now.',
      receivedAt: DateTime(2026, 1, 1),
    );
    final realTxn = NeedsReviewItem(
      id: 'real-txn',
      sender: 'AD-FEDSCP-S',
      body: 'Your txn of Rs.1018 at a restaurant earned you 5% rewards.',
      receivedAt: DateTime(2026, 1, 2),
    );
    await prefs.setStringList('pandapay_app.needs_review_queue_v1', [
      jsonEncode(oldOffer.toJson()),
      jsonEncode(realTxn.toJson()),
    ]);
    final repo = NeedsReviewRepository();
    expect((await repo.fetchAll()).map((item) => item.id), ['real-txn']);
    expect(prefs.getStringList('pandapay_app.needs_review_queue_v1'), hasLength(1));
  });

  test('fetchAll on an empty store returns an empty list, not an error', () async {
    final repo = NeedsReviewRepository();
    expect(await repo.fetchAll(), isEmpty);
  });

  test('does not enqueue the same SMS twice when delivery timestamps are close', () async {
    final repo = NeedsReviewRepository();
    final receivedAt = DateTime(2026, 1, 2, 10, 0);
    await repo.add(NeedsReviewItem(
      id: 'first',
      sender: 'VM-SLICE',
      body: 'Rs. 875 spent on your credit card xx9080 at slice on 29-Sep-26.',
      receivedAt: receivedAt,
    ));
    await repo.add(NeedsReviewItem(
      id: 'duplicate',
      sender: 'vm-slice',
      body: '  Rs. 875 spent on your credit card xx9080 at slice on 29-Sep-26.  ',
      receivedAt: receivedAt.add(const Duration(minutes: 2)),
    ));

    final all = await repo.fetchAll();
    expect(all, hasLength(1));
    expect(all.single.id, 'first');
  });

  test('keeps identical SMS text when it arrived on a different day', () async {
    final repo = NeedsReviewRepository();
    await repo.add(NeedsReviewItem(
      id: 'day-one',
      sender: 'VM-SLICE',
      body: 'Rs. 875 spent on your credit card xx9080 at slice.',
      receivedAt: DateTime(2026, 1, 2),
    ));
    await repo.add(NeedsReviewItem(
      id: 'day-two',
      sender: 'VM-SLICE',
      body: 'Rs. 875 spent on your credit card xx9080 at slice.',
      receivedAt: DateTime(2026, 1, 3),
    ));

    expect(await repo.fetchAll(), hasLength(2));
  });
}
