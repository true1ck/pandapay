import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/spend_exclusion_matches.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry _e(
  String id, {
  String? merchant,
  List<TransactionTag> tags = const [],
  bool excluded = false,
  TxnEntryKind kind = TxnEntryKind.spend,
}) => TransactionEntry(
  id: id,
  amount: Money.fromRupees(100),
  occurredAt: DateTime(2026, 11, 1),
  merchantName: merchant,
  entryKind: kind,
  excludeFromSpend: excluded,
  tags: tags,
  source: 'sms',
  status: 'active',
);

void main() {
  const family = TransactionTag(id: 't1', name: 'Family');
  final src = _e('a', merchant: 'Shop One', tags: [family]);

  test('offers the same merchant and the same tag, never the source or settled rows', () {
    final groups = exclusionMatches(src, [
      src,
      _e('b', merchant: 'shop  one'),
      _e('c', merchant: 'Other', tags: [family]),
      _e('d', merchant: 'Shop One', excluded: true),
      _e('e', merchant: 'Shop One', kind: TxnEntryKind.income),
      _e('f', merchant: 'Unrelated'),
    ]);
    expect(groups.map((g) => g.label), ['Same merchant: Shop One', 'Tagged Family']);
    expect(groups[0].entries.map((e) => e.id), ['b']);
    expect(groups[1].entries.map((e) => e.id), ['c']);
  });

  test('nothing to offer for an unknown merchant with no tags', () {
    expect(exclusionMatches(_e('a', merchant: 'UNKNOWN'), [_e('b', merchant: 'UNKNOWN')]), isEmpty);
  });

  testWidgets('nothing is applied until ticked and confirmed, and rows count once', (tester) async {
    final both = _e('b', merchant: 'Shop One', tags: [family]);
    final groups = exclusionMatches(src, [both]);
    List<TransactionEntry>? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => TextButton(
          onPressed: () async => result = await showExclusionMatchesSheet(c, groups),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('exclusion-match-apply'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('exclusion-match-0')));
    await tester.tap(find.byKey(const Key('exclusion-match-1')));
    await tester.pump();
    expect(find.text('Leave out 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('exclusion-match-apply')));
    await tester.pumpAndSettle();
    expect(result!.map((e) => e.id), ['b']);
  });
}
