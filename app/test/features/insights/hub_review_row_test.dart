// The Insights card says how many reviews are LEFT (the questions on Needs
// review), not how many messages sit behind them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/insights/insights_hub_screen.dart';
import 'package:pandapay/features/sms_v2/providers/review_question_count.dart';

Future<void> _pump(
  WidgetTester tester, {
  required int reviews,
  int dupes = 0,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: HubReviewRow(needsReview: reviews, duplicates: dupes),
    ),
  ),
);

void main() {
  test('the words are shared by every place that shows the count', () {
    expect(reviewsLeftText(1), '1 review left');
    expect(reviewsLeftText(2), '2 reviews left');
    expect(reviewsLeftText(38), '38 reviews left');
  });

  testWidgets('the card shows reviews left, not messages', (tester) async {
    await _pump(tester, reviews: 38);
    expect(find.text('38 reviews left'), findsOneWidget);
    expect(find.textContaining('messages need review'), findsNothing);
  });

  testWidgets('one review left is singular', (tester) async {
    await _pump(tester, reviews: 1);
    expect(find.text('1 review left'), findsOneWidget);
  });

  testWidgets('nothing left shows no review card, duplicates keep theirs', (
    tester,
  ) async {
    await _pump(tester, reviews: 0, dupes: 2);
    expect(find.textContaining('review'), findsNothing);
    expect(find.text('2 possible duplicates'), findsOneWidget);
  });
}
