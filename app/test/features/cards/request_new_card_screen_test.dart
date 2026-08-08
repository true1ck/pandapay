import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/card_feedback_repository.dart';
import 'package:pandapay/features/cards/request_new_card_screen.dart';

class _RecordingCardFeedbackRepository implements CardFeedbackRepository {
  Map<String, dynamic>? lastRequest;

  @override
  Future<void> requestNewCard({required String issuerName, required String productName, String? networkGuess}) async {
    lastRequest = {'issuerName': issuerName, 'productName': productName, 'networkGuess': networkGuess};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('shows a validation error when submitted empty', (tester) async {
    final repo = _RecordingCardFeedbackRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardFeedbackRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: RequestNewCardScreen()),
      ),
    );
    await tester.tap(find.text('Submit request'));
    await tester.pumpAndSettle();
    expect(find.textContaining('required'), findsOneWidget);
    expect(repo.lastRequest, isNull);
  });

  testWidgets('submits issuer + product name and shows the confirmation', (tester) async {
    final repo = _RecordingCardFeedbackRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cardFeedbackRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: RequestNewCardScreen()),
      ),
    );

    await tester.enterText(find.widgetWithText(TextField, 'Issuer (e.g. HDFC Bank)'), 'IDFC First');
    await tester.enterText(find.widgetWithText(TextField, 'Card name'), 'Wealth Card');
    await tester.tap(find.text('Submit request'));
    await tester.pumpAndSettle();

    expect(repo.lastRequest?['issuerName'], 'IDFC First');
    expect(repo.lastRequest?['productName'], 'Wealth Card');
    expect(find.text('Request sent'), findsOneWidget);
  });
}
