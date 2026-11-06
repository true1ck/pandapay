import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart' show SpendCategory;
import 'package:pandapay/features/cards/card_detail_screen.dart';
import 'package:pandapay/features/cards/widgets/model_status_label.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../../support/v2_catalogue_fixtures.dart';

/// WP9: card detail marks a Partial or Basic card and explains it in one
/// line; Verified cards (and v1-feed cards, which have no status) get no
/// warning label.
Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(home: Scaffold(body: Center(child: child))),
);

void main() {
  setUp(() => BambooFonts.useSystemFontsForTests = true);
  tearDown(() => BambooFonts.useSystemFontsForTests = false);

  group('ModelStatusLabel', () {
    testWidgets('Partial shows a "PARTIAL" label', (tester) async {
      await _pump(tester, const ModelStatusLabel(status: ModelStatus.partial));
      expect(find.text('PARTIAL'), findsOneWidget);
    });

    testWidgets('Basic shows a "BASIC" label', (tester) async {
      await _pump(tester, const ModelStatusLabel(status: ModelStatus.basic));
      expect(find.text('BASIC'), findsOneWidget);
    });

    testWidgets('Verified shows nothing', (tester) async {
      await _pump(tester, const ModelStatusLabel(status: ModelStatus.verified));
      expect(find.byKey(const ValueKey('model-status-label')), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('no status (the v1 feed) shows nothing', (tester) async {
      await _pump(tester, const ModelStatusLabel(status: null));
      expect(find.byKey(const ValueKey('model-status-label')), findsNothing);
    });

    testWidgets('tapping Partial opens the one-line explanation', (
      tester,
    ) async {
      await _pump(tester, const ModelStatusLabel(status: ModelStatus.partial));
      await tester.tap(find.byKey(const ValueKey('model-status-label')));
      await tester.pumpAndSettle();
      expect(
        find.text('Some earning rules for this card are estimated.'),
        findsOneWidget,
      );
    });

    testWidgets('tapping Basic explains that only the base rate is modelled', (
      tester,
    ) async {
      await _pump(tester, const ModelStatusLabel(status: ModelStatus.basic));
      await tester.tap(find.byKey(const ValueKey('model-status-label')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Only this card\'s base earning rate is modelled'),
        findsOneWidget,
      );
    });

    testWidgets('is announced as a button with its explanation', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const ModelStatusLabel(status: ModelStatus.partial));
      expect(
        find.bySemanticsLabel(
          'Partial model. Some earning rules for this card are estimated.',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('card detail', () {
    Future<void> pumpDetail(WidgetTester tester, String modelStatus) async {
      final product = parseCard(v2CardJson('a', modelStatus: modelStatus));
      final owned = parseUserCard(userCardJson('ua', 'a'));
      await tester.binding.setSurfaceSize(const Size(800, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catalogueProvider.overrideWith((ref) async => [product]),
            userCardsProvider.overrideWith((ref) async => [owned]),
            myCardsProvider.overrideWith((ref) async => [owned]),
            categoriesProvider.overrideWith(
              (ref) async => const <SpendCategory>[],
            ),
          ],
          child: const MaterialApp(home: CardDetailScreen(userCardId: 'ua')),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a Partial card carries the label', (tester) async {
      await pumpDetail(tester, 'partial');
      expect(find.text('PARTIAL'), findsOneWidget);
    });

    testWidgets('a Basic card carries the label', (tester) async {
      await pumpDetail(tester, 'basic');
      expect(find.text('BASIC'), findsOneWidget);
    });

    testWidgets('a Verified card carries no warning label', (tester) async {
      await pumpDetail(tester, 'verified');
      expect(find.byKey(const ValueKey('model-status-label')), findsNothing);
      expect(find.text('PARTIAL'), findsNothing);
      expect(find.text('BASIC'), findsNothing);
    });

    testWidgets('a v1 card (no status) carries no label', (tester) async {
      final product = parseCard(v1CardJson('v'));
      final owned = parseUserCard(userCardJson('uv', 'v'));
      await tester.binding.setSurfaceSize(const Size(800, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catalogueProvider.overrideWith((ref) async => [product]),
            userCardsProvider.overrideWith((ref) async => [owned]),
            myCardsProvider.overrideWith((ref) async => [owned]),
            categoriesProvider.overrideWith(
              (ref) async => const <SpendCategory>[],
            ),
          ],
          child: const MaterialApp(home: CardDetailScreen(userCardId: 'uv')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('model-status-label')), findsNothing);
    });

    testWidgets('tapping the label on card detail opens the sheet', (
      tester,
    ) async {
      await pumpDetail(tester, 'partial');
      await tester.tap(find.byKey(const ValueKey('model-status-label')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('model-status-explanation')),
        findsOneWidget,
      );
    });
  });
}
