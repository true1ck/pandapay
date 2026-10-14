import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/card_feedback_repository.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/cards/report_wrong_data_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

class _RecordingCardFeedbackRepository implements CardFeedbackRepository {
  Map<String, dynamic>? lastReport;

  @override
  Future<void> reportWrongData({
    required String cardProductId,
    required String fieldPath,
    String? shownValue,
    String? claimedValue,
    String? sourceUrl,
  }) async {
    lastReport = {
      'cardProductId': cardProductId,
      'fieldPath': fieldPath,
      'shownValue': shownValue,
      'claimedValue': claimedValue,
      'sourceUrl': sourceUrl,
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'pre-fills the card name from the catalogue and submits a report',
    (tester) async {
      final repo = _RecordingCardFeedbackRepository();
      final product = CardProduct(
        id: 'p1',
        name: 'Test Card',
        network: CardNetwork.rupay,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catalogueRepositoryProvider.overrideWithValue(
              _FakeCatalogueRepository([product]),
            ),
            cardFeedbackRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(
            home: ReportWrongDataScreen(
              cardProductId: 'p1',
              initialFieldPath: 'Dining rate',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Test Card'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Dining rate'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Dining rate'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('What it should be'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'What it should be'),
        '5%',
      );
      await tester.scrollUntilVisible(
        find.text('Submit report'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Submit report'));
      await tester.pumpAndSettle();

      expect(repo.lastReport?['cardProductId'], 'p1');
      expect(repo.lastReport?['fieldPath'], 'Dining rate');
      expect(repo.lastReport?['claimedValue'], '5%');
      expect(
        find.textContaining('we verify before publishing'),
        findsOneWidget,
      );
    },
  );

  testWidgets('requires a field before submitting', (tester) async {
    final repo = _RecordingCardFeedbackRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueRepositoryProvider.overrideWithValue(
            _FakeCatalogueRepository(const []),
          ),
          cardFeedbackRepositoryProvider.overrideWithValue(repo),
        ],
        child: const MaterialApp(
          home: ReportWrongDataScreen(cardProductId: 'p1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Submit report'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Submit report'));
    await tester.pumpAndSettle();

    expect(repo.lastReport, isNull);
    expect(find.textContaining('Tell us which field'), findsOneWidget);
  });

  testWidgets('selects a known field with a radio button', (tester) async {
    final repo = _RecordingCardFeedbackRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueRepositoryProvider.overrideWithValue(
            _FakeCatalogueRepository(const []),
          ),
          cardFeedbackRepositoryProvider.overrideWithValue(repo),
        ],
        child: const MaterialApp(
          home: ReportWrongDataScreen(cardProductId: 'p1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RadioListTile<String>), findsNWidgets(14));
    await tester.tap(find.text('Annual fee'));
    await tester.scrollUntilVisible(
      find.text('What it should be'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'What it should be'),
      'Lifetime free',
    );
    await tester.scrollUntilVisible(
      find.text('Submit report'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Submit report'));
    await tester.pumpAndSettle();

    expect(repo.lastReport?['fieldPath'], 'annual_fee');
    expect(repo.lastReport?['claimedValue'], 'Lifetime free');
  });
}
