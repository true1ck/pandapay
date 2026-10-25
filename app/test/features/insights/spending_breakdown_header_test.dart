import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/insights/spending_visuals.dart';

void main() {
  Widget amount(String value) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(value),
      const SizedBox(width: 6),
      const Icon(Icons.hourglass_top_rounded, size: 14),
    ],
  );

  testWidgets('percentage and amount rails align across breakdown rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: Column(
              children: [
                SpendingBreakdownHeader(
                  label: const Text('Other'),
                  percentage: '48%',
                  percentageKey: const Key('percentage-a'),
                  amountKey: const Key('amount-a'),
                  amount: amount('₹85,045.25'),
                ),
                SpendingBreakdownHeader(
                  label: const Text('Education'),
                  percentage: '0%',
                  percentageKey: const Key('percentage-b'),
                  amountKey: const Key('amount-b'),
                  amount: amount('₹6.00'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final percentageA = tester.getRect(find.byKey(const Key('percentage-a')));
    final percentageB = tester.getRect(find.byKey(const Key('percentage-b')));
    final amountA = tester.getRect(find.byKey(const Key('amount-a')));
    final amountB = tester.getRect(find.byKey(const Key('amount-b')));

    expect(percentageA.left, closeTo(percentageB.left, 0.01));
    expect(percentageA.right, closeTo(percentageB.right, 0.01));
    expect(amountA.left, closeTo(amountB.left, 0.01));
    expect(amountA.right, closeTo(amountB.right, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact width and larger text do not overflow', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            body: SizedBox(
              width: 220,
              child: SpendingBreakdownHeader(
                label: const Text(
                  'A very long spending category name',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                percentage: '100%',
                amount: amount('₹12,34,56,789.00'),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
