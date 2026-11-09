import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/router.dart' show AppRoute;
import 'package:pandapay/features/voice/answers/voice_answer.dart';
import 'package:pandapay/features/voice/answers/voice_answer_card.dart';
import 'package:pandapay/features/voice/answers/voice_answer_service.dart'
    show routeFor;

VoiceAnswer sample({String? coverage}) => VoiceAnswer(
  title: 'Dining · this month',
  headline: '₹4,200',
  comparison: '₹300 more than last month (8%)',
  rows: const [
    AnswerRow('Dining', '₹4,200', detail: '9 transactions'),
    AnswerRow('Groceries', '₹3,000', detail: '7 transactions'),
  ],
  evidence:
      '16 transactions, 1 Nov to 30 Nov. Same figures as the Spending screen.',
  coverageNote: coverage,
  actions: [
    AnswerAction(
      AnswerActionKind.showTransactions,
      'Show transactions',
      from: DateTime(2026, 11, 1),
      to: DateTime(2026, 11, 30),
      categoryId: 'dining-id',
      categoryLabel: 'Dining',
    ),
    const AnswerAction(AnswerActionKind.spendTrends, 'Open Spending trends'),
  ],
  spoken: 'You spent ₹4,200 on dining this month.',
);

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('shows the number, comparison, rows, evidence and buttons', (
    tester,
  ) async {
    final taps = <AnswerActionKind>[];
    var again = 0;
    await tester.pumpWidget(
      host(
        VoiceAnswerCard(
          answer: sample(),
          onAction: (a) => taps.add(a.kind),
          onAskAnother: () => again++,
        ),
      ),
    );
    expect(find.text('Dining · this month'), findsOneWidget);
    expect(find.text('₹4,200'), findsWidgets);
    expect(find.text('₹300 more than last month (8%)'), findsOneWidget);
    expect(find.text('Groceries'), findsOneWidget);
    expect(
      find.textContaining('Same figures as the Spending screen'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);

    await tester.tap(find.text('Show transactions'));
    await tester.tap(find.text('Open Spending trends'));
    await tester.tap(find.text('Ask or add something else'));
    expect(taps, [
      AnswerActionKind.showTransactions,
      AnswerActionKind.spendTrends,
    ]);
    expect(again, 1);
  });

  testWidgets('a gap in the data is called out', (tester) async {
    await tester.pumpWidget(
      host(
        VoiceAnswerCard(
          answer: sample(
            coverage:
                'History on this phone starts Thu 5 Nov, so earlier spending isn’t included.',
          ),
          onAction: (_) {},
          onAskAnother: () {},
        ),
      ),
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.textContaining('History on this phone starts'), findsOneWidget);
  });

  testWidgets('a plain message has no number and can still offer buttons', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        VoiceAnswerCard(
          answer: VoiceAnswer.message(
            'I haven’t found a bill for Amex on this phone yet.',
            status: AnswerStatus.noData,
            actions: const [
              AnswerAction(AnswerActionKind.paymentsDue, 'Open Payments due'),
            ],
          ),
          onAction: (_) {},
          onAskAnother: () {},
        ),
      ),
    );
    expect(find.text('Panda'), findsOneWidget);
    expect(find.textContaining('haven’t found a bill'), findsOneWidget);
    expect(find.text('Open Payments due'), findsOneWidget);
  });

  testWidgets('the speaker button reads aloud and stops', (tester) async {
    var toggles = 0;
    await tester.pumpWidget(
      host(
        VoiceAnswerCard(
          answer: sample(),
          onAction: (_) {},
          onAskAnother: () {},
          spoken: false,
          onToggleSpeech: () => toggles++,
        ),
      ),
    );
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.volume_up_rounded));
    expect(toggles, 1);
  });

  group('buttons lead to the right screens', () {
    test('show transactions carries the same days and category', () {
      final uri = Uri.parse(routeFor(sample().actions.first));
      expect(uri.path, AppRoute.activity);
      expect(uri.queryParameters, {
        'category': 'dining-id',
        'categoryLabel': 'Dining',
        'from': '2026-11-01',
        'to': '2026-11-30',
        'spendOnly': 'true',
      });
    });

    test('a merchant search and money in', () {
      final uri = Uri.parse(
        routeFor(
          AnswerAction(
            AnswerActionKind.showTransactions,
            'Show transactions',
            from: DateTime(2026, 11, 1),
            to: DateTime(2026, 11, 30),
            query: 'Swiggy Instamart',
            spendOnly: false,
          ),
        ),
      );
      expect(uri.queryParameters['q'], 'Swiggy Instamart');
      expect(uri.queryParameters.containsKey('spendOnly'), isFalse);
    });

    test('the other screens', () {
      String r(AnswerActionKind k) => routeFor(AnswerAction(k, ''));
      expect(r(AnswerActionKind.spendTrends), AppRoute.spendTrends);
      expect(r(AnswerActionKind.paymentsDue), AppRoute.paymentsGroup);
      expect(r(AnswerActionKind.caps), AppRoute.caps);
      expect(r(AnswerActionKind.milestones), AppRoute.milestones);
      expect(r(AnswerActionKind.wallet), AppRoute.cards);
      expect(r(AnswerActionKind.home), AppRoute.home);
      expect(r(AnswerActionKind.pointsExpiry), AppRoute.pointsExpiry);
    });
  });
}
