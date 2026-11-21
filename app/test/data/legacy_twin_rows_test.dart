import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/legacy_twin_rows.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry _row(
  String id, {
  required int pipeline,
  String? key = 'sms-key-1',
  double rupees = 4000,
  String status = 'active',
  String source = 'sms',
  String? merchant,
  List<TransactionTag> tags = const [],
  String? note,
  String? userCategoryId,
  bool exclude = false,
  List<TransactionObservation> observations = const [],
}) => TransactionEntry(
  id: id,
  pipelineVersion: pipeline,
  sourceKey: key,
  amount: Money.fromRupees(rupees),
  occurredAt: DateTime.utc(2026, 10, 13, 14),
  merchantName: merchant,
  entryKind: TxnEntryKind.spend,
  instrument: TxnInstrument.upiBank,
  source: source,
  status: status,
  tags: tags,
  note: note,
  userCategoryId: userCategoryId,
  excludeFromSpend: exclude,
  observations: observations,
);

List<String> _ids(List<TransactionEntry> rows) => [for (final r in rows) r.id];

void main() {
  test('the old-pipeline copy of a message the phone has read itself is hidden', () {
    final rows = [
      _row('v2:a', pipeline: 2, merchant: 'HANDRICH'),
      _row('legacy-a', pipeline: 1),
    ];
    expect(_ids(withoutLegacyTwins(rows)), ['v2:a']);
  });

  test('a message only the old pipeline read stays, and so does every other row', () {
    final rows = [
      _row('v2:a', pipeline: 2, key: 'k-a'),
      _row('legacy-b', pipeline: 1, key: 'k-b'),
      _row('manual', pipeline: 1, key: null, source: 'manual'),
    ];
    expect(_ids(withoutLegacyTwins(rows)), ['v2:a', 'legacy-b', 'manual']);
  });

  test('nothing is dropped when the amounts differ: that is not the same payment', () {
    final rows = [
      _row('v2:a', pipeline: 2, rupees: 4000),
      _row('legacy-a', pipeline: 1, rupees: 400),
    ];
    expect(_ids(withoutLegacyTwins(rows)), ['v2:a', 'legacy-a']);
  });

  test('a copy the person tagged, noted, re-categorised or excluded is kept', () {
    for (final legacy in [
      _row('legacy-a', pipeline: 1, tags: const [TransactionTag(id: 't', name: 'Trip')]),
      _row('legacy-a', pipeline: 1, note: 'for rent'),
      _row('legacy-a', pipeline: 1, userCategoryId: 'my-cat'),
      _row('legacy-a', pipeline: 1, exclude: true),
    ]) {
      expect(_ids(withoutLegacyTwins([_row('v2:a', pipeline: 2), legacy])), ['v2:a', 'legacy-a']);
    }
  });

  test('a withdrawn (ignored) new row does not hide the old one', () {
    final rows = [
      _row('v2:a', pipeline: 2, status: 'ignored'),
      _row('legacy-a', pipeline: 1),
    ];
    expect(_ids(withoutLegacyTwins(rows)), ['v2:a', 'legacy-a']);
  });

  test('the message is found through the old row\'s observation when it has no key of its own', () {
    final rows = [
      _row('v2:a', pipeline: 2),
      _row(
        'legacy-a',
        pipeline: 1,
        key: null,
        observations: const [TransactionObservation(source: 'sms', sourceKey: 'sms-key-1')],
      ),
    ];
    expect(_ids(withoutLegacyTwins(rows)), ['v2:a']);
  });

  test('the same list comes back untouched when there is nothing to hide', () {
    final rows = [_row('v2:a', pipeline: 2), _row('v2:b', pipeline: 2, key: 'k-b')];
    expect(identical(withoutLegacyTwins(rows), rows), isTrue);
  });

  group('a message read again', () {
    test('the earlier read is hidden, the later one stays', () {
      final rows = [
        _row('v2:old', pipeline: 2, key: 'm1'),
        _row('v2:new', pipeline: 2, key: 'm1#0ae94b245000'),
      ];
      expect(_ids(withoutLegacyTwins(rows)), ['v2:new']);
    });

    test('two payments of one amount from two messages are both kept', () {
      final rows = [
        _row('v2:a', pipeline: 2, key: 'm1', rupees: 10000),
        _row('v2:b', pipeline: 2, key: 'm2', rupees: 10000),
      ];
      expect(identical(withoutLegacyTwins(rows), rows), isTrue);
    });

    test('a different amount on the same message is not hidden', () {
      final rows = [
        _row('v2:old', pipeline: 2, key: 'm1', rupees: 100),
        _row('v2:new', pipeline: 2, key: 'm1#abc', rupees: 200),
      ];
      expect(_ids(withoutLegacyTwins(rows)), ['v2:old', 'v2:new']);
    });

    test('work the person did on the earlier read keeps it', () {
      final rows = [
        _row('v2:old', pipeline: 2, key: 'm1', note: 'rent'),
        _row('v2:new', pipeline: 2, key: 'm1#abc'),
      ];
      expect(_ids(withoutLegacyTwins(rows)), ['v2:old', 'v2:new']);
    });

    test('a withdrawn later read does not hide the earlier one', () {
      final rows = [
        _row('v2:old', pipeline: 2, key: 'm1'),
        _row('v2:new', pipeline: 2, key: 'm1#abc', status: 'ignored'),
      ];
      expect(_ids(withoutLegacyTwins(rows)), ['v2:old', 'v2:new']);
    });
  });
}
