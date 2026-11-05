// Lane X: how the inbox words and offers the receipt question.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/ui/review_inbox_screen.dart';

void main() {
  LocalReviewItem item({bool cardBill = true, String id = 'link:receipt:a'}) =>
      LocalReviewItem(
        id: id,
        kind: 'event',
        payload: {
          'reason': 'receipt_without_payment',
          'reviewId': id,
          'factId': 'a',
          'amountMinor': 120000,
          'receiptAt': '2026-11-05T10:15:00Z',
          'cardBill': cardBill,
          'app': 'Kiwi',
          'biller': 'YES Bank',
          'sourceKey': 'k',
          'hasReading': true,
        },
      );

  test('the question uses the stored facts and the wording set', () {
    expect(
      receiptQuestion(item()),
      'Did you pay this bill? We found a receipt for a credit card bill '
      'payment of ₹1,200 on 5 Nov 2026 through Kiwi, but no matching debit in '
      'your messages. Was this paid from one of your accounts?',
    );
    expect(receiptQuestion(item(cardBill: false)), contains('a payment of'));
    expect(isReceiptQuestion(item()), isTrue);
    expect(reviewKindOf(item()), 'receipt');
  });

  testWidgets('the inbox offers exactly the three answers', (tester) async {
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReviewInboxList(
            items: [item()],
            onAction: (group, action) => actions.add(action),
          ),
        ),
      ),
    );
    expect(find.text('Did you pay this bill?'), findsWidgets);
    expect(find.textContaining('through Kiwi'), findsOneWidget);
    expect(find.text('Yes, I paid it'), findsOneWidget);
    expect(find.text('No, someone else paid it'), findsOneWidget);
    expect(find.text('Not sure'), findsOneWidget);
    // The generic message buttons do not apply to this question.
    expect(find.text('Correct'), findsNothing);
    expect(find.text('Fix'), findsNothing);
    expect(find.text('Not financial'), findsNothing);
    await tester.tap(find.text('Yes, I paid it'));
    await tester.tap(find.text('No, someone else paid it'));
    await tester.tap(find.text('Not sure'));
    expect(actions, ['receipt-yes', 'receipt-no', 'receipt-unsure']);
  });
}
