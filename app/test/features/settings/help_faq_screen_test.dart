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

  testWidgets('the tracking answer describes SMS reading as it works now', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(
      find.text('What are the different ways PandaPay can track my spending?'),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('on-device in real time'), findsNothing);
    expect(find.textContaining("iOS doesn't allow apps to read SMS"), findsNothing);
    expect(
      find.textContaining('Shortcut', skipOffstage: false),
      findsOneWidget,
      reason: 'iPhone uses a Shortcut to share messages',
    );
    expect(
      find.textContaining('read on this phone', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('the privacy answer does not overclaim what stays on the phone', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('What does PandaPay know about where I shop?'));
    await tester.pumpAndSettle();

    expect(find.textContaining('statement PDFs', skipOffstage: false), findsNothing);
    expect(find.textContaining('50 metres', skipOffstage: false), findsNothing);
    expect(
      find.textContaining(
        'The text of your bank SMS stays on this phone and is never sent',
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('roughly 11 metres', skipOffstage: false),
      findsOneWidget,
    );
  });
}
