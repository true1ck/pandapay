import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pandapay/data/catalogue_repository.dart' show SpendCategory;
import 'package:pandapay/data/user_cards_repository.dart' show UserCard;
import 'package:pandapay/features/voice/follow_up/follow_up.dart';
import 'package:pandapay/features/voice/voice_action_parser.dart';
import 'package:pandapay/features/voice/voice_draft_editor.dart';
import 'package:pandapay/features/voice/voice_entry_review.dart';

final now = DateTime(2026, 11, 11, 15, 30);

const categories = [
  SpendCategory(id: 'dining-id', slug: 'dining', name: 'Dining'),
  SpendCategory(id: 'online-id', slug: 'online', name: 'Online'),
];

final cards = [
  UserCard(
    id: 'a',
    cardProductId: 'p-a',
    cardName: 'Axis Atlas Credit Card',
    last4: '4567',
    isDefault: false,
  ),
  UserCard(
    id: 'b',
    cardProductId: 'p-b',
    cardName: 'HDFC Swiggy Credit Card',
    last4: '1111',
    isDefault: false,
  ),
];

VoiceActionDraft draftOf(String text) => VoiceActionParser.parseMany(
  text,
  cards: cards,
  categories: categories,
  now: now,
).first;

class _Harness {
  _Harness(this.draft)
    : editor = VoiceDraftEditor(draft)..initKindAlternative();

  final VoiceActionDraft draft;
  final VoiceDraftEditor editor;
  final chosen = <String>[];
  final numbers = <double>[];
  int skipped = 0;

  FollowUp? get followUp => FollowUpPlanner.next(
    editor.followUpState(cards: cards, refundChoices: const []),
  );

  Widget build(void Function() rebuild) => ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: VoiceEntryReview(
            draft: draft,
            editor: editor,
            cards: cards,
            categories: categories,
            index: 0,
            total: 1,
            now: now,
            onChanged: rebuild,
            followUp: followUp,
            onFollowUpChoice: (f, c) {
              chosen.add(c.id);
              editor.asked.add(f.slot);
              rebuild();
            },
            onFollowUpNumber: (f, v) {
              numbers.add(v);
              editor.amountController.text = v.toStringAsFixed(2);
              editor.asked.add(f.slot);
              rebuild();
            },
            onFollowUpSkip: (f) {
              skipped++;
              editor.asked.add(f.slot);
              rebuild();
            },
            onFollowUpListen: (_) {},
            listeningForAnswer: false,
          ),
        ),
      ),
    ),
  );
}

Future<void> show(WidgetTester tester, _Harness h) async {
  late StateSetter set;
  await tester.pumpWidget(
    StatefulBuilder(
      builder: (context, setState) {
        set = setState;
        return h.build(() => set(() {}));
      },
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a spend shows what was heard and the editable fields', (
    tester,
  ) async {
    final h = _Harness(draftOf('spent two fifty on lunch yesterday'));
    await show(tester, h);
    expect(find.text('Spend details'), findsOneWidget);
    expect(find.textContaining('two fifty'), findsWidgets);
    expect(find.text('₹2.50?'), findsOneWidget);
    expect(find.text('Yesterday'), findsWidgets);
    expect(find.text('Amount (₹) *', findRichText: true), findsOneWidget);
    expect(find.text('Choose the wallet card for this entry.'), findsOneWidget);
  });

  testWidgets('tapping the other reading of an amount uses it', (tester) async {
    final h = _Harness(draftOf('spent two fifty on lunch'));
    await show(tester, h);
    expect(h.editor.amountController.text, '250.00');
    await tester.tap(find.text('₹2.50?'));
    await tester.pump();
    expect(h.editor.amountController.text, '2.50');
  });

  testWidgets('a foreign amount asks for the rupee amount and takes it', (
    tester,
  ) async {
    final h = _Harness(draftOf('spent 50 dollars in Dubai'));
    await show(tester, h);
    expect(find.text('How much was that in rupees?'), findsOneWidget);
    expect(find.textContaining('USD 50'), findsWidgets);
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '4200');
    await tester.tap(find.text('Use'));
    await tester.pump();
    expect(h.numbers, [4200]);
    expect(h.editor.amountController.text, '4200.00');
    // The next question is the card, since a credit-card spend needs one.
    expect(find.text('Which card?'), findsOneWidget);
  });

  testWidgets('money in asks what it was and shows money-in fields', (
    tester,
  ) async {
    final h = _Harness(draftOf('received 5000 from Rahul'));
    await show(tester, h);
    expect(find.text('Money in details'), findsOneWidget);
    expect(find.text('What was it?'), findsOneWidget);
    expect(
      find.text('Amount received (₹) *', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Who or what it was from'), findsOneWidget);
    expect(find.text('How it reached you'), findsOneWidget);
    // No wallet card for money in.
    expect(find.text('Wallet card'), findsNothing);
    await tester.tap(find.text('Salary'));
    await tester.pump();
    expect(h.chosen, ['salary']);
    expect(find.text('How did it reach you?'), findsOneWidget);
  });

  testWidgets('an unclear kind asks first and can be switched by chip', (
    tester,
  ) async {
    final h = _Harness(draftOf('got 500 from amazon'));
    await show(tester, h);
    expect(
      find.text('Is this money you received, or a refund?'),
      findsOneWidget,
    );
    // The kind chips let the user fix it directly too.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Refund'));
    await tester.pump();
    expect(h.editor.type, VoiceActionType.refund);
    expect(find.text('Refund details'), findsOneWidget);
    expect(find.text('Refund amount (₹) *', findRichText: true), findsOneWidget);
  });

  testWidgets('a future date blocks saving until the day is picked', (
    tester,
  ) async {
    final h = _Harness(draftOf('spent 500 on fuel on 25 november'));
    await show(tester, h);
    expect(find.textContaining('in the future'), findsOneWidget);
    expect(h.editor.currentIssues(cards), isNotEmpty);
    h.editor.dateConfirmed = true;
    expect(
      h.editor.currentIssues(cards).where((i) => i.contains('future')),
      isEmpty,
    );
  });

  testWidgets('leftover numbers are shown, not dropped', (tester) async {
    final h = _Harness(draftOf('paid 500 to account 123456789012'));
    await show(tester, h);
    expect(find.textContaining('I also heard 123456789012'), findsOneWidget);
  });

  testWidgets('"fill in below" leaves the question and moves on', (
    tester,
  ) async {
    final h = _Harness(draftOf('received 5000 from Rahul'));
    await show(tester, h);
    await tester.tap(find.text('Fill in below'));
    await tester.pump();
    expect(h.skipped, 1);
    expect(find.text('How did it reach you?'), findsOneWidget);
    await tester.tap(find.text('Fill in below'));
    await tester.pump();
    // Two questions is the limit; the form is the rest.
    expect(find.byType(ActionChip), findsNothing);
    expect(find.text('Fill in below'), findsNothing);
  });

  testWidgets('points redemption shows points and needs a card', (
    tester,
  ) async {
    final h = _Harness(draftOf('redeemed 5000 points on my axis atlas card'));
    await show(tester, h);
    expect(find.text('Points redemption details'), findsOneWidget);
    expect(find.text('Points *', findRichText: true), findsOneWidget);
  });
}
