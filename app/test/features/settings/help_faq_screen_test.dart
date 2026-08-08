import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/settings/help_faq_screen.dart';

/// H7 Help & FAQ — a fully static, offline, no-provider screen (spec's
/// simplest H-group screen), so this test needs no ProviderScope overrides,
/// fakes, or SharedPreferences mocking, unlike most screens under
/// app/test/features/. Covers: initial render shows every question,
/// searching narrows to a single match, and a no-match search shows the
/// empty state copy.
Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: HelpFaqScreen()));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders all FAQ questions initially', (tester) async {
    await _pump(tester);

    expect(find.text('What does setup actually involve?'), findsOneWidget);
    expect(find.text('What are the different ways PandaPay can track my spending?'), findsOneWidget);
    expect(find.text('Why did the recommended card look wrong for this purchase?'), findsOneWidget);
    expect(find.text('How accurate are the reward numbers I see?'), findsOneWidget);
    expect(find.text('What does PandaPay know about where I shop?'), findsOneWidget);
  });

  testWidgets('typing a search term filters down to the single matching question', (tester) async {
    await _pump(tester);

    await tester.enterText(find.byType(TextField), 'RuPay');
    await tester.pumpAndSettle();

    expect(find.text('Why did the recommended card look wrong for this purchase?'), findsOneWidget);
    expect(find.text('What does setup actually involve?'), findsNothing);
    expect(find.text('What are the different ways PandaPay can track my spending?'), findsNothing);
    expect(find.text('How accurate are the reward numbers I see?'), findsNothing);
    expect(find.text('What does PandaPay know about where I shop?'), findsNothing);
  });

  testWidgets('a search term matching nothing shows the empty state', (tester) async {
    await _pump(tester);

    await tester.enterText(find.byType(TextField), 'zzzznomatch');
    await tester.pumpAndSettle();

    expect(find.text("No results for 'zzzznomatch' — try a different word."), findsOneWidget);
    expect(find.text('What does setup actually involve?'), findsNothing);
  });
}
