import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/category_bulk_review_sheet.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

RelatedTransactionCandidate _candidate(
  String id,
  RelatedTransactionSelectionTier tier,
  String category,
) => RelatedTransactionCandidate(
  id: id,
  occurredAt: DateTime(2026, 10, 5),
  amount: Money.fromRupees(500),
  paymentSource: 'UPI / bank account',
  currentCategoryName: category,
  selectionTier: tier,
);

RelatedCategoryPreview _preview() => RelatedCategoryPreview(
  previewId: 'preview-1',
  sourceTransactionId: 'source',
  targetCategoryId: 'food',
  targetCategoryName: 'Food',
  matchBasis: RelatedTransactionMatchBasis.vpa,
  totalCandidateCount: 3,
  selectableCandidateCount: 2,
  defaultSelectedCount: 1,
  overflow: false,
  candidates: [
    _candidate('other-1', RelatedTransactionSelectionTier.defaultSelected, 'Other'),
    _candidate('review-1', RelatedTransactionSelectionTier.manualReview, 'Groceries'),
    _candidate('blocked-1', RelatedTransactionSelectionTier.ineligible, 'Other'),
  ],
);

Future<void> _open(
  WidgetTester tester, {
  required Future<CategoryBulkApplyResult> Function(Set<String>) onApply,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showCategoryBulkReviewSheet(
              context: context,
              preview: _preview(),
              onApply: onApply,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('defaults safe rows, leaves manual review unchecked, and supports select all/clear', (
    tester,
  ) async {
    await _open(
      tester,
      onApply: (ids) async {
        return const CategoryBulkApplyResult(
          operationId: 'op-1',
          changedCount: 1,
          unchangedCount: 0,
        );
      },
    );

    expect(find.text('Apply Food to more?'), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text('Manual review rows start unchecked'), findsOneWidget);
    expect(find.text('Some rows are unavailable for bulk editing'), findsOneWidget);

    await tester.tap(find.text('Select all'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(find.text('0 selected'), findsOneWidget);
    final applyButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Apply to 0'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(applyButton.onPressed, isNull);
  });

  testWidgets('sends exactly the selected IDs once and closes after apply', (
    tester,
  ) async {
    Set<String>? applied;
    await _open(
      tester,
      onApply: (ids) async {
        applied = ids;
        return const CategoryBulkApplyResult(
          operationId: 'op-1',
          changedCount: 1,
          unchangedCount: 0,
        );
      },
    );

    await tester.tap(find.text('Apply to 1'));
    await tester.pumpAndSettle();
    expect(applied, {'other-1'});
    expect(find.text('Apply Food to more?'), findsNothing);
  });

  testWidgets('Not now closes without applying', (tester) async {
    var called = false;
    await _open(
      tester,
      onApply: (ids) async {
        called = true;
        return const CategoryBulkApplyResult(
          operationId: 'op-1',
          changedCount: 1,
          unchangedCount: 0,
        );
      },
    );

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(called, isFalse);
    expect(find.text('Apply Food to more?'), findsNothing);
  });
}
